# Cycle 2 - m06 tests/gates skeptic (verify-m06-tests-gates)

Skeptic pass over find-m06-tests-gates.md (14 findings). Repository commit cee4620, read only
(`git status` shows only the untracked Verification/ before and after this pass).
Scratchpads (repro programs and outputs):
- first run: /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m06-tests-gates-skeptic/
  (xfail/, stream_cancel_skeptic.swift, with_timeout_skeptic.swift, sleep_overshoot.swift,
  pkgcopy/ = scratch copy of the package with SkepticProbeTests.swift, relevance-0/-5000/-100000.log)
- resumed run: /private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m06-tests-gates-skeptic/
  (probe-fusion.log, perf-run1.log, perf-db-repeat.log, probe-memory.log, probe-relevance-5000.log,
  probe-relevance-100000.log, sqlite-copy/ = scratch copy of core + Adapters/ZTronSearchEngineSQLite,
  sqlite-build.log, sqlite-targets-repeat.log, SkepticProbeTests.swift = copy of the probe source)

Scope note: per the task, nothing under Verification/ was read except the auditor's checkpoint and
Verification/_inputs/spec.txt. The run logs in Verification/_runs were NOT read; numbers quoted from
them are marked "auditor's log figure, not re-read".

Resumed run (2026-11-18): the first run stopped after building SkepticProbeTests.swift into pkgcopy/
(release, -enable-testing; probe-build.log exit 0) without running it. Re-checked: pkgcopy/Sources,
Tests and Package.swift are byte-identical to the repository (diff -rq) apart from the probe file.
This run reused that build (`swift test -c release -Xswiftc -enable-testing --skip-build`, run inside
pkgcopy, never in the repository). The SQLite adapter was copied with the SQLite.swift 0.17.0
checkout already on disk (pinned revision 4114679) and built offline
(`--disable-automatic-resolution --skip-update`, no fetch in sqlite-build.log). Machine during the
resumed run: load average 5.2-7.6 on 8 cores, with 5 simulators booted by someone else and
PerfPowerServices plus a MapKit snapshot service using about 2 cores (the first run saw 370-800).

## Verdicts

### C2-m06-tests-gates-01 - CONFIRMED - high
Traced: PerformanceTests.check (:70-87) calls `XCTExpectFailure(knownGap)` (no closure) only when
measured > allowed. Masked assertions are exactly those after a known-gap check in the same test:
:535 (after :534) and :327 (after :323-326). Earlier assertions in those tests are not affected.
Repro: scratch XCTest package xfail/ (copy of check()), `swift test`, log in xfail-run.log:
- testA (sync, shape of :534-535): both failures reported "XCTExpectFailure: matcher accepted ...";
  the over-budget scan-query check with NO known gap is an "Expected failure"; test passed.
- testB (async, shape of :316-327): "XCTExpectFailure: matcher accepted Assertion Failure at
  XFTests.swift:34: XCTAssertLessThan failed: ("1.0") is not less than ("0.25") - a query never waits
  for the rebuild"; test passed.
- testF: masking survives several awaits in an async test.
- Controls testC/testD (same assertions without the preceding known gap) failed as they should.
- testE: known gap now within budget -> XCTExpectFailure never called -> test passes with no failure
  (the strict option can never fire). Only the PERF line's "(within)" shows the gap closed.
No other test bounds query latency during the rebuild: InternationalizationTests
.testLocaleChangeRebuildsUnderANewGenerationWhileQueriesKeepWorking (:233-283) only checks the probe is
found, which a blocked-then-answered query also satisfies.
Minor correction: "nothing reports when a gap closes" - the PERF print says "within"; no test outcome
changes. That the rebuild was over budget in every run is the auditor's log figure, not re-read
(the knownGap text itself concedes it).
Resumed-run addendum: in the unmodified release class (perf-run1.log, load ~6) the rebuild was again
over budget (853.343 ms vs 333.333 ms allowed), so XCTExpectFailure was armed before :327 again
(:327 itself held: "slowest query during the rebuilds 50.263 ms"). Catalog-sized scan creation was
8.202 ms vs 8.333 ms (within), so :535 was not masked in that run: the masking of :535 depends on load.

### C2-m06-tests-gates-02 - CONFIRMED (code and docs; multiples re-measured smaller) - high
Code: knownGap on :323-326 (rebuild), :396-397 (upsert new/replaced) and :534 (catalog-sized scan
creation); gap texts concede the reference device cannot meet the rebuild ("is more work than the
reference device does in 2 s by this estimate") and upsert ("the word tokenizer alone takes most of the
budget by this estimate"). Spec 15.1 (p.42-43) fixes "2 s, in the background, never blocking a query"
and "0.1 ms amortized"; 17 milestone 1 gate includes "the lexical latency targets", gated "passing on
the reference device"; nothing in 16 or 17 defers them (milestone 9 tunes and locks baselines later,
it does not waive milestone 1). README:205 "hold every measurement against its budget" and ci.yml:5-7
"asserts each budget" are untrue for these four checks; README:216 discloses only parity.
The 1134-2568 ms / 0.053-0.146 ms figures are the auditor's log figures, not re-read (machine load
during the first pass reached 800, so no timing rerun was meaningful then).
Resumed-run addendum (perf-run1.log, load ~6): rebuild 853.3 ms vs 333.3 ms (2.6x); upsert new
0.050 ms and replaced 0.065 ms vs 0.017 ms (3.0x, 3.9x); NLTokenizer alone 0.014 ms per 57-word
document. All three still pass only as expected failures. The auditor's 3.4-7.7x and 5-8.8x include
load; the gaps are real at 2.6-3.9x. Catalog-sized scan creation passed narrowly at this load
(8.202 ms vs 8.333 ms).

### C2-m06-tests-gates-03 - PARTLY (design flaw confirmed; evidence and extrapolation unreliable) - medium
Confirmed in code (PerformanceTests.swift:244-275): overhead = total - 0.300 - measured lastEncoding;
allowance = 0.500 - 0.300 - 0.180 = 20 ms, never passed through ReferenceDevice.scaled (contrast
README:205-208 and ReferenceDevice.swift:39-43); 5,000 items (:249) and FakeSemanticSearcher, a
brute-force cosine search (FakeSemanticSearcher.swift:13-14, :110-122), not 100k + HNSW; no assertion of
the total against 500 ms (only :273-274). With 12 samples Measure.p95 returns the maximum (index
Int(12*0.95)=11), so "worst" is the package's p95. By the README rule the engine's CPU share should be
held to 20/6 = 3.3 ms here.
Overstated: the "engine adds" figure is not engine CPU. It includes the overshoot of the 300 ms
debounce Task.sleep (only the encoder's overshoot is subtracted). Repro sleep_overshoot.swift at load
~225: "debounce 300 ms: overshoot min 3.52 ms, median 15.89 ms, max (= p95 of 12) 24.19 ms"; "encoder
180 ms: overshoot min 6.71, median 11.51, max 17.93 ms". So the auditor's 12.7-19.9 ms (logs taken
under load 370 / 8.4 with 12 simulators) can be mostly timer latency, and multiplying all of it by 6
(556-599 ms) is not supported. What stands: a 6x engine regression inside the 20 ms passes, and a
total over 500 ms passes.
Resumed-run addendum (perf-run1.log, load ~6): "worst 504.642 ms in all; the engine adds at most
13.353 ms ... (allowance 20.000 ms)" and the test passed: a p95 total over 500 ms passes, seen here.

### C2-m06-tests-gates-04 - PARTLY (core claim confirmed by repro; one sub-claim refuted; scope of the failure scenario narrower) - medium
Scope correction: deleting every Task.checkCancellation in IndexSearcher (:685, :789, :852, :956 are
the only lexical checkpoints) makes testTheScoringLoopChecksCancellation (:82-107) fail - a pre-cancelled
task would finish the search and return false - so the suite catches that half of the failure scenario;
the onTermination removal (SearchService.swift:293) is caught by nothing. The implementation today does
install onTermination and has checkpoints, so this is a coverage gap for the producer side (spec 7
rule 7, 15.4), not a live defect: medium rather than high.
Repro: stream_cancel_skeptic.swift (copy of results(for:) shape + the three tests' shapes).
Output:
- before-search shape: onTermination installed: consumer saw [], exit 0.1 ms, producer's debounce
  sleep cancelled; onTermination REMOVED: consumer saw [], exit 0.0 ms, producer "debounce slept the
  full 300 ms, 263.9 ms after cancel".
- onTermination shape: installed: consumer ["lexical"], exit 0.0 ms, encode cancelled; REMOVED:
  consumer ["lexical"], exit 0.0 ms, producer "encode slept the full 5 s, 4948.7 ms after cancel".
- during-search shape: checkpoints: producer stopped 0.0 ms after cancel; NO checkpoints: consumer
  exit 0.0 ms, producer ran on 288-312 ms after cancel.
So count==0 / phases==[.lexical] / exit<0.1 s / exit<0.5 s / worst<10 ms+full/4 all hold for the
regressed producers. StubSemantic (TestSupport.swift:161-218) records no cancellation; grep of Tests/
finds no test asserting the producer stopped after a consumer cancel.
Refuted sub-claim: "10 ms + full/4 is looser than the spec's 10 ms". Spec 15.4/section 11 say "within
10 ms of the next checkpoint"; time to reach the next checkpoint is bounded separately (rule 4: every
1,000 postings), so an allowance for reaching it is not a relaxation.

### C2-m06-tests-gates-05 - PARTLY - low
Real: the Ledger (ConcurrencyTests.swift:167-178) only compares a snapshot with its own stream's
query and first generation, so a late yield of a stream's own snapshot is counted as correct; the doc
comment's second half ("once a newer query has been issued an older stream never yields again") is not
checked by this test.
Overstated: (1) the spec property is about snapshots *published* (15.4; section 11 rule 6 puts the
generation+query check at the UI boundary), and ResultsModelTests.testNoStaleSnapshotsOverTenThousand
RandomizedQueryChanges (Tests/ZTronSearchEngineUITests/ResultsModelTests.swift:118-150) checks exactly
that over 10,000 changes, comparing each published hit with model.query; (2) engine-side suppression is
asserted by testAnObsoleteProducerNeverYields (:223-244). (3) The failure scenario does not reproduce
by reasoning: SearchService.isCurrent checks Task.isCancelled first and results(for:) cancels the prior
task (SearchService.swift:283-286); the check and the yield run on the actor with no await between them
(publish(): `guard isCurrent(lane)` then `emit`), so dropping only the generation check reopens no
window for a late yield.

### C2-m06-tests-gates-06 - PARTLY - low
The auditor's measured failures come from runs at load 370 and 8.4 with 12 simulators (log figures,
not re-read). Re-measured in the resumed run at load 5.2-7.4 on 8 cores:
- RRF fusion: refuted. Unmodified testFusionOfThreeChannelsOfTwoHundredEntries: "0.068 ms measured;
  ... 0.083 ms here (within)" (perf-run1.log); probe testProbeFusionCPU, 3 runs: "wall p50 0.068 ms
  p95 0.069 ms; thread CPU p50 0.068 ms p95 0.069 ms; allowed here 0.083 ms" (probe-fusion.log).
  Wall = thread CPU, so no preemption at this load. Scaled by 6: 0.41 ms, under the 0.5 ms budget
  (the auditor's 0.66 ms came from the loaded 0.110 ms).
- One page of 500 rows (p95): within in every run: in-memory fake 4.197-6.351 ms (6 runs), SQLite
  4.033-4.523 ms (5 runs), against 6.667 ms.
- Context creation from 10k rows: fake 187.5-213.5 ms in 5 isolated runs and 262.0 ms once (the
  full-class run); SQLite 153.3-210.4 ms (5 runs); against 250 ms: within in 10 of 11 runs.
- Incremental upsert of 100 changed rows (p95 of 40 commits): intermittent. Fake: 20.812, 3.483,
  23.891, 3.504, 7.985, 10.312 ms (OVER in 3 of 6); SQLite: 5.447, 13.545, 3.008, 2.780, 2.674 ms
  (OVER in 1 of 5); against 8.333 ms. The p50 is 2.3-3.8 ms in every run, and the worst of 40 ranges
  2.8-67.5 ms. That p95 is the second-worst of 40 samples (index 38), and the wait is a Task.yield
  busy-poll on the pool the change handler also needs (PerformanceTests.swift:629-632,
  DatabaseTargetsTests.swift:170-173). The engine's persist/compact timer fires 1-2 s after the last
  change (SearchService+Context.swift:634-650), so it cannot land inside the loop (about 3 ms per
  round). The tail is scheduling noise, not a steady engine cost.
- Index round trip in the host database: write 3.8-12.2 ms, load 0.6-1.5 ms, far within.
Full-class run (perf-run1.log): "Executed 17 tests, with 2 failures": creation 262.0 ms and upsert
20.8 ms; the knownGap checks were expected failures as in 01/02.
Corrected description: at moderate load on this Mac, fusion and the page target pass with margin,
and context creation almost always passes (one 262 ms in 11). The one check that still fails is the
15.9 upsert p95. It fails intermittently, with a median under half the 8.33 ms allowance, because a
second-worst-of-40 busy-polled measurement picks up scheduling tails. The CI quality-targets job is
plausibly flaky on a shared runner because of that check; no target is shown to be missed, and the
device extrapolation for fusion does not hold. Severity low.

### C2-m06-tests-gates-07 - PARTLY - low
Real: RelevanceMetrics.precision returns 1 for [] (RelevanceMetrics.swift:69-72), the filterAndKind
gate is precision alone (GoldenGates.swift:38-39), testNoHitEverViolatesAHardConstraint only inspects
returned hits, and the golden filterAndKind judgments (GoldenSet.swift:620-657) are never used by a gate.
Overstated: the failure scenario "every kind or filter query returns an empty list" turns the unit job
red through CoreCorrectnessTests.testFiltersAndKindTokensAreHardConstraints (:285-307, asserts
["map-harbor"], {"map-harbor","image-harbor"}), testFiltersAreANDAcrossKeysAndORWithinAKey (:263-283)
and testPureTokenQueriesSkipSemantic... (:320-331), none skipped in debug. What the gate cannot catch is
a regression that empties some golden constrained queries only. The spec's own metric for the class is
"Precision 1.0; no hit may violate a hard constraint" (15.3, p.44), which an empty list satisfies.
Resumed-run addendum (probe PROBE07, release, at 5,000 and 100,000 distractors): "gate value if every
filterAndKind list were empty: 1.0000" (vacuous pass confirmed); today 0 of 69 filterAndKind lists are
empty, the source item is returned for all 69, recall@10 0.9553-0.9575, at every stage.

### C2-m06-tests-gates-08 - PARTLY - low
Confirmed in code: distractor titles and keywords are pseudo-words only (SyntheticCorpus.swift:248-261,
315-324). No Latin pseudo-word starts with the first three letters of any lemma, synonym or
Italian/German form (SyntheticVocabulary.swift:94-98, :125; FixtureLexicon.latinForms :205-209).
English lemmas enter base bodies only from word 24 on (SyntheticCorpus.swift:89, :363), and synonyms
and reserved translations never (SyntheticVocabulary.swift:158-169). The gated RELEVANCE rows are
identical, character for character, at 5,000 and 100,000 distractors (first run's
relevance-5000.log / relevance-100000.log, seen).
Refuted: "adds no competition", "built never to match a golden query", "no distractor can reach a
golden head position". The distractors are built never to be *relevant*, but they do match golden
queries through several routes:
- English lemmas in base bodies
- lexicon words from word 0 in localized bodies and captions (:384-388)
- typo-neighbour pseudo-words (the prefix rule does not stop a pseudo-word from lying within two
  edits of a misspelled token)
- filters (game genre values are lexicon tag lemmas, :98, :419)
Evidence (SkepticProbeTests.testProbeRelevanceOutcomes, release, scratch copy):
- 0 -> 5,000 distractors: lexical typo recall 1.0000 -> 0.9855, semantic titlePrefix MRR 0.9875 ->
  0.9867 (relevance-0/-5000.log).
- queries with a distractor in the top 10, 5,000 -> 100,000 (probe-relevance-5000/-100000.log):
  - lexical: exactTitle 12 -> 51 of 60 (46 -> 175 slots), titlePrefix 17 -> 32 of 60, typo 25 -> 42
    of 69, localizedTitle 12 -> 29 of 60, filterAndKind 49 -> 56 of 69
  - semantic: exactTitle 7 -> 11, typo 21 -> 28, filterAndKind 51 -> 54
- a distractor ranked above a judged item in the top 10: at 5,000 in 4 semantic paraphrase,
  1 semantic crossLanguage and 1 lexical filterAndKind query; at 100,000 only in 2 lexical
  filterAndKind queries.
- ungated numbers move between 5,000 and 100,000: semantic NDCG@10 paraphrase 0.9696 -> 0.9939,
  crossLanguage 0.9745 -> 0.9806, typo 0.9035 -> 0.9094; lexical filterAndKind recall@10
  0.9563 -> 0.9553.
So the 100k run does add competition, in the form of more distractors in the head. The gated means
do not move because the judged items keep their places above them.
Failure scenario: half refuted. Body-only matches already sit in the top 10 of 51 of 60 lexical
exact-title queries at 100k. A ranking change that let body-only matches outrank titles would put a
distractor at rank 1 and fail the exact-title gate (98% at rank 1). What stands: distractors are easy
negatives, and title-level near misses (titles sharing a prefix or words) come only from the 420
golden items (GoldenCorpus.swift:60-66 excludes only subset titles). So a regression that favours
near-miss titles is gated on that small set alone.
Not a false claim: README:179-180 and ci.yml:49-52 say "among 100,000 distractors", which is
accurate, and SyntheticCorpus.swift:14-23 documents the construction.
Corrected description: by construction the distractors never become relevant, so they almost never
outrank judged hits, and the gated means stop moving after 5,000. They are not inert, though: they
match through body and localized lemmas, typo neighbours and filters, take more top-10 slots as the
corpus grows, and change typo recall (0 vs 5,000) and several ungated NDCG figures (5,000 vs 100,000).
The gates cannot see near-miss title competition beyond the golden set's own items.

### C2-m06-tests-gates-09 - PARTLY (mostly confirmed) - medium
Confirmed:
- PerformanceBudget.rerankedSnapshot (ReferenceDevice.swift:67) is referenced nowhere in Tests/,
  Sources/, Adapters/ or ParityHost/; every other latency budget is used. The 750 ms final snapshot
  could be held like the 500 ms one, with a sleeping fake reranker.
- No test asserts the 15.2 steady state (110 MB) or peak (200 MB), and none checks "no frame over
  16.7 ms attributable to search". ResultsModelTests.testPublishingTwentyHitsCostsUnderAMillisecondOnMain
  (:268-289) covers only the 1 ms publish cost. The vector and graph rows are asserted on file sizes
  (HNSWRecallTests:56-58), and the model rows with stubbed footprints (CoreMLAdapterTests:182-186,
  511-515).
- testIndexingKeepsItsWorkingMemoryInBounds (:455-463) says "Not a target of section 15" and asserts
  < 200 MB. Measured here for 100,420 items held in memory: "heap retained afterwards 125.4 MB"
  (perf-run1.log) and 125.5 MB (probe-memory.log), over the 110 MB steady state. The auditor's
  131.6 MB is a log figure, of the same order.
- The in-memory segment alone is 88.2 MB: 41.6 MB of index sections, already over the 40 MB
  lexical-index row when all of it is resident (as it is in memory), plus 46.6 MB of stored documents
  (probe "compacted segment: index sections 41.6 MB, stored documents 46.6 MB").
- testLexicalIndexMemory (:402-438) measures only a freshly mapped index and leaves out the
  stored-document section. That choice decides the pass: 24.4 MB is measured without it; adding the
  29.6 MB of stored-document pages the golden set touched gives 54.0 MB, over 40 MB (perf-run1.log).
  The spec does not say whether the document store counts as "Lexical index", and the segment holds
  it (LexicalIndex.swift:5-8).
- testBaselineIndexingTenThousandItems (:678-689) uses 10k items. Reference.prepare does time the
  100k indexing (1.78 s here, printed), but section 15 gives that no budget.
Refuted sub-claim: excluding "any heap allocated by load" loses nothing. The probe printed "heap
allocated by load(from:) and kept: 0.0 MB".
Scope: the failure scenario holds for the README quick start (README:64-65,
`SearchService(index: LexicalIndex())` then `await service.index(tips)`), which keeps the segment on
the heap. The spec's memory policy (p.24, "Lexical index files are memory-mapped with .mappedIfSafe")
and LexicalIndex.save(to:) ("continues from the mapped file", :97-98) give the configuration with
24.4 MB of lexical residency, plus 29.6 MB of clean stored-document pages. That configuration is not
shown to exceed 110 MB, but no test measures steady state in either configuration. Peak during a
semantic query (200 MB) includes the 80 MB embedding model, so it belongs with the model-bound rows
the auditor accepts.
Severity medium kept: section 16 asks for "Index size and resident memory assertions from section
15.2", the steady-state row has none, and the quick-start configuration exceeds it on its lexical
side alone.

### C2-m06-tests-gates-10 - CONFIRMED (CI gap); measured failure intermittent - low
adapter-tests.yml:57-63 runs `swift test` and `swift test --sanitize=thread` (debug);
DatabaseTargetsTests.swift:70-72 throws XCTSkip under DEBUG; ci.yml and parity.yml never enter the
adapter directory in release. So the SQLite-backed 15.9 run never executes in CI.
Severity lowered: README:188-191 lists it as a local command and claims nothing about CI; the same
15.9 budgets are asserted in CI against the in-memory fake (PerformanceTests.testDatabaseSources,
ci.yml:47-48), which is what spec 16 prescribes for core database tests; the gap is the SQLite read and
change-hook cost only. The 10.154 ms vs 8.333 ms figure is the auditor's log figure.
Resumed-run addendum: the release DatabaseTargetsTests were re-run 5 times in sqlite-copy/ at load
~7.3 (sqlite-targets-repeat.log). Upsert p95 was OVER once (13.545 ms; p50 2.7 ms) and within 4
times (2.674-5.447 ms); every other target was within. "One target is already failing" therefore
describes an intermittent tail, not a steady miss (see 06).

### C2-m06-tests-gates-11 - PARTLY (revised in the resumed run; was CONFIRMED) - low
First-run reasoning, still standing: FakeEmbeddingProvider.swift:4-22 (one unit vector per lexicon
concept, synonyms and translations land on the same point), FakeReranker.swift:6-9 (score = share of
the query's concepts a passage covers); the golden queries come from the same lexicon.
testRerankedHeadNDCG (:265-281) passes when reranked == fused (after >= before - 1e-9; 0.85 already
met by fused), testTheFinalSnapshotIsTheOneTheStageAsksFor (:217-226) checks phase labels only. Seen
myself (scratch copy, release): at 0 and 5,000 distractors the RELEVANCE reranked row equals the
semantic row in every class, and lexical paraphrase/crossLanguage are 0.0000 while semantic are
0.9875/1.0000. Mitigation as the auditor says: SnapshotPipelineTests
.testThirdSnapshotReordersTheHeadOnDevicesPastTheGate (:300-321) asserts the reranked ids differ from
the semantic ids (XCTAssertNotEqual), so "fused order left in the reranked snapshot" fails the unit
job; README:212-214 discloses the fakes.
Revision: the first run had written PROBE11 to test "the rerank stage changes no metric", and it ran
in the resumed run:
- 5,000 distractors (the default, which the debug unit job runs): the reranked top 10 differs from
  the fused top 10 in 45 of 483 queries, and NDCG@10 rises for paraphrase (0.9696 -> 0.9939) and
  crossLanguage (0.9745 -> 0.9806). Other classes are equal.
- 100,000 (the CI quality job): the top 10 differs in 26 queries, and every class's NDCG@10 mean is
  equal to four decimals.
So "changes no metric, so never-below-fused holds by equality" is true of the gated RELEVANCE rows
and of NDCG@10 at 100,000 only. At the default size the stage improves NDCG@10. The rest stands: the
gates are reached with oracle fakes, and the rerank gate would pass with the fused order unchanged.

### C2-m06-tests-gates-12 - PARTLY - low
Repro: with_timeout_skeptic.swift (withTimeout copied verbatim) printed:
- lost continuation: "withTimeout(0.5), 3.1 s later: still waiting"
- blocked thread (semaphore): "withTimeout(0.5), 3.1 s later: still waiting"
- AsyncStream never finished: "withTimeout(0.5) returned nil -> XCTAssertEqual(finished, true) would FAIL"
- Task.sleep 1 h: "returned nil -> ... would FAIL"
Corrected description: the guard works only for hangs that respond to cancellation (a stuck stream
consumer, a sleep); for a lost continuation or a blocked thread in a directly awaited call - the classes
its message names - withTaskGroup waits for the child forever and only the CI job timeout ends it.

### C2-m06-tests-gates-13 - PARTLY - low
(a) True that :340-342 hold without any 2,000 cap (200-entry fusion cap; "Lantern n" title+body always
outscores body-only "Planner n"), and that PerformanceTests:143 reads timings.candidates = slotCount
(IndexSearcher.swift:713), bounded at every write by `limit` (:686, :799, :855). But "cannot fail" is
too strong: the limit-50 sub-check (:344-347) exercises the cap mechanism, and :143 fails if the default
lexicalCandidates is raised above 2,000 (a 100k query on common words fills it). Together they cover
mechanism + default.
(b) True: only `fileExists(directory)` is checked (SearchContextTests.swift:294-309); a read attempt
is invisible.
(c) True that id "picker" is reused and 2 MB is tolerated; but the weak-reference check (freed == 1,000)
catches any registry that retains the service, whatever the id, and grep finds no static registry in
Sources/ZTronSearchEngine. Only an id-keyed side table that does not retain the service would slip.
(d) True: the file is written just before each load (PerformanceTests.swift:285-290), so the page cache
is warm; a truly cold load needs a purge or the device.

### C2-m06-tests-gates-14 - CONFIRMED - low
(a) setUpWithError skips all 17 tests under DEBUG (:58-62; 17 `func test` counted); README:205-210 says
the class "carries XCTClockMetric and XCTMemoryMetric baselines to record there" without saying how to
build Release with testability for a device run. (b) ci.yml:65-67 calls ["15.5","18.6"] "The floor and
the current release" while parity.yml:67 and ParityHost/ReferenceSnapshots/ios-27.0 exist (parity.yml:10
itself calls 27.0 "the current beta"); 15.5 is also not the package floor (Package.swift: .iOS(.v15)).
Documentation only.

## Summary
| id | verdict | severity |
|---|---|---|
| 01 | confirmed | high |
| 02 | confirmed | high |
| 03 | partly | medium |
| 04 | partly | medium |
| 05 | partly | low |
| 06 | partly | low |
| 07 | partly | low |
| 08 | partly | low |
| 09 | partly | medium |
| 10 | confirmed | low |
| 11 | partly (revised from confirmed) | low |
| 12 | partly | low |
| 13 | partly | low |
| 14 | confirmed | low |

STATUS: complete
