# Cycle 2 — m01 text pipeline / lexical index / scan — skeptic verification

Scope: findings C2-m01-text-index-01 .. -12 from find-m01-text-index.md. Commit cee4620.
Resumed run. The earlier run left only a header here and an unrun harness under
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m01-text-index-skeptic/
(no results recorded), so every verdict below is from this run.
Scratch work for this run (S below): /private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m01-text-index-skeptic/
- S/pkg: fresh copy of Sources/ZTronSearchEngine and Sources/ZTronSearchFixtures (diff -rq identical to the repo) plus
  an executable Harness (the earlier run's main.swift, reviewed, plus three modes added here), `swift build -c release`.
- S/xctexpect: a 6-test XCTest probe of XCTExpectFailure semantics (`swift test`, debug).
- S/run.sh runs one harness mode per process with a wall-clock kill (hang detection); outputs in S/out*.txt.
Nothing was built, tested or changed in the repository. Machine: Apple M3 (8 cores), shared: load average 4.7-7.8
during the runs, so timings carry noise.

---------------------------------------------------------------------------------------------------
## C2-m01-text-index-01 — closure-less XCTExpectFailure masks later assertions
Verdict: PARTLY. Severity: medium (auditor: high).
- Code: PerformanceTests.swift:77-81 calls `XCTExpectFailure(knownGap)` (no closure) when a known-gap budget is over;
  :534 (creation, knownGap) precedes :535 (query, no knownGap); :323-326 (rebuild, knownGap) precedes :327
  `XCTAssertLessThan(worstQuery, 0.25, "a query never waits for the rebuild")`. :536 only prints memory; :58-62 skip in DEBUG.
- Probe (S/xctexpect, mirrors check()): testA (gap fires, then a non-gap check fails) PASSED with
  "XCTExpectFailure: matcher accepted Assertion Failure at ExpectTests.swift:18 ... query Reason: (creation gap)";
  testB (gap, then plain XCTAssertLessThan fails) PASSED; testE (later failure inside a helper) PASSED;
  controls: testC (gap not fired) FAILED as it should, testD (scoped closure form) FAILED the later assert as it should.
  So the mechanism is exactly as described: every later failure in the method is absorbed.
- Does the gap fire? Rebuild (perf-rebuild, perf-rebuild-probe, same shape as the test): worst of it/de = 820, 674,
  742 ms vs 333.3 ms allowed -> the gap fires on every run here, so :327 can never fail on this machine.
  Catalog-sized scan creation: p95 7.709 and 8.114 ms vs 8.333 ms allowed -> within budget in both of my runs, so the
  :535 query gate was live in my runs; it is masked only on runs where creation goes over (borderline, load-dependent).
- What the masking hides today: nothing. Slowest probe query during the rebuilds 43.6 ms / 31.0 ms (1,276 / 1,238
  queries) vs the 250 ms assertion; catalog-sized scan query p95 0.124 / 0.129 ms vs 0.5 ms allowed.
- No other test times queries during a rebuild: InternationalizationTests:233-283 would pass even if every query
  waited for the rebuild (they still return "probe" afterwards; nothing is timed). So the masked assertion is the
  only timing check of spec 5 rule 7 / 15.1 "never blocking a query" — and per the project's own estimate the
  rebuild gap would also fire on the reference device, so it is dead there too.
- Corrections: the harm is latent (no current failure is hidden); the 15.8 query gate is masked intermittently,
  not systematically; the scenario "2x slower scan queries" would not fail even unmasked (0.12 -> 0.25 ms < 0.5 ms),
  it takes a >4x regression; the DEBUG skip is deliberate and documented (budgets are meaningless unoptimized);
  the catalog-sized memory is 0.72 MB (would pass the 1 MB budget if asserted). The rebuild-liveness masking
  (a regression that blocks queries behind a locale rebuild ships green) is the real, medium-severity part.

## C2-m01-text-index-02 — rebuild / upsert / catalog-sized scan-creation budgets missed by the scaled estimate
Verdict: PARTLY. Severity: medium (auditor: high).
- Budgets: spec 15.1 "Full lexical rebuild on locale change 2 s, in the background, never blocking a query" and
  5 rule 7 "Budget: 2 s for 100k items"; 15.1 (page 43) "Incremental upsert, per document 0.1 ms amortized";
  15.8 "Context creation ... 500 documents 50 ms". ReferenceDevice.slowdown = 6 on macOS (ReferenceDevice.swift:21-22),
  scaled() = budget / 6. Section 15 header and 17 ("Milestones, each gated by its tests passing on the reference
  device"; milestone 1 gate includes "the lexical latency targets and the section 15.8 timings"; milestone 9 is device
  validation) keep the device as the gate; nothing in 16/17 relaxes the budgets.
- My measurements (S/out02-perf.txt, S/out01-probe.txt; harness modes mirror the tests):
  rebuild setLocale it/de = 589/820, 667/674, 525/742 ms wall vs 333.3 ms allowed -> over by 2.0-2.5x
  (process CPU 1.7-2.6 s per rebuild, i.e. ~3x parallelism here; a 2-core A9 cannot parallelize that far, so the
  wall/6 estimate is if anything optimistic). Upsert per document: replaced 0.066 ms, new 0.050 ms vs 0.017 ms
  allowed -> 3-4x over. Scan creation, 500 catalog-sized documents: p95 7.709 / 8.114 ms vs 8.333 ms -> WITHIN.
- So: rebuild and upsert misses are real and consistent; the rebuild overshoot is ~2-2.5x here, not the 3.4-7.7x
  quoted; the scan-creation miss did not reproduce (it sits at the limit and depends on load). Severity medium, not
  high: off-device estimates, the slow work is background work that does not block queries (measured), and the gaps
  are declared knownGap with explanations, so they are not hidden (the masking side effect is -01).

## C2-m01-text-index-03 — segment validation only at the outer layer; corrupt files crash, hang or mislead
Verdict: CONFIRMED. Severity: medium.
- Code: IndexSegment.init (IndexSegment.swift:107-196) checks magic, version, section bounds, fixed section sizes,
  power-of-two id table, kind/filter/metadata tables; nothing checks term/id/store/filter/forward offsets, posting
  bytes, kind/filter ordinals or id-hash entries, which the readers use unchecked (:299-302, :393-396, :402-404,
  :410-412, :419-422; `while true` in ordinal(ofID:) :428-445). :137 `Int(UInt64)` and :139 `offset + length` trap.
  No checksum anywhere in Index/. Reuse path SearchService+Context.swift:129-133 adopts whatever passes
  `try? IndexSegment(data:)` + `validate` (validate checks versions, languages, model id, fingerprint only).
  ByteCoding.swift:124 comment "The segment was validated when it was opened." is not true of offsets/payloads.
- Repro (S/out03-load.txt, S/out03-launch.txt): persist a 3-document context with `.files`, patch the file, then
  (a) LexicalIndex.load(from:) and (b) a second `SearchService(context:)` launch over the cached file:
  - documentKinds[0] = 0xFFFF: load accepted ("count = 3", file kept); launch: init returned, first query "apple" ->
    signal 5, frame "Index out of range ... IndexSearcher.rankedList <- IndexSearcher.search <- LexicalIndex.search".
  - every idHash slot = 1: load accepted; launch: `document(for: "zzz")` (public SearchService API) never returned,
    killed after 15 s; `document(for: "a")` and search still worked. upsert (difference -> locate) and remove
    (deleting -> ordinal(of:)) reach the same loop (LexicalIndex.swift:409, :440, :451), so an upsert of a new id
    would hang too (code reading), with the actor's mutation lock held.
  - storeOffsets[0] = 0x7FFFFFF0: `document(for: "a")` = nil (document silently lost), search still returned "a".
  - section 0 offset = UInt64.max: signal 5 "Not enough bits to represent the passed value" in closure #1 in
    IndexSegment.init <- static SearchService.prepare <- SearchService.init(context:) (and under
    LexicalIndex.load(from:expecting:) for path (a)); file still on disk -> same crash at every launch.
  - offset = length = 2^62: signal 5 "arithmetic overflow" at the same place.
  - termOffsets[0] = 5, [1] = 0: accepted; the lexical channel lost the exact match ("apple": lexical = [], control
    ["a"]) but fuzzy rescued it (service hits ["a"]); the auditor's "lexical = [b]" did not reproduce exactly, the
    lexical channel is still silently wrong.
  - control (kind table string-length varint 2^64-1 in a 5-byte section): threw corruptIndex and the file was removed,
    i.e. the throwing paths do recover; only traps/unchecked reads do not.
- Reach and likelihood: FileIO.write uses `.atomic` (FileIO.swift:12-16), so torn writes are excluded; corruption needs
  bit rot, tampering or a future writer bug. Spec 6 only requires discarding on version mismatch, but a cache file
  that crash-loops the app at every launch (no catch can run before the trap) is a robustness defect; medium stands.

## C2-m01-text-index-04 — persisted-index reuse ignores most content (filters, keywords, localizations, same-length edits)
Verdict: CONFIRMED (small correction). Severity: medium.
- Code: fingerprint(of:) (SearchService+Context.swift:181-199) mixes id, kind, searchText UTF-8 count, title UTF-8
  count, updatedAt only. Keywords, caption, OCR text, searchLocalizations, filters are absent; validate (LexicalIndex
  .swift:204-206) compares only that. Default indexStorage is `.files` in Caches (SearchContext.swift:23-28), so
  every `.automatic` memory context over 500 items (or `.indexed`) takes this path by default.
- Repro (mode `stale`, S/out-quick.txt): launch 1 with 600 tools (keyword "alpha", platform ios), persist; launch 2
  with t0 moved to mac + keyword "omega", t1 text "generic"->"special" (same length): platform=mac -> [] (expected
  [t0]); "tool 0" + platform=ios -> ["t0","t1","t10"] (t0 no longer qualifies: hard-constraint violation, spec 15.3
  "Precision 1.0"); "omega" -> []; "special" -> []; after refresh(): mac -> ["t0"], "omega" -> ["t0"].
- Docs: only the internal fingerprint comment mentions refresh(); public `init(context:)` says "Memory sources are
  projected and tokenized before the initializer returns" (false on reuse), `.files` and `refresh()` ("Re-reads every
  source on demand") say nothing about it; README silent.
- Correction: embeddings are not part of the fingerprint but are re-read from the items on reuse (:134-139), so they
  do not go stale; everything else in the description holds.

## C2-m01-text-index-05 — SearchLimits clamps bypassed through public properties; 0 / negative values crash
Verdict: CONFIRMED (scope slightly wider). Severity: medium.
- Code: SearchLimits fields are `public var` (SearchEngineConfiguration.swift:26-40); only init clamps (:50-55);
  nothing re-clamps between configuration and use (QueryPlanner.swift:142 passes limits.prefixExpansions,
  IndexSearcher.swift:673 reads lexicalCandidates). TopSelector.accepts (QueryPlanner.swift:198-200) reads
  elements[count-1] when limit <= 0 and empty.
- Repro (S/out-quick.txt, release): `limits.prefixExpansions = 0`, indexed: "cherry" ok, "ap" -> signal 5, frames
  TopSelector.accepts <- IndexTermSource.prefixExpansions <- QueryPlanner.plan; scan: no crash ("ap" -> []).
  `lexicalCandidates = 0` or `-5`, indexed: first query -> signal 5 in IndexSearcher.admitCandidates (Array subscript
  modify); scan: no crash. Extra: `prefixExpansions = -1` crashes the scan strategy too (Collection.prefix with a
  negative length in ScanEngine.Source.prefixExpansions), so "scan does not crash" holds only for 0.
- Spec 10 states the bounds as fixed numbers; configurability is the package's extension, and its property
  setters accept values the init rejects. Medium: deterministic crash on the indexed strategy only, so a host that
  develops on small (scan) contexts and ships a large (indexed) one meets it in production.

## C2-m01-text-index-06 — SearchableID equality is canonical equivalence, the index keys by UTF-8 bytes
Verdict: PARTLY (real as described; severity lower). Severity: low (auditor: medium).
- Code: SearchableID synthesizes ==/hash on String (canonical equivalence) and defines `<` on UTF-8 bytes
  (Searchable.swift:9-38); LexicalIndex dedup uses [SearchableID: Int] (LexicalIndex.swift:378-392); segment
  lookups hash and memcmp raw bytes (IndexSegment.swift:428-445, fnv1a ByteCoding.swift:175-187). Projection passes
  searchID through unchanged (SearchProjector.swift:147).
- Repro (mode nfc-nfd): "nfc == nfd: true; nfc < nfd: false; nfd < nfc: true; equal hashValue: true; Set count: 1";
  index holding NFD: contains(NFD) true, contains(NFC) false, document(for: NFC) nil; remove([NFC]) leaves count 1;
  NFC upserted in a second batch: count 2, search "espresso" returns 2 hits whose ids compare ==; same two in one
  batch: count 1; ScanIndex over both: count 1, 1 hit. All exactly as the auditor reported.
- Severity: needs non-ASCII ids arriving in two normalization forms (ids are normally ASCII keys; spec 9.2's database
  ids are "<table>#<id>"); when it happens the effects are as described, but it is an edge case -> low.

## C2-m01-text-index-07 — paging arithmetic overflows with limit = Int.max
Verdict: CONFIRMED. Severity: low.
- Code: ScanIndex.swift:76-77 and SearchService.swift:465-466 compute `start + max(0, limit)` with trapping
  arithmetic; SearchService.swift:837 `limit * 4`, :858-859 `limit + 1`. SearchQuery.limit is an unclamped public
  Int (SearchQuery.swift:34); SearchCursor(offset:) is public; results(for:) honours query.cursor (SearchService.swift:379).
- Repro: ScanIndex: limit 2 -> nextCursor(offset 2); same query with limit .max and that cursor -> signal 5
  "arithmetic overflow" in ScanIndex.snapshot(for:generation:contextID:). Indexed service: limit .max then
  page(after: SearchCursor(offset: 1)) -> lldb: "arithmetic overflow" at SearchService.swift:466:52.
  suggestions(for: "app", limit: .max) -> lldb: "arithmetic overflow" at SearchService.swift:837:52 (no cursor needed).
  The natural host sequence (page 1, then "the rest" with cursor = nextCursor and limit = .max) reaches it.

## C2-m01-text-index-08 — filter-only queries keep the first 2,000 live documents in segment order
Verdict: CONFIRMED (now executed). Severity: low.
- Repro (mode matchall): 100 ios docs a000-a099 then 2,000 ios docs m0000-m1999 (two segments): filter-only page 1 =
  a000..a004. Add 3 batches of 100 *mac* docs (no change to the matching set) and settle: segments become
  [2000, 400] and page 1 = m0000..m0004; same after compact() and after save + load. ScanIndex over the same 2,100
  matching items: a000..a004. So the first page depends on merge history and differs from the scan strategy.
- Low: only filter-only queries with more than 2,000 matches, where every hit scores the same.

## C2-m01-text-index-09 — plans over 64 clauses drop documents that match only later clauses
Verdict: CONFIRMED (now executed through public API). Severity: low.
- Code: parser caps parsed clauses at 64 (QueryParser.swift:37, :63) but the planner adds one plan clause per matched
  fallback bigram (QueryPlanner.swift:150-157); clause index >= 64 gets bit 0 (IndexSearcher.swift:899,
  ScanEngine.swift:189) and `matched != 0` is required (IndexSearcher.swift:928-929).
- Repro (mode clauses-public, added here; ScanIndex and SearchService(context:) only): query = 86 distinct katakana
  (NLTokenizer: 4 words [25,25,25,11], fallbacks [24,24,24,10]); doc "head" holds bigrams 0..<70 as words, doc "tail"
  holds the query's last 2 bigrams. Scan and indexed, head+tail: ["head"] (tail lost); tail alone: ["tail"];
  control with head holding only 40 bigrams: ["head","tail"]. Both strategies agree (no parity break).
- Low: needs a long unspaced-script query with more than 64 matched bigrams; the lost document matches little of it.

## C2-m01-text-index-10 — normalization adds ı -> i beyond the spec recipe
Verdict: CONFIRMED. Severity: low.
- Spec 5 rule 4 (page 9): "NFKC, then folding(options: [.caseInsensitive, .diacriticInsensitive,
  .widthInsensitive], locale:)". Sections 16 ("Unicode and diacritic normalization, including NFKC folding and width
  folding") and 17 add nothing that allows an extra step.
- Code: SearchNormalizer.swift:21-35 maps U+0131 to "i" after folding; the type's doc comment (:8-13) says so on purpose.
- Repro (mode fold): recipe ı -> U+0131 under nil/en/tr; engine ı -> U+0069 under all three; recipe "kır" -> "kır",
  engine -> "kir" (merges kır/kir in every locale). The same output shows the quirk the step fixes: under the bare
  recipe "IŞIK" -> "isik" but "ışık" -> "ısık" (en), and "İstanbul" -> "ıstanbul" (tr). A real but deliberate,
  documented and arguably beneficial deviation; low.

## C2-m01-text-index-11 — weak or nondeterministic tests
Verdict: PARTLY. Severity: low.
- Locale-change test (InternationalizationTests.swift:233-283): confirmed. The probe item ("Zyxquartz beacon") reads the
  same in every locale, so the 20 queries cannot tell old index from new; nothing records that any of them overlapped
  the rebuild, and none is timed: they would pass if every one waited for the rebuild (relevant to -01).
- Corrupt-file test (StrategyParityTests.swift:187-199): confirmed. The file is bytes i*31 mod 256, first byte 0x00 vs
  magic "ZTSI" (IndexSegment.swift:41), so only the magic check runs; no other test (grep for load(from:),
  IndexSegment(data:), byte patching in Tests/) feeds a corrupted valid segment.
- Trigram property test (TextPipelineTests.swift:160-183): SystemRandomNumberGenerator with no seed, true — but the
  assertion message prints the failing pair ("\(query) vs \(other): \(shared) shared, threshold ..."), and the
  property is a pure function of that pair, so a failure can be replayed from the log. "Cannot be reproduced" is
  overstated; only the sample is not reproducible.

## C2-m01-text-index-12 — "heaviest field first" comment vs fixed ordinal order
Verdict: CONFIRMED (now executed). Severity: low.
- Code: IndexSearcher.swift:694-695 comment; :773 `for field in 0..<SearchField.count` (title, keywords, caption,
  text, localizedAlt, ocrText = SearchDocument.swift:4-10). Default weights 8/4/2.5/1/0.5/0.5 (RankingProfile.swift
  :145-152, spec 7.1 table) follow that order, so the comment holds only for default weights; fieldWeights is a
  public var and spec 7.1 calls the weights "defaults".
- Repro (mode fieldorder, added here; LexicalIndex.upsert + SearchService(index:profile:)): 2,500 docs with "zeta" in
  the title + 5 with "zeta" only in ocrText, profile ocrText 50 / title 0.01: indexed service top 5 = t0000..t0004,
  "candidates scored 2000", the five OCR docs absent; ScanEngine over the same documents: o0..o4. Control with 1,500
  title docs (no admission bound hit): both give o0..o4.

---------------------------------------------------------------------------------------------------
## Summary
| id | verdict | severity |
|----|---------|----------|
| 01 | partly (mechanism and both masked asserts real; harm latent today, query-gate masking intermittent) | medium |
| 02 | partly (rebuild 2.0-2.5x and upsert 3-4x over the scaled allowance; scan creation within in my runs) | medium |
| 03 | confirmed (crash at init and at first query, hang on id lookup, lost document) | medium |
| 04 | confirmed (stale filters/keywords/same-length edits reused; embeddings are re-read, not stale) | medium |
| 05 | confirmed (also: prefixExpansions < 0 crashes the scan strategy) | medium |
| 06 | partly (real as described; edge case) | low |
| 07 | confirmed (scan, service paging and suggestions all trap) | low |
| 08 | confirmed (executed: first page changes after a merge; differs from scan) | low |
| 09 | confirmed (executed through public API, both strategies) | low |
| 10 | confirmed (deliberate, documented deviation) | low |
| 11 | partly (two of three confirmed; trigram failures are replayable from the message) | low |
| 12 | confirmed (executed: OCR-weighted matches never admitted past 2,000 title matches) | low |

Outputs: S/out01-xctexpect.txt, S/out01-probe.txt, S/out02-perf.txt, S/out03-load.txt, S/out03-launch.txt,
S/out-09-03c.txt, S/out-quick.txt (04, 05, 06, 07, 10), S/out-0809.txt, S/out-12.txt; crash frames from
~/Library/Logs/DiagnosticReports/Harness-2026-11-18-*.ips and lldb (07).

STATUS: complete
