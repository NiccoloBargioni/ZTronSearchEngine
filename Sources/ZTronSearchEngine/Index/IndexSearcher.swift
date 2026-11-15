import Foundation

/// One segment of a ``LexicalIndex`` with what has been deleted from it since it was written.
struct IndexEntry: Sendable {
    /// Names the entry inside its index, so a merge that ran aside can tell whether the
    /// segments it read are still the ones in place.
    var id: UInt64 = 0
    var segment: IndexSegment
    /// Deleted document ordinals.
    var tombstones: Bitset
    var liveCount: Int
    /// Per term ordinal: deleted documents that contained the term. Subtracted from the stored
    /// document frequency, so statistics stay exactly those of the live documents. Empty until
    /// the first deletion.
    var removedDocumentFrequency: [UInt32] = []
    /// Field lengths of the deleted documents.
    var removedFieldLengths = [UInt64](repeating: 0, count: SearchField.count)

    init(segment: IndexSegment) {
        self.segment = segment
        tombstones = Bitset()
        liveCount = segment.documentCount
    }

    @inline(__always)
    func documentFrequency(_ term: Int, in view: SegmentView) -> Int {
        let stored = view.documentFrequency(term)
        return removedDocumentFrequency.isEmpty ? stored : stored - Int(removedDocumentFrequency[term])
    }

    /// Marks a document as deleted and takes it out of the statistics: its field lengths and
    /// one count for each term it held, read from its stored term list.
    mutating func delete(_ ordinal: Int) {
        guard tombstones.insert(ordinal) else { return }
        liveCount -= 1
        let segment = segment
        if removedDocumentFrequency.isEmpty {
            removedDocumentFrequency = [UInt32](repeating: 0, count: segment.termCount)
        }
        segment.withView { view in
            for field in 0..<SearchField.count {
                removedFieldLengths[field] += UInt64(view.fieldLength(field: field, document: ordinal))
            }
            view.forEachTerm(of: ordinal) { term in
                removedDocumentFrequency[term] += 1
            }
        }
    }
}

/// Where a term's postings live: which segment, which term ordinal.
struct TermLocation: Sendable, Hashable {
    let segment: Int
    let term: Int
}

/// What the service asks the lexical index.
struct LexicalRequest: Sendable {
    var parsed: ParsedQuery
    var constraints: HardConstraints
    var profile: RankingProfile
    var limits: SearchLimits
    var fuzzyEnabled: Bool
    var minimumFuzzyLength: Int
}

/// Where the time of one lexical search went, in seconds. The latency table of specification
/// section 15.1 budgets these stages one by one.
struct LexicalTimings: Sendable, Hashable {
    /// Exact lookups and prefix expansion of the final token.
    var prefixLookup: TimeInterval = 0
    /// Trigram candidate generation and bounded edit-distance verification.
    var fuzzyExpansion: TimeInterval = 0
    /// Candidate admission and BM25F scoring.
    var scoring: TimeInterval = 0
    /// Sorting, phrase verification and building the two ranked lists.
    var ranking: TimeInterval = 0
    /// Documents that were scored.
    var candidates = 0
}

/// The two ranked lists of the lexical phase and what is needed to explain them.
struct LexicalResponse: Sendable {
    var lexical: [RankedDocument] = []
    var fuzzy: [RankedDocument] = []
    /// The fuzzy channel ran for this query.
    var fuzzyRan = false
    /// Every term that can match, with its weight.
    var matchTerms: [String: Double] = [:]
    var phrases: [[String]] = []
    var timings = LexicalTimings()
}

/// The vocabulary of the indexed strategy: sorted terms in every segment, with a trigram index
/// for typo candidates.
struct IndexTermSource: TermSource {
    typealias Handle = [TermLocation]

    let entries: [IndexEntry]
    let views: [SegmentView]
    /// Counters reused from query to query; a source without them allocates its own.
    var scratch: FuzzyScratch?

    func exact(_ term: String) -> TermReference<[TermLocation]>? {
        var total = 0
        var locations: [TermLocation] = []
        for (index, view) in views.enumerated() {
            guard let ordinal = view.find(term) else { continue }
            let frequency = entries[index].documentFrequency(ordinal, in: view)
            if frequency > 0 {
                total += frequency
                locations.append(TermLocation(segment: index, term: ordinal))
            }
        }
        return total > 0 ? TermReference(term: term, documentFrequency: total, handle: locations) : nil
    }

    func prefixExpansions(of prefix: String, limit: Int) -> [TermReference<[TermLocation]>] {
        struct Candidate {
            let frequency: Int
            let locations: [TermLocation]
        }
        let prefixLength = prefix.utf8.count
        var cursors = views.map { $0.prefixRange(prefix) }
        // Terms are visited in ascending byte order and ties keep their arrival order, so the
        // selection is by document frequency, then by term.
        var selector = TopSelector<Candidate>(limit: limit) { $0.frequency > $1.frequency }
        var holders: [Int] = []
        while true {
            holders.removeAll(keepingCapacity: true)
            var smallest: UnsafeRawBufferPointer?
            for index in views.indices where !cursors[index].isEmpty {
                let candidate = views[index].termBuffer(cursors[index].lowerBound)
                guard let current = smallest else {
                    smallest = candidate
                    holders.append(index)
                    continue
                }
                let order = Self.compare(candidate, current)
                if order < 0 {
                    smallest = candidate
                    holders.removeAll(keepingCapacity: true)
                    holders.append(index)
                } else if order == 0 {
                    holders.append(index)
                }
            }
            guard let bytes = smallest else { break }
            if bytes.count > prefixLength && !Self.isExactOnly(bytes) {
                var frequency = 0
                for index in holders {
                    frequency += max(0, entries[index].documentFrequency(cursors[index].lowerBound, in: views[index]))
                }
                if frequency > 0 && selector.accepts(Candidate(frequency: frequency, locations: [])) {
                    var locations: [TermLocation] = []
                    for index in holders where entries[index].documentFrequency(cursors[index].lowerBound, in: views[index]) > 0 {
                        locations.append(TermLocation(segment: index, term: cursors[index].lowerBound))
                    }
                    selector.insert(Candidate(frequency: frequency, locations: locations))
                }
            }
            for index in holders {
                cursors[index] = (cursors[index].lowerBound + 1)..<cursors[index].upperBound
            }
        }
        return selector.elements.map { candidate in
            let first = candidate.locations[0]
            return TermReference(term: views[first.segment].termString(first.term), documentFrequency: candidate.frequency, handle: candidate.locations)
        }
    }

    func fuzzyCandidates(for term: String, maximumEdits: Int, limit: Int) -> [(reference: TermReference<[TermLocation]>, edits: Int)] {
        let scalars = EditDistance.scalars(term)
        guard maximumEdits > 0, scalars.count >= 2 else { return [] }
        let query = FuzzyQuery(scalars: scalars, maximumEdits: maximumEdits)

        struct Found {
            var edits: Int
            var frequency: Int
            var locations: [TermLocation]
        }
        var found: [String: Found] = [:]
        let scratch = scratch ?? FuzzyScratch()
        for (index, view) in views.enumerated() where view.segment.termCount > 0 && view.segment.trigramCount > 0 {
            let entry = entries[index]
            scratch.forEachCandidate(of: query, in: view, segment: index, segments: views.count) { ordinal, edits in
                let frequency = entry.documentFrequency(ordinal, in: view)
                guard frequency > 0 else { return }
                let candidate = view.termString(ordinal)
                found[candidate, default: Found(edits: edits, frequency: 0, locations: [])].frequency += frequency
                found[candidate]?.locations.append(TermLocation(segment: index, term: ordinal))
            }
        }

        let ranked = found.sorted { lhs, rhs in
            if lhs.value.edits != rhs.value.edits { return lhs.value.edits < rhs.value.edits }
            if lhs.value.frequency != rhs.value.frequency { return lhs.value.frequency > rhs.value.frequency }
            return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        return ranked.prefix(limit).map { element in
            (TermReference(term: element.key, documentFrequency: element.value.frequency, handle: element.value.locations), element.value.edits)
        }
    }

    @inline(__always)
    private static func compare(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Int {
        let common = min(lhs.count, rhs.count)
        if common > 0 {
            let order = memcmp(lhs.baseAddress!, rhs.baseAddress!, common)
            if order != 0 { return Int(order) }
        }
        return lhs.count - rhs.count
    }

    @inline(__always)
    private static func isExactOnly(_ bytes: UnsafeRawBufferPointer) -> Bool {
        ScriptClass.isExactOnly(utf8: bytes)
    }
}

/// A token prepared for typo-candidate generation over any number of segments.
///
/// A term of `n` scalars padded with two sentinels on each side has `n + 2` trigram positions,
/// numbered 0 to `n + 1`. Position 0 holds for the terms that start with the first scalar,
/// position 1 for those that start with the first two, position `n` for those that end with
/// the last two and position `n + 1` for those that end with the last one; the positions in
/// between are trigrams of the term itself. An insertion breaks at most two positions, a
/// deletion or a substitution three, a transposition four.
struct FuzzyQuery {
    let scalars: [UInt32]
    let maximumEdits: Int
    /// UTF-8 of the token, and where each scalar starts in it (one entry more than scalars).
    let utf8: [UInt8]
    let offsets: [Int]
    /// The trigram of every position.
    let keys: [UInt64]
    let pattern: EditPattern?
    /// Which scalars the token contains.
    let signature: UInt64
    let scheme: Scheme

    enum Scheme {
        /// Candidates are split by the edits that reach them, so each part can use the tight
        /// bound of its edits: without a transposition a candidate keeps `threshold` positions
        /// of the token; with one it is a transposed variant of the token, two of them, or one
        /// edit away from a variant and keeps `count - 1` positions of that variant.
        case decomposed(threshold: Int)
        /// Long tokens: the bound that allows every edit to be a transposition is already
        /// strict enough.
        case counted(threshold: Int)
        /// No usable bound: every term is verified.
        case exhaustive
    }

    init(scalars: [UInt32], maximumEdits: Int) {
        self.scalars = scalars
        self.maximumEdits = maximumEdits
        var utf8: [UInt8] = []
        var offsets: [Int] = [0]
        for scalar in scalars {
            if let unicode = Unicode.Scalar(scalar) {
                utf8.append(contentsOf: Array(String(Character(unicode)).utf8))
            }
            offsets.append(utf8.count)
        }
        self.utf8 = utf8
        self.offsets = offsets
        var padded: [UInt32] = [Trigram.pad, Trigram.pad]
        padded.append(contentsOf: scalars)
        padded.append(Trigram.pad)
        padded.append(Trigram.pad)
        keys = (0..<(padded.count - 2)).map { Trigram.key(padded[$0], padded[$0 + 1], padded[$0 + 2]) }
        pattern = EditPattern(scalars)
        signature = TermSignature.of(scalars)

        let count = scalars.count
        let generic = count + 2 - 4 * maximumEdits
        // Without a transposition one edit breaks at most three positions.
        let plain = count + 2 - 3 * maximumEdits
        if count > 61 || maximumEdits > 2 {
            // Positions no longer fit one word next to the bookkeeping bit, or the edit budget
            // is one the engine never asks for.
            scheme = generic >= 3 ? .counted(threshold: generic) : .exhaustive
        } else if generic >= 4 {
            scheme = .counted(threshold: generic)
        } else if plain >= 2 {
            // Every length the channel corrects lands here or above: three to five scalars
            // with one edit, six to nine with two.
            scheme = .decomposed(threshold: plain)
        } else {
            scheme = .exhaustive
        }
    }

    var count: Int { scalars.count }

    /// The optimal-string-alignment distance to a stored term, when within the edit budget.
    func distance(toUTF8 bytes: UnsafeRawBufferPointer, table: inout EditDistance.Scratch, buffer: inout [UInt32]) -> Int? {
        if let pattern {
            return pattern.distance(toUTF8: bytes, maximum: maximumEdits)
        }
        buffer.removeAll(keepingCapacity: true)
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars { buffer.append(scalar.value) }
        return EditDistance.bounded(scalars, buffer, maximum: maximumEdits, scratch: &table)
    }
}

/// Reusable memory of the fuzzy channel, and the candidate generator that works in it.
/// Confined to the index actor that owns it.
final class FuzzyScratch {
    /// Per segment and per term: the positions of the token the term holds, plus one bit that
    /// marks a term as already verified. All zero between two tokens.
    private var masks: [[UInt64]] = []
    /// Per segment and per term: a small counter. All zero between two uses.
    private var counters: [[UInt8]] = []
    private var touched: [Int32] = []
    private var counted: [Int32] = []
    private var variant: [UInt8] = []
    private var variantOffsets: [Int] = []
    private var variantScalars: [UInt32] = []
    private var table = EditDistance.Scratch()
    private var buffer: [UInt32] = []

    private static let verified: UInt64 = 1 << 63

    /// How candidates are found.
    enum Strategy {
        /// Trigram lists while they are short, the signature scan otherwise.
        case automatic
        /// Always the trigram lists. For tests of that path.
        case lists
        /// Always the signature scan. For tests of that path.
        case scan
    }

    let strategy: Strategy

    init(strategy: Strategy = .automatic) {
        self.strategy = strategy
    }

    /// Calls `body` with the ordinal and the distance of every term of the segment within the
    /// edit budget of the token, the token itself and exact-only terms excluded. No term is
    /// reported twice.
    func forEachCandidate(of query: FuzzyQuery, in view: SegmentView, segment: Int, segments: Int, _ body: (Int, Int) -> Void) {
        if masks.count != segments {
            masks = [[UInt64]](repeating: [], count: segments)
            counters = [[UInt8]](repeating: [], count: segments)
        }
        let termCount = view.segment.termCount
        var masks: [UInt64] = []
        swap(&masks, &self.masks[segment])
        if masks.count != termCount { masks = [UInt64](repeating: 0, count: termCount) }
        var counters: [UInt8] = []
        swap(&counters, &self.counters[segment])
        if counters.count != termCount { counters = [UInt8](repeating: 0, count: termCount) }
        touched.removeAll(keepingCapacity: true)

        masks.withUnsafeMutableBufferPointer { masks in
            counters.withUnsafeMutableBufferPointer { counters in
                query.utf8.withUnsafeBytes { utf8 in
                    generate(query, utf8: utf8, view: view, masks: masks, counters: counters, body)
                }
            }
            for entry in touched { masks[Int(entry)] = 0 }
        }
        swap(&masks, &self.masks[segment])
        swap(&counters, &self.counters[segment])
    }

    private func generate(
        _ query: FuzzyQuery,
        utf8: UnsafeRawBufferPointer,
        view: SegmentView,
        masks: UnsafeMutableBufferPointer<UInt64>,
        counters: UnsafeMutableBufferPointer<UInt8>,
        _ body: (Int, Int) -> Void
    ) {
        let count = query.count
        let budget = query.maximumEdits
        let termCount = view.segment.termCount

        /// `false` for a term that cannot be within the budget, whatever positions it holds.
        @inline(__always) func isPlausible(_ ordinal: Int) -> Bool {
            TermSignature.mayBeWithin(budget, query.signature, view.signature(ordinal))
        }

        /// Verifies a term once and reports it when it is within the budget.
        func verify(_ ordinal: Int) {
            let state = masks[ordinal]
            if state & Self.verified != 0 { return }
            if state == 0 { touched.append(Int32(truncatingIfNeeded: ordinal)) }
            masks[ordinal] = state | Self.verified
            // Terms that differ by too many scalars are settled without reading them.
            guard TermSignature.mayBeWithin(budget, query.signature, view.signature(ordinal)) else { return }
            let bytes = view.termBuffer(ordinal)
            // Each scalar takes one to four bytes: a cheap bound before any decoding.
            if bytes.count < count - budget || bytes.count > 4 * (count + budget) { return }
            guard let edits = query.distance(toUTF8: bytes, table: &table, buffer: &buffer), edits > 0 else { return }
            if ScriptClass.isExactOnly(utf8: bytes) { return }
            body(ordinal, edits)
        }

        /// Adds one to the counter of every term that holds a trigram.
        func tally(_ key: UInt64) {
            guard let range = view.trigramRange(key) else { return }
            var offset = range.start
            let end = range.start + range.length
            var ordinal = 0
            while offset < end {
                ordinal += Int(readVarint(view.trigramPostings, &offset))
                let seen = counters[ordinal]
                if seen == 0 { counted.append(Int32(truncatingIfNeeded: ordinal)) }
                if seen < UInt8.max { counters[ordinal] = seen + 1 }
            }
        }

        func ends(_ ordinal: Int, with suffix: UnsafeRawBufferPointer) -> Bool {
            let bytes = view.termBuffer(ordinal)
            guard bytes.count >= suffix.count, suffix.count > 0 else { return false }
            return memcmp(bytes.baseAddress! + (bytes.count - suffix.count), suffix.baseAddress!, suffix.count) == 0
        }

        /// Weighs every term of the segment by its signature alone and verifies the plausible
        /// ones. One word per term, read in order: the cost depends on the size of the
        /// vocabulary and on nothing else.
        func scanVocabulary() {
            for ordinal in 0..<termCount where isPlausible(ordinal) {
                verify(ordinal)
            }
        }

        let threshold: Int
        let isDecomposed: Bool
        switch query.scheme {
        case .exhaustive:
            scanVocabulary()
            return
        case .counted(let value) where count > 61:
            // Too long for one word of positions: plain counters over every position.
            counted.removeAll(keepingCapacity: true)
            for key in query.keys { tally(key) }
            for entry in counted {
                let ordinal = Int(entry)
                let seen = Int(counters[ordinal])
                counters[ordinal] = 0
                if seen >= value { verify(ordinal) }
            }
            return
        case .counted(let value):
            threshold = value
            isDecomposed = false
        case .decomposed(let value):
            threshold = value
            isDecomposed = true
        }

        // Reading the trigram lists pays while they are short. A token made of the commonest
        // trigrams of a large vocabulary would read more list entries than the vocabulary has
        // terms; scanning the signatures is cheaper then, and bounds the cost of any token.
        let scans: Bool
        switch strategy {
        case .lists:
            scans = false
        case .scan:
            scans = true
        case .automatic:
            var listBytes = 0
            for position in 2...count {
                if let range = view.trigramRange(query.keys[position]) { listBytes += range.length }
            }
            scans = listBytes * 5 > termCount * 3
        }
        if scans {
            scanVocabulary()
            return
        }

        // The token's own positions. Positions 2 to n are read from the trigram index.
        let lastBit: UInt64 = 1 << UInt64(count + 1)
        for position in 2...count {
            guard let range = view.trigramRange(query.keys[position]) else { continue }
            let bit: UInt64 = 1 << UInt64(position)
            var offset = range.start
            let end = range.start + range.length
            var ordinal = 0
            while offset < end {
                ordinal += Int(readVarint(view.trigramPostings, &offset))
                let state = masks[ordinal]
                if state == 0 { touched.append(Int32(truncatingIfNeeded: ordinal)) }
                masks[ordinal] = state | bit
            }
        }
        // Position 1: the terms that start with the first two scalars are one run of the
        // sorted vocabulary. Position 0, the run of the first scalar, and position n + 1, the
        // last scalar, are read off a term when it is weighed: their lists are the longest of
        // all and say the least.
        let firstTwo = view.prefixRange(utf8: UnsafeRawBufferPointer(rebasing: utf8[0..<query.offsets[2]]))
        for ordinal in firstTwo {
            let state = masks[ordinal]
            if state == 0 { touched.append(Int32(truncatingIfNeeded: ordinal)) }
            masks[ordinal] = state | 2
        }
        let first = view.prefixRange(utf8: UnsafeRawBufferPointer(rebasing: utf8[0..<query.offsets[1]]))
        let lastScalar = UnsafeRawBufferPointer(rebasing: utf8[query.offsets[count - 1]..<query.offsets[count]])
        if threshold <= 2 {
            // Two positions can be the first and the last scalar alone, which nothing above reaches.
            for ordinal in first where masks[ordinal] == 0 && isPlausible(ordinal) && ends(ordinal, with: lastScalar) {
                touched.append(Int32(truncatingIfNeeded: ordinal))
                masks[ordinal] = 1 | lastBit
            }
        }

        /// The positions of the token a term holds, the two that are read off the term included.
        func positions(of ordinal: Int) -> UInt64 {
            var held = masks[ordinal] & ~Self.verified
            if first.contains(ordinal) { held |= 1 }
            if held & lastBit == 0, ends(ordinal, with: lastScalar) { held |= lastBit }
            return held
        }

        // Candidates no transposition is needed for.
        let reached = touched.count
        for index in 0..<reached {
            let ordinal = Int(touched[index])
            let held = masks[ordinal] & ~Self.verified
            if held.nonzeroBitCount + 2 < threshold || !isPlausible(ordinal) { continue }
            if positions(of: ordinal).nonzeroBitCount >= threshold { verify(ordinal) }
        }
        guard isDecomposed else { return }

        // Candidates that need a transposition: the token with two neighbours swapped, the
        // same with a second pair swapped, and the terms one edit away from a swapped token.
        let allPositions: UInt64 = (1 << UInt64(count + 2)) - 1
        for pair in 0..<(count - 1) where query.scalars[pair] != query.scalars[pair + 1] {
            makeVariant(of: query, swapping: pair)
            let found = variant.withUnsafeBytes { view.find(utf8: $0) }
            if let found { verify(found) }
            guard budget >= 2 else { continue }

            if pair + 2 < count - 1 {
                for second in (pair + 2)..<(count - 1) where query.scalars[second] != query.scalars[second + 1] {
                    swapRuns(at: second)
                    let twice = variant.withUnsafeBytes { view.find(utf8: $0) }
                    if let twice { verify(twice) }
                    swapRuns(at: second)
                }
            }

            // One more edit keeps count - 1 of the variant's positions. The swap changed
            // positions pair to pair + 3; every other position is the token's own.
            let unaffected = allPositions & ~(UInt64(0b1111) << UInt64(pair))
            counted.removeAll(keepingCapacity: true)
            for position in max(pair, 2)...min(pair + 3, count) {
                tally(Trigram.key(variantScalars[position], variantScalars[position + 1], variantScalars[position + 2]))
            }
            var newFirst: Range<Int>?
            variant.withUnsafeBytes { bytes in
                if pair <= 1 {
                    for ordinal in view.prefixRange(utf8: UnsafeRawBufferPointer(rebasing: bytes[0..<variantOffsets[2]])) {
                        let seen = counters[ordinal]
                        if seen == 0 { counted.append(Int32(truncatingIfNeeded: ordinal)) }
                        counters[ordinal] = seen + 1
                    }
                }
                if pair == 0 {
                    newFirst = view.prefixRange(utf8: UnsafeRawBufferPointer(rebasing: bytes[0..<variantOffsets[1]]))
                }
                let newLast = UnsafeRawBufferPointer(rebasing: bytes[variantOffsets[count - 1]..<variantOffsets[count]])
                for entry in counted {
                    let ordinal = Int(entry)
                    var held = Int(counters[ordinal])
                    counters[ordinal] = 0
                    guard isPlausible(ordinal) else { continue }
                    held += (positions(of: ordinal) & unaffected).nonzeroBitCount
                    if let newFirst, newFirst.contains(ordinal) { held += 1 }
                    if pair == count - 2, ends(ordinal, with: newLast) { held += 1 }
                    if held >= count - 1 { verify(ordinal) }
                }
            }
        }
    }

    /// Writes the token with scalars `pair` and `pair + 1` swapped into `variant`, with the
    /// byte offsets of its scalars and its padded scalars.
    private func makeVariant(of query: FuzzyQuery, swapping pair: Int) {
        variantScalars.removeAll(keepingCapacity: true)
        variantScalars.append(Trigram.pad)
        variantScalars.append(Trigram.pad)
        variantScalars.append(contentsOf: query.scalars)
        variantScalars.append(Trigram.pad)
        variantScalars.append(Trigram.pad)
        variantScalars.swapAt(pair + 2, pair + 3)
        variant.removeAll(keepingCapacity: true)
        variant.append(contentsOf: query.utf8)
        variantOffsets.removeAll(keepingCapacity: true)
        variantOffsets.append(contentsOf: query.offsets)
        swapRuns(at: pair)
    }

    /// Swaps two neighbouring scalars of `variant` in place.
    private func swapRuns(at pair: Int) {
        let start = variantOffsets[pair]
        let middle = variantOffsets[pair + 1]
        let end = variantOffsets[pair + 2]
        let left = Array(variant[start..<middle])
        let right = Array(variant[middle..<end])
        variant.replaceSubrange(start..<end, with: right + left)
        variantOffsets[pair + 1] = start + right.count
    }
}

/// Scores a planned query against the segments of an index.
///
/// The searcher owns reusable scratch memory, so it lives inside the index actor.
struct IndexSearcher {
    private struct Slot {
        var segment: Int32 = 0
        var ordinal: Int32 = 0
        var lexical = 0.0
        var fuzzy = 0.0
        var clauseLexical = 0.0
        var clauseFuzzy = 0.0
        var termFrequency = 0.0
        var alternativeEpoch: Int32 = -1
        var clauseEpoch: Int32 = -1
        var matchedLexical: UInt64 = 0
        var matchedFuzzy: UInt64 = 0
        /// 0 = not checked, 1 = contains every phrase, 2 = does not.
        var phraseState: UInt8 = 0
    }

    private static let none: Int32 = -1
    private static let rejected: Int32 = -2

    /// Per segment: document ordinal to slot, `none` or `rejected`. All `none` between queries.
    private var slotIndex: [[Int32]] = []
    /// Preallocated to the candidate limit; the first `slotCount` are in use.
    private var slots: [Slot] = []
    private var slotCount = 0
    private var rejectedDocuments: [(segment: Int, ordinal: Int)] = []
    /// Per segment: the highest ordinal that holds a candidate, once admission is closed.
    private var highestCandidate: [Int] = []
    private var alternativeTouched: [Int32] = []
    private var clauseTouched: [Int32] = []
    private let fuzzyScratch = FuzzyScratch()

    mutating func search(
        _ request: LexicalRequest,
        entries: [IndexEntry],
        views: [SegmentView],
        statistics: CorpusStatistics,
        session: TokenizerSession
    ) throws -> LexicalResponse {
        var response = LexicalResponse()
        response.phrases = request.parsed.phrases
        guard statistics.documentCount > 0 else { return response }

        let parameters = ScoringParameters(profile: request.profile, statistics: statistics)
        let source = IndexTermSource(entries: entries, views: views, scratch: fuzzyScratch)
        var planTimings = PlanTimings()
        let plan = QueryPlanner.plan(
            request.parsed, source: source, parameters: parameters, limits: request.limits,
            fuzzyEnabled: request.fuzzyEnabled, minimumFuzzyLength: request.minimumFuzzyLength, timings: &planTimings
        )
        response.matchTerms = plan.matchTerms
        response.fuzzyRan = plan.fuzzyActive
        response.timings.prefixLookup = planTimings.lookup
        response.timings.fuzzyExpansion = planTimings.fuzzy
        guard !plan.isUnsatisfiable else { return response }
        let scoringStart = DispatchTime.now().uptimeNanoseconds

        let limit = request.limits.lexicalCandidates
        prepareScratch(entries, limit: limit)
        defer { resetScratch() }

        let constraints = SegmentConstraints(request.constraints, entries: entries)
        var work = 0

        if plan.isMatchAll {
            // Only hard constraints: every surviving document matches with the same score.
            outer: for (index, entry) in entries.enumerated() {
                for ordinal in 0..<entry.segment.documentCount where !entry.tombstones.contains(ordinal) {
                    work += 1
                    if work >= 1_000 { try Task.checkCancellation(); work = 0 }
                    if slotCount >= limit { break outer }
                    guard constraints.allows(segment: index, ordinal: ordinal, view: views[index]) else { continue }
                    slots[slotCount] = Slot(segment: Int32(index), ordinal: Int32(ordinal), lexical: 1, matchedLexical: 1)
                    slotIndex[index][ordinal] = Int32(slotCount)
                    slotCount += 1
                }
            }
        } else {
            // Bounded work: at most `limit` candidates are scored. When the postings could hold
            // more, candidates are admitted rarest clause first, heaviest field first.
            var admitting = true
            if plan.candidateUpperBound > limit {
                try admitCandidates(plan, entries: entries, views: views, constraints: constraints, limit: limit, work: &work)
                admitting = false
                // Postings are in ordinal order: past the last candidate of a segment there is
                // nothing left to score in any list.
                highestCandidate = [Int](repeating: -1, count: entries.count)
                for position in 0..<slotCount {
                    let segment = Int(slots[position].segment)
                    highestCandidate[segment] = max(highestCandidate[segment], Int(slots[position].ordinal))
                }
            }
            try score(plan, entries: entries, views: views, parameters: parameters, constraints: constraints, admitting: admitting, limit: limit, work: &work)
        }

        let rankingStart = DispatchTime.now().uptimeNanoseconds
        response.timings.scoring = Double(rankingStart - scoringStart) / 1_000_000_000
        response.timings.candidates = slotCount
        defer { response.timings.ranking = Double(DispatchTime.now().uptimeNanoseconds - rankingStart) / 1_000_000_000 }
        let listLimit = request.limits.fusionEntriesPerChannel
        response.lexical = try rankedList(
            fuzzy: false, plan: plan, entries: entries, views: views, limit: listLimit, session: session
        )
        if plan.fuzzyActive {
            response.fuzzy = try rankedList(
                fuzzy: true, plan: plan, entries: entries, views: views, limit: listLimit, session: session
            )
        }
        return response
    }

    // MARK: Candidates

    /// Sizes the scratch for the current segments. A table is reused whenever its size still
    /// fits: every entry is `none` between two queries, whatever segment it served last.
    private mutating func prepareScratch(_ entries: [IndexEntry], limit: Int) {
        if slotIndex.count > entries.count { slotIndex.removeSubrange(entries.count...) }
        while slotIndex.count < entries.count { slotIndex.append([]) }
        for (index, entry) in entries.enumerated() where slotIndex[index].count != entry.segment.documentCount {
            slotIndex[index] = [Int32](repeating: Self.none, count: entry.segment.documentCount)
        }
        if slots.count < limit {
            slots.append(contentsOf: repeatElement(Slot(), count: limit - slots.count))
        }
        slotCount = 0
        rejectedDocuments.removeAll(keepingCapacity: true)
    }

    private mutating func resetScratch() {
        for position in 0..<slotCount {
            slotIndex[Int(slots[position].segment)][Int(slots[position].ordinal)] = Self.none
        }
        for document in rejectedDocuments {
            slotIndex[document.segment][document.ordinal] = Self.none
        }
        slotCount = 0
        rejectedDocuments.removeAll(keepingCapacity: true)
    }

    private mutating func admitCandidates(
        _ plan: QueryPlan<[TermLocation]>,
        entries: [IndexEntry],
        views: [SegmentView],
        constraints: SegmentConstraints,
        limit: Int,
        work: inout Int
    ) throws {
        let order = plan.clauses.indices.sorted { lhs, rhs in
            let left = plan.clauses[lhs]
            let right = plan.clauses[rhs]
            if left.isRequired != right.isRequired { return left.isRequired }
            if left.maximumDocumentFrequency != right.maximumDocumentFrequency {
                return left.maximumDocumentFrequency < right.maximumDocumentFrequency
            }
            return lhs < rhs
        }
        for clause in order {
            for field in 0..<SearchField.count {
                for alternative in plan.clauses[clause].alternatives {
                    for location in alternative.reference.handle {
                        let segment = location.segment
                        let view = views[segment]
                        guard let range = view.postingRange(term: location.term, field: field) else { continue }
                        let tombstones = entries[segment].tombstones
                        let hasTombstones = !tombstones.isEmpty
                        let full: Bool = try slotIndex[segment].withUnsafeMutableBufferPointer { index in
                            var offset = range.start
                            let end = range.start + range.length
                            var document = -1
                            while offset < end {
                                document += Int(readVarint(view.postings, &offset))
                                _ = readVarint(view.postings, &offset)
                                work += 1
                                if work >= 1_000 { try Task.checkCancellation(); work = 0 }
                                guard index[document] == Self.none, !(hasTombstones && tombstones.contains(document)) else { continue }
                                guard constraints.allows(segment: segment, ordinal: document, view: view) else {
                                    index[document] = Self.rejected
                                    rejectedDocuments.append((segment, document))
                                    continue
                                }
                                slots[slotCount] = Slot(segment: Int32(segment), ordinal: Int32(document))
                                index[document] = Int32(slotCount)
                                slotCount += 1
                                if slotCount >= limit { return true }
                            }
                            return false
                        }
                        if full { return }
                    }
                }
            }
        }
    }

    // MARK: Scoring

    private mutating func score(
        _ plan: QueryPlan<[TermLocation]>,
        entries: [IndexEntry],
        views: [SegmentView],
        parameters: ScoringParameters,
        constraints: SegmentConstraints,
        admitting: Bool,
        limit: Int,
        work: inout Int
    ) throws {
        var alternativeEpoch: Int32 = 0
        var clauseEpoch: Int32 = 0
        for (clauseIndex, clause) in plan.clauses.enumerated() {
            clauseEpoch += 1
            clauseTouched.removeAll(keepingCapacity: true)
            for alternative in clause.alternatives {
                for location in alternative.reference.handle {
                    // One pass per (alternative, segment): documents of different segments are
                    // disjoint, so each document still sums its fields in field order.
                    alternativeEpoch += 1
                    alternativeTouched.removeAll(keepingCapacity: true)
                    let segment = location.segment
                    let view = views[segment]
                    let tombstones = entries[segment].tombstones
                    let hasTombstones = !tombstones.isEmpty
                    let epoch = alternativeEpoch
                    let lastOfInterest = admitting ? Int.max : highestCandidate[segment]
                    if lastOfInterest < 0 { continue }
                    try slots.withUnsafeMutableBufferPointer { slots in
                        try slotIndex[segment].withUnsafeMutableBufferPointer { index in
                            for field in 0..<SearchField.count {
                                guard let range = view.postingRange(term: location.term, field: field) else { continue }
                                var offset = range.start
                                let end = range.start + range.length
                                var document = -1
                                while offset < end {
                                    document += Int(readVarint(view.postings, &offset))
                                    if document > lastOfInterest { break }
                                    let frequency = readVarint(view.postings, &offset)
                                    work += 1
                                    if work >= 1_000 { try Task.checkCancellation(); work = 0 }
                                    var slot = index[document]
                                    if slot == Self.none {
                                        guard admitting, slotCount < limit, !(hasTombstones && tombstones.contains(document)) else { continue }
                                        guard constraints.allows(segment: segment, ordinal: document, view: view) else {
                                            index[document] = Self.rejected
                                            rejectedDocuments.append((segment, document))
                                            continue
                                        }
                                        slot = Int32(slotCount)
                                        slots[slotCount] = Slot(segment: Int32(segment), ordinal: Int32(document))
                                        index[document] = slot
                                        slotCount += 1
                                    } else if slot == Self.rejected {
                                        continue
                                    }
                                    let position = Int(slot)
                                    if slots[position].alternativeEpoch != epoch {
                                        slots[position].alternativeEpoch = epoch
                                        slots[position].termFrequency = 0
                                        alternativeTouched.append(slot)
                                    }
                                    slots[position].termFrequency += parameters.contribution(
                                        field: field, frequency: frequency, length: view.fieldLength(field: field, document: document)
                                    )
                                }
                            }
                        }
                        for slot in alternativeTouched {
                            let position = Int(slot)
                            if slots[position].clauseEpoch != clauseEpoch {
                                slots[position].clauseEpoch = clauseEpoch
                                slots[position].clauseLexical = 0
                                slots[position].clauseFuzzy = 0
                                clauseTouched.append(slot)
                            }
                            let frequency = slots[position].termFrequency
                            if !alternative.isFuzzy {
                                let value = parameters.score(weight: alternative.weight, idf: clause.idfLexical, tf: frequency)
                                if value > slots[position].clauseLexical { slots[position].clauseLexical = value }
                            }
                            let value = parameters.score(weight: alternative.weight, idf: clause.idfFuzzy, tf: frequency)
                            if value > slots[position].clauseFuzzy { slots[position].clauseFuzzy = value }
                        }
                    }
                }
            }
            let bit: UInt64 = clauseIndex < 64 ? 1 << UInt64(clauseIndex) : 0
            for slot in clauseTouched {
                let position = Int(slot)
                if slots[position].clauseLexical > 0 {
                    slots[position].lexical += slots[position].clauseLexical
                    slots[position].matchedLexical |= bit
                }
                if slots[position].clauseFuzzy > 0 {
                    slots[position].fuzzy += slots[position].clauseFuzzy
                    slots[position].matchedFuzzy |= bit
                }
            }
        }
    }

    // MARK: Results

    private mutating func rankedList(
        fuzzy: Bool,
        plan: QueryPlan<[TermLocation]>,
        entries: [IndexEntry],
        views: [SegmentView],
        limit: Int,
        session: TokenizerSession
    ) throws -> [RankedDocument] {
        let required = plan.requiredMask
        var order: [Int] = []
        order.reserveCapacity(slotCount)
        for index in 0..<slotCount {
            let matched = fuzzy ? slots[index].matchedFuzzy : slots[index].matchedLexical
            if matched != 0 && matched & required == required { order.append(index) }
        }
        slots.withUnsafeBufferPointer { slots in
            order.sort { lhs, rhs in
                let leftScore = fuzzy ? slots[lhs].fuzzy : slots[lhs].lexical
                let rightScore = fuzzy ? slots[rhs].fuzzy : slots[rhs].lexical
                if leftScore != rightScore { return leftScore > rightScore }
                let leftID = views[Int(slots[lhs].segment)].idBuffer(Int(slots[lhs].ordinal))
                let rightID = views[Int(slots[rhs].segment)].idBuffer(Int(slots[rhs].ordinal))
                let common = min(leftID.count, rightID.count)
                if common > 0 {
                    let comparison = memcmp(leftID.baseAddress!, rightID.baseAddress!, common)
                    if comparison != 0 { return comparison < 0 }
                }
                return leftID.count < rightID.count
            }
        }

        var result: [RankedDocument] = []
        result.reserveCapacity(min(limit, order.count))
        for (visited, index) in order.enumerated() {
            if result.count >= limit { break }
            let slot = slots[index]
            let view = views[Int(slot.segment)]
            let ordinal = Int(slot.ordinal)
            if !plan.phrases.isEmpty {
                if slot.phraseState == 0 {
                    if visited % 16 == 0 { try Task.checkCancellation() }
                    let contains = (try? view.document(at: ordinal)).map {
                        Highlighter.containsPhrases(plan.phrases, in: $0, session: session)
                    } ?? false
                    slots[index].phraseState = contains ? 1 : 2
                }
                if slots[index].phraseState != 1 { continue }
            }
            result.append(RankedDocument(
                id: SearchableID(view.idString(ordinal)),
                rawKind: entries[Int(slot.segment)].segment.kinds[view.kindOrdinal(ordinal)],
                updatedAt: view.updatedAt(ordinal),
                score: fuzzy ? slot.fuzzy : slot.lexical
            ))
        }
        return result
    }
}

/// Hard constraints translated to the kind and filter ordinals of each segment.
struct SegmentConstraints {
    private let isEmpty: Bool
    /// Per segment: allowed kind ordinals, or `nil` when every kind is allowed.
    private let kinds: [[Bool]?]
    /// Per segment, per filter key: which filter ordinals satisfy the key.
    private let groups: [[[Bool]]]

    init(_ constraints: HardConstraints, entries: [IndexEntry]) {
        isEmpty = constraints.isEmpty
        kinds = entries.map { entry in
            constraints.kinds.map { allowed in entry.segment.kinds.map(allowed.contains) }
        }
        groups = entries.map { entry in
            constraints.filters.keys.sorted().map { key in
                let values = constraints.filters[key] ?? []
                return entry.segment.filters.map { $0.key == key && values.contains($0.value) }
            }
        }
    }

    /// AND across keys, OR among the values of one key; equality on the record.
    @inline(__always)
    func allows(segment: Int, ordinal: Int, view: SegmentView) -> Bool {
        if isEmpty { return true }
        if let allowed = kinds[segment], !allowed[view.kindOrdinal(ordinal)] { return false }
        let segmentGroups = groups[segment]
        guard !segmentGroups.isEmpty else { return true }
        let count = view.filterCount(ordinal)
        for group in segmentGroups {
            var satisfied = false
            for position in 0..<count where group[view.filterOrdinal(ordinal, position)] {
                satisfied = true
                break
            }
            if !satisfied { return false }
        }
        return true
    }
}
