import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// The relevance gates of specification section 15.3, over the golden set.
///
/// The corpus is the golden corpus among synthetic distractors: 5,000 by default, which keeps a
/// debug `swift test` quick, and the reference 100,000 with `ZTRON_FULL_CORPUS=1` (meant for a
/// release build). The production embedding model and cross-encoder are open questions of the
/// specification, so the semantic channel is the deterministic fake of the fixtures: 384
/// dimensions, reading a mistyped or unfinished word the way a subword model does.
///
/// A gate that fails here fails the build.
final class RelevanceTests: XCTestCase {
    enum Stage: String, CaseIterable, Sendable {
        /// Milestones 1 to 3: lexical and fuzzy channels only.
        case lexical
        /// The semantic snapshot: the final one on the reference device.
        case semantic
        /// The reranked snapshot of devices past the calibration gate.
        case reranked
        /// The semantic snapshot under the shipped profile with its signals on (milestone 7):
        /// popularity and freshness at their tuned weights, the popularity one that knows
        /// nothing about relevance.
        case signals
    }

    struct Outcome: Sendable {
        /// Ids of the final snapshot's hits, best first.
        var ranked: [SearchableID]
        var phase: SearchPhase
        var degraded: Set<SearchChannel>
    }

    /// Runs the golden set once per stage and keeps the outcomes for every test of the class.
    actor Evaluation {
        static let shared = Evaluation()

        private var outcomes: [Stage: [String: Outcome]] = [:]
        private var corpus: [AnySearchable<CatalogKind>]?
        private var searcher: FakeSemanticSearcher?

        static var distractorCount: Int {
            if let requested = ProcessInfo.processInfo.environment["ZTRON_RELEVANCE_DISTRACTORS"].flatMap(Int.init) { return max(0, requested) }
            return ProcessInfo.processInfo.environment["ZTRON_FULL_CORPUS"] != nil ? 100_000 : 5_000
        }

        func items() -> [AnySearchable<CatalogKind>] {
            if let corpus { return corpus }
            let built = SyntheticCorpus.combined(seed: 2026, count: Self.distractorCount)
            corpus = built
            return built
        }

        /// One vector set for every locale: item vectors come from the base-language composition.
        private func semantic() async -> FakeSemanticSearcher {
            if let searcher { return searcher }
            let created = FakeSemanticSearcher(provider: FakeEmbeddingProvider(dimensions: 384, recognizesPartialWords: true))
            await created.index(items())
            searcher = created
            return created
        }

        func outcomes(_ stage: Stage) async -> [String: Outcome] {
            if let cached = outcomes[stage] { return cached }
            let items = items()
            var result: [String: Outcome] = [:]
            for locale in ["en", "it", "de", "ja"] {
                let queries = GoldenSet.queries.filter { $0.locale == locale }
                guard !queries.isEmpty else { continue }
                let configuration = SearchEngineConfiguration(
                    locale: Locale(identifier: locale), followsSystemLocale: false, secondaryLanguages: .none,
                    preferredLanguages: { [] }, reranking: stage == .reranked ? .on : .off,
                    lexicalDebounce: 0, semanticDebounce: 0, semanticHardCap: 60, rerankHardCap: 60,
                    assertsOnProgrammerError: false, now: { GoldenCorpus.referenceDate }
                )
                var profile = RankingProfile.default
                var signals = SignalProviders.none
                if stage == .signals {
                    profile.popularity = .popularity
                    profile.freshness = .freshness(halfLifeDays: 30)
                    signals = SignalProviders(popularity: RelevanceBlindSignals(seed: 1))
                }
                let service = SearchService<CatalogSchema>(
                    index: LexicalIndex(),
                    semantic: stage == .lexical ? nil : await semantic(),
                    reranker: stage == .reranked ? FakeReranker() : nil,
                    profile: profile,
                    signals: signals,
                    configuration: configuration
                )
                await service.index(items)
                for query in queries {
                    var final: SearchSnapshot<CatalogSchema>?
                    for await snapshot in await service.results(for: query.query, trigger: .submit) where snapshot.isFinal {
                        final = snapshot
                    }
                    result[query.id] = Outcome(
                        ranked: final?.hits.map(\.id) ?? [], phase: final?.phase ?? .lexical, degraded: final?.degraded ?? []
                    )
                }
            }
            outcomes[stage] = result
            return result
        }
    }

    // MARK: Metrics

    /// The metric a class is gated on, for one query.
    private func value(of query: GoldenQuery, ranked: [SearchableID], allowed: Set<SearchableID>?) -> Double {
        query.gatedValue(ranked: ranked, allowed: allowed ?? [])
    }

    private func mean(_ queryClass: GoldenQueryClass, _ outcomes: [String: Outcome], items: [AnySearchable<CatalogKind>]) -> Double {
        let queries = GoldenSet.queries(of: queryClass)
        let values = queries.map { query -> Double in
            let allowed = queryClass == .filterAndKind ? query.allowedIDs(in: items) : nil
            return value(of: query, ranked: outcomes[query.id]?.ranked ?? [], allowed: allowed)
        }
        return RelevanceMetrics.mean(values)
    }

    private func failures(_ queryClass: GoldenQueryClass, _ outcomes: [String: Outcome], items: [AnySearchable<CatalogKind>]) -> String {
        var lines: [String] = []
        for query in GoldenSet.queries(of: queryClass) {
            let ranked = outcomes[query.id]?.ranked ?? []
            let allowed = queryClass == .filterAndKind ? query.allowedIDs(in: items) : nil
            let score = value(of: query, ranked: ranked, allowed: allowed)
            guard score < 0.999 else { continue }
            let position = ranked.firstIndex(of: query.sourceID).map { "\($0 + 1)" } ?? "-"
            lines.append("\(query.id) [\(query.locale)] «\(query.text)» \(String(format: "%.2f", score)), source at \(position)")
        }
        return lines.prefix(12).joined(separator: "; ")
    }

    private func assertGate(
        _ queryClass: GoldenQueryClass, atLeast threshold: Double, stage: Stage, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let evaluation = Evaluation.shared
        let outcomes = await evaluation.outcomes(stage)
        let items = await evaluation.items()
        let measured = mean(queryClass, outcomes, items: items)
        XCTAssertGreaterThanOrEqual(
            measured, threshold,
            "\(queryClass.rawValue), \(stage.rawValue) stage, \(Evaluation.distractorCount) distractors: \(String(format: "%.4f", measured)) is below the gate of \(threshold). \(failures(queryClass, outcomes, items: items))",
            file: file, line: line
        )
    }

    // MARK: The golden set itself

    func testTheGoldenSetIsWhatSection15Asks() {
        XCTAssertGreaterThanOrEqual(GoldenSet.queries.count, 300, "at least 300 judged queries")
        XCTAssertEqual(Set(GoldenSet.countsByKind.keys), Set(CatalogKind.allCases), "all five item types")
        XCTAssertGreaterThanOrEqual(GoldenSet.countsByLanguage.count, 3, "at least three languages")
        XCTAssertNotNil(GoldenSet.countsByLanguage["ja"], "one of them non-Latin")
        XCTAssertTrue(GoldenSet.queries.contains { $0.judgments.values.contains(3) } && GoldenSet.queries.contains { $0.judgments.values.contains { $0 < 3 } }, "graded judgments")
        XCTAssertEqual(GoldenSet.validate(), [])
        XCTAssertEqual(GoldenCorpus.validate(), [])
    }

    /// What every class measures at every stage, in the log of the run. Asserts nothing: the
    /// tests below hold each number to its gate.
    func testEveryStageReportsItsNumbers() async {
        let evaluation = Evaluation.shared
        let items = await evaluation.items()
        print("RELEVANCE \(GoldenSet.queries.count) golden queries among \(Evaluation.distractorCount) distractors")
        for stage in Stage.allCases {
            let outcomes = await evaluation.outcomes(stage)
            let cells = GoldenQueryClass.allCases.map { queryClass in
                "\(queryClass.rawValue) \(String(format: "%.4f", mean(queryClass, outcomes, items: items)))"
            }
            print("RELEVANCE \(stage.rawValue): \(cells.joined(separator: ", "))")
        }
    }

    // MARK: Lexical and fuzzy channels (milestones 1 and 3)

    func testLexicalStageExactTitle() async { await assertGate(.exactTitle, atLeast: 0.98, stage: .lexical) }
    func testLexicalStageTitlePrefix() async { await assertGate(.titlePrefix, atLeast: 0.85, stage: .lexical) }
    func testLexicalStageTypos() async { await assertGate(.typo, atLeast: 0.90, stage: .lexical) }
    func testLexicalStageKeywords() async { await assertGate(.keyword, atLeast: 0.80, stage: .lexical) }
    func testLexicalStageLocalizedTitle() async { await assertGate(.localizedTitle, atLeast: 0.95, stage: .lexical) }
    func testLexicalStageFiltersAndKinds() async { await assertGate(.filterAndKind, atLeast: 1.0, stage: .lexical) }

    // MARK: The final snapshot of the reference device (semantic channel on)

    func testExactTitleIsRankOne() async { await assertGate(.exactTitle, atLeast: 0.98, stage: .semantic) }
    func testTitlePrefixMRR() async { await assertGate(.titlePrefix, atLeast: 0.85, stage: .semantic) }
    func testTypoRecall() async { await assertGate(.typo, atLeast: 0.90, stage: .semantic) }
    func testKeywordNDCG() async { await assertGate(.keyword, atLeast: 0.80, stage: .semantic) }
    func testParaphraseRecall() async { await assertGate(.paraphrase, atLeast: 0.75, stage: .semantic) }
    func testCrossLanguageRecall() async { await assertGate(.crossLanguage, atLeast: 0.70, stage: .semantic) }
    func testLocalizedTitleIsRankOne() async { await assertGate(.localizedTitle, atLeast: 0.95, stage: .semantic) }
    func testFilterAndKindPrecision() async { await assertGate(.filterAndKind, atLeast: 1.0, stage: .semantic) }

    func testNoHitEverViolatesAHardConstraint() async {
        // Precision 1.0 is asked of every query that carries a kind, a filter or a phrase,
        // whatever its class and whichever snapshot is final.
        let evaluation = Evaluation.shared
        let items = await evaluation.items()
        for stage in Stage.allCases {
            let outcomes = await evaluation.outcomes(stage)
            var checked = 0
            for query in GoldenSet.queries where query.hasHardConstraints {
                let allowed = query.allowedIDs(in: items)
                let ranked = outcomes[query.id]?.ranked ?? []
                let violations = ranked.filter { !allowed.contains($0) }
                XCTAssertEqual(violations, [], "\(query.id) «\(query.text)», \(stage.rawValue) stage")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 60)
        }
    }

    func testTheFinalSnapshotIsTheOneTheStageAsksFor() async {
        let evaluation = Evaluation.shared
        let semantic = await evaluation.outcomes(.semantic)
        let reranked = await evaluation.outcomes(.reranked)
        for query in GoldenSet.queries(of: .paraphrase) + GoldenSet.queries(of: .crossLanguage) {
            XCTAssertEqual(semantic[query.id]?.phase, .semantic, query.id)
            XCTAssertEqual(semantic[query.id]?.degraded, [], query.id)
            XCTAssertEqual(reranked[query.id]?.phase, .reranked, query.id)
        }
    }

    // MARK: Ranking profile and signal providers (milestone 7)

    /// The gate of milestone 7: no regression on any class of section 15.3.
    ///
    /// The profile is the shipped one, its weights tuned from the judgments of this set
    /// (`SignalTuningTests`), and no class may sit below its value without signals. Kind boosts
    /// ship neutral and editorial pins override the ranking on purpose, so neither is a weight
    /// to hold to this gate; `RankingTests` covers how they apply.
    func testSignalsLeaveEveryGateStanding() async {
        let evaluation = Evaluation.shared
        let items = await evaluation.items()
        let without = await evaluation.outcomes(.semantic)
        let with = await evaluation.outcomes(.signals)
        for queryClass in GoldenQueryClass.allCases {
            await assertGate(queryClass, atLeast: queryClass.gate, stage: .signals)
            let before = mean(queryClass, without, items: items)
            let after = mean(queryClass, with, items: items)
            XCTAssertGreaterThanOrEqual(
                after, before - GoldenQueryClass.regressionTolerance,
                "\(queryClass.rawValue), \(Evaluation.distractorCount) distractors: \(String(format: "%.4f", after)) with the signals on, \(String(format: "%.4f", before)) without. \(failures(queryClass, with, items: items))"
            )
        }
        // The signals are on, not idle: below the head, where fused scores are close, they do
        // reorder.
        let reordered = GoldenSet.queries.filter { without[$0.id]?.ranked != with[$0.id]?.ranked }.count
        XCTAssertGreaterThan(reordered, GoldenSet.queries.count / 4, "the signals moved \(reordered) lists of \(GoldenSet.queries.count)")
    }

    // MARK: Reranked head (devices past the calibration gate)

    /// NDCG@10 of a class under a stage. Classes whose queries carry only tokens have no free
    /// text to rerank and are left out.
    private func ndcg(_ queryClass: GoldenQueryClass, _ outcomes: [String: Outcome]) -> Double {
        let queries = GoldenSet.queries(of: queryClass).filter { !$0.text.isEmpty }
        return RelevanceMetrics.mean(queries.map { RelevanceMetrics.ndcg(outcomes[$0.id]?.ranked ?? [], judgments: $0.judgments, at: 10) })
    }

    func testRerankedHeadNDCG() async {
        let evaluation = Evaluation.shared
        let fused = await evaluation.outcomes(.semantic)
        let reranked = await evaluation.outcomes(.reranked)
        var all: [Double] = []
        for queryClass in GoldenQueryClass.allCases {
            let before = ndcg(queryClass, fused)
            let after = ndcg(queryClass, reranked)
            all.append(after)
            XCTAssertGreaterThanOrEqual(
                after, before - 1e-9,
                "\(queryClass.rawValue): the reranked NDCG@10 (\(String(format: "%.4f", after))) is below the fused one (\(String(format: "%.4f", before)))"
            )
            XCTAssertGreaterThanOrEqual(after, 0.85, "\(queryClass.rawValue): reranked NDCG@10 \(String(format: "%.4f", after))")
        }
        XCTAssertGreaterThanOrEqual(RelevanceMetrics.mean(all), 0.85)
    }

    func testTheRerankedStageKeepsEveryGate() async {
        await assertGate(.exactTitle, atLeast: 0.98, stage: .reranked)
        await assertGate(.titlePrefix, atLeast: 0.85, stage: .reranked)
        await assertGate(.typo, atLeast: 0.90, stage: .reranked)
        await assertGate(.keyword, atLeast: 0.80, stage: .reranked)
        await assertGate(.paraphrase, atLeast: 0.75, stage: .reranked)
        await assertGate(.crossLanguage, atLeast: 0.70, stage: .reranked)
        await assertGate(.localizedTitle, atLeast: 0.95, stage: .reranked)
        await assertGate(.filterAndKind, atLeast: 1.0, stage: .reranked)
    }
}
