import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

/// Runs the golden set through the frozen core with the fake semantic channel and prints the
/// section 15.3 numbers. Diagnostic only: the gates belong to the core's own test targets.
final class EngineSmokeTests: XCTestCase {
    struct Outcome {
        var ranked: [SearchableID]
        var channels: [Set<SearchChannel>]
    }

    func run(
        _ queries: [GoldenQuery], items: [AnySearchable<CatalogKind>], dimensions: Int, semantic: Bool = true, partialWords: Bool = false
    ) async -> [String: Outcome] {
        var outcomes: [String: Outcome] = [:]
        let provider = FakeEmbeddingProvider(dimensions: dimensions, recognizesPartialWords: partialWords)
        for locale in ["en", "it", "de", "ja"] {
            let ofLocale = queries.filter { $0.locale == locale }
            guard !ofLocale.isEmpty else { continue }
            let configuration = SearchEngineConfiguration(
                locale: Locale(identifier: locale), followsSystemLocale: false, secondaryLanguages: .none,
                preferredLanguages: { [] }, reranking: .off, lexicalDebounce: 0, semanticDebounce: 0,
                semanticHardCap: 30, now: { GoldenCorpus.referenceDate }
            )
            let context = SearchContext<CatalogSchema>(
                id: SearchContextID("golden-\(locale)"), sources: [.memory(items)], locale: Locale(identifier: locale),
                strategy: .indexed, indexStorage: .inMemory
            )
            let searcher = FakeSemanticSearcher(provider: provider)
            await searcher.index(items)
            let service = SearchService<CatalogSchema>(context: context, semantic: semantic ? searcher : nil, configuration: configuration)
            await service.waitUntilReady()
            for query in ofLocale {
                var final: SearchSnapshot<CatalogSchema>?
                for await snapshot in await service.results(for: query.query, trigger: .submit) where snapshot.isFinal {
                    final = snapshot
                }
                outcomes[query.id] = Outcome(ranked: final?.hits.map(\.id) ?? [], channels: final?.hits.map(\.channels) ?? [])
            }
        }
        return outcomes
    }

    func report(_ title: String, _ queries: [GoldenQuery], _ outcomes: [String: Outcome], items: [AnySearchable<CatalogKind>], verbose: Bool) {
        print("---- \(title)")
        for queryClass in GoldenQueryClass.allCases {
            let ofClass = queries.filter { $0.queryClass == queryClass }
            var values: [Double] = []
            var failures: [String] = []
            for query in ofClass {
                let ranked = outcomes[query.id]?.ranked ?? []
                let value: Double
                switch queryClass {
                case .exactTitle, .localizedTitle:
                    value = RelevanceMetrics.isRankOne(ranked, judgments: query.judgments) ? 1 : 0
                case .titlePrefix:
                    value = RelevanceMetrics.reciprocalRank(ranked, judgments: query.judgments, at: 10)
                case .typo, .paraphrase, .crossLanguage:
                    value = RelevanceMetrics.recall(ranked, judgments: query.judgments, at: 10)
                case .keyword:
                    value = RelevanceMetrics.ndcg(ranked, judgments: query.judgments, at: 10)
                case .filterAndKind:
                    value = RelevanceMetrics.precision(ranked, allowed: query.allowedIDs(in: items))
                }
                values.append(value)
                if value < 0.999 {
                    let position = ranked.firstIndex(of: query.sourceID).map { "\($0 + 1)" } ?? "-"
                    failures.append("    \(query.id) [\(query.locale)] «\(query.text)» value \(String(format: "%.2f", value)) source@\(position) relevant \(query.judgments.count) top3 \(ranked.prefix(3).map { GoldenCorpus.entry(for: $0)?.title ?? $0.rawValue })")
                }
            }
            var byVariant: [String: [Double]] = [:]
            for (query, value) in zip(ofClass, values) { byVariant[query.variant, default: []].append(value) }
            let variants = byVariant.keys.sorted().map { "\($0)=\(String(format: "%.3f", RelevanceMetrics.mean(byVariant[$0] ?? [])))(\(byVariant[$0]?.count ?? 0))" }
            print(String(format: "%@: %d queries, mean %.4f, below 1: %d", queryClass.rawValue, ofClass.count, RelevanceMetrics.mean(values), failures.count), variants.joined(separator: " "))
            if verbose { for failure in failures.prefix(8) { print(failure) } }
        }
    }

    func testGoldenSetAgainstFrozenCore() async {
        let queries = GoldenSet.queries
        let golden = GoldenCorpus.items
        let lexical = await run(queries, items: golden, dimensions: 64, semantic: false)
        report("golden corpus, lexical and fuzzy only", queries, lexical, items: golden, verbose: false)
        let outcomes = await run(queries, items: golden, dimensions: 64)
        report("golden corpus, 64 dimensions", queries, outcomes, items: golden, verbose: true)
        let tolerant = await run(queries, items: golden, dimensions: 64, partialWords: true)
        report("golden corpus, 64 dimensions, partial words recognized", queries, tolerant, items: golden, verbose: true)
    }

    /// The same among distractors. Slow in a debug build, so it only runs when asked:
    /// `ZTRON_FIXTURES_DISTRACTORS=20000 swift test -c release --filter EngineSmokeTests`.
    func testGoldenSetAmongDistractors() async throws {
        let requested = ProcessInfo.processInfo.environment["ZTRON_FIXTURES_DISTRACTORS"].flatMap(Int.init) ?? 0
        try XCTSkipIf(requested <= 0, "set ZTRON_FIXTURES_DISTRACTORS to a number of distractors to run this diagnostic")
        let queries = GoldenSet.queries
        let combined = SyntheticCorpus.combined(seed: 2026, count: requested)
        let start = Date()
        let outcomes = await run(queries, items: combined, dimensions: 64)
        report("golden + \(requested) distractors, 64 dimensions (\(Int(Date().timeIntervalSince(start))) s)", queries, outcomes, items: combined, verbose: true)
        let wide = await run(queries, items: combined, dimensions: 384)
        report("golden + \(requested) distractors, 384 dimensions", queries, wide, items: combined, verbose: false)
        let tolerant = await run(queries, items: combined, dimensions: 64, partialWords: true)
        report("golden + \(requested) distractors, 64 dimensions, partial words recognized", queries, tolerant, items: combined, verbose: false)
        let reference = await run(queries, items: combined, dimensions: 384, partialWords: true)
        report("golden + \(requested) distractors, 384 dimensions, partial words recognized", queries, reference, items: combined, verbose: true)
        let lexical = await run(queries, items: combined, dimensions: 64, semantic: false)
        report("golden + \(requested) distractors, lexical and fuzzy only", queries, lexical, items: combined, verbose: true)
    }
}
