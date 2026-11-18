# Cycle 2 — m01 text pipeline / lexical index / scan strategy — findings

Auditor scope: Sources/ZTronSearchEngine/{Text,Index,Scan,Support}; tests TextPipelineTests,
InternationalizationTests, IndexMaintenanceTests, CoreCorrectnessTests, FuzzyChannelTests,
StrategyParityTests, HighlighterTests, PerformanceTests (15.2/15.8 parts); spec sections 5, 7.1, 7.2,
9.1, 10, 15.2, 15.8. Commit cee4620. Paths below are relative to /Users/admin/Documents/ZTronSearchEngine.

Scratch harness (allowed by the task): a copy of Sources/ZTronSearchEngine plus a main.swift, compiled
with `swiftc -O -swift-version 6 -module-name ZTronSearchEngine` in
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m01-text-index/harness/
(main.swift there). Crash frames were read from ~/Library/Logs/DiagnosticReports/harness-*.ips.
Nothing was written in the repository except this file; no .build was created.

---------------------------------------------------------------------------------------------------
## C2-m01-text-index-01 — Non-scoped XCTExpectFailure in PerformanceTests.check() silently excuses every later assertion of the test
- severity: high; category: test-integrity; spec: 15.8 (scan query budget), 5 rule 7 / 11 (queries never wait for a rebuild), 15.2
- locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87 (XCTExpectFailure(knownGap) at :80),
  :527-537 (testSmallContextsOfCatalogSizedDocuments, query check :535 has no knownGap, memory only printed :536),
  :301-328 (testFullLexicalRebuildOnLocaleChange, liveness assert :327 after knownGap check :323-326), :58-62 (class skipped in DEBUG)
- description: check() calls the closure-less XCTExpectFailure(knownGap) when a known-gap budget is over.
  That form marks every failure for the rest of the test method as expected, not just the next assertion.
  So in testSmallContextsOfCatalogSizedDocuments, once creation is over budget (it is in both release runs),
  the 15.8 "scan query, 500 documents, 3 ms" gate at :535 — which has no known gap — can no longer fail.
  In testFullLexicalRebuildOnLocaleChange the rebuild is always over budget on this machine, so
  `XCTAssertLessThan(worstQuery, 0.25, "a query never waits for the rebuild")` (:327) is never able to fail.
  Also: the 15.8 memory budget for the catalog-sized case is printed, not asserted; the whole class is
  skipped in debug builds, so the TSan and debug CI runs check no budget.
- evidence: Verification/_runs/c2-release-performance.log:142: "XCTExpectFailure: matcher accepted Assertion
  Failure at PerformanceTests.swift:535 ... scan query, 500 catalog-sized documents (p95): 0.898 ms, budget
  3.000 ms on the reference device (0.500 ms on this machine)" and :144 the test "passed". The rerun log
  (c2-release-performance-rerun.log:69-71) shows the creation gap firing again (9.543 ms vs 8.333 ms).
- failure scenario: a regression that makes catalog-sized scan queries 2x slower, or makes queries block
  for seconds behind a locale rebuild, ships with a green PerformanceTests run.

## C2-m01-text-index-02 — Locale-rebuild, incremental-upsert and catalog-sized scan-creation budgets are not met by the project's own scaled estimate; the suite records them as expected failures
- severity: high; category: performance; spec: 5 rule 7 ("Budget: 2 s for 100k items"), 15.8 (500 documents: creation 50 ms), 15.x upsert budget (0.1 ms per document, PerformanceBudget.upsertPerDocument)
- locations: Tests/ZTronSearchEngineTests/PerformanceTests.swift:323-326, :396-397, :534; Sources/ZTronSearchFixtures/ReferenceDevice.swift:17-25 (slowdown 6 on macOS), :72, :74; code paths LexicalIndex rebuild/upsert, DocumentTokenizer, SearchTokenizer (NLTokenizer)
- description: with the package's own reference-device factor (6 on Apple-silicon Macs), the measured times
  exceed the allowed times: locale rebuild of 100k items 1134.2 ms (rerun) and 2567.5 ms (first run) vs
  333.3 ms allowed (about 3.4x to 7.7x over the 2 s spec budget); upsert 0.053/0.083 ms per document (rerun)
  and 0.066/0.146 ms (first run) vs 0.017 ms allowed; 500 catalog-sized scan contexts 9.543 ms (rerun) and
  46.582 ms (first run) vs 8.333 ms allowed. Each is a knownGap, so every test passes.
- evidence: c2-release-performance-rerun.log:91, :96, :97, :69/:114; c2-release-performance.log:112-113, :119-122, :140-141.
  (The first run may have overlapped other jobs, judging by log timestamps; the rerun numbers are the
  conservative ones and are still over. The first run also failed testSmallContexts outright — 40-document
  creation 1.762 ms vs 0.833 ms, c2-release-performance.log:137-138 — while the rerun passed with 0.488 ms.)
- failure scenario: on the reference device (iPhone 6s class) a locale change on a 100k catalog takes
  roughly 7 s instead of 2 s; a 100-item sync batch costs about 3-5x the budget.

## C2-m01-text-index-03 — A segment is "validated when opened" only at the outer layer; corrupt files that pass crash, hang or return wrong results at every launch, and the header check itself can trap
- severity: medium; category: bug; spec: 6 (persisted files are versioned and discarded on mismatch), 9.1 rule 6, 10 (mapped files)
- locations: Sources/ZTronSearchEngine/Index/IndexSegment.swift:107-196 (init), :137-139 (`Int(try reader.fixed(UInt64.self))`
  and `offset + length` unchecked), :299-302 termBuffer, :393-396 idBuffer, :402-404 kindOrdinal, :410-412 filterOrdinal,
  :419-422 storeBuffer, :428-445 ordinal(ofID:) `while true`; Index/ByteCoding.swift:113-114 (`Int(try varint())`), :124
  (comment "The segment was validated when it was opened." is false); Index/IndexSearcher.swift:966 (`kinds[view.kindOrdinal(ordinal)]`),
  :1000, :1006; Index/LexicalIndex.swift:151-167 (load removes the file only when init/validate throw);
  Service/SearchService+Context.swift:129-132 (`try? IndexSegment(data:)` on the cached file)
- description: init checks magic, version, section bounds, fixed section sizes, a power-of-two id table and
  the kind/filter/metadata tables. It never checks term/id/store/filter/forward offsets, posting payloads,
  kind or filter ordinals or id-hash entries, all of which the readers use unchecked (raw pointers, `&*`,
  array subscripts). Header fields at or above 2^63, or an offset+length sum that overflows, trap inside
  init itself, before load()'s catch can delete the file. There is no checksum.
- evidence (harness, -O build, corrupting the output of LexicalIndex.serialized() and calling load(from:)):
  - documentKinds[0] = 0xFFFF: load accepted the file ("file still exists: true"); search "apple" -> SIGTRAP in
    IndexSearcher.search (rankedList, kinds[...] out of range).
  - every idHash slot = 1: load accepted; search still worked; `contains("zzz")` never returned (killed by
    a 10 s alarm, SIGALRM) — ordinal(ofID:) loops forever, which would wedge the LexicalIndex actor.
  - termOffsets[0] = 5, termOffsets[1] = 0: load accepted; search "apple" returned lexical=["b"] (the apricot
    document) instead of ["a"] — silently wrong.
  - storeOffsets[0] = 0x7FFFFFF0: document(for: "a") returned nil (document silently lost).
  - section 0 offset = UInt64.max, or offset = length = 2^62: SIGTRAP in "closure #1 in IndexSegment.init(data:)"
    under LexicalIndex.load(from:expecting:); the file was still on disk afterwards.
- failure scenario: a cached `<context>.vN.ztsi` in Caches is damaged (flash error, restored/tampered
  container, a future writer bug that keeps format 2). SearchService.init maps and adopts it, and the app
  crashes or hangs on the first query or id lookup at every launch until the cache is purged.

## C2-m01-text-index-04 — Persisted-index reuse ignores most of the content: changed filters, keywords, captions, OCR text or localizations keep a stale index (outside module files)
- severity: medium; category: bug; spec: 9.1 rule 6, 6 (persisted files), 9.1 rule 5 (filters are hard constraints)
- locations: Sources/ZTronSearchEngine/Service/SearchService+Context.swift:123-140 (reuse branch), :176-199 (fingerprint and its doc comment),
  :673-703 (adoptPersistedIndex uses fingerprint ""); Index/LexicalIndex.swift:187-207 (validate skips the content
  check when the expected fingerprint is empty); Contracts/SearchContext.swift:13-16 (public doc: "keyed by its id and projectionVersion")
- description: fingerprint(of:) mixes only id, kind, the UTF-8 length of text and title, and updatedAt.
  Keywords, caption, OCR text, localized strings, filters and embeddings are not part of it, nor are text
  edits that keep the byte length. A file whose fingerprint matches is memory-mapped and projection is
  skipped. The limitation is stated only on the internal function ("Edits that keep all of them need an
  explicit refresh()"); the public `.files` documentation does not mention it.
- evidence: code reading; the persisted-file test in SearchContextTests changes content only by appending an item.
- failure scenario: an app update re-categorizes catalog items (filter change) or adds keywords/translations
  without touching text length, title length or dates. On the next launch the old index is reused: a
  filter chip returns items that no longer carry the filter and misses the ones that now do; new keywords
  and translations are unsearchable until the host happens to call refresh().

## C2-m01-text-index-05 — SearchLimits clamps are bypassed by its public properties; prefixExpansions = 0 or lexicalCandidates <= 0 crash the indexed strategy (scan does not crash)
- severity: medium; category: bug; spec: 10 (bounded work), 9.1 rule 3 (strategies behave identically)
- locations: Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:26-56 (public vars; init clamps with max(1, ...));
  Query/QueryPlanner.swift:198-200 (TopSelector.accepts reads elements[elements.count - 1] when limit <= 0);
  Index/IndexSearcher.swift:127, :154 (selector.accepts before insert); :737-739 (prepareScratch grows slots only up to limit),
  :697-698 (admitCandidates runs whenever candidateUpperBound > limit), :796-799 (writes slots[slotCount] before checking the limit)
- description: `var c = SearchEngineConfiguration(); c.limits.prefixExpansions = 0` (a natural way to switch
  prefix matching off) makes TopSelector.accepts index elements[-1]. `c.limits.lexicalCandidates = 0` (or
  negative) leaves the slot array empty and admitCandidates writes slots[0].
- evidence (harness, -O): "prefix0-index": "Fatal error: Index out of range", frames TopSelector.accepts <-
  IndexTermSource.prefixExpansions <- QueryPlanner.plan <- IndexSearcher.search. "prefix0-scan": no crash,
  lexical=[] fuzzy=[]. "cand0-index": SIGTRAP in IndexSearcher.search on the first query ("apple");
  "cand0-scan": no crash, lexical=["a"].
- failure scenario: a host disables prefix expansion through the property; every indexed query whose last
  word has a completion in the vocabulary crashes the app, while the same configuration works on scan contexts.

## C2-m01-text-index-06 — SearchableID equality is canonical (Unicode) equivalence but the index identifies documents by UTF-8 bytes: remove/contains miss, duplicates appear, strategies diverge
- severity: medium; category: bug; spec: 4 / 9.1 rule 1 (ids unique inside a context), 9.1 rule 3 (identical ranking across strategies)
- locations: Sources/ZTronSearchEngine/Contracts/Searchable.swift:9-38 (synthesized ==/hash on String; `<` compares UTF-8 bytes);
  Index/LexicalIndex.swift:373-400 (dedup by SearchableID ==), :449-458 / :571-578 (locate by bytes via ordinal(ofID:));
  Index/IndexSegment.swift:428-445; Scan/ScanEngine.swift:32-45 (dedup by [SearchableID: Int]); Query/Fusion.swift (FNV over bytes plus ==)
- description: "café" in NFC and NFD are == (and hash equal) as Swift Strings, so batch dedup and the scan
  engine treat them as one id, while the index hashes and compares raw bytes. Also `<` disagrees with ==
  (nfd < nfc is true while nfc == nfd), so the tie-break order is not a valid Comparable order.
- evidence (harness "nfc-nfd", -O): "nfc == nfd: true; nfc < nfd: false; nfd < nfc: true; equal hashes: true";
  index holding the NFD id: "contains(NFD) = true, contains(NFC) = false, document(for: NFC) = nil";
  "after remove([NFC]): count = 1"; after upserting the NFC document in a second batch "count = 2" and
  search "espresso" returns both ids; the same two documents in one batch: "count = 1"; scan engine over both:
  "count = 1", one hit.
- failure scenario: ids built from names arrive in NFD from one source (file names, a server) and NFC from
  another. Removing an item by the other form leaves it searchable; the indexed strategy shows two hits
  whose ids compare equal (SwiftUI ForEach duplicate ids) while the scan strategy shows one.

## C2-m01-text-index-07 — Paging arithmetic overflows: limit = Int.max with a cursor traps
- severity: low; category: bug; spec: 9 / 9.1 (paging, ScanIndex)
- locations: Sources/ZTronSearchEngine/Scan/ScanIndex.swift:76-77; same pattern Service/SearchService.swift:465-466
  (indexed contexts), :837 (`limit * 4`) and :858-859 (`limit + 1`) in suggestions
- description: `start + max(0, query.limit)` is computed with trapping arithmetic. SearchQuery.limit is an
  unclamped public Int, and Int.max is the usual "no limit" value.
- evidence (harness "scan-overflow", -O): limit 20 -> 5 hits; limit .max without cursor -> 5 hits; limit .max
  with SearchCursor(offset: 1) -> SIGTRAP in ScanIndex.snapshot(for:generation:contextID:).
- failure scenario: a host asks for "everything" and pages with the returned cursor; page two crashes.

## C2-m01-text-index-08 — Filter-only queries on the indexed strategy keep the first 2,000 live documents in segment order, so results depend on merge history
- severity: low; category: bug; spec: 10 (2,000 candidates), 9.1 rule 3
- locations: Sources/ZTronSearchEngine/Index/IndexSearcher.swift:680-692 (match-all admission), :916-944 (ties by id);
  Index/LexicalIndex.swift:661-672 (install reorders segments by live count)
- description: all admitted documents score 1, so the list is sorted by id, but only over whichever 2,000
  came first in segment/ordinal order. Segment order changes with upserts and merges.
- evidence: code reading (not executed).
- failure scenario: with more than 2,000 items matching a filter chip and no text, the first page is not the
  lowest ids overall and changes after a merge or a save/compaction, with no content change.

## C2-m01-text-index-09 — Plans with more than 64 clauses lose matches: clause bit 0 makes documents matching only later clauses disappear
- severity: low; category: bug; spec: 7.1
- locations: Sources/ZTronSearchEngine/Query/QueryPlanner.swift:122, :150-157 (each matched bigram adds its own clause);
  Index/IndexSearcher.swift:899 and :929; Scan/ScanEngine.swift:189
- description: the parser caps clauses at 64, but the bigram fallback adds one plan clause per matched
  bigram, so a long CJK/Thai query can exceed 64. Clauses from index 64 contribute score but bit 0, and a
  document whose matched mask is 0 is dropped. Both strategies share it (no parity break).
- evidence: code reading (not executed).
- failure scenario: a pasted Chinese sentence: a document that matches only bigrams of the last words is not returned.

## C2-m01-text-index-10 — Normalization adds a ı -> i step beyond the spec recipe
- severity: low; category: spec-deviation; spec: 5 rule 4 (NFKC, then folding(caseInsensitive, diacriticInsensitive, widthInsensitive, locale))
- locations: Sources/ZTronSearchEngine/Text/SearchNormalizer.swift (normalize, the documented ı -> i step after folding)
- description: deliberate and commented, but it merges the distinct Turkish letters ı and i in every locale,
  which the spec recipe does not do (folding leaves ı unchanged; harness check in nltok/ confirmed ø, ł, đ, æ, œ, ı unchanged by folding).
- failure scenario: Turkish words that differ only in ı/i match each other; harmless for most users, but it is a spec deviation.

## C2-m01-text-index-11 — Weak or nondeterministic tests in the module
- severity: low; category: test-integrity; spec: 7.2, 5 rule 7
- locations: Tests/ZTronSearchEngineTests/TextPipelineTests.swift:160-163 (SystemRandomNumberGenerator, no seed printed);
  InternationalizationTests.swift:233-283 (testLocaleChangeRebuildsUnderANewGenerationWhileQueriesKeepWorking);
  StrategyParityTests (testCorruptFileIsRejected only uses bytes that fail the magic check)
- description: the trigram-losslessness property test draws a fresh random sample each run and cannot be
  replayed; the locale-change test's probe item reads the same in every locale and nothing records that any
  of the 20 queries actually overlapped the rebuild; the corrupt-file test never exercises a file that
  passes the outer checks (see -03).
- failure scenario: a rare trigram-filter miss fails once and cannot be reproduced; a rebuild that blocks
  queries could still pass the i18n test if the queries happen to run before or after it.

## C2-m01-text-index-12 — admitCandidates comment says "heaviest field first", but fields are visited in fixed ordinal order
- severity: low; category: false-claim; spec: 7.1
- locations: Sources/ZTronSearchEngine/Index/IndexSearcher.swift:694-695 (comment), :773 (`for field in 0..<SearchField.count`)
- description: the fixed order (title, keywords, caption, text, localizedAlt, ocrText) matches the default
  weights only; with a custom RankingProfile.fieldWeights the admission order ignores the weights.
- failure scenario: a profile weighting ocrText highest, on a query with more than 2,000 candidates, admits
  title/keyword matches first and can leave the best-scoring OCR matches unscored.

---------------------------------------------------------------------------------------------------
## Checked and found correct (no finding)
Header layout writer/reader agreement; merger rebasing and DF recount; trigram generator losslessness
including transposition branches; bit-vector OSA vs table; BM25F field-order summation shared by both
strategies; prefix (DF, then bytes) and fuzzy (edits, DF, term) tie-breaks shared; highlighter ASCII
fast path; AsyncLock FIFO handoff; spec 7.1/7.2/10 constants (k1 1.2, prefix cap 32, prefix weight 0.7,
exact-only identifiers, edits by length 0/1/2, 8 fuzzy candidates, weight 1/(1+edits), 2,000/8/200 limits);
TSan run: all module suites passed (c2-tsan-swift-test.log).

## Files read
Text: EditDistance, LanguageTag, SearchNormalizer, SearchTokenizer. Index: ByteCoding, DocumentAnalysis,
IndexSearcher, IndexSegment, LexicalIndex, SegmentMerger, SegmentWriter. Scan: ScanEngine, ScanIndex.
Support: Diagnostics, FileIO. Query: BM25F, QueryPlanner, QueryParser, Fusion, Highlighter. Service:
SearchPipeline, SearchService+Context (most), SearchService (paging, suggestions). Contracts: SearchDocument,
SearchQuery, Searchable, SearchSchema, SearchContext (part), SearchEngineConfiguration (part), RankingProfile (part).
Projection/SearchProjector. Fixtures: ReferenceDevice. Package.swift. Tests: StrategyParityTests, RandomCorpus,
PerformanceTests (budget parts), TextPipelineTests, FuzzyChannelTests, InternationalizationTests,
HighlighterTests (part), SearchContextTests (part), IndexMaintenanceTests (names, parts), CoreCorrectnessTests (names).
Run logs: c2-tsan-swift-test.log, c2-release-performance.log, c2-release-performance-rerun.log (grep).
Spec: sections 5, 6, 7.1, 7.2, 9.1, 9.2 rules 5-6, 10, 15.8, 15.2 header.

## Not checked
Device-only budgets (no device); the remainder of Service, Database, Chat and Semantic code; most of
CoreCorrectnessTests and IndexMaintenanceTests bodies; HighlighterTests beyond the fast path; findings -08
and -09 were not executed; DocumentCodec language-count mismatch on hand-made JSON and TokenSpan.piece
UInt16 wrap were noted but judged unreachable in practice and not reported.

STATUS: complete
