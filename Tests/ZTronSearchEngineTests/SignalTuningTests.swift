import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// How the signal weights of `RankingProfile` are tuned from the relevance judgments of the
/// golden set (milestone 7).
///
/// The sweep runs the golden set under one profile after another, each time against signals
/// that know nothing about relevance, and prints what every class is gated on next to its value
/// without signals. The shipped default (`SignalSpec.tunedWeight`) is the largest weight of the
/// sweep at which, with popularity and freshness both on, no exact-title or localized-title
/// query loses the first place and no class moves by a tenth of a percent, for every seed, among
/// 5,000 and among 100,000 distractors. `RelevanceTests.testSignalsLeaveEveryGateStanding` then
/// holds the shipped profile to it on every run.
///
/// What the sweep shows beyond the default: a relevance-blind popularity breaks a rank-one gate
/// at 3% of the top fused score, a freshness with a year's half-life at 5%, kind boosts at 1%
/// and affinities at 2%; each starts costing queries at half that.
///
/// A host with real popularity data tunes the same way: its own providers in place of the
/// relevance-blind ones, its own judged queries in place of the golden set.
///
///     ZTRON_TUNE_SIGNALS=1 swift test -c release -Xswiftc -enable-testing --filter SignalTuningTests
///     ZTRON_TUNE_SIGNALS=1 ZTRON_FULL_CORPUS=1 swift test -c release -Xswiftc -enable-testing --filter SignalTuningTests
final class SignalTuningTests: XCTestCase {
    struct Candidate {
        var label: String
        var popularity: Double = 0
        var freshness: (weight: Double, halfLifeDays: Double)?
        var kindBoost: Double = 0
        var affinity: Double = 0
        /// Candidates that read no seeded signal are run once.
        var isSeeded: Bool { popularity > 0 || affinity > 0 }

        var profile: RankingProfile {
            var profile = RankingProfile.default
            profile.popularity = popularity > 0 ? SignalSpec(weight: popularity) : nil
            profile.freshness = freshness.map { .freshness(halfLifeDays: $0.halfLifeDays, weight: $0.weight) }
            profile.kindBoosts = kindBoost > 0
                ? ["tip": 1 + kindBoost, "game": 1 + kindBoost / 2, "map": 1 - kindBoost / 2, "image": 1 - kindBoost]
                : [:]
            return profile
        }
    }

    static let seeds: [UInt64] = [1, 2, 3]

    static var candidates: [Candidate] {
        var list = [Candidate(label: "no signals")]
        for weight in [0.15, 0.10, 0.05, 0.03, 0.02, 0.015, 0.01, 0.005] {
            list.append(Candidate(label: "popularity \(weight)", popularity: weight))
        }
        for weight in [0.10, 0.05, 0.03, 0.02, 0.015, 0.01, 0.005] {
            list.append(Candidate(label: "freshness \(weight), half-life 30 d", freshness: (weight, 30)))
        }
        for weight in [0.05, 0.02, 0.01] {
            list.append(Candidate(label: "freshness \(weight), half-life 365 d", freshness: (weight, 365)))
        }
        for boost in [0.20, 0.10, 0.05, 0.02, 0.01, 0.005] {
            list.append(Candidate(label: "kind boosts ±\(boost)", kindBoost: boost))
        }
        for spread in [0.20, 0.05, 0.02, 0.01, 0.005] {
            list.append(Candidate(label: "affinity ±\(spread)", affinity: spread))
        }
        for (popularity, freshness) in [(0.02, 0.01), (0.01, 0.01), (0.01, 0.005), (0.005, 0.005)] {
            list.append(Candidate(label: "popularity \(popularity) + freshness \(freshness) (30 d)", popularity: popularity, freshness: (freshness, 30)))
            list.append(Candidate(
                label: "popularity \(popularity) + freshness \(freshness) (30 d) + kind boosts ±0.005 + affinity ±0.005",
                popularity: popularity, freshness: (freshness, 30), kindBoost: 0.005, affinity: 0.005
            ))
        }
        return list
    }

    func testSweep() async throws {
        guard ProcessInfo.processInfo.environment["ZTRON_TUNE_SIGNALS"] != nil else {
            throw XCTSkip("the tuning sweep runs on request: ZTRON_TUNE_SIGNALS=1")
        }
        let distractors = RelevanceTests.Evaluation.distractorCount
        let items = SyntheticCorpus.combined(seed: 2026, count: distractors)
        let searcher = FakeSemanticSearcher(provider: FakeEmbeddingProvider(dimensions: 384, recognizesPartialWords: true))
        await searcher.index(items)
        let candidates = Self.candidates
        var allowed: [String: Set<SearchableID>] = [:]
        for query in GoldenSet.queries(of: .filterAndKind) { allowed[query.id] = query.allowedIDs(in: items) }

        // values[candidate][seed][query id]
        var values = [[[String: Double]]](repeating: [], count: candidates.count)
        for locale in ["en", "it", "de", "ja"] {
            let queries = GoldenSet.queries.filter { $0.locale == locale }
            guard !queries.isEmpty else { continue }
            let signals = RelevanceBlindSignals()
            let configuration = SearchEngineConfiguration(
                locale: Locale(identifier: locale), followsSystemLocale: false, secondaryLanguages: .none,
                preferredLanguages: { [] }, reranking: .off, lexicalDebounce: 0, semanticDebounce: 0,
                semanticHardCap: 60, assertsOnProgrammerError: false, now: { GoldenCorpus.referenceDate }
            )
            let service = SearchService<CatalogSchema>(
                index: LexicalIndex(), semantic: searcher, profile: .default,
                signals: SignalProviders(popularity: signals, personalization: signals), configuration: configuration
            )
            await service.index(items)
            for (position, candidate) in candidates.enumerated() {
                await service.setProfile(candidate.profile)
                let seeds = candidate.isSeeded ? Self.seeds : [Self.seeds[0]]
                if values[position].isEmpty { values[position] = Array(repeating: [:], count: seeds.count) }
                for (seedPosition, seed) in seeds.enumerated() {
                    signals.configure(seed: seed, affinitySpread: candidate.affinity)
                    for query in queries {
                        var ranked: [SearchableID] = []
                        for await snapshot in await service.results(for: query.query, trigger: .submit) where snapshot.isFinal {
                            ranked = snapshot.hits.map(\.id)
                        }
                        values[position][seedPosition][query.id] = query.gatedValue(ranked: ranked, allowed: allowed[query.id] ?? [])
                    }
                }
            }
        }

        let classes = GoldenQueryClass.allCases
        func mean(_ queryClass: GoldenQueryClass, _ run: [String: Double]) -> Double {
            RelevanceMetrics.mean(GoldenSet.queries(of: queryClass).map { run[$0.id] ?? 0 })
        }
        let baseline = values[0][0]
        print("TUNE \(distractors) distractors, \(GoldenSet.queries.count) queries, seeds \(Self.seeds)")
        print("TUNE classes: " + classes.map(\.rawValue).joined(separator: " | "))
        for (position, candidate) in candidates.enumerated() {
            var cells: [String] = []
            var costsAClass = false
            var breaksAGate = false
            for queryClass in classes {
                let perSeed = values[position].map { mean(queryClass, $0) }
                let worst = perSeed.min() ?? 0
                if worst < mean(queryClass, baseline) - GoldenQueryClass.regressionTolerance { costsAClass = true }
                if worst < queryClass.gate { breaksAGate = true }
                cells.append(String(format: "%.4f", worst))
            }
            var worse = 0
            var better = 0
            for run in values[position] {
                for query in GoldenSet.queries {
                    let before = baseline[query.id] ?? 0
                    let after = run[query.id] ?? 0
                    if after < before - 1e-9 { worse += 1 } else if after > before + 1e-9 { better += 1 }
                }
            }
            let verdict = breaksAGate ? "BREAKS A GATE" : (costsAClass ? "costs a class" : "no regression")
            print("TUNE \(candidate.label): worst seed \(cells.joined(separator: " | ")) | queries worse \(worse), better \(better), of \(values[position].count * GoldenSet.queries.count) | \(verdict)")
        }
    }
}
