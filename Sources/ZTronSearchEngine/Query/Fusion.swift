import Foundation

/// A document as a retrieval channel ranked it.
struct RankedDocument: Sendable, Hashable {
    let id: SearchableID
    let rawKind: String
    let updatedAt: Date?
    let score: Double
}

/// The channels that returned a document, as one byte: fusion touches hundreds of documents per
/// snapshot and only the twenty that become hits need a real set.
struct ChannelMask: Sendable, Hashable, ExpressibleByArrayLiteral {
    private(set) var bits: UInt8 = 0

    init() {}

    init(arrayLiteral elements: SearchChannel...) {
        for element in elements { insert(element) }
    }

    @inline(__always)
    private static func bit(_ channel: SearchChannel) -> UInt8 {
        switch channel {
        case .lexical: return 1
        case .fuzzy: return 2
        case .semantic: return 4
        case .rerank: return 8
        }
    }

    @inline(__always)
    mutating func insert(_ channel: SearchChannel) {
        bits |= Self.bit(channel)
    }

    func contains(_ channel: SearchChannel) -> Bool {
        bits & Self.bit(channel) != 0
    }

    var set: Set<SearchChannel> {
        var result = Set<SearchChannel>()
        for channel in SearchChannel.allCases where contains(channel) { result.insert(channel) }
        return result
    }
}

/// A document after fusion: one score, and the channels that returned it.
struct FusedDocument: Sendable, Hashable {
    let id: SearchableID
    let rawKind: String
    let updatedAt: Date?
    var score: Double
    var channels: ChannelMask
}

/// Weighted Reciprocal Rank Fusion (specification section 8).
///
///     s(d) = sum over channels c of  w_c / (k + r_c(d))
///
/// `r_c(d)` is the 1-based rank of `d` in channel `c`; a channel that did not return `d`
/// contributes 0. Raw channel scores are never added.
enum RankFusion {
    struct Channel {
        let channel: SearchChannel
        let weight: Double
        let documents: [RankedDocument]
    }

    static func fuse(_ channels: [Channel], k: Double, entriesPerChannel: Int) -> [FusedDocument] {
        let total = channels.reduce(0) { $0 + min($1.documents.count, entriesPerChannel) }
        var fused: [FusedDocument] = []
        fused.reserveCapacity(total)
        // Where each id already sits in `fused`: an open-addressing table over a cheap hash of
        // the id. A few hundred lookups per snapshot are most of what fusion costs.
        var capacity = 16
        while capacity < total * 2 { capacity <<= 1 }
        var slots = [Int32](repeating: 0, count: capacity)
        let mask = capacity - 1

        for channel in channels where channel.weight > 0 {
            for (index, document) in channel.documents.prefix(entriesPerChannel).enumerated() {
                let contribution = channel.weight / (k + Double(index + 1))
                var slot = Int(truncatingIfNeeded: fnv1a(document.id.rawValue)) & mask
                var found = -1
                while slots[slot] != 0 {
                    let position = Int(slots[slot]) - 1
                    if fused[position].id == document.id {
                        found = position
                        break
                    }
                    slot = (slot + 1) & mask
                }
                if found >= 0 {
                    fused[found].score += contribution
                    fused[found].channels.insert(channel.channel)
                } else {
                    slots[slot] = Int32(fused.count + 1)
                    fused.append(FusedDocument(
                        id: document.id, rawKind: document.rawKind, updatedAt: document.updatedAt,
                        score: contribution, channels: [channel.channel]
                    ))
                }
            }
        }
        return fused
    }

    /// The order of every result list: best score first, ties broken by id so the order never
    /// depends on how a strategy happens to store its documents.
    @inline(__always)
    static func precedes(_ lhsScore: Double, _ lhsID: SearchableID, _ rhsScore: Double, _ rhsID: SearchableID) -> Bool {
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhsID < rhsID
    }
}

/// Everything the engine weighs after fusion: kind boosts, the injected signals and the
/// editorial policy (specification section 8).
struct ResultRanker: Sendable {
    let profile: RankingProfile
    let signals: SignalProviders
    let now: Date
    let reporter: DiagnosticReporter

    /// Boosts, suppresses and orders fused documents; keeps at most `limit`.
    ///
    /// Kind boosts and user affinity are multiplicative and clamped to 0.5...1.5, so they only
    /// reorder what survived the hard constraints. Popularity and freshness add a bounded share
    /// of the top fused score. Pins are applied separately, after any rerank.
    func rank(_ fused: [FusedDocument], limit: Int) -> [FusedDocument] {
        guard !fused.isEmpty else { return [] }
        var documents = fused
        let top = documents.reduce(0) { max($0, $1.score) }

        // Editorial suppressions.
        if profile.editorial.appliesSuppressions, let decisions = editorialDecisions(for: documents) {
            var kept: [FusedDocument] = []
            kept.reserveCapacity(documents.count)
            for (index, document) in documents.enumerated() where decisions[index] != .suppress {
                kept.append(document)
            }
            documents = kept
            guard !documents.isEmpty else { return [] }
        }

        let affinities = affinities(for: documents)
        let popularity = popularityShares(for: documents)
        let freshnessSpec = profile.freshness.flatMap { spec -> (weight: Double, halfLife: Double)? in
            guard let halfLife = spec.halfLifeDays, halfLife > 0, spec.weight > 0 else { return nil }
            return (spec.weight, halfLife)
        }

        // A list holds a handful of kinds: each boost is looked up once.
        let boostsKinds = !profile.kindBoosts.isEmpty
        var lastKind = ""
        var lastBoost = 1.0
        for index in documents.indices {
            var score = documents[index].score
            if boostsKinds {
                if documents[index].rawKind != lastKind {
                    lastKind = documents[index].rawKind
                    lastBoost = profile.kindBoost(for: lastKind)
                }
                score *= lastBoost
            }
            if let affinities {
                score *= affinities[index]
            }
            if let popularity {
                score += popularity.weight * top * popularity.shares[index]
            }
            if let freshnessSpec, let updatedAt = documents[index].updatedAt {
                let ageInDays = max(0, now.timeIntervalSince(updatedAt)) / 86_400
                score += freshnessSpec.weight * top * pow(0.5, ageInDays / freshnessSpec.halfLife)
            }
            documents[index].score = score
        }

        // Positions are sorted rather than the documents themselves, which are several words
        // each and would be moved at every swap.
        var order = Array(documents.indices)
        documents.withUnsafeBufferPointer { documents in
            order.sort { lhs, rhs in
                RankFusion.precedes(documents[lhs].score, documents[lhs].id, documents[rhs].score, documents[rhs].id)
            }
        }
        var ranked: [FusedDocument] = []
        ranked.reserveCapacity(min(limit, order.count))
        for position in order.prefix(limit) { ranked.append(documents[position]) }
        return ranked
    }

    /// Moves editorially pinned documents to the top, lowest pin rank first. Limited per query so
    /// pins cannot hide organic results.
    func applyingPins(to documents: [FusedDocument]) -> [FusedDocument] {
        let maximum = profile.editorial.maximumPins
        guard maximum > 0, !documents.isEmpty, let decisions = editorialDecisions(for: documents) else { return documents }
        var pinned: [(rank: Int, position: Int)] = []
        for (position, decision) in decisions.enumerated() {
            if case .pin(let rank)? = decision { pinned.append((rank, position)) }
        }
        guard !pinned.isEmpty else { return documents }
        pinned.sort { $0.rank == $1.rank ? $0.position < $1.position : $0.rank < $1.rank }
        let chosen = pinned.prefix(maximum)
        let chosenPositions = Set(chosen.map(\.position))
        var result: [FusedDocument] = []
        result.reserveCapacity(documents.count)
        // A pinned document outranks everything, so its score may not be lower than the head's.
        let headScore = documents[0].score
        for pin in chosen {
            var document = documents[pin.position]
            document.score = max(document.score, headScore)
            result.append(document)
        }
        for (position, document) in documents.enumerated() where !chosenPositions.contains(position) {
            result.append(document)
        }
        return result
    }

    // MARK: Providers

    private func editorialDecisions(for documents: [FusedDocument]) -> [EditorialDecision?]? {
        guard let provider = signals.editorial else { return nil }
        do {
            return try documents.map { try provider.decision(for: $0.id) }
        } catch {
            reporter.report(.signalProviderFailed(signal: "editorial"))
            return nil
        }
    }

    private func affinities(for documents: [FusedDocument]) -> [Double]? {
        guard let provider = signals.personalization else { return nil }
        do {
            return try documents.map { document in
                guard let affinity = try provider.affinity(for: document.id), affinity.isFinite else { return 1 }
                return min(max(affinity, RankingProfile.boostRange.lowerBound), RankingProfile.boostRange.upperBound)
            }
        } catch {
            reporter.report(.signalProviderFailed(signal: "personalization"))
            return nil
        }
    }

    /// log1p-scaled popularity, normalized by the most popular document of the list, with the
    /// weight capped at 15% of the top fused score.
    private func popularityShares(for documents: [FusedDocument]) -> (weight: Double, shares: [Double])? {
        guard let spec = profile.popularity, spec.weight > 0, let provider = signals.popularity else { return nil }
        do {
            let raw = try documents.map { document -> Double in
                guard let value = try provider.popularity(for: document.id), value.isFinite, value > 0 else { return 0 }
                return log1p(value)
            }
            let maximum = raw.reduce(0, max)
            guard maximum > 0 else { return nil }
            return (min(spec.weight, SignalSpec.maximumPopularityWeight), raw.map { $0 / maximum })
        } catch {
            reporter.report(.signalProviderFailed(signal: "popularity"))
            return nil
        }
    }
}
