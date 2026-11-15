import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 8: fusion, the ranking profile and the signal providers.
final class RankingTests: XCTestCase {
    private func ranked(_ ids: [String]) -> [RankedDocument] {
        ids.enumerated().map { RankedDocument(id: SearchableID($1), rawKind: "tool", updatedAt: nil, score: Double(ids.count - $0)) }
    }

    private func reporter(_ recorder: DiagnosticsRecorder? = nil) -> DiagnosticReporter {
        DiagnosticReporter(sink: recorder?.sink, assertsOnProgrammerError: false)
    }

    // MARK: Weighted RRF

    func testWeightedReciprocalRankFusion() {
        let fused = RankFusion.fuse([
            .init(channel: .lexical, weight: 1.0, documents: ranked(["a", "b", "c"])),
            .init(channel: .fuzzy, weight: 0.6, documents: ranked(["b", "a"])),
            .init(channel: .semantic, weight: 0.8, documents: ranked(["d", "a"])),
        ], k: 60, entriesPerChannel: 200)
        let scores = Dictionary(uniqueKeysWithValues: fused.map { ($0.id.rawValue, $0.score) })
        // s(d) = sum over channels of w_c / (k + r_c(d)); a channel that did not return d contributes 0.
        XCTAssertEqual(scores["a"]!, 1.0 / 61 + 0.6 / 62 + 0.8 / 62, accuracy: 1e-15)
        XCTAssertEqual(scores["b"]!, 1.0 / 62 + 0.6 / 61, accuracy: 1e-15)
        XCTAssertEqual(scores["c"]!, 1.0 / 63, accuracy: 1e-15)
        XCTAssertEqual(scores["d"]!, 0.8 / 61, accuracy: 1e-15)
        let channels = Dictionary(uniqueKeysWithValues: fused.map { ($0.id.rawValue, $0.channels) })
        XCTAssertEqual(channels["a"], [.lexical, .fuzzy, .semantic])
        XCTAssertEqual(channels["d"], [.semantic])
    }

    func testRawChannelScoresAreNeverAdded() {
        // Enormous raw scores in one channel change nothing: only ranks count.
        let huge = [RankedDocument(id: "x", rawKind: "tool", updatedAt: nil, score: 1e12), RankedDocument(id: "y", rawKind: "tool", updatedAt: nil, score: 1e-12)]
        let tiny = [RankedDocument(id: "x", rawKind: "tool", updatedAt: nil, score: 2), RankedDocument(id: "y", rawKind: "tool", updatedAt: nil, score: 1)]
        let first = RankFusion.fuse([.init(channel: .lexical, weight: 1, documents: huge)], k: 60, entriesPerChannel: 200)
        let second = RankFusion.fuse([.init(channel: .lexical, weight: 1, documents: tiny)], k: 60, entriesPerChannel: 200)
        XCTAssertEqual(first.map(\.score), second.map(\.score))
    }

    func testFusionIsBoundedPerChannel() {
        let long = ranked((0..<500).map { "d\($0)" })
        let fused = RankFusion.fuse([.init(channel: .lexical, weight: 1, documents: long)], k: 60, entriesPerChannel: 200)
        XCTAssertEqual(fused.count, 200)
        XCTAssertEqual(SearchLimits.default.fusionEntriesPerChannel * 3, 600, "600 entries in fusion")
        XCTAssertEqual(SearchLimits.default.lexicalCandidates, 2_000)
        XCTAssertEqual(SearchLimits.default.fuzzyCandidatesPerToken, 8)
        XCTAssertEqual(SearchLimits.default.prefixExpansions, 32)
        XCTAssertEqual(SearchLimits.default.semanticNeighbours, 50)
        XCTAssertEqual(SearchLimits.default.retainedHits, 200)
    }

    func testDefaultProfileMatchesTheSpecification() {
        let profile = RankingProfile.default
        XCTAssertEqual(profile.fieldWeights, [.title: 8.0, .keywords: 4.0, .caption: 2.5, .text: 1.0, .localizedAlt: 0.5, .ocrText: 0.5])
        XCTAssertEqual(profile.bm25.b, [.title: 0.5, .keywords: 0.3, .caption: 0.75, .text: 0.75, .localizedAlt: 0.75, .ocrText: 0.75])
        XCTAssertEqual(profile.bm25.k1, 1.2)
        XCTAssertEqual(profile.channelWeights, [.lexical: 1.0, .fuzzy: 0.6, .semantic: 0.8])
        XCTAssertEqual(profile.rrfK, 60)
        XCTAssertEqual(profile.rerank, RerankSpec(topN: 16, blend: 0.7))
        XCTAssertEqual(profile.editorial.maximumPins, 3)
        XCTAssertEqual(RerankSpec(topN: 99).topN, 32, "configurable, at most 32")
        XCTAssertEqual(EditorialPolicy(maximumPins: 9).maximumPins, 3, "limited to 3 per query")
    }

    // MARK: Kind boosts

    private func fusedList(_ scores: [(String, String, Double)]) -> [FusedDocument] {
        scores.map { FusedDocument(id: SearchableID($0.0), rawKind: $0.1, updatedAt: nil, score: $0.2, channels: [.lexical]) }
    }

    func testKindBoostsAreMultiplicativeAndClamped() {
        var profile = RankingProfile.default
        profile.kindBoosts = ["map": 1.2, "tip": 50, "tool": 0.01, "game": .nan]
        XCTAssertEqual(profile.kindBoost(for: "map"), 1.2)
        XCTAssertEqual(profile.kindBoost(for: "tip"), 1.5, "clamped to 0.5...1.5")
        XCTAssertEqual(profile.kindBoost(for: "tool"), 0.5)
        XCTAssertEqual(profile.kindBoost(for: "game"), 1.0)
        XCTAssertEqual(profile.kindBoost(for: "image"), 1.0, "1.0 neutral")

        let ranker = ResultRanker(profile: profile, signals: .none, now: Date(), reporter: reporter())
        let result = ranker.rank(fusedList([("a", "tool", 1.0), ("b", "map", 0.9), ("c", "tip", 0.7)]), limit: 200)
        XCTAssertEqual(result.map(\.id.rawValue), ["b", "c", "a"])
        XCTAssertEqual(result.map(\.score), [0.9 * 1.2, 0.7 * 1.5, 1.0 * 0.5])
    }

    // MARK: Signals

    private struct Popularity: PopularityProvider {
        let counts: [SearchableID: Double]
        func popularity(for id: SearchableID) throws -> Double? { counts[id] }
    }

    private struct Affinity: PersonalizationProvider {
        let values: [SearchableID: Double]
        func affinity(for id: SearchableID) throws -> Double? { values[id] }
    }

    private struct Editorial: EditorialProvider {
        let decisions: [SearchableID: EditorialDecision]
        func decision(for id: SearchableID) throws -> EditorialDecision? { decisions[id] }
    }

    private struct Failing: PopularityProvider, EditorialProvider, PersonalizationProvider {
        struct Boom: Error {}
        func popularity(for id: SearchableID) throws -> Double? { throw Boom() }
        func decision(for id: SearchableID) throws -> EditorialDecision? { throw Boom() }
        func affinity(for id: SearchableID) throws -> Double? { throw Boom() }
    }

    func testPopularityIsLogScaledAndAddsAtMostFifteenPercentOfTheTopFusedScore() {
        let documents = fusedList([("top", "tool", 1.0), ("popular", "tool", 0.9), ("mild", "tool", 0.89), ("none", "tool", 0.88)])
        var profile = RankingProfile.default
        profile.popularity = SignalSpec(weight: 0.9)   // asks for more than the ceiling
        let ranker = ResultRanker(
            profile: profile,
            signals: SignalProviders(popularity: Popularity(counts: ["popular": 1_000_000, "mild": 999, "top": 0])),
            now: Date(), reporter: reporter()
        )
        let result = ranker.rank(documents, limit: 200)
        let scores = Dictionary(uniqueKeysWithValues: result.map { ($0.id.rawValue, $0.score) })
        // The most popular document gets the whole capped boost: 15% of the top fused score.
        XCTAssertEqual(scores["popular"]!, 0.9 + 0.15 * 1.0, accuracy: 1e-12)
        // log1p scaling: a thousand times fewer views is half the boost, not a thousandth.
        XCTAssertEqual(scores["mild"]!, 0.89 + 0.15 * log1p(999) / log1p(1_000_000), accuracy: 1e-12)
        XCTAssertEqual(scores["top"]!, 1.0, accuracy: 1e-12)
        XCTAssertEqual(scores["none"]!, 0.88, accuracy: 1e-12)
        XCTAssertEqual(result.first?.id, "popular")
        for document in result {
            let original = documents.first { $0.id == document.id }!.score
            XCTAssertLessThanOrEqual(document.score - original, 0.15 + 1e-12)
        }
    }

    func testFreshnessDecaysExponentiallyWithTheHalfLife() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 86_400.0
        let documents = [
            FusedDocument(id: "new", rawKind: "tip", updatedAt: now, score: 0.5, channels: [.lexical]),
            FusedDocument(id: "week", rawKind: "tip", updatedAt: now.addingTimeInterval(-7 * day), score: 0.5, channels: [.lexical]),
            FusedDocument(id: "old", rawKind: "tip", updatedAt: now.addingTimeInterval(-70 * day), score: 0.5, channels: [.lexical]),
            FusedDocument(id: "undated", rawKind: "tool", updatedAt: nil, score: 0.5, channels: [.lexical]),
            FusedDocument(id: "top", rawKind: "tool", updatedAt: nil, score: 1.0, channels: [.lexical]),
        ]
        var profile = RankingProfile.default
        profile.freshness = .freshness(halfLifeDays: 7, weight: 0.2)
        let ranker = ResultRanker(profile: profile, signals: .none, now: now, reporter: reporter())
        let scores = Dictionary(uniqueKeysWithValues: ranker.rank(documents, limit: 200).map { ($0.id.rawValue, $0.score) })
        XCTAssertEqual(scores["new"]!, 0.5 + 0.2, accuracy: 1e-12)
        XCTAssertEqual(scores["week"]!, 0.5 + 0.1, accuracy: 1e-12, "one half-life halves the boost")
        XCTAssertEqual(scores["old"]!, 0.5 + 0.2 * pow(0.5, 10), accuracy: 1e-12)
        XCTAssertEqual(scores["undated"]!, 0.5, "only when TemporalSearchable is present")
        // No half-life, no freshness.
        XCTAssertNil(RankingProfile.default.freshness)
    }

    func testAffinityIsAClampedMultiplier() {
        let ranker = ResultRanker(
            profile: .default,
            signals: SignalProviders(personalization: Affinity(values: ["a": 9, "b": 0.0, "c": 1.25])),
            now: Date(), reporter: reporter()
        )
        let scores = Dictionary(uniqueKeysWithValues: ranker.rank(fusedList([("a", "t", 1), ("b", "t", 1), ("c", "t", 1), ("d", "t", 1)]), limit: 200).map { ($0.id.rawValue, $0.score) })
        XCTAssertEqual(scores, ["a": 1.5, "b": 0.5, "c": 1.25, "d": 1.0])
    }

    func testEditorialSuppressionsAndPins() {
        let documents = fusedList((0..<8).map { ("d\($0)", "tool", 1.0 - Double($0) * 0.1) })
        let editorial = Editorial(decisions: [
            "d1": .suppress,
            "d7": .pin(rank: 1), "d5": .pin(rank: 0), "d6": .pin(rank: 2), "d4": .pin(rank: 3),
        ])
        let ranker = ResultRanker(profile: .default, signals: SignalProviders(editorial: editorial), now: Date(), reporter: reporter())
        let ranked = ranker.rank(documents, limit: 200)
        XCTAssertFalse(ranked.contains { $0.id == "d1" }, "suppressed")
        XCTAssertEqual(ranked.map(\.id.rawValue), ["d0", "d2", "d3", "d4", "d5", "d6", "d7"], "pins do not move during ranking")

        let pinned = ranker.applyingPins(to: ranked)
        // At most 3 pins per query, lowest pin rank first; the fourth pin stays where it ranked.
        XCTAssertEqual(pinned.map(\.id.rawValue), ["d5", "d7", "d6", "d0", "d2", "d3", "d4"])
        // Scores stay non-increasing down the list.
        XCTAssertEqual(pinned.map(\.score), pinned.map(\.score).sorted(by: >))

        var noSuppression = RankingProfile.default
        noSuppression.editorial = EditorialPolicy(maximumPins: 1, appliesSuppressions: false)
        let lenient = ResultRanker(profile: noSuppression, signals: SignalProviders(editorial: editorial), now: Date(), reporter: reporter())
        let kept = lenient.applyingPins(to: lenient.rank(documents, limit: 200))
        XCTAssertTrue(kept.contains { $0.id == "d1" })
        XCTAssertEqual(kept.prefix(2).map(\.id.rawValue), ["d5", "d0"])
    }

    func testAProviderThatThrowsIsTreatedAsAbsentForThatQuery() async {
        let recorder = DiagnosticsRecorder()
        let documents = fusedList([("a", "tool", 1.0), ("b", "tool", 0.9)])
        let failing = Failing()
        let ranker = ResultRanker(
            profile: .default,
            signals: SignalProviders(popularity: failing, editorial: failing, personalization: failing),
            now: Date(), reporter: reporter(recorder)
        )
        let result = ranker.applyingPins(to: ranker.rank(documents, limit: 200))
        XCTAssertEqual(result, documents, "exactly the fused order and scores")
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains(.signalProviderFailed(signal: "popularity")))
        XCTAssertTrue(diagnostics.contains(.signalProviderFailed(signal: "editorial")))
        XCTAssertTrue(diagnostics.contains(.signalProviderFailed(signal: "personalization")))
    }

    func testRankingKeepsAtMostTheRetainedHits() {
        let documents = fusedList((0..<600).map { ("d\($0)", "tool", Double(600 - $0)) })
        let ranker = ResultRanker(profile: .default, signals: .none, now: Date(), reporter: reporter())
        XCTAssertEqual(ranker.rank(documents, limit: 200).count, 200)
    }

    func testTiesAreBrokenByID() {
        let ranker = ResultRanker(profile: .default, signals: .none, now: Date(), reporter: reporter())
        let result = ranker.rank(fusedList([("b", "t", 1), ("c", "t", 1), ("a", "t", 1)]), limit: 200)
        XCTAssertEqual(result.map(\.id.rawValue), ["a", "b", "c"])
    }

    func testTheDefaultWeightsAreTheTunedOnesAndOnlyBreakTies() {
        XCTAssertEqual(RankingProfile.default.popularity, .popularity)
        XCTAssertEqual(SignalSpec.popularity.weight, SignalSpec.tunedWeight)
        XCTAssertEqual(SignalSpec.freshness(halfLifeDays: 30).weight, SignalSpec.tunedWeight)
        XCTAssertLessThanOrEqual(SignalSpec.tunedWeight, SignalSpec.maximumPopularityWeight)
        XCTAssertEqual(RankingProfile.default.kindBoosts, [:], "kind boosts ship neutral")

        // One rank in every channel is 1/62 of the top fused score. Both signals together, each
        // at its default weight and both entirely on the side of the second document, stay
        // below that: a document every channel ranks first keeps its place.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weight = RankingProfile.defaultChannelWeights.values.reduce(0, +)
        let documents = [
            FusedDocument(id: "first", rawKind: "tip", updatedAt: now.addingTimeInterval(-3_650 * 86_400), score: weight / 61, channels: [.lexical, .fuzzy, .semantic]),
            FusedDocument(id: "second", rawKind: "tip", updatedAt: now, score: weight / 62, channels: [.lexical, .fuzzy, .semantic]),
        ]
        var profile = RankingProfile.default
        profile.freshness = .freshness(halfLifeDays: 30)
        let ranker = ResultRanker(
            profile: profile, signals: SignalProviders(popularity: Popularity(counts: ["second": 1_000_000])), now: now, reporter: reporter()
        )
        let ranked = ranker.rank(documents, limit: 10)
        XCTAssertEqual(ranked.map(\.id.rawValue), ["first", "second"])
        XCTAssertGreaterThan(ranked[1].score, documents[1].score, "the signals did apply")
    }

    // MARK: End to end

    func testSignalsApplyThroughTheService() async {
        // Five documents that tie lexically: fusion ranks them by id.
        let items: [AnySearchable<CatalogKind>] = (0..<5).map { Tool(id: "tool-\($0)", title: "Lantern", text: "a lantern") }.erased()
        let plain = await TestSupport.indexedService(items)
        let unsignalled = await TestSupport.final(plain, "lantern")
        XCTAssertEqual(TestSupport.ids(unsignalled), ["tool-0", "tool-1", "tool-2", "tool-3", "tool-4"])

        // The host weighs popularity at the ceiling here. The default weight only breaks ties.
        var profile = RankingProfile.default
        profile.popularity = SignalSpec(weight: SignalSpec.maximumPopularityWeight)
        let service = await TestSupport.indexedService(
            items,
            profile: profile,
            signals: SignalProviders(
                popularity: Popularity(counts: ["tool-3": 5_000]),
                editorial: Editorial(decisions: ["tool-1": .suppress, "tool-4": .pin(rank: 0)])
            )
        )
        let snapshot = await TestSupport.final(service, "lantern")
        // Suppressed: gone. Pinned: first, after fusion. Popular: lifted past the others, within its cap.
        XCTAssertEqual(TestSupport.ids(snapshot), ["tool-4", "tool-3", "tool-0", "tool-2"])
        let top = unsignalled?.hits.first?.score ?? 0
        let lifted = snapshot?.hits.first { $0.id == "tool-3" }?.score ?? 0
        let original = unsignalled?.hits.first { $0.id == "tool-3" }?.score ?? 0
        XCTAssertEqual(lifted - original, 0.15 * top, accuracy: 1e-12, "adds at most 15% of the top fused score")
    }

    func testRankingIsRetunedBySwappingTheProfile() async {
        let items: [AnySearchable<CatalogKind>] = [
            AnySearchable(Tool(id: "in-title", title: "Lantern", text: "a tool for other things entirely")),
            AnySearchable(Tool(id: "in-text", title: "Planner", text: "lantern lantern lantern lantern")),
        ]
        let service = await TestSupport.indexedService(items)
        let byTitle = await TestSupport.final(service, "lantern")
        XCTAssertEqual(TestSupport.ids(byTitle), ["in-title", "in-text"])
        // No domain type changes; no reindexing.
        var profile = RankingProfile.default
        profile.fieldWeights[.title] = 0.1
        profile.fieldWeights[.text] = 10
        await service.setProfile(profile)
        let byText = await TestSupport.final(service, "lantern")
        XCTAssertEqual(TestSupport.ids(byText), ["in-text", "in-title"])
    }

    // MARK: Rerank blend

    func testRerankBlendIsConfinedToTheHead() {
        let documents = fusedList((0..<40).map { ("d\($0)", "tool", 1.0 - Double($0) * 0.01) })
        // The cross-encoder loves the 16th document and hates the first.
        var scores = [Float](repeating: 0, count: 16)
        for index in 0..<16 { scores[index] = Float(index) }
        let reranked = SearchPipeline.reranked(documents, scores: scores, spec: RerankSpec(topN: 16, blend: 0.7))

        XCTAssertEqual(reranked.count, 40)
        XCTAssertEqual(Set(reranked.prefix(16).map(\.id)), Set(documents.prefix(16).map(\.id)), "the head only permutes")
        XCTAssertEqual(reranked.suffix(24).map(\.id), documents.suffix(24).map(\.id), "every position below keeps the fused order")
        XCTAssertEqual(reranked.suffix(24).map(\.score), documents.suffix(24).map(\.score))
        XCTAssertEqual(reranked.first?.id, "d15")
        XCTAssertTrue(reranked.prefix(16).allSatisfy { $0.channels.contains(.rerank) })
        XCTAssertTrue(reranked.suffix(24).allSatisfy { !$0.channels.contains(.rerank) })
        XCTAssertEqual(reranked.map(\.score), reranked.map(\.score).sorted(by: >), "scores stay non-increasing")
    }

    func testBlendFormula() {
        // Final = 0.7 x normalized cross-encoder + 0.3 x normalized RRF.
        let documents = fusedList([("a", "t", 1.0), ("b", "t", 0.5), ("c", "t", 0.0)])
        // a: 0.7*0 + 0.3*1 = 0.30 ; b: 0.7*1 + 0.3*0.5 = 0.85 ; c: 0.7*0.5 + 0 = 0.35
        let reranked = SearchPipeline.reranked(documents, scores: [0, 10, 5], spec: RerankSpec(topN: 16, blend: 0.7))
        XCTAssertEqual(reranked.map(\.id.rawValue), ["b", "c", "a"])
        // With blend 0 the fused order stands whatever the cross-encoder says.
        let ignored = SearchPipeline.reranked(documents, scores: [0, 10, 5], spec: RerankSpec(topN: 16, blend: 0))
        XCTAssertEqual(ignored.map(\.id.rawValue), ["a", "b", "c"])
    }

    func testOneConfidentPassCannotPushAnExactTitleHitOutOfTheHead() {
        // The exact-title hit leads the fused list by a wide margin; the cross-encoder ranks it last.
        var list = [("exact", "tool", 0.0262)]
        for index in 1..<16 { list.append(("d\(index)", "tool", 0.0160 - Double(index) * 0.0001)) }
        let documents = fusedList(list)
        var scores = [Float](repeating: 0, count: 16)
        for index in 0..<16 { scores[index] = Float(index) }   // lowest for the exact hit
        let reranked = SearchPipeline.reranked(documents, scores: scores, spec: .default)
        let position = reranked.firstIndex { $0.id == "exact" }!
        XCTAssertLessThan(position, 16, "it stays inside the head")
        // Its RRF share alone outranks every document the cross-encoder scores in its lower third.
        XCTAssertLessThan(position, 11)
        // With the cross-encoder merely indifferent, the exact hit keeps the top.
        let indifferent = SearchPipeline.reranked(documents, scores: [Float](repeating: 1, count: 16), spec: .default)
        XCTAssertEqual(indifferent.first?.id, "exact")
    }

    func testRerankPassageIsTitlePlusCaptionOrTheFirstSixtyFourTokensOfText() {
        let titled = SearchDocument(id: "a", kind: "image", title: "Harbor at dawn", text: "long text", caption: "The lighthouse")
        XCTAssertEqual(SearchPipeline.passage(for: titled), "Harbor at dawn\nThe lighthouse")
        let words = (0..<200).map { "w\($0)" }
        let bare = SearchDocument(id: "b", kind: "tip", text: words.joined(separator: " "))
        XCTAssertEqual(SearchPipeline.passage(for: bare), words.prefix(64).joined(separator: " "))
    }
}
