# Cycle 1, slice s06-quality: skeptic verification

Skeptic for the findings in find-s06-quality.md (spec sections 15-18, pages 42-58).
Repository: /Users/admin/Documents/ZTronSearchEngine at cee4620. Nothing in the repository was
built, tested or modified. Scratch programs live in
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s06-quality-skeptic/
(xfail2/ = XCTExpectFailure scope repro, lint/ = SourceLint repro).

Summary: 01 confirmed (high), 02 confirmed (high), 03 confirmed (high), 04 confirmed (medium),
05 confirmed (medium), 06 partly (low), 07 confirmed (medium), 08 confirmed (low),
09 partly (low), 10 confirmed (low), 11 refuted (none).

## C1-s06-quality-01: UI parity gate not met. Verdict: confirmed (high)

- Spec: 15.7 p45 ("UI parity, every cell of the section 12.5 matrix"; "any other difference fails
  the build"), 16 p48 (parity on every matrix cell), 17 p51 milestone 4 gate ("section 15.7
  thresholds on the full 12.5 matrix"). Nothing in 16 or 17 relaxes it.
- Recounted from ParityHost/Results (find + summary.csv): 7,440 result files (3,200 for 15.5,
  3,200 for 16.4, 440 for 17.5, 440 for 18.6, 160 for 27.0); 781 ran, 179 passed, 602 failed,
  6,659 not runnable. iPad and iPhone SE: 0 passes on every iOS; 27.0: 0 passes. Every pass is
  at content size L, left to right (iPhone 15: light, dark, increased contrast, reduce
  transparency; Pro Max: light). README.md:216-218 says the gate is not met.
- The failures are real comparator failures (for example "initial pixels: 1.706% differ (limit
  0.5%), max ΔE 28.74" on SE, "the clone shows no Cancel button to tap" on iPad), not harness
  noise. gate.py exits non-zero on any fail, not-runnable or missing cell, so CI is honest.
- Corrections that only strengthen it: the worst values quoted (55.394%, 254.5 pt) are the
  17.5/18.6 maxima; iOS 27.0 reaches 98.367% pixels and 890 pt. The matrix is 800 cells per iOS
  and device, 16,000 in all; 8,560 cells on 17.5/18.6/27.0 have no result file at all
  (gate.py counts them as missing), which the finding does not mention.

## C1-s06-quality-02: knownGap XCTExpectFailure absorbs later assertions. Verdict: confirmed (high)

- PerformanceTests.swift:70-87: `if let knownGap, measured > allowed { XCTExpectFailure(knownGap) }`
  then XCTAssertLessThanOrEqual. Call sites with a knownGap: 323-326 (locale rebuild), 396-397
  (upsert new and replaced), 534 (scan creation, 500 catalog-sized). Line 327
  `XCTAssertLessThan(worstQuery, 0.25, "a query never waits for the rebuild")` and line 535
  (scan query, 500 catalog-sized, no knownGap) follow in the same tests.
- Independent scratch XCTest (xfail2/, swift test on this Mac): with the gap triggered, both a
  later XCTAssertLessThan and a later budget check without a knownGap were recorded as
  "Expected failure" and the tests passed; the control (gap not triggered) failed. So the
  non-block XCTExpectFailure covers the rest of the test, as the finding says.
- ci.yml quality-targets runs `swift test -c release ... --filter PerformanceTests`, so the CI
  scenario is real. README.md:175-177 and 205-210 describe the budgets as asserted and do not
  mention the waivers (no README mentions a known gap).
- Worse than stated: the waiver is not Mac-only. On the reference device `scaled` divides by 1
  and the same code path runs, so the milestone gate run on the device ("tests passing on the
  reference device", 17 p50) also passes with the rebuild and upsert budgets missed and with the
  "never blocking" check absorbed. The comment at 78-79 ("strictly: the day it is met, this test
  says so") is wrong: XCTExpectFailure is only issued when the budget is missed, so a met target
  is an ordinary pass and strictness never triggers.
- InternationalizationTests.swift:233-283 checks that queries during a rebuild return correct
  answers, not that they are not delayed, so the 250 ms check is the only "never blocking"
  latency check, and it is the one that gets absorbed.
- Mitigations considered (explicit, logged waivers; the 500-document scan-query budget is also
  asserted without a waiver on settings-sized documents in testSmallContexts) do not outweigh a
  gate that cannot fail on its expected path. Nuance: the catalog-sized knownGap says "at the
  limit of 50 ms", not "not reached".

## C1-s06-quality-03: no grounded-answers golden set or measurement. Verdict: confirmed (high)

- Spec: 15.6 p45 (100-question golden set over the corpus: >= 90% cite a correct source, 100%
  unknown citations dropped, >= 80% decline); 17 p51 milestone 8 gate ("section 15.6 targets on
  an A17 Pro-class iPhone and an M-series Mac"). Section 16 does not relax it.
- Sources/ZTronSearchFixtures has no chat golden set (only GoldenSet/GoldenCorpus for 15.3).
  Grep of Chat sources, ChatTests, FakeChatBoundaries and the MLX adapter finds no question set,
  no expected-source or should-decline labels, and no computation of citation accuracy or
  decline rate. Qwen3IntegrationTests (tests at 148-525) covers load, TTFT/decode, cancellation,
  footprint, seeds, thinking mode and the context window, not grounding. The MLX README
  (279-283) lists what those tests cover and is silent on grounded answers, so the gap is not
  disclosed.
- What exists: PromptAssembler.groundingInstructions (CitationParser.swift:109-112) tells the
  model to decline; CitationParser drops unknown ids deterministically and ChatTests:576-604
  test it on scripted output. That covers the mechanism of the "100% dropped" sub-target (it
  does not depend on the model for `[kind:id]` markers); the 90% and 80% sub-targets have no
  fixture and no harness, with fakes or with Qwen3. Description accurate; severity kept.

## C1-s06-quality-04: 15.9 targets over real SQLite never run in CI. Verdict: confirmed (medium)

- DatabaseTargetsTests.swift:68-70: `#if DEBUG throw XCTSkip(...)`; adapter-tests.yml:58 and 63
  run only `swift test` and `swift test --sanitize=thread` (debug). No other workflow touches the
  adapter in release (ci.yml, parity.yml checked). README.md:188-191 documents the release
  command as a manual step.
- PerformanceTests.swift:571-657 (run in release by ci.yml quality-targets) measures
  FakeSearchDatabaseConnection; the test itself says the fake's read "is no SQLite". The upsert
  path there is the fake's `transaction`, not the adapter's update/commit hooks
  (ConfinedConnection.swift:52-56), so hook-driven upsert timing is only in the skipped test.
- "Never blocking a query on an existing generation" (15.9 row 1) is asserted nowhere: grep of
  Tests and the SQLite adapter tests finds no query-latency check during a database context
  build, refresh or rebuild (EndToEndTests:462-485 and DatabaseSourceTests:658 are correctness
  checks of commits during a refresh).
- Knock-down considered: section 16 puts performance on the reference device and WP32 only asks
  for "the adapter test target in CI", which exists; so this is a regression-detection gap, not
  a broken spec clause on its own. Medium stands because one 15.9 clause has no test at all and
  the only real-database measurement is never automated.

## C1-s06-quality-05: 15.2 resident budgets untested; model budgets on disk. Verdict: confirmed (medium)

- PerformanceBudget (ReferenceDevice.swift) has no steady-state (110 MB), semantic-peak
  (200 MB), reranked-peak (320 MB) or reload-time (800 ms) constant; itemVectorBytes,
  graphBytes, embeddingModelBytes and rerankerModelBytes are referenced nowhere but their
  definitions (grep of Sources, Tests, Adapters).
- Model budgets: CoreMLEmbeddingProvider.load (CoreMLEmbeddingProvider.swift:149-153) compares
  `loader.footprint(modelURL)`, which is FileAccess.footprintBlocking (sum of file sizes on
  disk), against SemanticLimits (SemanticError.swift:78-83, documented "On-disk budget");
  CoreMLAdapterTests testTheBudgetIsCheckedAgainstTheFilesOnDisk confirms the intent. 15.2 says
  "Embedding model, loaded 80 MB" and "Reranker model, loaded 60 MB".
- Reload: SemanticIndexTests:59-74 and CoreMLAdapterTests:147 check that the model reloads,
  never how long it takes. Vectors and graph: HNSWRecallTests.swift:56-58 compare file sizes,
  only under ZTRON_SEMANTIC_LARGE (which ci.yml quality-targets does set).
- Section 16 p50 asks for "index size and resident memory assertions from section 15.2"; nothing
  in 17 defers them. Component sizes (lexical 40 MB, vectors, graph) are tested, so the sum is
  partly bounded; the whole-subsystem budgets are not. Accurate as described.

## C1-s06-quality-06: semantic snapshot proxy weak; 750 ms reranked target untested. Verdict: partly (low)

- Real: PerformanceTests.swift:244-275 holds `worst` (total minus the 300 ms debounce minus the
  measured encode time) to `allowance` = 0.5 - 0.3 - 0.18 = 20 ms (line 270, unscaled) while the
  class doc and every `check` call divide CPU-bound budgets by the slowdown of 6. The remainder
  is engine CPU work (nearest over 5,000 items in the fake, fusion, ranking, snapshot) plus
  timer slack, so it should scale. PerformanceBudget.rerankedSnapshot is referenced only by its
  definition; no test times the reranked snapshot.
- Wrong detail in the failure scenario: an engine overhead of 60 ms on the Mac fails
  `XCTAssertLessThanOrEqual(worst, allowance)` (60 > 20). The real slack is: anything up to
  20 ms on the Mac passes, about 120 ms on the reference device against a 20 ms share, so the
  proxy is 6x weaker, not 18x.
- Severity lowered: the components are each held to scaled budgets elsewhere (fusion, first
  lexical snapshot, HNSW 5 ms at 100k), the lexical phase runs inside the debounce, and the 750 ms
  target applies only to calibrated devices, where its engine share beyond the 250 ms model call
  is a 16-document blend; the rerank cap and breach rules are tested (SnapshotPipelineTests).

## C1-s06-quality-07: latency timed on English queries only; bigram lookups untimed. Verdict: confirmed (medium)

- PerformanceTests.swift:56 filters GoldenSet.queries to locale "en"; every 15.1 stage test and
  the end-to-end tests use Self.queries (or a 5,000-item paraphrase subset), on one "en" engine.
  The golden set's crossLanguage and localizedTitle classes (GoldenSet.swift:213-214, up to 4 per
  kind and language over it, de, ja, so up to 120 of the 483 queries) are never timed, including
  every Japanese query. RelevanceTests builds one engine per locale (RelevanceTests.swift:68-72),
  so a per-locale timing run was feasible. No other test times CJK queries (grep of DispatchTime
  users in Tests).
- QueryPlanner.swift:136-162: when the bigram fallback matches, `if matchedAny { continue }`
  skips `timings.lookup += ...` (line 162), so exact, prefix and bigram lookups of that clause
  never reach LexicalTimings.prefixLookup (IndexSearcher.swift:668). Verified in code.
- Precision: LexicalTimings is internal and read only by PerformanceTests, so "stage
  diagnostics" means the test's own stage timings, not a public diagnostic; and because no CJK
  query is timed, the timing bug has no effect today. The same English-only test is what would
  run on the reference device, so the gate itself is narrowed. Medium stands.

## C1-s06-quality-08: service-level stale test weaker than its doc comment. Verdict: confirmed (low)

- ConcurrencyTests.swift:157-219: Ledger.received counts a mismatch only when a snapshot's query
  differs from its own stream's query or its generation from the stream's first generation; a
  late snapshot of a superseded stream satisfies both. `finals <= changes + 20` cannot detect
  superseded streams finishing either (one final per stream is at most `changes`).
- Covered elsewhere as the finding says: ResultsModelTests.swift:118-150 (10,000 random changes,
  each published hit checked against the model's current query) and ConcurrencyTests.swift:223-
  244 (deterministic: an obsolete producer yields nil). Low is right.

## C1-s06-quality-09: filter/kind precision gate vacuous on empty lists. Verdict: partly (low)

- True: RelevanceMetrics.precision returns 1 for an empty list (RelevanceMetrics.swift:68-71,
  documented); GoldenGates.swift:38-39 gates filterAndKind on precision alone;
  testNoHitEverViolatesAHardConstraint (RelevanceTests.swift:198-215) accepts empty lists. This
  matches 15.3's own definition ("Precision 1.0; no hit may violate a hard constraint").
- Wrong: "Nothing checks that filtered queries still return their judged items."
  RelevanceTests.testRerankedHeadNDCG (265-280) loops over every class including filterAndKind,
  takes the queries with text (most constrained queries carry a lemma, GoldenSet.swift:675-725)
  and asserts reranked NDCG@10 >= 0.85 and >= the fused NDCG; an empty list scores 0 there.
  CoreCorrectnessTests.testFiltersAndKindTokensAreHardConstraints (285-307) asserts exact,
  non-empty ids for kind, two-kind and filter tokens. The finding's scenario (every filtered or
  kind-token query returns nothing) fails both.
- Corrected description: the class gate and the no-violation test are vacuous on empty lists;
  filtered recall is checked only in the reranked stage at golden-set scale and on the small
  catalog, so a regression that empties filtered results only in the lexical or semantic stage
  at scale (and is masked in the reranked stage) would pass. Low.

## C1-s06-quality-10: any `.environmentObject(` satisfies the lint for every model. Verdict: confirmed (low)

- SourceLint.swift:223-226: `attached = sources.contains { ... || source.code.contains(".environmentObject(") }`
  for each of the three models. Scratch demo (lint/: the repository's SourceLint.swift compiled
  unchanged with a two-file input): a Chat.swift reading `@EnvironmentObject ZTronChatModel`
  alone gives one finding; adding a Settings.swift with `.environmentObject(settings)` gives
  none.
- Spec 13.1 rule 3 (p36) and 16 p49 ask the lint to catch a screen that reads a model without
  attaching it. Latent today: the lint scans ParityHost and a missing Examples directory, and no
  scanned file reads a package model through @EnvironmentObject. Low is right.

## C1-s06-quality-11: exact title inside the head only tested with an agreeable reranker. Verdict: refuted (none)

- The facts are right (RankingTests.swift:334 `position < 16` is vacuous for a 16-document list;
  the golden-set reranked stage uses FakeReranker's lexicon overlap, which scores an exact title
  1, the maximum), but the gap does not exist. Spec 7.4 (p13) defines the head as the reranked
  top 16: "Only the reranked head is reordered; hits below position 16 keep their fused order".
  SearchPipeline.reranked (SearchPipeline.swift:155-184) permutes only documents[..<headCount]
  and appends the rest unchanged; SearchService.swift:453 builds the reranked snapshot from it
  (pins applied after), and RankingTests.testRerankBlendIsConfinedToTheHead (297-311) tests
  the confinement. So no blend weight and no cross-encoder can move a hit that is in the fused head
  out of the head; the failure scenario ("pushes exact-title hits ... out of the top 16") cannot
  happen. Whether the hit is in the fused head at all is fusion's job, held by the exactTitle
  rank-1 gates (>= 0.98) at every stage. The `< 11` check also catches a blend-weight change on
  the constructed list.
- Only under a narrower, unstated reading of "head" (for example the top 10) would a golden-set
  run with an adversarial reranker be missing; the spec gives no such definition.

STATUS: complete
