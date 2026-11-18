# Cycle 1, slice s06-quality: spec sections 15-18 (pages 42-58)

Auditor: C1-s06-quality. Repository: /Users/admin/Documents/ZTronSearchEngine at cee4620.
Evidence used: the spec text, the sources and tests, CI workflows, ParityHost/Results/summary.md,
the run log Verification/_runs/c1-debug-swift-test.log (debug `swift test` of the root package:
4 bundles, 580 tests, 0 failures, 22 skipped, PerformanceTests all skipped in DEBUG), a grep of
Verification/_runs/c2-tsan-swift-test.partial (0 ThreadSanitizer warnings at the time of the grep),
and one scratch XCTest package (path in finding 02). No release run of the package was available.

Status legend: met / partial / missing / contradicted / unverifiable (unverifiable-here).
"Proxy" = the test asserts the budget divided by ReferenceDevice.slowdown (6 on a Mac) in a release
build only; no release log exists, so a proxy that is the only evidence counts as unverifiable.
Section 16 rows marked met: a test with assertions exists for the item and passed in the cycle-1
debug log (adapter tests: present with assertions, not run here); bodies were spot-read, not all
reviewed line by line (see Not checked).

## Requirement table

| R# | Section/page | Requirement | Status | Code | Test |
|---|---|---|---|---|---|
| R1 | 15 p42 | Every target is a p95 on iPhone 6s / iOS 15.8 / 100k items / Release, over the golden query set | unverifiable | Sources/ZTronSearchFixtures/ReferenceDevice.swift:17-43 | PerformanceTests (release only; see finding 07 for the query set) |
| R2 | 15.1 p42 | Tokenization + normalization, query <= 64 chars: 0.3 ms | unverifiable (proxy) | ReferenceDevice.swift (PerformanceBudget) | PerformanceTests.swift:102-120 |
| R3 | 15.1 p42 | Prefix lookup: 3 ms | unverifiable (proxy; timing gap, finding 07) | QueryPlanner.swift:133-162; IndexSearcher.swift:668 | PerformanceTests.swift:122-147 |
| R4 | 15.1 p42 | BM25F scoring <= 2,000 candidates: 3 ms | unverifiable (proxy) | IndexSearcher.swift:648-725 | PerformanceTests.swift:122-147 |
| R5 | 15.1 p42 | Fuzzy expansion, 8 per token: 6 ms | unverifiable (proxy) | QueryPlanner.swift:160-177 | PerformanceTests.swift:122-147 |
| R6 | 15.1 p42 | RRF over 3 x 200: 0.5 ms | unverifiable (proxy) | Ranking/Fusion | PerformanceTests.swift:149-174 |
| R7 | 15.1 p42 | First lexical snapshot: 12 ms | unverifiable (proxy) | SearchService.swift:368-422 | PerformanceTests.swift:178-197 |
| R8 | 15.1 p42 | Query embedding 180 ms; hard cap 300 ms then skip | partial: cap implemented and tested; 180 ms needs a model | SearchEngineConfiguration.swift:164; SearchService.swift:547-623 | SnapshotPipelineTests testASemanticCapBreachSkipsTheChannelAndTheLexicalSnapshotStands |
| R9 | 15.1 p42 | HNSW top 50: 5 ms, recall@10 >= 0.95 | partial: recall 0.9940 / 0.9999 at 20k in the debug log; 100k and latency only in the CI large release job | Sources/ZTronSearchEngineSemantic/HNSW | HNSWRecallTests.swift:37-66, 130-250 |
| R10 | 15.1 p42 | Semantic snapshot 500 ms incl. 300 ms debounce | partial (finding 06) | SearchService.swift:424-444, 547-614 | PerformanceTests.swift:244-275 |
| R11 | 15.1 p42 | Rerank 16 pairs 250 ms; cap 400 ms | partial: cap tested; 250 ms needs a model | SearchEngineConfiguration.swift:165; SearchService.swift:681-738 | SnapshotPipelineTests testARerankCapBreachFallsBackToTheFusedOrderAndThreeBreachesDisableTheStage |
| R12 | 15.1 p42 | Final reranked snapshot: 750 ms | missing (finding 06; PerformanceBudget.rerankedSnapshot unused) | - | none |
| R13 | 15.1 p42 | Next page of 20 hits: 8 ms | unverifiable (proxy) | SearchService.swift:300-307 | PerformanceTests.swift:199-217 |
| R14 | 15.1 p42 | Cold start from memory-mapped index: 250 ms | unverifiable (proxy) | LexicalIndex load | PerformanceTests.swift:279-299 |
| R15 | 15.1 p42 | Full lexical rebuild on locale change 2 s, never blocking a query | contradicted (self-declared known gap; finding 02) | SearchService.swift:892-903 | PerformanceTests.swift:301-328 |
| R16 | 15.1 p43 | Incremental upsert 0.1 ms amortized per document | contradicted (self-declared known gap; finding 02) | Index write path | PerformanceTests.swift:330-398 |
| R17 | 15.1 p43 | Main-thread publish of 20 hits 1 ms; no frame over 16.7 ms from search | partial: 1 ms proxy; frame rule untested | ZTronSearchResultsModel.swift:130-142 | ResultsModelTests.swift:268-289 |
| R18 | 15.2 p43 | Lexical index 100k, active + base: 40 MB | unverifiable (proxy, release only) | - | PerformanceTests.swift:402-438 |
| R19 | 15.2 p43 | Each secondary language: 10 MB | unverifiable (proxy, structural bytes) | - | PerformanceTests.swift:440-453 |
| R20 | 15.2 p43 | Item vectors 100k x 384 INT8: 40 MB | partial: file size, ZTRON_SEMANTIC_LARGE run only | QuantizedVectorStore | HNSWRecallTests.swift:56-58 |
| R21 | 15.2 p43 | HNSW graph M=16: 20 MB | partial: file size, large run only | HNSW | HNSWRecallTests.swift:56-58 |
| R22 | 15.2 p43 | Embedding model loaded 80 MB; reload after unload <= 800 ms | partial: on-disk size budget only; reload time untested (finding 05) | SemanticError.swift:78-83; CoreMLEmbeddingProvider.swift:149-153 | CoreMLAdapterTests |
| R23 | 15.2 p43 | Steady state, models unloaded: 110 MB | missing (finding 05) | - | none |
| R24 | 15.2 p43 | Peak during a semantic query: 200 MB | missing (finding 05) | - | none |
| R25 | 15.2 p43 | Reranker loaded: 60 MB | partial: on-disk size only (finding 05) | CoreMLCrossEncoder.swift:49 | CoreMLAdapterTests |
| R26 | 15.2 p43 | Peak during a reranked query: 320 MB | missing (finding 05) | - | none |
| R27 | 15.3 p43 | Golden set >= 300 judged queries, 5 item types, >= 3 languages incl. non-Latin, graded | met (483 queries) | Sources/ZTronSearchFixtures/GoldenSet.swift validate() | RelevanceTests testTheGoldenSetIsWhatSection15Asks (line ~150-160) |
| R28 | 15.3 p43 | Thresholds are release acceptance gates (fail the build) | met | - | RelevanceTests asserts; ci.yml unit + quality-targets (ZTRON_FULL_CORPUS=1) |
| R29 | 15.3 p43 | Exact title rank 1 in >= 98% | met (1.0000 at 5k distractors, debug log) | - | RelevanceTests.swift:180-196 |
| R30 | 15.3 p43 | Title prefix >= 3 chars MRR@10 >= 0.85 | met (0.9867) | - | RelevanceTests.swift:180-196 |
| R31 | 15.3 p43 | Typos <= 2 edits on tokens >= 6 chars Recall@10 >= 0.90 | met (0.9855) | - | RelevanceTests.swift:180-196 |
| R32 | 15.3 p44 | Keyword/tag NDCG@10 >= 0.80 | met (1.0000) | - | RelevanceTests.swift:180-196 |
| R33 | 15.3 p44 | Paraphrase Recall@10 >= 0.75 | unverifiable (oracle FakeEmbeddingProvider; no model shipped) | - | RelevanceTests testParaphraseRecall |
| R34 | 15.3 p44 | Cross-language Recall@10 >= 0.70 | unverifiable (oracle fake) | - | RelevanceTests testCrossLanguageRecall |
| R35 | 15.3 p44 | Localized title rank 1 >= 95%; localized beats base | met | - | RelevanceTests; InternationalizationTests.swift:134-153 |
| R36 | 15.3 p44 | Filter/kind precision 1.0; no hit violates a hard constraint | partial: precision scores an empty list as 1 (finding 09) | RelevanceMetrics.swift:66-71 | RelevanceTests.swift:185,196,198-215 |
| R37 | 15.3 p44 | Reranked head NDCG@10 >= 0.85, never below fused for any class | unverifiable (oracle FakeReranker; pipeline check present) | - | RelevanceTests.swift:264-280 |
| R38 | 15.4 p44 | Zero stale snapshots over randomized 10,000 query changes | met at the model boundary; service-level test weaker than it claims (finding 08) | ZTronSearchResultsModel.swift:130-142; SearchService.swift:278-296 | ResultsModelTests.swift:119-150; ConcurrencyTests.swift:157-219 |
| R39 | 15.4 p44 | Cancellation honoured within 10 ms of the next checkpoint | met (debug) | IndexSearcher.swift:648-725 | ConcurrencyTests testCancellationDuringTheIndexSearchIsHonouredAtTheNextCheckpoint |
| R40 | 15.4 p44 | Zero duplicate page requests | met | ZTronSearchResultsModel.swift:158-183 | ResultsModelTests testARepeatedTriggerNeverDuplicatesAPageRequest; AttachmentModifierTests testAFooterLoadsExactlyOnePagePerCursor... |
| R41 | 15.4 p44 | Thread Sanitizer clean under Swift 6 strict concurrency | unverifiable (CI job exists; partial cycle-2 log had 0 warnings) | Package.swift (Swift 6 mode) | ci.yml thread-sanitizer |
| R42 | 15.5 p44 | Cap breach skips channel, reported in degraded; lexical never withheld | met | SearchService.swift:547-623 | SnapshotPipelineTests testASemanticCapBreachSkips... |
| R43 | 15.5 p44 | 3 semantic breaches or memory warning disable semantic for the session; re-enabled on foreground | met | SearchService.swift:616-623, 767-785, 793-803 | SnapshotPipelineTests testThreeConsecutiveSemanticBreaches..., testAMemoryWarningDisables..., testTheMemoryWarningNotificationIsObserved |
| R44 | 15.5 p44 | Rerank > 400 ms skipped, fused order stands; 3 breaches disable for session and force recalibration next launch | met | SearchService.swift:681-738 (734 invalidateCalibration) | SnapshotPipelineTests:391-420; RerankCalibrationGateTests testInvalidationTurnsTheStageOff... |
| R45 | 15.5 p44 | Model that cannot meet 80/60 MB is not shipped; engine runs affordable channels | partial: on-disk size check only (finding 05) | SemanticError.swift:78-83 | CoreMLAdapterTests |
| R46 | 15.6 p44 | LLM load cold/warm 4 s / 1 s | unverifiable (weights + Metal toolchain; test skips) | Adapters/ZTronSearchEngineMLX | Qwen3IntegrationTests.swift:180-202 |
| R47 | 15.6 p45 | TTFT, 512-token prompt: 2 s p95 | unverifiable | - | Qwen3IntegrationTests.swift:320-350 |
| R48 | 15.6 p45 | Decode 12 tok/s p50, 8 p95; below 8 calibration disables chat | partial: disable logic tested on fakes; rates unverifiable | Chat calibration | ChatTests testCalibrationEnablesOnlyInsideItsThresholds...; MLX ChatCalibrationTests |
| R49 | 15.6 p45 | Resident 1.8 GB during generation; LLM unloads before embedding model on memory warning | partial: ordering tested; footprint test macOS-only and skipped without weights | ChatService | ChatTests testTheLanguageModelUnloadsBeforeTheEmbeddingModel...; Qwen3IntegrationTests.swift:523-539 |
| R50 | 15.6 p45 | Download 968 MB, resumable, SHA-256 verified; verified file never re-downloaded | unverifiable (AssetKit adapter needs external ZTronAssetKit; fakes only here) | Adapters/ZTronSearchEngineAssetKit | AssetKit FetchTests/AvailabilityTests; ChatTests resume tests |
| R51 | 15.6 p45 | Cancellation within one token, <= 150 ms | partial: fake runtime tested; real runtime test skips | ChatService | ChatTests testCancelDuringGenerationStopsWithinOneToken; Qwen3IntegrationTests.swift:358-394 |
| R52 | 15.6 p45 | Grounded answers on a 100-question golden set: >= 90% cite correct source, 100% unknown citations dropped, >= 80% decline | missing (finding 03) | - | none |
| R53 | 15.7 p45 | Pixel snapshot <= 0.5% pixels, no pixel > ΔE 2 | contradicted (finding 01) | ParityHost comparators (PixelComparator.swift:154-155) | ParityHost/Results/summary.md |
| R54 | 15.7 p45 | Layout metrics within 0.5 pt | contradicted (finding 01) | MetricsComparator.swift:45 | summary.md |
| R55 | 15.7 p45 | Event log identical after dropping the one notification | contradicted (finding 01; e.g. 246/248 on iPhone 15 17.5, none run on 15.5/16.4) | EventLogComparator.swift | summary.md |
| R56 | 15.7 p45 | Accessibility tree identical | contradicted (finding 01) | ParitySession.swift | summary.md |
| R57 | 15.7 p45 | Text-to-token animation within one frame, same final frame | contradicted (finding 01) | AnimationComparator.swift:72 | summary.md |
| R58 | 15.7 p45 | Only 12.5 deviations; any other difference fails the build | met (mechanism: gate.py) | ParityHost/Tools/gate.py | .github/workflows/parity.yml |
| R59 | 15.8 p46 | Scan context creation 5 ms (40) / 50 ms (500) | partial: settings-sized proxy asserted; catalog-sized 500 is a known gap (finding 02) | ScanIndex | PerformanceTests.swift:507-537 |
| R60 | 15.8 p46 | Scan query p95 0.5 ms / 3 ms | unverifiable (proxy; catalog-sized check can be absorbed, finding 02) | ScanIndex | PerformanceTests.swift:507-537 |
| R61 | 15.8 p46 | Resident memory per context 100 KB / 1 MB | unverifiable (proxy heap delta; catalog-sized only printed) | - | PerformanceTests.swift:479-503, 536 |
| R62 | 15.8 p46 | One final snapshot per query | met | SearchService scan path | SearchContextTests.swift:124-137 |
| R63 | 15.8 p46 | Ranking identical to the indexed strategy | met | - | StrategyParityTests.swift:16-43 |
| R64 | 15.8 p46 | No disk I/O | met | - | SearchContextTests.swift:294-309 |
| R65 | 15.9 p46 | 10k rows context creation 1.5 s, pages of 500, never blocking a query on an existing generation | partial: fake proxy only; non-blocking not asserted; real SQLite not in CI (finding 04) | Database sources | PerformanceTests.swift:571-592; DatabaseTargetsTests.swift:68-70 |
| R66 | 15.9 p46 | One page read+resolve+project 500 rows: 40 ms | partial (finding 04) | - | PerformanceTests.swift:596-616 |
| R67 | 15.9 p46 | Upsert of 100 changed rows: 50 ms after commit | partial (finding 04) | ConfinedConnection.swift:52-56 (hooks) | PerformanceTests.swift:617-638 |
| R68 | 15.9 p46 | Resident memory per 10k-row context: 6 MB | partial (fake; finding 04) | - | PerformanceTests.swift:591 |
| R69 | 15.9 p46 | Query latency unchanged (same strategy as memory items) | met (one document set, one strategy) | SearchContext assembly | DatabaseSourceTests testAMixedContextRanksIdentically... |
| R70 | 15.9 p46 | Index round trip in host DB, 10k docs: 400 ms write, 250 ms load | partial (fake; finding 04) | DatabaseIndexStore.swift:5-36 | PerformanceTests.swift:639-657 |
| R71 | 15.9 p46 | Database row vs same item in memory: identical score and order | met | - | DatabaseSourceTests testAMixedContextRanksIdentically... (RankingFingerprint equality) |
| R72 | 16 p47 | Async XCTest on the iOS 15 floor | unverifiable (ci.yml ios job, OS 15.5; no iOS 15 simulator here) | Package.swift | ci.yml ios |
| R73 | 16 p47 | Thread Sanitizer on in CI | met | - | ci.yml thread-sanitizer; adapter-tests.yml:63 |
| R74 | 16 p47 | Performance tests record baselines on the reference device with XCTClockMetric and XCTMemoryMetric | partial: metric tests exist, no baselines recorded (no .xcbaseline) | - | PerformanceTests.swift:663-689 |
| R75 | 16 p47 | Relevance tests load the golden fixtures and fail below the section 15 gates | met | - | RelevanceTests |
| R76 | 16 p47 | Exact-title ranking; body and caption matching; prefix matching | met | - | CoreCorrectnessTests testExactTitleRanksFirst, testBodyMatching, testCaptionAndOCRMatching, testPrefixMatchingOnTheLastToken |
| R77 | 16 p47 | Empty/too-short queries: empty final snapshot without semantic | met | - | CoreCorrectnessTests testEmptyAndTooShortQueries... |
| R78 | 16 p47 | Unicode, diacritic, NFKC and width folding | met | - | TextPipelineTests testCaseAndDiacriticFolding, testNFKCFolding, testWidthFolding |
| R79 | 16 p47 | Fuzzy at distance 1 and 2; no expansion for IDs, URLs, tokens | met | - | CoreCorrectnessTests testFuzzyCorrectionAtDistanceOne/Two, testNoExpansionForIdentifiersURLsAndModelNumbers, testFiltersAreNeverFuzzed... |
| R80 | 16 p47 | Valid kinds; unknown kind dropped and logged; hitsByKind partitions | met | - | CoreCorrectnessTests (3 tests) |
| R81 | 16 p47 | FilterRecord round trip; unknown records ignored; AND/OR; ZTronStringSchema | met | - | CoreCorrectnessTests (5 tests) |
| R82 | 16 p47 | Filters and kind tokens as hard constraints | met | - | CoreCorrectnessTests testFiltersAndKindTokensAreHardConstraints; RelevanceTests:198-215 |
| R83 | 16 p47 | Context disjointness incl. statistics, signals, contextID | met | - | SearchContextTests:25-64, testStatisticsAreNotSharedBetweenContexts |
| R84 | 16 p47 | Scan vs indexed identical, property test up to 500 docs | met | - | StrategyParityTests.swift:16-43 |
| R85 | 16 p47 | 40-doc context meets 15.8 timings on the reference device; no disk I/O | partial: no-disk-I/O met; timing proxy only | - | PerformanceTests.swift:507-525; SearchContextTests.swift:294-309 |
| R86 | 16 p47 | replace(items:) and release free everything; no growth over 1,000 cycles | met | - | SearchContextTests.swift:342-384, testReplaceItemsIsWholesale |
| R87 | 16 p47 | Context with its own locale | met | - | SearchContextTests testAContextWithItsOwnLocale... |
| R88 | 16 p47 | ScanIndex.hits from main actor in the same run-loop turn | met | - | SearchContextTests.swift:256-276; ResultsModelTests testAScanModelPublishes...SameTurn |
| R89 | 16 p47 | Database tests with in-memory fake boundary and fake resolver, no SQLite in core | met | FakeSearchDatabase.swift:11 | DatabaseSourceTests; LintTests testNoProductImportsAThirdPartyPackage |
| R90 | 16 p47 | SQL composition snapshots: quoting, predicate, paging, bindings | met | - | DatabaseSourceTests testSQLCompositionSnapshots, testIdentifiersAreQuoted... |
| R91 | 16 p47 | One read transaction per page; cancellation between pages | met | - | DatabaseSourceTests (3 tests) |
| R92 | 16 p47 | Literal, localized-key, per-row projection; fallback chain; unresolved keys | met | - | DatabaseSourceTests (4 tests) |
| R93 | 16 p48 | Mixed context ranks like all-memory | met | - | DatabaseSourceTests testAMixedContextRanksIdentically... |
| R94 | 16 p48 | Filters rebuilt from filter columns; id collisions debug-asserted | met | - | DatabaseSourceTests (2 tests) |
| R95 | 16 p48 | Change stream: upsert, remove, refresh, batching, generation guard | met | - | DatabaseSourceTests (11 tests) |
| R96 | 16 p48 | Index-in-database: round trip, atomic swap, rebuild on mismatch | met | DatabaseIndexStore.swift | DatabaseSourceTests (4 tests) |
| R97 | 16 p48 | Adapter integration target: connections, transactions, hooks, expressions, WAL | met (not run here) | Adapters/ZTronSearchEngineSQLite | ConnectionTests (incl. :161 WAL), TransactionTests, ChangeStreamTests, ExpressionRenderingTests |
| R98 | 16 p48 | Localized title wins; base wins when localization empty | met | - | InternationalizationTests (2 tests) |
| R99 | 16 p48 | Fallback chain it-IT -> it -> base | met | - | InternationalizationTests testFallbackChain... |
| R100 | 16 p48 | Secondary languages through localizedAlt at low weight | met | - | InternationalizationTests testSecondaryPreferredLanguagesHit... |
| R101 | 16 p48 | CJK bigram tokenization and prefix matching | met | - | InternationalizationTests testCJKBigram...; TextPipelineTests testCJKEmits... |
| R102 | 16 p48 | Locale change rebuilds under a new generation, queries keep working | met | SearchService.swift:892-903 | InternationalizationTests.swift:233-283 |
| R103 | 16 p48 | Cross-language semantic retrieval with the deterministic fake | met | - | SemanticIndexTests testNearestRanksByCosineSimilarityAcrossLanguages; RelevanceTests testCrossLanguageRecall |
| R104 | 16 p48 | Cancellation before, during, after index search | met | - | ConcurrencyTests (4 tests) |
| R105 | 16 p48 | Stale-result suppression with randomized sequences | met (model layer); finding 08 on the service-level test | - | ResultsModelTests.swift:119-150; ConcurrencyTests.swift:157-244 |
| R106 | 16 p48 | Pagination reset on query change; duplicate-page prevention | met | ZTronSearchResultsModel.swift:158-183 | ResultsModelTests (2 tests) |
| R107 | 16 p48 | No deadlock under reentrant calls into SearchService | met | - | ConcurrencyTests.swift:248-296 |
| R108 | 16 p48 | Parity comparisons on every matrix cell within 15.7; references regenerated per iOS release | contradicted (finding 01) | ParityHost | parity.yml; summary.md |
| R109 | 16 p48 | Token scripts incl. overflow scrolling | partial: core-model tests; overflow only in parity scripts that do not pass | ParityScript.swift | SearchFieldCoreTests |
| R110 | 16 p48 | Sentinel never in text binding, accessibility tree, parity log | partial: checks implemented (ParitySession.swift:184-212), run only on cells that ran | - | SearchFieldCoreTests testTheSentinelNeverReaches...; ComparatorTests:243-250 |
| R111 | 16 p49 | Focus, submit, clear, cancel; every 12.3 modifier fires once per UIKit callback | partial: parity event-log comparison not passing on the matrix | - | SearchFieldCoreTests; parity matrix |
| R112 | 16 p49 | isZTronSearching tracks isLoading | met | - | AttachmentModifierTests testIsZTronSearchingTracksIsLoading |
| R113 | 16 p49 | Lint fails on import UIKit, UIViewRepresentable, UI-prefixed types | met | SourceLint.swift | LintTests testTheUIProductNeverUsesUIKit, testTheUIKitLintCatchesWhatItShould |
| R114 | 16 p49 | .zTronSearch forwards changes, injects model, sets isZTronSearching | met | - | AttachmentModifierTests |
| R115 | 16 p49 | Reading a model via @EnvironmentObject without attaching modifier fails lint | partial (finding 10) | SourceLint.swift:211-240 | LintTests:154-161 |
| R116 | 16 p49 | .zTronLoadsNextPage loads one page per cursor | met | - | AttachmentModifierTests |
| R117 | 16 p49 | .zTronSuggestions only at/above minimumQueryLength | met | - | AttachmentModifierTests |
| R118 | 16 p49 | .zTronChat prepare/never-nil/cancel; state survives | met | - | AttachmentModifierTests (3 tests) |
| R119 | 16 p49 | No modifier creates state | met | - | AttachmentModifierTests; LintTests testNoModifierCreatesState |
| R120 | 16 p49 | Calibration thresholds; .off never loads; recomputed after update | met | Calibration/RerankCalibrationGate.swift | RerankCalibrationGateTests; SnapshotPipelineTests testOffNeverLoadsTheModel |
| R121 | 16 p49 | Reordering confined to top 16 | met | - | RankingTests.swift:297-310 |
| R122 | 16 p49 | Cap breach falls back with degraded; 3 breaches disable | met | SearchService.swift:681-738 | SnapshotPipelineTests:391-420 |
| R123 | 16 p49 | Blend keeps an exact-title hit inside the head on the full golden set | partial (finding 11) | Ranking blend | RankingTests.swift:325-336; RelevanceTests.swift:283-292 |
| R124 | 16 p49 | Fake runtime and fake asset provider scripted states incl. offline | met | FakeChatBoundaries.swift:152-243 | ChatTests |
| R125 | 16 p49 | Lifecycle: resume, retry, cancel during download and generation | met | - | ChatTests (5 tests) |
| R126 | 16 p49 | Prompt budget trimming rules | met | CitationParser.swift:104-140 | ChatTests (3 tests) |
| R127 | 16 p49 | Citation parsing; unknown ids dropped and logged | met | - | ChatTests (3 tests) |
| R128 | 16 p49 | Grounding honours kinds, uses localized surface | met | - | ChatTests (2 tests) |
| R129 | 16 p50 | 6s profile -> unavailable(.device) without touching asset provider | met | - | ChatTests testTheIPhone6sProfileIsUnavailable... |
| R130 | 16 p50 | One generation at a time; unload idle/memory warning; history survives | met | - | ChatTests (4 tests) |
| R131 | 16 p50 | MLX integration tests run through xcodebuild on Apple silicon | unverifiable (documented in adapter README:260-290; CI uses swift test --build-system native where they skip) | - | Qwen3IntegrationTests.swift:8-43 |
| R132 | 16 p50 | Perf: 100k indexing, cold start, 15.1 table; 15.2 size and resident memory; HNSW recall on 1,000 sampled queries | partial: 15.1 table lacks R12; 15.2 resident budgets missing (findings 05, 06) | - | PerformanceTests; HNSWRecallTests (1,000 queries) |
| R133 | 17 p50-51 | Each milestone gated by its tests passing on the reference device | partial: milestone 4 gate (15.7) not met (finding 01); milestone 2 gate 15.9 not run on SQLite in CI (finding 04); device gates unverifiable | - | - |
| R134 | 18.1 p55 | WP1 SQL value types | met | SearchSQL, SearchBindingValue, SearchDatabaseLocation, SearchRow in Contracts | DatabaseSourceTests |
| R135 | 18.1 p55 | WP2 connection boundary | met | protocol SearchDatabase, SearchDatabaseConnection | DatabaseSourceTests |
| R136 | 18.1 p55 | WP3 reader/writer boundary | met | SearchDatabaseReader/Writer/Change | DatabaseSourceTests |
| R137 | 18.1 p55 | WP4 source descriptors | met | SearchStringEncoding, SearchStringField, SearchTableSource, SearchFilterColumn | DatabaseSourceTests |
| R138 | 18.1 p55 | WP5 resolver boundary | met | LocalizedStringResolving, SearchBundleID | DatabaseSourceTests |
| R139 | 18.1 p56 | WP6 context sources | met | SearchContext.swift (SearchSource, sources, localizedStrings, indexStorage) | SearchContextTests |
| R140 | 18.1 p56 | WP7 fake database | met | Sources/ZTronSearchFixtures/FakeSearchDatabase.swift:11 | DatabaseSourceTests |
| R141 | 18.1 p56 | WP8 fake resolver | met | FakeSearchDatabase.swift (FakeLocalizedStringResolver) | DatabaseSourceTests |
| R142 | 18.1 p56 | WP9 SQL composer | met | Database composer | testSQLCompositionSnapshots |
| R143 | 18.1 p56 | WP10 paged reader | met | - | testPagedReadsUseOneReadTransactionPerPage, testCancellationBetweenPages |
| R144 | 18.1 p56 | WP11 row projection | met | - | DatabaseSourceTests |
| R145 | 18.1 p56 | WP12 localized-key projection | met | - | testLocalizedKeysFollowTheFallbackChain, testUnresolvedKeys... |
| R146 | 18.1 p56 | WP13 per-row encoding | met | - | testLiteralLocalizedKeyAndPerRowFieldsInOneRow |
| R147 | 18.1 p56 | WP14 mixed-context assembly | met | - | testAMixedContext..., testIDCollisionsAcrossSourcesAreDebugAsserted |
| R148 | 18.1 p56 | WP15 change stream | met | - | DatabaseSourceTests change-stream tests |
| R149 | 18.1 p56 | WP16 refresh | met | SearchService+Context.swift (func refresh) | testAChangeWithoutRowIDsRefreshesItsTable |
| R150 | 18.1 p56 | WP17 index tables schema | met | DatabaseIndexStore.swift:5-36 (projectionVersion) | testIndexInDatabaseRoundTrip |
| R151 | 18.1 p56 | WP18 index write path | met | DatabaseIndexStore | testGenerationsSwapAtomically |
| R152 | 18.1 p56 | WP19 index read path | met | DatabaseIndexStore | testAStoredIndexOfAnotherVersionIsRebuilt |
| R153 | 18.1 p56 | WP20 adapter connection, documented @unchecked Sendable, serialized calls | met | SQLiteSearchDatabase.swift; SQLiteSearchConnection.swift:9-41 | ConnectionTests |
| R154 | 18.1 p56 | WP21 transactions, WAL recommendation, read-only locations | met | ConfinedConnection.swift:25-45, 79 | TransactionTests, ConnectionTests:161 |
| R155 | 18.1 p57 | WP22 Expression<String>/Table to SearchSQL | met | adapter | ExpressionRenderingTests |
| R156 | 18.1 p57 | WP23 update and commit hooks into the change stream | met | ConfinedConnection.swift:52-56 | ChangeStreamTests |
| R157 | 18.1 p57 | WP24 Bundle-backed resolver with per-language caching | met | BundleLocalizedStringResolver.swift | BundleLocalizedStringResolverTests |
| R158 | 18.1 p57 | WP25 tests: composer and reader | met | - | DatabaseSourceTests |
| R159 | 18.1 p57 | WP26 tests: projection | met | - | DatabaseSourceTests |
| R160 | 18.1 p57 | WP27 tests: mixed contexts | met | - | DatabaseSourceTests |
| R161 | 18.1 p57 | WP28 tests: change stream | met | - | DatabaseSourceTests |
| R162 | 18.1 p57 | WP29 tests: index-in-database | met | - | DatabaseSourceTests |
| R163 | 18.1 p57 | WP30 tests: adapter integration (separate target on SQLite.swift) | met | Adapters/ZTronSearchEngineSQLite/Package.swift | adapter test target |
| R164 | 18.1 p57 | WP31 performance tests vs 15.9 | partial (finding 04: real-SQLite test skips in debug, never run in CI) | - | PerformanceTests.swift:571-657; DatabaseTargetsTests.swift:68-70 |
| R165 | 18.1 p57 | WP32 adapter README and CI job | met | Adapters/ZTronSearchEngineSQLite/README.md | .github/workflows/adapter-tests.yml |

Counts: 165 requirements; met 100, partial 30, missing 5, contradicted 8, unverifiable 22.
Section 18 outside 18.1 (effort estimate, points, plan coverage) is not normative for the code
and is not numbered.

## Findings

### C1-s06-quality-01 (high, spec-deviation): the section 15.7 UI parity gate is not met
- Spec: 15.7 p45 (every cell of the 12.5 matrix); 16 p48 parity suite; 17 milestone 4 gate.
- Locations: ParityHost/Results/summary.md:1-30; README.md:216-218; .github/workflows/parity.yml; ParityHost/Tools/gate.py.
- Evidence: summary.md, coverage table: 7,440 cell results; 781 ran, 179 passed, 602 failed, 6,659 not
  runnable. All 3,200 iOS 15.5 and 3,200 iOS 16.4 results are "not runnable"; no iPad or iPhone SE
  cell passes on any iOS; iOS 27.0 passes nothing. Worst numbers: pixel 55.394% (limit 0.5%), ΔE
  100 (limit 2), metric 254.5 pt (limit 0.5 pt). README.md:216-218 states the gate is not met.
- Failure scenario: on an iPad, an iPhone SE or any iOS 15/16 device the field renders and behaves
  outside the parity thresholds (or unverified), which the spec says fails the build.
- Knock-down: the README is transparent, so it is not a false claim; still a stated gate not met.

### C1-s06-quality-02 (high, test-integrity): missed budgets become expected failures, and the expectation also swallows later assertions
- Spec: 15.1 p42-43 (locale rebuild 2 s "never blocking a query", upsert 0.1 ms); 15.8 p46.
- Locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87 (check), 301-328, 330-398, 527-537.
- Evidence: `check` calls `XCTExpectFailure(knownGap)` whenever `measured > allowed` and a knownGap
  string is passed, then asserts. Three call sites pass a knownGap: locale rebuild (323-326),
  upsert new and replaced documents (395-397), catalog-sized scan creation (533-534). The knownGap
  texts say the target is not reached "by this estimate". XCTExpectFailure(_:) without a block
  applies to the rest of the test, so a failure after it is also accepted: in
  testFullLexicalRebuildOnLocaleChange the check `XCTAssertLessThan(worstQuery, 0.25, "a query never
  waits for the rebuild")` (327) and in testSmallContextsOfCatalogSizedDocuments the scan-query
  budget check (535) cannot fail on a run where the rebuild or creation misses its budget. The
  "never blocking" check is also unscaled (250 ms on a Mac, 6x that on the reference device).
  README.md:175-177 presents these tests as asserting the section 15 budgets and does not mention
  the waived ones.
- Repro (scratch, outside the repo): /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s06-quality/xfail
  (mirrors `check` then a later failing assertion). `swift test` printed "XCTExpectFailure: matcher
  accepted Assertion Failure at XFailTests.swift:16: XCTAssertLessThan failed: ("1.0") is not less
  than ("0.25") - a query never waits for the rebuild" and "testLaterUnrelatedFailureIsAbsorbed
  passed"; the control test without the known gap failed.
- Failure scenario: a regression that makes queries wait 1 s behind a locale rebuild, or a slow
  scan query over 500 catalog-sized documents, passes the quality-targets CI job whenever the
  rebuild/creation is also over budget, which the code expects to be the normal case.
- Knock-down: making a known gap visible is legitimate, but it must be scoped (block form) and
  the requirement status must be "not met"; as written the job is green while R15/R16 are unmet.

### C1-s06-quality-03 (high, spec-missing): no grounded-answers golden set or measurement for local chat
- Spec: 15.6 p45 (100-question golden set: >= 90% cite a correct source, 100% unknown citations
  dropped, >= 80% decline when sources do not cover the question); 17 milestone 8 gate.
- Locations: Sources/ZTronSearchFixtures (no chat golden set); Tests/ZTronSearchEngineTests/ChatTests.swift;
  Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift.
- Evidence: grep for grounded/decline/100-question finds only prompt assembly
  (CitationParser.swift:104-140, ChatService.swift:446-469). No fixture of questions with expected
  sources or "should decline" labels exists, and no test computes citation accuracy or decline
  rate, with fakes or with Qwen3. Unknown-citation dropping is tested on scripted output only.
- Failure scenario: a runtime/prompt that cites wrong sources half the time, or answers instead of
  declining, passes every test; even on the A17 Pro device nothing measures the target.

### C1-s06-quality-04 (medium, test-integrity): the 15.9 targets over real SQLite never run in CI
- Spec: 15.9 p46; 17 milestone 2 gate ("the section 15.9 targets"); 18.1 WP31 and WP32.
- Locations: Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:68-70;
  .github/workflows/adapter-tests.yml:58,63; README.md:188-191.
- Evidence: testSection159TargetsOverSQLite throws XCTSkip under `#if DEBUG`; adapter-tests.yml runs
  only `swift test` and `swift test --sanitize=thread` (debug). The core PerformanceTests database
  test (571-657) measures FakeSearchDatabaseConnection, a dictionary-backed actor, not SQLite; it
  also does not assert "never blocking a query on an existing generation".
- Failure scenario: a change that makes SQLite paging or the hook-driven upsert 10x slower (e.g. a
  per-row statement) keeps every CI job green.

### C1-s06-quality-05 (medium, spec-missing): 15.2 resident-memory budgets are untested; model budgets are checked on disk size
- Spec: 15.2 p43 (steady 110 MB, semantic peak 200 MB, reranked peak 320 MB, reload <= 800 ms,
  80/60 MB loaded); 15.5 p44; 16 p50 ("index size and resident memory assertions from 15.2").
- Locations: Sources/ZTronSearchFixtures/ReferenceDevice.swift (no steady/peak constants;
  itemVectorBytes, graphBytes, embeddingModelBytes, rerankerModelBytes unused by PerformanceTests);
  Sources/ZTronSearchEngineSemantic/SemanticError.swift:78-83; CoreML/CoreMLEmbeddingProvider.swift:149-153;
  Tests/ZTronSearchEngineSemanticTests/HNSWRecallTests.swift:56-58.
- Evidence: no test measures the subsystem's resident memory with models unloaded or at a query
  peak; reload time after unload is not timed (SemanticIndexTests only checks it reloads). The
  model budgets compare the on-disk size of the model files, not the loaded footprint. Vectors
  and graph are checked as file sizes, and only when ZTRON_SEMANTIC_LARGE is set.
- Failure scenario: a Core ML model of 70 MB on disk that takes 150 MB resident is accepted, and
  steady-state growth past 110 MB is never reported.

### C1-s06-quality-06 (medium, test-integrity): end-to-end semantic and reranked snapshot targets are checked weakly or not at all
- Spec: 15.1 p42 (semantic snapshot 500 ms incl. 300 ms debounce; final reranked snapshot 750 ms).
- Locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:244-275; ReferenceDevice.swift
  (PerformanceBudget.rerankedSnapshot unused).
- Evidence: the semantic test sleeps 180 ms in a FakeSemanticSearcher over 5,000 items and holds
  the engine's remaining share (lexical, ANN, fusion, scheduling) to 20 ms wall clock on the Mac,
  unscaled, while every other engine-side budget is divided by the slowdown of 6. No test measures
  the reranked snapshot.
- Failure scenario: engine overhead of 60 ms on the Mac (about 360 ms on the reference device)
  passes; the 750 ms reranked target can regress without any test noticing.

### C1-s06-quality-07 (medium, spec-deviation): latency targets are measured over English golden queries only, and bigram-fallback lookups are not timed
- Spec: 15 p42 ("measured over the golden query set"); 15.1 prefix lookup 3 ms.
- Locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:56; Sources/ZTronSearchEngine/Query/QueryPlanner.swift:133-162;
  Sources/ZTronSearchEngine/Index/IndexSearcher.swift:668.
- Evidence: `static let queries = GoldenSet.queries.filter { $0.locale == "en" && ... }`, so the
  Japanese and other-language queries of the golden set are never timed. In QueryPlanner, a clause
  that matches through the CJK bigram fallback hits `if matchedAny { continue }` before
  `timings.lookup += ...`, so its exact, prefix and bigram lookups never reach
  `response.timings.prefixLookup`.
- Failure scenario: a slow path for CJK queries (many bigram postings) breaches 3 ms / 12 ms on
  the device with no test noticing; the stage timings report 0 lookup time for such clauses.

### C1-s06-quality-08 (low, test-integrity): the service-level randomized stale test does not check what its doc comment claims
- Spec: 15.4 p44; 16 p48 (stale-result suppression with randomized sequences).
- Locations: Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:157-219.
- Evidence: the doc says "once a newer query has been issued an older stream never yields again";
  the ledger only checks that each snapshot matches its own stream's query and generation, which
  a late snapshot of a superseded query also satisfies; `finals <= changes + 20` is loose.
- Failure scenario: a service that keeps yielding superseded streams passes this test.
- Knock-down: ResultsModelTests.swift:119-150 checks every published hit list against the model's
  current query over 10,000 random changes, and ConcurrencyTests.swift:223-244 checks the producer
  side deterministically, so the requirement itself is covered; hence low.

### C1-s06-quality-09 (low, test-integrity): the filter/kind precision gate passes on empty result lists
- Spec: 15.3 p44 (filter and kind tokens: precision 1.0).
- Locations: Sources/ZTronSearchFixtures/RelevanceMetrics.swift:66-71; Tests/ZTronSearchEngineTests/GoldenGates.swift:38-39;
  RelevanceTests.swift:185,196,198-215.
- Evidence: `guard !ranked.isEmpty else { return 1 }`; the class gate uses only precision and
  testNoHitEverViolatesAHardConstraint also accepts an empty list. Nothing checks that filtered
  queries still return their judged items.
- Failure scenario: a bug that makes every filtered query return nothing keeps the gate at 1.0.

### C1-s06-quality-10 (low, test-integrity): the environment-object lint accepts any `.environmentObject(` as attaching every model
- Spec: 16 p49 / 13.1 (a screen that reads a model via @EnvironmentObject without an attaching modifier fails the lint).
- Locations: Sources/ZTronSearchFixtures/SourceLint.swift:211-240 (224-226); Tests/ZTronSearchEngineUITests/LintTests.swift:154-161.
- Evidence: `attached = ... || source.code.contains(".environmentObject(")` for each of the three
  models; one `.environmentObject(settings)` anywhere in the scanned files disables the check.
- Failure scenario: a sample screen reads `@EnvironmentObject var chat: ZTronChatModel` with no
  `.zTronChat(` anywhere while another file injects an unrelated object; lint passes, the screen
  crashes at run time.

### C1-s06-quality-11 (low, test-integrity): "exact-title hit stays inside the head on the full golden set" is only checked with a reranker that agrees with titles
- Spec: 16 p49 (reranker tests).
- Locations: Tests/ZTronSearchEngineTests/RankingTests.swift:325-336; RelevanceTests.swift:283-292; Sources/ZTronSearchFixtures/FakeReranker.swift.
- Evidence: the adversarial case is one constructed 16-document list; its `XCTAssertLessThan(position, 16)`
  is always true for 16 documents (the `< 11` check is the real one). Over the golden set the
  reranked stage uses FakeReranker, which scores by lexicon overlap and so never opposes an
  exact title.
- Failure scenario: a blend weight change that pushes exact-title hits with a smaller fused margin
  out of the head is not caught on the golden set.

### Considered and dropped
- HNSW queries between two topics assert recall >= 0.90 (measured 0.9338): a design check of the
  multi-entry descent; the 0.95 gate is held on 1,000 sampled queries (0.9940 / 0.9999).
- Cancellation bound `0.010 + full / 4`: matches "within 10 ms of the next checkpoint".
- Semantic and reranked relevance on oracle fakes: disclosed in README.md:212-214; status unverifiable.

## Not checked
- Every reference-device p95 and memory target (no iPhone 6s; release builds not allowed here; no
  release log in Verification/_runs): R1-R7, R13, R14, R18, R19, R60, R61 rest on proxy tests only.
- Model-dependent targets: query embedding 180 ms, rerank 250 ms, paraphrase / cross-language /
  reranked relevance with a production model (the package ships no model).
- 15.6 local-chat targets on an A17 Pro iPhone or M-series Mac (needs Qwen3 weights and the Metal
  toolchain; the integration tests skip without them).
- The iOS 15 floor CI job and the parity matrix (no simulators booted per the rules).
- A complete TSan run (only a partial cycle-2 log, 0 warnings at grep time).
- Adapter test runs (SQLite, MLX, AssetKit): read, not run; AssetKit needs an external checkout.
- Section 16 test bodies for core correctness, contexts, database sources, i18n, UI and chat:
  mapped by name, checked for assertions and a green debug run, spot-read only.
- Section 18 effort/points estimate and section 17 history: not normative for the code.

STATUS: complete
