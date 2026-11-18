# Cycle 2 - m06 tests/gates audit (find-m06-tests-gates)

Auditor: m06-tests-gates (cycle 2). Repository commit cee4620. Scope: Tests/ZTronSearchEngineTests,
Sources/ZTronSearchFixtures, Tests/ZTronSearchFixturesTests, .github/workflows/*.yml, Package.swift,
README.md, against spec sections 15, 16, 17. Run logs read from Verification/_runs (complete .log files
only). Two confirmation programs were written and run in
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m06-tests-gates/
(stream_cancel.swift, with_timeout.swift). Nothing in the repository was modified apart from this file.

## Findings

### C2-m06-tests-gates-01 - high - test-integrity
Title: The non-scoped XCTExpectFailure in PerformanceTests.check(knownGap:) turns every later failure in the same test into an expected failure.
Spec: 15.1, 15.4 ("never blocking a query" of the locale rebuild row), 15.8, 16, 17 milestone 1 gate.
Locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87 (XCTExpectFailure at :80); :323-327; :533-535; Verification/_runs/c2-release-performance.log:140-142.
Description: When a measurement carrying a knownGap is over budget, check() calls `XCTExpectFailure(knownGap)` without a closure. That form matches every failure for the rest of the test. In testSmallContextsOfCatalogSizedDocuments the scan-query check at :535 (no knownGap) is masked whenever the creation check at :534 is over budget. In testFullLexicalRebuildOnLocaleChange, `XCTAssertLessThan(worstQuery, 0.25, "a query never waits for the rebuild")` at :327 is masked whenever the rebuild is over budget, which it was in every run. The comment "Recorded as an expected failure, strictly: the day it is met, this test says so" is false: XCTExpectFailure is only called once the measurement is already over budget, so strictness can never fire, and nothing reports when a gap closes.
Evidence: c2-release-performance.log:142: "XCTExpectFailure: matcher accepted Assertion Failure at PerformanceTests.swift:535: ... scan query, 500 catalog-sized documents (p95): 0.898 ms, budget 3.000 ms on the reference device (0.500 ms on this machine)". The test was counted as passed. The rebuild was over budget in both runs (2567.5 ms and 1134.2 ms against 333.3 ms allowed), so :327 has been masked in every run so far.
Failure scenario: A regression makes queries wait a second for the locale rebuild, or doubles the 500-document scan query. As long as the preceding known-gap check is over budget (always, so far), the failure is reported as expected, `swift test` exits 0, and the CI quality-targets job stays green.
Repro: grep "matcher accepted" Verification/_runs/c2-release-performance.log

### C2-m06-tests-gates-02 - high - spec-deviation
Title: The 2 s locale-rebuild and 0.1 ms-per-document upsert targets are missed by the package's own measure and pass as expected failures; README and CI do not disclose it.
Spec: 15.1 (full lexical rebuild on locale change 2 s; incremental upsert 0.1 ms amortized); 17 milestone 1 gate ("the lexical latency targets"); 16 (latency table).
Locations: PerformanceTests.swift:301-328 (knownGap :325); :330-398 (gap :395, checks :396-397); :527-536; README.md:175-177, 205-210; .github/workflows/ci.yml:5-7, 41-48.
Description: Three checks carry a knownGap, and an over-budget measurement becomes an expected failure.
- Rebuild: 1134-2568 ms against 333 ms allowed (3.4-7.7x).
- Upsert of new documents: 0.053-0.066 ms against 0.017 ms (3.2-4x).
- Upsert of replaced documents: 0.083-0.146 ms (5-8.8x).
The gap strings concede the reference device cannot meet these: "is more work than the reference device does in 2 s by this estimate" and "the word tokenizer alone takes most of the budget". README says "The performance tests hold every measurement against its budget". The only unmet gate it discloses is parity (README:216). ci.yml says the job "asserts each budget". Catalog-sized scan creation (9.5-46.6 ms against 8.3 ms) is also a known gap. Spec 15.8 fixes no document size, though, and the settings-sized 15.8 checks pass.
Evidence: c2-release-performance-rerun.log:42, 49, 50, 69 and c2-release-performance.log:112, 119, 120, 140 ("XCTExpectFailure: matcher accepted ... lexical rebuild on locale change ... 1134.206 ms ... (333.333 ms on this machine)" and so on). Grep of README.md and .github/ finds no mention of known gaps or expected failures.
Failure scenario: Milestone 1 is declared met on a green CI while two rows of the 15.1 table fail by 3-9x.

### C2-m06-tests-gates-03 - high - test-integrity
Title: The 500 ms semantic-snapshot test holds the engine's share to an unscaled 20 ms. Its own measured totals exceed 500 ms on this Mac and it passes anyway.
Spec: 15.1 (semantic snapshot after the typing pause: 500 ms including the 300 ms debounce, p95, reference device, 100k items).
Locations: PerformanceTests.swift:244-275 (allowance :270, assertions :273-274); README.md:205-208.
Description: The test works out an overhead: the total, minus the debounce, minus the measured encoder time (not the 180 ms budget). It compares that overhead with 20 ms wall-clock and does not apply ReferenceDevice.scaled. The README says off-device runs assert the budget divided by the slowdown, 6 on this Mac. The test also uses 5,000 items and a brute-force fake searcher instead of 100k items and HNSW. It never asserts the total against 500 ms.
Evidence:
- c2-release-performance.log: "PERF semantic snapshot after the typing pause: worst 502.036 ms in all; the engine adds at most 12.736 ms ... (allowance 20.000 ms)".
- Rerun: "worst 504.614 ms in all; ... at most 19.850 ms ... (allowance 20.000 ms)".
- With 12 samples, the worst is the p95. The test passed both times.
Failure scenario: Applying the package's factor of 6, the engine share of 12.7-19.9 ms becomes about 76-119 ms on the reference device. The total is then about 300 + 180 + 76-119 = 556-599 ms, over 500 ms, and the gate stays green. Even on this Mac a p95 total of 504.6 ms passes.

### C2-m06-tests-gates-04 - high - test-integrity
Title: The cancellation tests time the consumer's own exit, which AsyncStream provides without the producer. None of them can fail if the producer ignores cancellation.
Spec: 15.4 (cancellation honoured within 10 ms of the next checkpoint); section 11 liveness table ("Cancellation tests before, during and after index search"); the SearchService.results doc ("Cancelling the consuming task terminates the stream and cancels the producer").
Locations: Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:34-47, 49-80 (assertion :75), 119-140; Sources/ZTronSearchEngine/Service/SearchService.swift:278-296 (onTermination :293).
Description: results(for:) returns an AsyncStream. Each test cancels the Task that iterates it and times how long task.value takes to return. AsyncStream's iterator finishes the stream and returns nil as soon as the iterating task is cancelled, whatever the producer does. So:
- The "worst" in testCancellationDuringTheIndexSearchIsHonouredAtTheNextCheckpoint is the consumer's resume latency. Its bound, 10 ms + full/4, is also looser than 10 ms.
- In testCancellingTheConsumerCancelsTheProducerThroughOnTermination, `phases == [.lexical]` and "< 0.5 s" hold with no onTermination at all.
- In testCancellationBeforeTheSearchStarts, "the sleep is cancelled, not waited out" does not test the producer's sleep.
No test checks that the producer stopped: StubSemantic records no cancellation, and nearestCalls is not checked after the cancel. testTheScoringLoopChecksCancellation proves a checkpoint exists inside the loops (there is no entry check), not how fast it is reached.
Evidence: Scratchpad program stream_cancel.swift copies the test shape, with a producer that spins 1 s without checking cancellation and no onTermination. It printed:
- "consumer phases ["lexical"]; consumer finished 0.053 ms after cancel"
- "producer (ignores cancellation, no onTermination) kept running until 891.1 ms after cancel"
- "test assertions would be: phases == [lexical] -> true; consumer exit < 500 ms -> true; worst < 10 ms -> true"
Failure scenario: Delete `continuation.onTermination = { _ in task.cancel() }` (SearchService.swift:293), or every Task.checkCancellation in IndexSearcher. All three tests still pass, while an abandoned search keeps encoding and scoring for seconds.
Repro: swiftc -O -parse-as-library -swift-version 6 stream_cancel.swift && ./stream_cancel

### C2-m06-tests-gates-05 - medium - test-integrity
Title: The engine-level stale-snapshot test over 10,000 changes cannot detect the property its doc comment states.
Spec: 15.4 (zero stale snapshots over 10,000 randomized query changes); 16 ("Stale-result suppression with randomized query sequences").
Locations: ConcurrencyTests.swift:157-221 (Ledger :167-178).
Description: The doc comment promises that "once a newer query has been issued an older stream never yields again". The Ledger only compares each snapshot with its own stream's query and first generation. It records nothing about time or order relative to newer queries, so an old stream yielding its own late semantic snapshot after a newer query has been issued counts as correct. At the engine, suppression is checked only by testAnObsoleteProducerNeverYields (60 iterations). The 10,000-change metric itself is covered at the UI boundary by ResultsModelTests.testNoStaleSnapshotsOverTenThousandRandomizedQueryChanges (Tests/ZTronSearchEngineUITests/ResultsModelTests.swift:118-150; unseeded SystemRandomNumberGenerator, 40 items), so this is medium.
Failure scenario: A regression drops the generation check before the semantic snapshot is yielded, so late publication is back. mismatched stays 0 and this test passes.

### C2-m06-tests-gates-06 - medium - performance
Title: The release quality suites failed on this Mac in every run (RRF fusion and the 15.9 database targets), and the SQLite release targets failed too.
Spec: 15.1 (RRF fusion 0.5 ms); 15.9 (10k-row context 1.5 s, 500-row page 40 ms, upsert of 100 rows 50 ms).
Locations: PerformanceTests.swift:149-174 (:173), :571-655 (:590, :616, :638); Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:179; .github/workflows/ci.yml:41-56.
Description: Release PerformanceTests failed 6 checks in run 1 (load 370) and 4 in the rerun (load 8.4, with 12 simulators booted).
- testDatabaseSources creation: 314.3 ms against 250 ms (1379 ms in run 1).
- One page: 7.07 ms against 6.67 ms.
- Upsert: 13.76 ms against 8.33 ms.
- Fusion: 0.110 ms against 0.083 ms (0.161 ms in run 1).
The SQLite release run failed upsert at 10.154 ms against 8.333 ms. By the README's rule that passing off the device is necessary, these targets are not shown to be met. The margins (1.06-1.9x) may be partly load, so this is PLAUSIBLE rather than confirmed for an idle machine.
Evidence: c2-release-performance-rerun.log:33-35, 46; c2-release-performance.log:102-104, 109, 116, 137; c2-sqlite-release-targets.log:47, 58.
Failure scenario: The CI quality-targets job is red on a comparably loaded runner. On the device, at the package's factor of 6, fusion is about 0.66 ms, over 0.5 ms.

### C2-m06-tests-gates-07 - medium - test-integrity
Title: The filter/kind precision gate and the hard-constraint test pass when the engine returns nothing.
Spec: 15.3 (filter and kind tokens: precision 1.0); 16 ("Filters and kind tokens as hard constraints").
Locations: Sources/ZTronSearchFixtures/RelevanceMetrics.swift:67-72; Tests/ZTronSearchEngineTests/GoldenGates.swift:38-39; Tests/ZTronSearchEngineTests/RelevanceTests.swift:185, 196, 198-214, 291; Tests/ZTronSearchFixturesTests/RelevanceMetricsTests.swift:77.
Description: `precision` returns 1 for an empty list (asserted at RelevanceMetricsTests:77, "no hit violates anything"), and the filterAndKind class is gated on precision alone. testNoHitEverViolatesAHardConstraint counts violations among the hits returned. Nothing requires these queries to return their judged items, although the golden set holds those judgments. Only the first page of the final snapshot is checked.
Failure scenario: A regression in hard-constraint evaluation makes every kind or filter token query return an empty list. testLexicalStageFiltersAndKinds, testFilterAndKindPrecision, the reranked and signals gates and testNoHitEverViolatesAHardConstraint all pass, and filterAndKind still prints 1.0000.

### C2-m06-tests-gates-08 - medium - false-claim
Title: "Relevance gates among 100,000 distractors" adds no competition. Distractors are built never to match a golden query, and the numbers are identical at 5,000 and 100,000.
Spec: 15.3; the section 15 preamble (100k items).
Locations: Sources/ZTronSearchFixtures/SyntheticCorpus.swift:14-23; Sources/ZTronSearchFixtures/SyntheticVocabulary.swift:53; README.md:179-180; RelevanceTests.swift:43-46; ci.yml:49-52.
Description: By construction:
- Titles and keywords are pseudo-words.
- No pseudo-word starts with the first three letters of a lexicon word.
- Lemmas appear only past word 24 of a body.
- Synonyms and reserved translations never appear.
So no distractor can reach a golden head position through a title, prefix, keyword, paraphrase, translation or embedding. Near-miss competitors (shared prefixes, typo neighbours, titles that share words) are absent. The CI's 100k relevance run therefore exercises scale only, not relevance under competition.
Evidence: The RELEVANCE rows are identical, character for character, among 5,000 distractors (c1-debug-swift-test.log:1113-1117; c2-tsan-swift-test.log:1092-1096) and among 100,000 (c2-release-relevance-full.log:73-77).
Failure scenario: A ranking change that lets body-only matches or prefix-sharing titles outrank exact titles in a real 100k catalog is invisible to every gate, while README implies the gates hold among 100,000 competitors.

### C2-m06-tests-gates-09 - medium - spec-missing
Title: Several 15.1 and 15.2 targets that need no model have no assertion. The one steady-state measurement exceeds 110 MB and is gated at 200 MB.
Spec: 15.1 (final snapshot past the calibration gate, 750 ms; "no frame over 16.7 ms attributable to search"); 15.2 (steady state with models unloaded 110 MB; peak during a semantic query 200 MB); 16 ("Index size and resident memory assertions from section 15.2"; "100k-item indexing time").
Locations: Sources/ZTronSearchFixtures/ReferenceDevice.swift:67 (rerankedSnapshot, used by no test); PerformanceTests.swift:402-438, 455-463, 678-689.
Description:
- No test uses PerformanceBudget.rerankedSnapshot, and none checks steady state or peak.
- testIndexingKeepsItsWorkingMemoryInBounds prints "heap retained afterwards 131.6 MB (the in-memory segment and the items kept for a locale change)". It says "Not a target of section 15" and asserts < 200 MB.
- testLexicalIndexMemory measures only a freshly memory-mapped index, not the in-memory index a host has after index(_:). It excludes the stored-document section (29.6 MB paged in after the golden set) and any heap allocated by load (heapBefore is taken after load, :412-413).
- The indexing baseline uses 10k items, not 100k.
- Rows bound to a model (80 MB and 60 MB models, 320 MB peak) cannot be tested without one, which is acceptable.
Evidence: c2-release-performance-rerun.log, the PERF lines "indexing 100000 items: 2.39 s; heap retained afterwards 131.6 MB" and "after the 353 queries of the golden set: 29.6 MB of the stored documents paged in".
Failure scenario: A host that indexes 100k items at launch (README's `await service.index(tips)` path) holds at least 131.6 MB of heap for the lexical side alone, over the 110 MB steady-state target before 60 MB of vectors and graph. No test fails below 200 MB.

### C2-m06-tests-gates-10 - medium - spec-missing
Title: CI never runs the SQLite adapter's release DatabaseTargetsTests, and run here it fails the upsert target.
Spec: 15.9; 17 milestone 2 gate ("the adapter integration tests, and the section 15.9 targets").
Locations: .github/workflows/adapter-tests.yml:56-63; README.md:188-191; Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:70, :179.
Description: The adapter workflow runs `swift test` and `swift test --sanitize=thread`, both debug builds, where DatabaseTargetsTests throws XCTSkip. No job runs it in release. README:188-191 presents that release command as the place where the adapter "asserts the section 15.9 targets against a real database".
Evidence: c2-sqlite-adapter.log: "testSection159TargetsOverSQLite ... skipped". c2-sqlite-release-targets.log:47, 58: "incremental upsert of 100 changed rows, after the commit (p95 of 40 commits): 10.154 ms measured; ... 8.333 ms here (OVER)".
Failure scenario: Regressions of the 15.9 targets over SQLite never turn CI red. One target is already failing.

### C2-m06-tests-gates-11 - low - test-integrity
Title: The semantic, cross-language and rerank gates are reached only with oracle fakes built from the queries' own lexicon. The rerank stage changes no metric, so "never below fused" holds by equality.
Spec: 15.3 (paraphrase recall 0.75, cross-language recall 0.70, reranked NDCG 0.85 and never below fused).
Locations: Sources/ZTronSearchFixtures/FakeEmbeddingProvider.swift; Sources/ZTronSearchFixtures/FakeReranker.swift; RelevanceTests.swift:217-224, 265-281; README.md:212-214.
Description: The fake embedding maps lexicon concepts (synonyms and translations) to orthonormal vectors, and the fake reranker scores concept overlap. The queries come from the same lexicon, so the jump from 0.0000 lexical to 0.9875 and 1.0000 semantic is built in. In every log, every reranked number equals the semantic number. testRerankedHeadNDCG would pass if the rerank stage returned the fused order unchanged, and testTheFinalSnapshotIsTheOneTheStageAsksFor checks only the phase label. README discloses that the fakes say nothing about a production model, hence low. Applying the reranker is unit-tested with a stub (SnapshotPipelineTests.testThirdSnapshotReordersTheHeadOnDevicesPastTheGate).
Failure scenario: A bug that leaves the fused order in the reranked snapshot passes every relevance gate.

### C2-m06-tests-gates-12 - low - test-integrity
Title: The "timeout-guarded" deadlock test cannot time out, because withTaskGroup waits for the hung child.
Spec: section 11 liveness table (No deadlock: "Thread Sanitizer in CI; timeout-guarded tests").
Locations: ConcurrencyTests.swift:19-30, 248-296.
Description: The timer child returns nil and the closure calls cancelAll, but withTaskGroup still awaits every child. A deadlocked operation or a lost continuation never completes, so withTimeout never returns and `XCTAssertEqual(finished, true, "... no deadlock, no lost continuation")` is never reached. Only the CI job timeout (45 or 90 min) ends the run.
Evidence: Scratchpad program with_timeout.swift, a verbatim copy, printed "withTimeout(0.5) around a never-resumed continuation, 3 s later: still waiting".
Failure scenario: An actor deadlock in the service hangs the unit job for 45 minutes, which is killed with no assertion naming the test.

### C2-m06-tests-gates-13 - low - test-integrity
Title: Several bounded-work and context tests check proxies that cannot fail for the property they name.
Spec: sections 10 and 11 (bounded work: 2,000 candidates); 16 (contexts: no disk I/O, no growth across 1,000 cycles); 15.1 (cold start).
Locations: ConcurrencyTests.swift:328-348; PerformanceTests.swift:143, 279-299; Tests/ZTronSearchEngineTests/SearchContextTests.swift:294-309, 342-384; Sources/ZTronSearchEngine/Index/IndexSearcher.swift:686, 799, 855.
Description:
- (a) testAtMostTwoThousandLexicalCandidatesAreScored: its first two assertions hold with no candidate cap at all. The 200-entry fusion cap applies, and the 2,000 title matches outrank body-only matches regardless. Only the sub-check with a limit of 50 exercises a cap. PerformanceTests:143 (`candidates <= 2_000`) reads the engine's own slotCount, which is bounded by construction by the configured limit, so it only checks the configuration default.
- (b) testAScanContextPerformsNoDiskIO asserts only that the storage directory was not created, so reads cannot be detected.
- (c) testCreatingAndReleasingContextsDoesNotGrowMemory reuses the context id "picker" in every cycle, so a registry keyed by id would not grow. It also tolerates 2 MB.
- (d) testColdStartFromAMemoryMappedIndex loads a file it has just written, so every "cold" load hits the page cache.
Failure scenario: A context that reads its index file on every query passes (b). A leak keyed by a fresh context id per screen passes (c).

### C2-m06-tests-gates-14 - low - false-claim
Title: README and CI comments the configuration does not keep.
Locations: README.md:209-210; PerformanceTests.swift:57-61, 660-689; .github/workflows/ci.yml:64-67; .github/workflows/parity.yml:67.
Description:
- (a) README:209-210 says PerformanceTests "carries XCTClockMetric and XCTMemoryMetric baselines to record there", meaning on the device. setUpWithError skips the whole class in DEBUG, which is Xcode's default test configuration for a device run, and nothing says how to run Release with testability on the device.
- (b) ci.yml:64-67 says "The floor and the current release" for ["15.5", "18.6"], while parity.yml:67 and ParityHost/ReferenceSnapshots already use iOS 27.0.
- (c) The "strictly: the day it is met, this test says so" comment, covered under 01.
Failure scenario: Someone following README to record device baselines gets 17 skipped tests and no baselines.

## Considered and dropped
- persist() being a no-op that would make the 15.9 write timing trivial: dropped. persistIndex on .database storage always compacts and writes (SearchService+Context.swift:653-668).
- Dilution of the fuzzy p95 over queries where fuzzy does not run: dropped. Fuzzy runs on every clause of 3 or more characters once the longest token reaches the minimum length (QueryPlanner.swift:109-110, 164-176).
- setLocale returning before the rebuild: dropped. The measured 1.1-2.6 s shows it awaits.
- The race in FakeSearchDatabaseConnection.changes(in:), which subscribes from an unstructured Task (FakeSearchDatabase.swift:61-69): real, but every test that commits first polls subscriberCount with eventually{}, so it has limited effect. Not reported.
- LintTests allowing "HNSWWrapper.swift", which does not exist: harmless, since it allows nothing.
- SourceLint.code(of:) blanks the code inside string interpolations and does not handle raw strings: latent false negatives only, with no current instance in Sources.

## Files read
Package.swift; README.md; .github/workflows/ci.yml, adapter-tests.yml, parity.yml.

Tests/ZTronSearchEngineTests:
- In full: PerformanceTests, TestSupport, RelevanceTests, GoldenGates, ConcurrencyTests, SignalTuningTests, RandomCorpus, SearchContextTests, StrategyParityTests.
- Parts: SnapshotPipelineTests, InternationalizationTests.

Sources/ZTronSearchFixtures:
- In full: ReferenceDevice, RelevanceMetrics, GoldenQuery, GoldenSet, GoldenCorpus, SyntheticCorpus, SyntheticVocabulary, FixtureText, FakeEmbeddingProvider, FakeSemanticSearcher, FakeReranker, FakeSearchDatabase, SourceLint, SeededGenerator.

Tests/ZTronSearchFixturesTests: TestSupport, EngineSmokeTests, RelevanceMetricsTests, DeterminismTests, GoldenSetTests, SyntheticCorpusTests.

Other tests: Tests/ZTronSearchEngineUITests/LintTests (full) and ResultsModelTests (parts); Tests/ZTronSearchEngineSemanticTests/HNSWRecallTests (grep).

Engine and tool code, in parts: IndexSearcher, QueryPlanner, SearchService, SearchService+Context, LexicalIndex; ParityHost/Tools/matrix.py.

Spec sections 7.1-7.4, 11 (liveness table), 15, 16 and 17.

Run logs: c1-debug-swift-test, c2-tsan-swift-test, c2-release-performance, c2-release-performance-rerun, c2-release-relevance-full, c2-release-semantic-large, c2-release-hnsw-recall-rerun, c2-sqlite-adapter, c2-sqlite-release-targets, c2-ios-build, c2-assetkit-adapter (summary lines).

## Not reached
- Sources/ZTronSearchFixtures: FakeChatBoundaries, CatalogSchema, FixtureLexicon, FixtureLexiconData, GoldenPhrases.
- Tests/ZTronSearchFixturesTests: GoldenCorpusTests, FakeEmbeddingTests, LexiconTests.
- Tests/ZTronSearchEngineTests: ChatTests, CoreCorrectnessTests, DatabaseSourceTests (only grepped), FuzzyChannelTests, HighlighterTests, IndexMaintenanceTests, RankingTests, SmokeTests, TextPipelineTests.
- Whether GitHub's macos-latest image provides the iOS 15.5 runtime the ios job asks for (not verifiable offline).
- Whether the database and fusion failures reproduce on an idle machine (the orchestrator's runs were under load).

STATUS: complete
