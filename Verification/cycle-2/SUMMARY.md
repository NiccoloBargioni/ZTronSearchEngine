# Cycle 2 summary — code-centric

Six auditors read one module each line by line and held it against the specification; one skeptic per module then traced each finding concretely and tried standalone repros. Runs `wf_246c0e17-55f` (auditors and the m04 skeptic; the weekly usage limit cut off the other five skeptics) and the resume `cycle-2/workflow-resume.js`. Full notes: `find-<module>.md` and `verify-<module>.md`. Machine-readable: `result.json`.

| Module | Files read | Lines read | Findings | Skeptic ran |
|---|---:|---:|---:|---|
| m01-text-index | 44 | 12000 | 12 | yes |
| m02-query-service | 48 | 12300 | 19 | yes |
| m03-semantic | 61 | 14300 | 14 | yes |
| m04-ui | 57 | 10500 | 14 | yes |
| m05-adapters | 85 | 14200 | 17 | yes |
| m06-tests-gates | 48 | 12000 | 14 | yes |

## Findings: 90 reported, 50 confirmed, 39 partly confirmed, 0 refuted, 1 uncertain, 0 unverified

Surviving findings by verified severity: 0 critical, 6 high, 23 medium, 59 low.


## High

### C2-m02-query-service-01 — Database-backed contexts adopt a persisted index without reading their rows, so writes made while no context is subscribed are never indexed

- Verdict: **partly**; severity critical → high; category bug; spec 9.2 rules 4-6 (one document set from the sources; change stream; refresh; index persistence), 9.1 rule 6, section 6 persisted-index rule, 16 Index-in-database persistence
- Where: `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:156-166`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:351-353`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:671-703`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:123-125`
- What: As described (offline inserts, updates and deletes invisible; mixed-context memory items replaced by the persisted ones; .database + .default never re-persisted after incremental changes). Also SearchService.deinit cancels the 1 s persist, so releasing a context within 1 s of a live change drops that change from the file. Severity high rather than critical: the index heals on refresh(), a locale change, or the first change to the table while a context is alive.
- Skeptic: Every mechanic reproduces. adoptPersistedIndex builds its expectation with fingerprint "", so only versions, languages and the model are checked. When the adopted count exceeds the scan threshold, rebuildLocked returns before reading any table. A deliberate design (doc at :671-672; DatabaseSourceTests asserts 'rows not re-read') that contradicts the public docs at :6-11 and :47. The spec (section …
- Repro: S/f01, S/f01b (S = /private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m02-query-service-skeptic). .files, id tools-screen, 900 row…

### C2-m02-query-service-02 — Memory-context index files are reused after content edits: the fingerprint ignores keywords, filters, captions, OCR text, localizations and any edit that keeps text and title lengths

- Verdict: **confirmed**; severity high; category bug; spec 9.1 rule 6 (an indexed context persists under its own file), section 6 persisted-index rule, section 5 localizations
- Where: `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:176-199`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:123-141`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:204-206`, `Tests/ZTronSearchEngineTests/SearchContextTests.swift:311-340`
- What: This affects an indexed memory context (more than 500 items, or .indexed) with .files storage (the default) and a non-default id. Such a context persists its index, and at the next init it memory-maps that file when the content fingerprint matches. The fingerprint mixes in only the id, the kind raw value, the UTF-8 lengths of searchText and searchTitle, and updatedAt. The fingerprint does not change for any of these edits: keywords, filters, caption, OCR text, searchLanguage, or searchLocalizations (for example, an app update that ships translations). The same holds for text or title edits tha…
- Skeptic: The fingerprint mixes only id, kind, searchText UTF-8 length, title UTF-8 length and updatedAt. When the file validates, prepare memory-maps it, skips projection and starts no background work. Only an internal doc comment mentions refresh(); the public SearchIndexStorage and SearchContext docs and the README say nothing, and init(id:items:) defaults to .files in Caches. Section 6 and 9.1 rule 6 ke…
- Repro: S/f02: fingerprints equal and the adopted index misses the edit for: keywords alpha->omega ('omega' -> [], fresh -> special); same-length text edit anchor->zebras; same-length title edit; an added 'it…

### C2-m04-ui-01 — The 15.7 parity gate is not met. iOS 15/16, the package floor, were never sampled or run, so the field ships iOS 17 metrics and behavior there without verification

- Verdict: **confirmed**; severity high; category spec-missing; spec 12.4, 12.5 matrix (15.5, 16.4, 17.5, 18.x, beta), 15.7 (every cell), 12.2 rule 12
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics+Sampled.swift:8`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics.swift:223-240`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics.swift:272`, `ParityHost/Results/summary.md`
- What: sampledVersions is [17, 18], and nearestSampledVersion maps iOS 15 and 16 to 17 and iOS 26/27 to 18. On those versions the field uses another version's field height, insets, glyph and token frames, durations and behavior flags (clearRemovesTokens, clearBeginsEditing, submitKeepsEditing, typingReplacesSelectedTokens, conversionSelectsToken), and none of it was ever compared with the UIKit field of that version. The matrix is mostly unattempted or failing. The README discloses that the gate is not met, but it is still a 15.7 release gate.
- Skeptic: sampledVersions is [17, 18], and both the metrics and ZTronSearchFieldBehavior are looked up through nearestSampledVersion. So iOS 15 and 16 get the iOS 17 sample, and iOS 26 and 27 get the iOS 18 sample. The package floor is .iOS(.v15). I tallied summary.csv myself: 7440 rows, of which 6659 are not runnable, 602 fail and 179 pass. 15.5 and 16.4 have 3200 not-runnable cells each and 0 ran. On 27.0…
- Repro: nearest.swift printed: iOS 15 -> sampled 17, iOS 16 -> sampled 17, iOS 26 -> sampled 18, iOS 27 -> sampled 18. The CSV tally is as given above.

### C2-m05-adapters-02 — A retry in the same process restarts the 968 MB weights file from byte 0 (resume works only per file)

- Verdict: **confirmed**; severity high; category spec-deviation; spec 14.4 'a retry re-verifies and resumes instead of starting over'; 15.6 'Download 968 MB, resumable'; 17 open question (the bridge may own resume)
- Where: `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchOperation.swift:260-264`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchOperation.swift:279-284`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchCoordinator.swift:78-84`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/AssetKitModelAssetProvider.swift:183-186`
- What: On any failure the bridge fails the fetch and withdraws every ZTronAssetKit request through group.cancelAll(). Failures include .offline, .policy when the device leaves Wi-Fi under .wifiOnly, and any resolve error. A cancelled reader has the same effect. With no interest left, ZTronAssetKit retires the job: it cancels the transfer ('Stop, discarding the partial') and removeJob drops the job's state. A new job in the same process adopts a resume point only from launchResumes, so earlier partials are found only at launch. Stored files are kept, so resume works per file only. For the reference mo…
- Skeptic: Bridge: FetchOperation.download breaks its loop on a refused lane (:260-264), on the first resolve failure (:279-281) or on a contradicted blob, then group.cancelAll() (:284) cancels every resolve. The resolve's onCancel withdraws its waiter (ZTronAssetKit EngineCommands.swift:91-132). FetchCoordinator.detach cancels the session when the last reader leaves (:78-84). In ZTronAssetKit (read only), a…
- Repro: Not run: it needs ZTronAssetKit's engine and a scripted origin. Confirmed by tracing the code and by the author's own doc comment and README. RealClientTests.swift:80-110 asserts only per-file resume …

### C2-m06-tests-gates-01 — The non-scoped XCTExpectFailure in PerformanceTests.check(knownGap:) turns every later failure in the same test into an expected failure

- Verdict: **confirmed**; severity high; category test-integrity; spec 15.1, 15.4 (locale rebuild 'never blocking a query'), 15.8, 16, 17 milestone 1 gate
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:80`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:323-327`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:533-535`
- What: As described. One nuance: the PERF print does show 'within' when a gap closes, but no test outcome changes. In the resumed run, catalog-sized scan creation came in at 8.202 ms against 8.333 ms, so the masking of :535 depends on load.
- Skeptic: check() calls XCTExpectFailure(knownGap) with no closure, and only when measured > allowed. Every later failure in the same test becomes an expected failure: :535 after :534, and :327 after :323-326. Earlier assertions are unaffected. The strict option can never fire, because XCTExpectFailure is not called once a gap is within budget. Only the PERF line's '(within)' shows that the gap closed.
- Repro: A scratch XCTest package (xfail/) with check() copied verbatim. An over-budget check with no known gap, placed after an over-budget known-gap check, was reported as 'matcher accepted ... Expected fail…

### C2-m06-tests-gates-02 — The 2 s locale-rebuild and 0.1 ms-per-document upsert targets are missed by the package's own measure and pass as expected failures; README and CI do not disclose it

- Verdict: **confirmed**; severity high; category spec-deviation; spec 15.1 (full lexical rebuild on locale change 2 s; incremental upsert 0.1 ms amortized); 17 milestone 1 gate (lexical latency targets); 16
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:301-328`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:395-397`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:527-536`, `README.md:175-177`
- What: Three checks carry a knownGap, and an over-budget measurement becomes an expected failure. Rebuild measured 1134-2568 ms against 333 ms allowed (3.4-7.7x). Upsert of new documents measured 0.053-0.066 ms against 0.017 ms (3.2-4x). Upsert of replaced documents measured 0.083-0.146 ms (5-8.8x). The gap strings themselves say the reference device cannot meet these: "is more work than the reference device does in 2 s by this estimate" and "the word tokenizer alone takes most of the budget". README says "The performance tests hold every measurement against its budget", and the only unmet gate it di…
- Skeptic: Known gaps sit on the rebuild (:323-326), the new and replaced upserts (:396-397) and catalog-sized scan creation (:534), and the gap texts concede the reference device cannot meet them. Spec 15.1 fixes 2 s for the rebuild and 0.1 ms amortized per upsert. Milestone 1's gate includes the lexical latency targets, and nothing in 16 or 17 defers them. README:205 ('hold every measurement against its bu…
- Repro: Unmodified release class at load about 6: rebuild 853.3 ms vs 333.3 ms (2.6x); upsert of new documents 0.050 ms and replaced 0.065 ms vs 0.017 ms (3.0x, 3.9x). All three pass only as expected failures…


## Medium

### C2-m01-text-index-01 — Non-scoped XCTExpectFailure in PerformanceTests.check() silently excuses every later assertion of the test, masking the 15.8 scan-query gate and the 'query never waits for the rebuild' gate

- Verdict: **partly**; severity high → medium; category test-integrity; spec 15.8 (scan query 3 ms / 500 docs, memory 1 MB), 5 rule 7 and 11 (queries keep working during a rebuild), 15.2
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:527-537`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:301-328`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:58-62`
- What: The closure-less XCTExpectFailure in check() masks every later failure in the test method. In testFullLexicalRebuildOnLocaleChange the rebuild gap fires on every run here (674-820 ms vs 333 ms allowed), and by the project's own estimate it would on the reference device too, so the only timed check that queries are not blocked by a locale rebuild (:327) is dead. In testSmallContextsOfCatalogSizedDocuments the 15.8 query gate (:535) is masked only on runs where creation exceeds 8.33 ms, which is borderline and load-dependent. Neither masked assertion would fail today (slowest query during the re…
- Skeptic: Mechanism confirmed. check() calls the closure-less XCTExpectFailure(knownGap) when a budget is over (PerformanceTests.swift:77-81), and that form absorbs every later failure in the method. Both masked assertions are real: :535, the catalog-sized scan-query gate, comes after the :534 creation gap; :327, the rebuild liveness assert, comes after the :323-326 rebuild gap. On this machine the rebuild …
- Repro: XCTest probe (S/xctexpect, mirrors check()): testA (gap fires, then a non-gap check fails) PASSED with 'XCTExpectFailure: matcher accepted Assertion Failure at ExpectTests.swift:18 ... Reason: (creati…

### C2-m01-text-index-02 — Locale-rebuild (2 s/100k), incremental-upsert and catalog-sized scan-creation budgets are not met by the project's own scaled estimate; recorded as expected failures so the suite stays green

- Verdict: **partly**; severity high → medium; category performance; spec 5 rule 7 (Budget: 2 s for 100k items), 15.8 (context creation 50 ms for 500 documents), 15.x upsert budget (0.1 ms per document)
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:323-326`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:396-397`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:534`, `Sources/ZTronSearchFixtures/ReferenceDevice.swift:17-25,72,74`
- What: By the project's own off-device estimate (budget / 6), the locale rebuild (100k items) and incremental upsert miss their spec budgets on every run. Rebuild: 525-820 ms against 333 ms allowed, 2.0-2.5x over; on the device that means roughly 4.5-8 s instead of 2 s. Upsert: 0.050-0.066 ms per document against 0.017 ms, 3-4x over. Both are recorded as knownGap expected failures, so the tests pass. Scan-context creation for 500 catalog-sized documents sits at its limit (7.7-8.1 ms against 8.33 ms) and was within budget in my runs; it is not a consistent miss.
- Skeptic: Spec budgets checked: 15.1 'Full lexical rebuild on locale change 2 s, in the background, never blocking a query' (also 5 rule 7); page 43 'Incremental upsert, per document 0.1 ms amortized'; 15.8 '500 documents 50 ms' context creation. Sections 16 and 17 do not relax them; 17 makes the reference device the gate for milestone 1, which covers the lexical latency targets and the 15.8 timings. With t…
- Repro: Harness on an Apple M3, load average 4.7-7.8. Rebuild setLocale it/de: 589/820, 667/674 and 525/742 ms wall, against 333.333 ms allowed; process CPU 1.7-2.6 s per rebuild. Upsert per document: replace…

### C2-m01-text-index-03 — Segments are validated only at the outer layer; corrupt cached files that pass crash, hang or return wrong results at every launch, and the header check itself can trap before the file is discarded

- Verdict: **confirmed**; severity medium; category bug; spec 6 (persisted index files are versioned; mismatch discards the file), 9.1 rule 6, 10 (memory-mapped index files)
- Where: `Sources/ZTronSearchEngine/Index/IndexSegment.swift:107-196`, `Sources/ZTronSearchEngine/Index/IndexSegment.swift:299-302, :393-396, :402-404, :410-412, :419-422, :428-445`, `Sources/ZTronSearchEngine/Index/ByteCoding.swift:113-114, :124`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:966, :1000, :1006`
- What: IndexSegment.init checks only:
- the magic, format version and section bounds;
- the fixed section sizes and a power-of-two id table;
- the kind, filter and metadata tables.
It never checks the values inside the term, id, store, filter and forward offset tables, the posting payloads, the kind and filter ordinals, or the id-hash entries. The readers then use all of these unchecked, through raw pointers and array subscripts.

The header check can itself trap: Int(UInt64) traps for values of 2^63 or more, and offset+length can overflow. Both happen inside init, before LexicalIndex.load's catch ca…
- Skeptic: IndexSegment.init (IndexSegment.swift:107-196) checks magic, version, section bounds, fixed section sizes, the power-of-two id table and the kind/filter/metadata tables. It never checks term, id, store, filter or forward offsets, posting bytes, kind or filter ordinals, or id-hash entries, and the readers use all of these unchecked. ordinal(ofID:) loops with `while true` (:428-445). Line 137, `Int(…
- Repro: Persisted a 3-document .files context, patched the file, then relaunched. documentKinds[0] = 0xFFFF: init returned; first query 'apple' -> signal 5, 'Index out of range' in IndexSearcher.rankedList <-…

### C2-m01-text-index-04 — Persisted-index reuse fingerprints only id, kind, text/title byte length and updatedAt; changed filters, keywords, captions, OCR text or localizations keep a stale index (Service code, outside module files)

- Verdict: **confirmed**; severity medium; category bug; spec 9.1 rule 6 (indexed context persists under its own file), 6 (persisted files), 9.1 rule 5 / 4.1 (filters are hard constraints)
- Where: `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:123-140`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:176-199`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:673-703`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:187-207`
- What: fingerprint(of:) mixes in only the id, the kind, the UTF-8 length of the text and title, and updatedAt. It leaves out keywords, caption, OCR text, localized strings, filters and embeddings, and it misses text edits that keep the byte length.

When the fingerprint matches, the file is memory-mapped and projection is skipped entirely. The only place this limitation is stated is the doc comment of the internal function ('Edits that keep all of them need an explicit refresh()'). The public .files documentation does not mention it.
- Skeptic: fingerprint(of:) (SearchService+Context.swift:181-199) mixes only id, kind, the UTF-8 byte counts of searchText and title, and updatedAt. validate (LexicalIndex.swift:204-206) compares only that fingerprint. The default indexStorage is .files in Caches (SearchContext.swift:23-28), so every .automatic memory context over 500 items, and every .indexed one, takes the reuse path by default. The public…
- Repro: Mode 'stale'. Launch 1: 600 tools with keyword 'alpha' and platform ios, persisted. Launch 2: t0 moved to mac with keyword 'omega', and t1's text changed 'generic' -> 'special' (same length). Results:…

### C2-m01-text-index-05 — SearchLimits clamps are bypassed by its public properties: prefixExpansions = 0 or lexicalCandidates <= 0 crash the indexed strategy, while the scan strategy keeps working

- Verdict: **confirmed**; severity medium; category bug; spec 10 (bounded work limits), 9.1 rule 3 (both strategies behave identically)
- Where: `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:26-56`, `Sources/ZTronSearchEngine/Query/QueryPlanner.swift:198-200`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:127, :154`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:697-698, :737-739, :796-799`
- What: SearchLimits.init clamps its values with max(1, ...), but the properties are public vars, so assigning to them afterwards skips the clamp.
- With limits.prefixExpansions = 0, which is a natural way to switch prefix matching off, IndexTermSource.prefixExpansions calls selector.accepts on an empty TopSelector, and accepts reads elements[-1].
- With limits.lexicalCandidates = 0 or a negative value, prepareScratch leaves the slot array empty, and admitCandidates writes slots[0] before checking the limit.
- Skeptic: SearchLimits fields are public vars, and only the init clamps them (SearchEngineConfiguration.swift:26-56). Nothing re-clamps on the way to use: QueryPlanner.swift:142 passes limits.prefixExpansions straight through, and IndexSearcher.swift:673 reads lexicalCandidates. TopSelector.accepts (QueryPlanner.swift:198-200) reads elements[count-1] when limit <= 0 and the list is empty, and IndexSearcher.…
- Repro: Release harness. prefixExpansions = 0, indexed: 'cherry' ok; 'ap' -> signal 5, frames TopSelector.accepts <- IndexTermSource.prefixExpansions <- QueryPlanner.plan. Same setting on scan: 'ap' -> [], 'a…

### C2-m02-query-service-03 — The randomized no-stale-snapshots test cannot detect a stale snapshot

- Verdict: **partly**; severity high → medium; category test-integrity; spec 15.4 'Zero stale snapshots published over a randomized sequence of 10,000 query changes'; 11 No stale results; 16 Stale-result suppression with randomized query sequences
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:157-219`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:175-176`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:191`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:223-243`
- What: As described. Impact: the 15.4 and section 11 gate is unverified against regressions. Currently correct code and the UI model's own check prevent stale results today.
- Skeptic: The test ledger only compares a stream's snapshots with that stream's own query and first generation, so it cannot see a late publication. Proven by mutation: removing the publish-time isCurrent guard leaves every assertion of the 10,000-change test green while the library emits 692 stale snapshots. testAnObsoleteProducerNeverYields does not catch this mutant either. Severity is medium, not high: …
- Repro: S/f03, test logic verbatim, seed 2024. Mutant: mismatched 0, published 2228, finals 1184, probes failing 0, last final true; ground truth 692 emits after a newer query. Unmodified: all pass. DYLD_PRIN…

### C2-m02-query-service-04 — A row with a literal and a localized key in the same role loses the literal from its field: it is moved to localizedAlt, even under the base language

- Verdict: **confirmed**; severity medium; category spec-deviation; spec 9.2 rule 3 (literals keep their declared language; only other preferred languages feed localizedAlt), 9.2 rule 4 / 15.9 (row ranks like the same memory item), section 5
- Where: `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:132-147`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:153-156`, `Sources/ZTronSearchEngine/Projection/SearchProjector.swift:109`
- What: For a keyed field, the row projector writes the resolved string for every catalog language, base language included, into searchLocalizations[tag] (for .text, into localizedTexts[tag]). Literal fields of the same role go only to the base surface. So for the active language, the localization holds only the key's string. SearchProjector then treats the base surface (literal plus key string) as shadowed and demotes it to localizedAlt. That field has a BM25F weight of 0.5, against 1.0 for text and 4.0 for keywords. With the base locale and no secondary languages, localizedAlt should be empty.
- Skeptic: A keyed field writes its base-language string into searchLocalizations[base]; SearchProjector then lets that localization win and moves the shadowed base surface (literal plus key string) to localizedAlt. This happens even under the base locale with no secondary languages, which violates 9.2 rule 3 and 15.9's identical score and order for a row and the same item in memory. Only same-role mixes are…
- Repro: S/f04, locale en, no secondary, 30 competing filler docs. Text role: row text='Frozen Harbor', localizedAlt=[literal+key]; 'lanterns' row rank 31 (localizedAlt) vs memory rank 1 (text). Keywords role:…

### C2-m02-query-service-06 — ChatService.load is not reentrancy-safe: unload() or a memory warning during a load is undone, and prepare() during a send-triggered load loads the weights twice

- Verdict: **confirmed**; severity medium; category concurrency; spec 14.3 rule 5, 14.4 (unload on memory warning; LLM unloads before the embedding model; 1.8 GB resident)
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:282-298`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:409-420`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:129-155`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:243-248`
- What: There are two races. (a) unload() during .loading unloads the runtime and sets .onDisk. The suspended load(from:) then resumes and settles .ready with the runtime loaded, so a memory warning that arrives during the load is lost. (b) A send that finds the lifecycle .onDisk loads the weights in ensureLoaded without setting `preparation`. A prepare() that arrives meanwhile sees preparation == nil and starts runPreparation. That overwrites the lifecycle with .onDisk and calls model.load a second time, concurrently.
- Skeptic: (a) unload() during .loading sets .onDisk and unloads, but the suspended load resumes and settles .ready with the runtime loaded. (b) ensureLoaded loads without setting `preparation`, so a concurrent prepare() starts a second load. A memory warning during the roughly 1 GB load is the likeliest moment for one, and losing it breaks 14.4 and 15.7.
- Repro: S/f06, load 300 ms, real memory-warning notification. (a) Just after the warning: onDisk, unloadCalls 1. After the load: ready, isLoaded true. A control warning while ready unloads for good. (b) At +2…

### C2-m02-query-service-07 — Source truncation splits on whitespace only, so unspaced scripts (Japanese, Chinese, Thai) lose the whole caption or text of a source

- Verdict: **confirmed**; severity medium; category bug; spec 14.3 rule 1 ('[kind:id] title, caption from its localized surface, at most 80 tokens per source'); multilingual and CJK requirements (sections 2, 5)
- Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:164-180`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:564-579`
- What: PromptAssembler.truncate keeps the longest prefix of whitespace-separated words that fits the limit. A Japanese caption or text counts as a single word. So a rendered source over 80 tokens is cut to '[kind:id] <title>,' and the caption or text disappears, even though about 60 tokens of budget remain. With a long unspaced title, only the marker remains. ChatTests exercise English only.
- Skeptic: PromptAssembler.truncate keeps the longest prefix of whitespace-separated words, so an unspaced CJK caption or text is dropped whole even though most of the 80-token budget remains. ChatTests cannot see it because the fake counts whitespace words.
- Repro: S/f0708, real truncate, one token per character. ja: 167 tokens -> '[map:harbor] 凍った港,' (17 tokens). zh: 122 -> 17 tokens. Long ja title -> '[map:harbor]' only. en: cut cleanly to 80 tokens.

### C2-m02-query-service-08 — Citations of ids that contain ':' are never recognised and the raw marker leaks into the transcript

- Verdict: **confirmed**; severity medium; category bug; spec 14.3 rule 3 (markers parsed incrementally, emitted as .citation when the id is in the sources; markers never reach the text)
- Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:76-81`
- What: After each ':' inside a pending marker, consume() checks that everything before it is a kind: isKind(String(pending.dropFirst().dropLast())...). For '[map:m:harbor]' the second colon tests 'map:m', which is not a kind, so the bracket is released as ordinary text. marker(in:), which splits on the first colon and would accept the marker, is never reached. Such ids are legal. The engine's own SearchRowIdentity.prefixed produces them (DatabaseSourceTests uses .prefixed("m:")), and the prompt tells the model to cite ids verbatim.
- Skeptic: consume() re-checks the whole prefix as a kind at every ':', so 'map:m' fails and the bracket is released as text before marker(in:) can split on the first colon. Ids with ':' come from the engine's own .prefixed identity, and the prompt tells the model to cite them verbatim. This violates 14.3 rule 3.
- Repro: S/f0708. 'See [map:m:harbor] and [map:harbor].' -> [.text('See [map:m:harbor] and '), .citation(harbor), .text('.')]. '[tip:tip:42]' leaks. A marker split across deltas leaks. Control '[tool:tools#7]'…

### C2-m02-query-service-09 — Text date columns cost up to two ISO8601DateFormatter constructions per row

- Verdict: **confirmed**; severity medium; category performance; spec 15.9 (one page of 500 rows read, resolved and projected in 40 ms; 10k-row context in 1.5 s on the reference device)
- Where: `Sources/ZTronSearchEngine/Database/SearchSQLComposer.swift:190-209`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:175`
- What: SearchDateParser creates a new ISO8601DateFormatter for each option set it tries, for every value. SQLite.swift stores Date as TEXT ('yyyy-MM-dd'T'HH:mm:ss.SSS'). SQLite's CURRENT_TIMESTAMP produces 'YYYY-MM-DD HH:MM:SS', which costs two constructions because the fractional-seconds attempt fails first. The adapter's database target tests use REAL dates, so this path is never measured against the budget.
- Skeptic: SearchDateParser constructs an ISO8601DateFormatter per option set per value. The path is reached in the reference setup: SQLite.swift stores Date as TEXT 'yyyy-MM-dd'T'HH:mm:ss.SSS' and the adapter maps it to .text. That costs one construction per row, and two for CURRENT_TIMESTAMP text. It breaches the 15.9 page and context budgets by more than an order of magnitude under the README's Mac scalin…
- Repro: S/f09, verbatim copy (diff clean), -O, M3 with load average about 5-6. SQLite.swift text: 236-242 us/value (118-121 ms per 500-row page). CURRENT_TIMESTAMP: 379-381 us (about 190 ms per page). Cached …

### C2-m03-semantic-01 — Model budgets are enforced as on-disk size in MiB, not the resident memory budgeted by section 15.2

- Verdict: **partly**; severity high → medium; category spec-deviation; spec 15.2 (Memory, resident: embedding model loaded 80 MB, reranker loaded 60 MB, semantic-query peak 200 MB), 15.5, 7.3, 7.4
- Where: `Sources/ZTronSearchEngineSemantic/SemanticError.swift:79-82`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLEmbeddingProvider.swift:150-152`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLCrossEncoder.swift:137-138`, `Scripts/semantic/ztron_conversion.py:32-33`
- What: The package checks only the model's on-disk size, against 80/60 MiB. It has no assertion or measurement of the loaded model's resident memory, the 200 MB semantic-query peak or the 800 ms reload (a section 16 gap). Its docs and conversion script present the on-disk figure as 'the budget', although the iOS 15 conversion route expands the 8-bit weights at load, so passing the check does not show the 15.2 loaded targets are met. The on-disk gate itself matches the spec's artifact-size framing (7.4, 17). This is a missing verification of a release target that needs a chosen model and the device, n…
- Skeptic: The code facts are confirmed. SemanticLimits budgets are 80/60 MiB and labelled 'On-disk budget ... (specification section 15.5)'. Both adapters compare footprintBlocking of the .mlmodelc with sizeBudget before loading. ztron_conversion.py:373-374 says the default neuralnetwork route, the only one for iOS 15, stores 8-bit weights 'expanded when the model loads'. The 15.2 constants in ZTronSearchFi…
- Repro: Not runnable here: no model, no device, no coremltools. Verified by reading the code and grepping Sources and Tests: no use of embeddingModelBytes/rerankerModelBytes, and no 110 MB, 200 MB or 800 ms a…

### C2-m03-semantic-02 — QuantizedVectorStore.build writes out of bounds when the quantization has more dimensions than the space

- Verdict: **confirmed**; severity medium; category bug; spec 7.3 (INT8 vector store); build() API contract (throws dimensionMismatch)
- Where: `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:172`, `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:187`, `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:194`, `Sources/ZTronSearchEngineSemantic/Vector/VectorQuantization.swift:182-195`
- What: build(from:modelID:dimensions:quantization:) checks every vector against `dimensions` but uses the caller's quantization without checking quantization.dimensions == dimensions. It then calls parameters.encode(valueBase, into: target, scratch: workBase) (line 187), which runs vDSP over parameters.dimensions elements. That reads past the vector, and writes parameters.dimensions floats into the dimensions-sized scratch array and parameters.dimensions codes into the ids.count*dimensions code array. The check that would throw dimensionMismatch comes later, in the staging initializer (line 194). The…
- Skeptic: This verdict is kept from the first run. QuantizedVectorStore.build checks vectors against `dimensions` but never compares quantization.dimensions with it. scratch and codes are sized by `dimensions`, while encode(_:into:scratch:) runs vDSP over parameters.dimensions. The only dimension check on the quantization is in the staging initializer, after the writes. The only internal caller, SemanticInd…
- Repro: f02 (first run; binary re-run this session): build(... dimensions: 4, quantization: .uniform(dimensions: 384)) exits 137 in 3 of 3 runs, with heap corruption in _swift_release_dealloc under build(). T…

### C2-m03-semantic-03 — A large `limit` crashes the HNSW search (Int.max) or pins scratch memory proportional to the limit

- Verdict: **confirmed**; severity medium; category bug; spec 10 (bounded work), 15.2 (memory)
- Where: `Sources/ZTronSearchEngineSemantic/HNSW/HNSWGraph.swift:192-194`, `Sources/ZTronSearchEngineSemantic/HNSW/HNSWWorkspace.swift:206-218`, `Sources/ZTronSearchEngineSemantic/HNSW/HNSWIndex.swift:227-246`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:152-161`
- What: HNSWGraph.search sets breadth = max(ef, limit) and sizes the workspace with ef: max(breadth, efEntry). HNSWWorkspace.reserve computes `ef + 2` and allocates 2*listCapacity + ... entries plus listCapacity node slots. The size is never capped by the node count and never shrinks. Neither SemanticIndex.nearest(to:limit:) nor HNSWIndex.search bounds `limit`, while the exhaustive path does (TopMatches(limit: min(limit, liveCount))).
- Skeptic: This verdict is kept from the first run. SemanticIndex.nearest only requires limit > 0. HNSWIndex.search clamps efSearch to 4,096 but passes limit through. HNSWGraph.search sets breadth = max(ef, limit), and HNSWWorkspace.reserve computes ef + 2 and allocates in proportion to it, never shrinking. The exhaustive path clamps with min(limit, liveCount). Core passes semanticNeighbours (default 50) or …
- Repro: f03 (first run; re-run this session): HNSWIndex.search(limit: Int.max) and SemanticIndex.nearest(limit: Int.max) exit 133 (SIGTRAP in HNSWWorkspace.withScratch). exhaustiveSearch(limit: Int.max) retur…

### C2-m03-semantic-04 — WordPiece misfiles '##' continuation pieces that start with a combining mark, so words that need them become [UNK]

- Verdict: **confirmed**; severity medium; category bug; spec 7.3 / 7.4 (multilingual embedding and cross-encoder models), 15.3 (non-Latin language in the golden set)
- Where: `Sources/ZTronSearchEngineSemantic/Tokenization/WordPieceTokenizer.swift:121-122`, `Tests/ZTronSearchEngineSemanticTests/WordPieceTokenizerTests.swift:6-15`
- What: The initializer splits the vocabulary with entry.piece.hasPrefix(prefix) and dropFirst(prefix.count). Both compare Swift Characters (grapheme clusters). In a piece such as "##" + U+0902 (Devanagari anusvara) or "##" + U+093F (vowel sign i), the second '#' and the mark form one grapheme, so hasPrefix("##") is false. The piece goes into the word-initial table, where no word can reach it because BERT pre-tokenization splits '#'. Every word whose segmentation needs such a continuation becomes a single [UNK]. Multilingual WordPiece vocabularies (mBERT, DistilmBERT, LaBSE) contain many such pieces f…
- Skeptic: This verdict is kept from the first run. WordPieceTokenizer.init splits the vocabulary with Character-based hasPrefix/dropFirst. A combining mark extends the second '#' into one grapheme, so '##'+mark pieces land in the initial table. split walks scalar boundaries and looks continuations up only in the continuation table, so any word that needs such a piece becomes [UNK]. Both the vocab.txt and to…
- Repro: f04 (first run; re-run this session): hasPrefix("##") is false for '##'+U+0902/U+093F/U+0E31/U+064E (2 Characters, 3 scalars) and true for U+00E9 and U+0930. Cased: tokenize(U+0915 U+0902) = [1] (refe…

### C2-m04-ui-02 — Setting pageSize while a query is in flight drops all of its snapshots and leaves the previous query's hits stuck on screen

- Verdict: **partly**; severity medium; category bug; spec 13 (results model, generation guard, paging), 14.5
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:65-70`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:78-81`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:131`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:149-152`
- What: Setting pageSize to a different value while a service-backed query is in flight makes every snapshot of that query fail the equality guard. The previous query's hits stay published with isLoading false until the text or tokens change or submit() is called. reset() also silently reverts pageSize to 20.
- Skeptic: The mechanism is real. The pageSize setter writes query.limit and does not bump revision. SearchQuery's synthesized Hashable includes limit. SearchService echoes state.query, the query it was handed, into every snapshot, so a stream started at limit 20 always carries limit 20, and apply's `snapshot.query == query` drops all of them. streamEnded then clears isLoading, and update() with the same tex…
- Repro: pagesize.swift printed, for case B: 'apply: DROPPED snapshot of "harb" (snapshot limit 20, model limit 50, revision match true)' twice, then 'streamEnded: isLoading -> false' and 'query="harb" limit=5…

### C2-m04-ui-05 — The parity suite does not check what the spec places under it: three token scripts, the public modifiers' callback counts, and the sampled clone profile

- Verdict: **confirmed**; severity medium; category test-integrity; spec UI parity suite list (spec p.48: token scripts incl. insert/remove through binding, onTokenDelete veto, programmatic text-to-token; every modifier in the 12.3 map fires exactly once per UIKit callback), 15.7
- Where: `ParityHost/Sources/ZTronSearchEngineUIParity/ParityScript.swift:12-88`, `ParityHost/Sources/ZTronSearchEngineUIParity/CloneField.swift:19-25`, `ParityHost/Sources/ZTronSearchEngineUIParity/CloneField.swift:63-66`, `ParityHost/App/ParityHostUITests/SamplerUITests.swift:36-38`
- What: Three gaps. (1) The 10 matrix scripts have no binding insert/remove, no onTokenDelete veto and no programmatic conversion, and FieldSetup.allowsDeletingTokens is never false in a matrix script. (2) The compared clone log is the core's own onSearchFieldEvent stream. The public .onEditingChanged/.onSubmit/.onSearchCancel calls are counted into editingChanges/submitCount/cancelCount and never compared; nothing else in the repository reads them. (3) The sampler stores the clone's log and final state for every elementary action and its doc says the reference log 'is what the clone's log is held to'…
- Skeptic: There are 10 matrix scripts. None of them mutates the bindings, vetoes a deletion or converts programmatically. The clone host never registers onTokenDelete, onSelectionChanged, onClear, editingPolicy or textInputPolicy, and allowsDeletingTokens is never false in a matrix script. grep finds submitCount, cancelCount and editingChanges only in CloneField.swift, where they are written and never read.…
- Repro: grep over Sources, Tests, ParityHost and Scripts: submitCount, cancelCount and editingChanges match only CloneField.swift:23-25,64-66; cloneEventProfile and cloneFinalStates match only SamplerUITests.…

### C2-m04-ui-07 — With an editingPolicy set, the host's .focused binding cannot begin editing (plausible)

- Verdict: **confirmed**; severity medium; category bug; spec 12.2 ('.focused($isFocused) works directly: the field forwards focus to its inner text input'), 12.3 editingPolicy row, UI suite 'Focus round trip through .focused'
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:345`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:652`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:729`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:691-699`
- What: When an editingPolicy is configured and the field is not editing, allowsInput is false and the inner TextField is .disabled. requestFocus(), the only path that asks the policy and enables the input, is reached only from taps. A host that sets its FocusState to true targets a disabled control, and nothing in the field observes the request, so the policy is never asked and editing never begins. UIKit's becomeFirstResponder() asks textFieldShouldBeginEditing and begins editing when allowed. Derived from code; not run, because simulators may not be booted.
- Skeptic: This is derived from code and was not run (no simulator). With a policy set, allowsInput is false while idle (synchronize :652, blur :729), and the inner TextField is .disabled (:345). requestFocus(), the only code that asks the policy and enables the input, is reached only from the editing gate's tap (:488), tappedOutsideTokens (:681), tappedToken (:675) and the clear button's takesFocus (:640). …
- Repro: No runtime repro is possible without a simulator. The call-site trace above shows no path from the host's FocusState to requestFocus().

### C2-m04-ui-08 — On iOS 18+, text set through the binding while editing keeps the caret at its old UTF-16 offset (possibly inside a surrogate pair), and the field pushes that caret into the input (plausible)

- Verdict: **partly**; severity medium; category spec-deviation; spec 12.2 rule 12, 12.5 (text selection compared from iOS 18)
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:180-187`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:143-146`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:647-653`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:456-471`
- What: On iOS 18 and later, host-set text while editing leaves the core caret at its old UTF-16 offset, which may fall inside a surrogate pair, and the field pushes that caret into the inner input. If SwiftUI honors the selection, the next keystroke lands mid-text, unlike UIKit's caret-to-end. The runtime effect is unverified.
- Skeptic: The mechanism is confirmed in code. When the host sets text while the field is editing, adopt() keeps textSelection.lowerBound, clamped but not scalar-aligned. On iOS 18, synchronize -> setBuffer then sets the inner input's TextSelection to sentinels + that caret. My repro shows caret 3 kept for 'harbor', where the end would be 6, and an index that is neither scalar- nor Character-aligned for '😀x…
- Repro: textlogic.swift printed: 'text -> harbor with caret 3: core caret 3 (end would be 6); index scalar-aligned=true ...; prefix before it: "\u{200B}har"'; 'text -> \u{1F600}x with caret 1: core caret 1 (e…

### C2-m05-adapters-03 — View and virtual-table sources are never refreshed by the change stream

- Verdict: **confirmed**; severity medium; category bug; spec 9.2 rule 5
- Where: `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteExpressions.swift:204-207`, `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteExpressions.swift:218-235`, `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteExpressions.swift:272`, `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteExpressions.swift:278`
- What: Core subscribes with changes(in: Set(tables.map(\.name))) and matches table.name == change.table. The source docs advertise 'The table, view or virtual table'. When `name` is not given, a View source gets the view's name and a VirtualTable source gets the virtual table's name (line 278). SQLite's update hook never reports either name. Writes to a view's base table, including writes through an INSTEAD OF trigger on the view, are reported under the base table. FTS4/FTS5 writes are reported under the shadow tables. So these sources never receive a change and stay stale until an explicit refresh. …
- Skeptic: Kept from the first run. SearchTableSource(table: View(...)) defaults name to the view's own name (SQLiteExpressions.swift:278); a VirtualTable gets the virtual table's name. Core subscribes with changes(in: Set(tables.map(\.name))) and matches table.name == change.table (SearchService+Context.swift:504, :519, :571). ChangeTracker routes only the names the update hook reports. The hook reports wri…
- Repro: hooks/main.swift (swiftc, SQLite 3.54.0, update hook installed): UPDATE through the view's base table -> ['UPDATE tools rowid=1']; through INSTEAD OF trigger -> ['UPDATE tools rowid=2']; FTS5 insert -…

### C2-m06-tests-gates-03 — The 500 ms semantic-snapshot test holds the engine's share to an unscaled 20 ms; its own measured totals exceed 500 ms on this Mac and it passes anyway

- Verdict: **partly**; severity high → medium; category test-integrity; spec 15.1 (semantic snapshot after the typing pause: 500 ms p95 including the 300 ms debounce, reference device, 100k items)
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:244-275`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:270`, `README.md:205-208`
- What: The test holds an unscaled 20 ms residual, which also contains debounce-timer overshoot, and never asserts the 500 ms total. A 6x engine regression inside 20 ms passes, and so does a total over 500 ms (504.6 ms was seen passing). The 556-599 ms device extrapolation is not supported.
- Skeptic: Confirmed in code: the overhead is total minus 0.300 minus the measured encoding. It is held to an unscaled 20 ms rather than 20/6, on 5,000 items with a brute-force fake searcher, and the total is never asserted against 500 ms. Overstated: the 'engine adds' figure includes the overshoot of the 300 ms debounce Task.sleep. Under load, that timer latency can account for most of the 12.7-19.9 ms, so …
- Repro: sleep_overshoot.swift at load about 225: debounce overshoot median 15.89 ms, max 24.19 ms; encoder overshoot median 11.51 ms. Resumed run, unmodified test at load about 6: 'worst 504.642 ms in all; th…

### C2-m06-tests-gates-04 — The cancellation tests time the consumer's own exit, which AsyncStream provides without the producer; none of them can fail if the producer ignores cancellation

- Verdict: **partly**; severity high → medium; category test-integrity; spec 15.4 (cancellation honoured within 10 ms of the next checkpoint); section 11 liveness table (cancellation tests before, during and after index search); SearchService.results doc (cancelling the consumer cancels the producer)
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:34-47`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:49-80`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:119-140`, `Sources/ZTronSearchEngine/Service/SearchService.swift:278-296`
- What: No test detects a producer that keeps running after the consumer cancels, for example with onTermination removed. Removing the IndexSearcher checkpoints is caught by testTheScoringLoopChecksCancellation. The 10 ms + full/4 bound is not a relaxation of the spec.
- Skeptic: Core claim confirmed: the three tests time the consumer's own exit, which AsyncStream provides without the producer, and nothing checks that the producer stopped. Scope correction: removing every Task.checkCancellation in IndexSearcher makes testTheScoringLoopChecksCancellation fail, so only the onTermination removal goes uncaught. The implementation has both today, so this is a coverage gap, not …
- Repro: stream_cancel_skeptic.swift. With onTermination removed, the consumer exited in 0.0 ms while the producer's debounce slept the full 300 ms and the encode the full 5 s. With no checkpoints, the produce…

### C2-m06-tests-gates-09 — Several 15.1 and 15.2 targets that need no model have no assertion; the one steady-state measurement exceeds 110 MB and is gated at 200 MB

- Verdict: **partly**; severity medium; category spec-missing; spec 15.1 (final snapshot past the calibration gate 750 ms; no frame over 16.7 ms attributable to search); 15.2 (steady state with models unloaded 110 MB; semantic peak 200 MB); 16 (resident memory assertions from 15.2; 100k-item indexing time)
- Where: `Sources/ZTronSearchFixtures/ReferenceDevice.swift:67`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:402-438`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:455-463`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:678-689`
- What: No test asserts the 15.2 steady state or the 750 ms reranked snapshot. The in-memory quick-start configuration holds about 125 MB of heap for 100k items, over 110 MB, and is gated only at 200 MB. The mapped-index memory test passes only because it leaves out stored-document pages. The load-heap exclusion is immaterial (0.0 MB).
- Skeptic: Confirmed: rerankedSnapshot (750 ms) is used by no test. No test asserts the 110 MB steady state or the 200 MB peak, and none checks for frames over 16.7 ms. testIndexingKeepsItsWorkingMemoryInBounds measures 125.4-125.5 MB of heap held for 100,420 in-memory items and asserts only < 200 MB. The in-memory segment's index sections alone are 41.6 MB (over 40 MB), plus 46.6 MB of stored documents. tes…
- Repro: Probe: 'in-memory index of 100420 items: heap retained 125.5 MB'; 'compacted segment: index sections 41.6 MB, stored documents 46.6 MB'; 'heap allocated by load(from:) and kept: 0.0 MB'. Release suite…


## Low

### C2-m01-text-index-06 — SearchableID == is Unicode canonical equivalence but the index identifies documents by UTF-8 bytes: remove/contains miss, 'equal' duplicates appear, scan and indexed strategies diverge, and < is inconsistent with ==

- Verdict: **partly**; severity medium → low; category bug; spec 4 and 9.1 rule 1 (ids unique inside a context), 9.1 rule 3 (identical ranking across strategies)
- Where: `Sources/ZTronSearchEngine/Contracts/Searchable.swift:9-38`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:373-400`, `Sources/ZTronSearchEngine/Index/IndexSegment.swift:428-445`, `Sources/ZTronSearchEngine/Scan/ScanEngine.swift:32-45`
- What: As described: NFC and NFD forms of the same id are equal as SearchableIDs, but the lexical index identifies documents by bytes. The index misses contains/remove for the other form, keeps two documents (and returns two hits with equal ids) when the forms arrive in separate batches, and disagrees with the scan strategy, which merges them. `<` is not consistent with `==`. This is an edge case that needs ids arriving in mixed Unicode normalization, so it is low rather than medium.
- Skeptic: Real exactly as described. SearchableID synthesizes ==/hash on String, which means canonical equivalence, and defines `<` on UTF-8 bytes (Searchable.swift:9-38). Batch dedup (LexicalIndex.swift:378-392) and ScanEngine use dictionary keys, while segment lookups hash and memcmp raw bytes (IndexSegment.swift:428-445, fnv1a in ByteCoding.swift:175-187). Projection passes searchID through unchanged (Se…
- Repro: Mode nfc-nfd: 'nfc == nfd: true; nfc < nfd: false; nfd < nfc: true; equal hashValue: true; Set count: 1'. Index holding NFD: contains(NFD) = true, contains(NFC) = false, document(for: NFC) = nil. Afte…

### C2-m01-text-index-07 — Paging arithmetic overflows: SearchQuery.limit = Int.max with a cursor offset > 0 traps (ScanIndex, and the same pattern in SearchService paging and suggestions)

- Verdict: **confirmed**; severity low; category bug; spec 9 / 9.1 (paging, ScanIndex.hits)
- Where: `Sources/ZTronSearchEngine/Scan/ScanIndex.swift:76-77`, `Sources/ZTronSearchEngine/Service/SearchService.swift:465-466`, `Sources/ZTronSearchEngine/Service/SearchService.swift:837, :858-859`
- What: `start + max(0, query.limit)` uses trapping arithmetic, and SearchQuery.limit is a public Int with no clamp. Int.max is the usual way to ask for 'no limit'. The suggestions code has the same problem with `limit * 4` and `limit + 1`.
- Skeptic: `start + max(0, limit)` is computed with trapping arithmetic in ScanIndex.swift:76-77 and SearchService.swift:465-466. SearchService.swift:837 computes `limit * 4`, and :858-859 compute `limit + 1`. SearchQuery.limit is an unclamped public Int (SearchQuery.swift:34), SearchCursor(offset:) is public, and results(for:) honours query.cursor (SearchService.swift:379). So the natural host sequence reac…
- Repro: ScanIndex: limit 2 -> nextCursor offset 2. The same query with limit .max and that cursor -> signal 5 'arithmetic overflow' in ScanIndex.snapshot(for:generation:contextID:). Indexed service: limit .ma…

### C2-m01-text-index-08 — Filter-only queries on the indexed strategy keep the first 2,000 live documents in segment order, so the hits depend on upsert/merge history

- Verdict: **confirmed**; severity low; category bug; spec 10 (at most 2,000 candidates), 9.1 rule 3
- Where: `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:680-692`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:916-944`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:661-672`
- What: A query with only filters or kinds gives every admitted document the same score of 1, so the result list is sorted by id. But it is sorted only over whichever 2,000 documents came first in segment and ordinal order. install reorders segments by live count, and merges and saves change that order.
- Skeptic: The match-all path (IndexSearcher.swift:680-692) admits live documents in segment and ordinal order, scores them all 1, and stops at the 2,000 limit. The ranked list is then sorted by id, but only over the admitted set. Segment order follows merges (install reorders segments by size), so the first page depends on merge history, and it differs from the scan strategy, which has no admission bound. I…
- Repro: Mode matchall: 100 ios documents a000-a099, then 2,000 ios documents m0000-m1999, in segments [100, 2000]. Filter-only page 1 = a000..a004. Added 3 batches of 100 mac documents (the matching set is un…

### C2-m01-text-index-09 — Plans with more than 64 clauses (bigram fallback) give later clauses match bit 0, so documents matching only those clauses are dropped

- Verdict: **confirmed**; severity low; category bug; spec 7.1
- Where: `Sources/ZTronSearchEngine/Query/QueryPlanner.swift:122, :150-157`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:899, :929`, `Sources/ZTronSearchEngine/Scan/ScanEngine.swift:189`
- What: The parser caps clauses at 64. The planner's bigram fallback, however, adds one plan clause for every matched bigram, so a long CJK or Thai query can push the plan past 64 clauses. Clauses from index 64 onward still add to the score but contribute match bit 0, and a document whose match mask is 0 is dropped from the list. Both strategies share this code, so parity is not broken.
- Skeptic: The parser caps parsed clauses at 64 (QueryParser.swift:37, :63). For unspaced-script words that miss the vocabulary, the planner adds one plan clause per matched fallback bigram (QueryPlanner.swift:150-157). Clauses at index 64 or above get mask bit 0 (IndexSearcher.swift:899, ScanEngine.swift:189), and ranking keeps only documents with `matched != 0` (IndexSearcher.swift:928-929). Required claus…
- Repro: Mode clauses-public (ScanIndex and SearchService(context:) only). Query: 86 distinct katakana; NLTokenizer gives 4 words [25,25,25,11] with bigram fallbacks [24,24,24,10]. Document 'head' holds bigram…

### C2-m01-text-index-10 — Normalization adds a dotless-i to i step beyond the spec recipe

- Verdict: **confirmed**; severity low; category spec-deviation; spec 5 rule 4 (NFKC, then folding(.caseInsensitive, .diacriticInsensitive, .widthInsensitive, locale))
- Where: `Sources/ZTronSearchEngine/Text/SearchNormalizer.swift`
- What: The extra step is deliberate and commented. It merges the distinct Turkish letters ı and i in every locale, which the spec's recipe does not do: folding on its own leaves ı unchanged.
- Skeptic: Spec 5 rule 4 (page 9) prescribes exactly 'NFKC, then folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale:)'. Section 16 ('Unicode and diacritic normalization, including NFKC folding and width folding') and section 17 allow no extra step. SearchNormalizer.swift:28-34 maps U+0131 to 'i' after folding, on purpose, as its doc comment (:8-13) says. The recipe leaves ı…
- Repro: Mode fold. Recipe: ı -> U+0131 under nil, en and tr. Engine: ı -> U+0069 under all three. 'kır': recipe 'kır', engine 'kir' in every locale. Recipe under en: 'IŞIK' -> 'isik' but 'ışık' -> 'ısık'. Rec…

### C2-m01-text-index-11 — Weak or nondeterministic tests: unseeded trigram property test, locale-change test that does not prove overlap with the rebuild, corrupt-file test that only fails the magic check

- Verdict: **partly**; severity low; category test-integrity; spec 7.2, 5 rule 7, 6
- Where: `Tests/ZTronSearchEngineTests/TextPipelineTests.swift:160-163`, `Tests/ZTronSearchEngineTests/InternationalizationTests.swift:233-283`, `Tests/ZTronSearchEngineTests/StrategyParityTests.swift`
- What: The locale-change i18n test cannot tell the old index from the new one and never shows that queries overlapped or were not blocked by the rebuild. The corrupt-file test only covers the magic check, and no test feeds a corrupted valid segment. The trigram losslessness test draws an unseeded sample each run, but any failure prints its query and candidate, so it can be reproduced from the log.
- Skeptic: Two of the three sub-claims are confirmed. Locale-change test (InternationalizationTests.swift:233-283): the probe item reads the same in every locale, and nothing records or times whether the 20 queries overlapped the rebuild, so the test would pass even if every query waited for it. Corrupt-file test (StrategyParityTests.swift:187-199): the bytes are i*31 mod 256, so the first byte is 0x00 again…
- Repro: Code reading and grep. The garbage file starts 0x00, 0x1F, 0x3E... against magic 'ZTSI' (IndexSegment.swift:41). grep over Tests/ for load(from:), IndexSegment(data:) and byte patching found no test t…

### C2-m01-text-index-12 — admitCandidates comment claims 'heaviest field first', but fields are visited in fixed ordinal order regardless of the profile's field weights

- Verdict: **confirmed**; severity low; category false-claim; spec 7.1 (field weights per RankingProfile)
- Where: `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:694-695`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:773`
- What: Fields are visited in the fixed order title, keywords, caption, text, localizedAlt, ocrText. That matches the default weights only. With a custom RankingProfile.fieldWeights, the admission order ignores the weights, so the comment is true only for the default profile.
- Skeptic: The comment at IndexSearcher.swift:694-695 says 'heaviest field first', but :773 loops `for field in 0..<SearchField.count` in fixed ordinal order: title, keywords, caption, text, localizedAlt, ocrText (SearchDocument.swift:4-10). That order equals the default weights 8/4/2.5/1/0.5/0.5 (RankingProfile.swift:145-152; spec 7.1 calls them defaults), so the comment holds only for the default profile. …
- Repro: Mode fieldorder (LexicalIndex.upsert + SearchService(index:profile:)): 2,500 documents with 'zeta' in the title plus 5 with 'zeta' only in ocrText, under a profile of ocrText 50 / title 0.01. Indexed …

### C2-m02-query-service-05 — The chat idle-unload timer can fire while a new turn is retrieving or assembling its prompt, and cancels that turn

- Verdict: **partly**; severity medium → low; category concurrency; spec 14.3 rules 4-5 (unload after 120 s idle), 14.4 lifecycle
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:377-400`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:440-477`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:583-602`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:409-420`
- What: As described, but rare by construction: the vulnerable window is one turn's retrieval and assembly time at the idleUnload boundary. Severity low.
- Skeptic: send() never bumps `use` and the lifecycle stays .ready until line 477, so an idle timer that expires during retrieval or assembly unloads the model and cancels the turn. The race reproduces with a realistic window (a semantic phase under its cap) rather than the auditor's slowed countTokens. Severity is low, not medium: only a send landing in the roughly 0.05-0.7 s retrieval window at the 120 s b…
- Repro: S/f05, idleUnload 0.6 s, StubSemantic 0.25 s. Send at +451 ms: CancellationError after 187 ms, sources 0, unloadCalls 1, generateCalls 0. Controls (send at +103 ms; no semantic delay) finish normally …

### C2-m02-query-service-10 — The cancellation-latency test allows 10 ms plus a quarter of the whole search, instead of 10 ms after the next checkpoint

- Verdict: **partly**; severity medium → low; category test-integrity; spec 15.4 'Cancellation honoured within 10 ms of the next checkpoint'; 11 (checkpoint every 1,000 postings)
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:49-79`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:75`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:82-107`
- What: The cancellation-latency assertion is vacuous: it times the consumer's exit, which never waits for the producer. testTheScoringLoopChecksCancellation only bounds the spacing by the work of a 4,000-item heavy search (15,188 units). Spacing up to about 15,000 postings (15x sparser) keeps both tests green; 100,000 does not.
- Skeptic: The `0.010 + full / 4` bound is as described, but it is moot. `worst` measures the consumer task's exit after cancel(), and cancelling the consumer ends its AsyncStream iteration at once, so the value is about 0 whatever the producer does. The stated failure scenario is wrong: with checkpoints every 100,000 postings, testTheScoringLoopChecksCancellation fails, because its 4,000-item search does on…
- Repro: S/f10, test logic verbatim plus a producer-side probe (index-actor hop after cancel). Test metric 0.02-0.09 ms in every build. Spacing 1,000: both tests PASS, producer worst 4.2-4.9 ms. 15,000: both P…

### C2-m02-query-service-11 — Every keyed field resolves the key in every catalog language, though only the active, fallback and secondary languages are used

- Verdict: **confirmed**; severity low; category performance; spec 15.9 (page and context-creation budgets)
- Where: `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:116-147`
- What: For each keyed field of each row, the projector calls resolver.string(forKey:...) for every language the catalog lists and stores all the results in searchLocalizations. SearchProjector then keeps only the active language, its fallback chain and the configured secondary languages. The cost grows linearly with the number of catalog languages. Section 15.9 is specified, and tested, with only 2.
- Skeptic: The row projector resolves every keyed field in every catalog language. The projector only reads the active chain and secondary languages (all of them only under includesAllLanguages), and a locale change re-reads the rows anyway. The cost is linear and all of it is discarded in the common configuration.
- Repro: S/fsearch arg 11, debug build, 2,000 rows x 3 keyed fields, cached fake resolver. 2 languages: ready in 130-144 ms. 30 languages: 349-465 ms. localizedAlt of notes#1 is empty in both.

### C2-m02-query-service-12 — A row's literal fields lose their declared language unless every field of the row agrees on one language

- Verdict: **confirmed**; severity low; category spec-deviation; spec 9.2 rule 3 ('Literal fields keep their declared language tag')
- Where: `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:157-161`
- What: The row item has a single searchLanguage for its base surface. It is set only when no literal is untagged and the union of literal tags and the keys' first-resolved languages has exactly one element. Two cases get nil: a literal tagged 'fr' next to a key whose catalog base is 'en', and two literals with different tags. The literal is then tokenized and normalized without its language (DocumentAnalysis passes languages.<field> to the tokenizer), and matchedLanguage is unknown.
- Skeptic: The row item has a single base searchLanguage, set only when all literal tags and key base languages agree. A 'fr' literal next to an 'en'-base key therefore gets a nil field language. That language feeds the NLTokenizer hint and the folding locale, and leaves matchedLanguage nil, contrary to 9.2 rule 3. Practical impact is small: mostly segmentation-sensitive scripts and Turkish/Azeri casing.
- Repro: S/fsearch. Literal fr + keyed title: languages.text=nil, 'hôtel' matchedLanguage=nil. Control literal en: languages.text=en, matchedLanguage=en.

### C2-m02-query-service-13 — Public setters bypass the clamps of RerankSpec, EditorialPolicy and SearchLimits; out-of-range values exceed the spec ceilings or trap

- Verdict: **confirmed**; severity low; category api; spec 7.4 / 8 (rerank top 16, at most 32; at most 3 pins)
- Where: `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:73-85`, `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:88-101`, `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:40`, `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:54-55`
- What: The clamps (topN 1...32, blend 0...1, maximumPins 0...3, retainedHits >= 1) run only in the initializers. The properties themselves are public vars, and the README configures profiles by mutating them. Setting topN = 64 sends 64 passages to the cross-encoder. Setting maximumPins = 10 pins ten results. A negative topN or retainedHits traps in prefix(_:).
- Skeptic: The clamps (topN 1...32, blend 0...1, maximumPins 0...3, retainedHits >= 1) run only in initializers. The properties are public vars and the README configures profiles by mutation. Out-of-range values exceed the 7.4 and section 8 ceilings, and negative values trap in prefix(_:).
- Repro: S/fsearch. Init clamps topN 64->32, but assignment keeps 64; blend 5 kept; maximumPins 10 kept; retainedHits -1 kept. topN=64 sent [64] passages to the cross-encoder. retainedHits=-1 and topN=-1 queri…

### C2-m02-query-service-14 — A non-finite cross-encoder score puts NaN into the published hits and silently disables the rerank for the head

- Verdict: **confirmed**; severity low; category bug; spec 7.4 (blend formula), 6 (snapshot semantics)
- Where: `Sources/ZTronSearchEngine/Service/SearchService.swift:716-719`, `Sources/ZTronSearchEngine/Service/SearchPipeline.swift:155-192`
- What: rerankPhase accepts any score array of the right length, and reranked() min-max normalizes it. An +inf score becomes NaN for that document and 0 for all the others. A NaN score breaks the sort comparator and the score mapping. The snapshot then carries NaN scores and scores above the head's top score, the cross-encoder order is lost, and no degraded flag is set.
- Skeptic: rerankPhase accepts any score array of the right length, and reranked() min-max normalizes it with no finiteness check. +inf zeroes every finite score and becomes NaN itself; a NaN breaks the sort and the score mapping. The snapshot is published with no degraded flag.
- Repro: S/fsearch, direct reranked(). Control: d1 leads. [.., inf, ..]: d0=0.0500 d1=0.0490 d2=nan (rerank lost). [.., nan, ..]: d2=0.0830, above the head's top 0.05. End to end with FakeReranker returning +i…

### C2-m02-query-service-15 — Wiring chat through ZTronSearch creates a retain cycle; neither the search service nor the chat service is ever freed

- Verdict: **confirmed**; severity low; category bug; spec 9.1 rule 6 ('releasing the service frees everything'); 11 predictable cleanup / leak tests
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:679-684`
- What: The facade installs `{ await service.unload() }` as the search service's memoryWarningPredecessor, and that closure captures the ChatService strongly. ChatService in turn holds the SearchService strongly. Releasing the facade therefore leaves both services alive, along with their index, observers and change-stream subscriptions.
- Skeptic: ZTronSearch stores `{ await service.unload() }`, which captures the ChatService strongly, as the search service's memoryWarningPredecessor; nothing clears it. ChatService holds the search service strongly, so a cycle forms and releasing the facade frees neither. Low because the facade is documented as wired once, but it breaks 9.1 rule 6 for per-screen use.
- Repro: S/fchat. With chat: predecessor installed true; search service freed false, chat service freed false. Without chat: search service freed true.

### C2-m02-query-service-16 — A send that arrives during a model fetch waits, uncancellably, for the whole download while holding the generation lock

- Verdict: **partly**; severity low; category concurrency; spec 14.3 rule 4 (a new send in the same session cancels the one in flight; other sessions queue), 14.4 cancellation target
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:435-440`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:532-539`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:181-187`
- What: A turn cancelled through ChatService.cancel(_:), or superseded, while waiting for a fetch or load keeps its stream and the generation lock until the preparation ends. Only hosts that wait for that stream to end after cancel(_:) see 'stop' lag. Other sessions are not delayed beyond the download they need anyway, and the shipped UI's stop is immediate.
- Skeptic: The mechanism is real: the turn takes the generation lock, then parks in withCheckedContinuation until runPreparation's defer, after both fetch and load, and task cancellation does not resume it. The impact is overstated. No session can generate before the fetch and load end anyway, so other sessions are not delayed. The UI model's cancel() ends its consumer and clears isGenerating at once.
- Repro: S/fchat, 2 s fake download. cancel(a) at +322 ms: A's stream ended at +2063 ms with CancellationError, 1741 ms after the cancel. Session B, sent right after, finished at +2063 ms, the same moment the …

### C2-m02-query-service-17 — query.limit = 0 yields a cursor that never advances

- Verdict: **confirmed**; severity low; category bug; spec 6 rule 8 (paging continues the final snapshot's list)
- Where: `Sources/ZTronSearchEngine/Service/SearchService.swift:464-479`, `Sources/ZTronSearchEngine/Contracts/SearchQuery.swift:34`
- What: The page end is computed as start + max(0, limit). With limit 0, every snapshot and page is empty, but nextCursor is SearchCursor(offset: start) while documents remain. page(after:) therefore returns the same cursor forever.
- Skeptic: SearchQuery.limit is an unvalidated public var. With limit 0, end == start, so nextCursor = SearchCursor(offset: start) whenever documents remain, and page(after:) returns the same cursor forever. A host that pages until nil never terminates; the UI's one-page-per-cursor guard would stop it.
- Repro: S/fsearch, 30-item scan context, limit 0. Final: hits 0, next cursor offset 0. Pages 1-5: hits 0, cursor offset 0 each. Control limit 10: cursor offset 10.

### C2-m02-query-service-18 — The prompt budget counts message contents only, not the chat template's per-message tokens, and the test measures the same quantity

- Verdict: **confirmed**; severity low; category spec-deviation; spec 14.3 rule 2 (prompt inside contextWindow - maxNewTokens - 64)
- Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:144-161`, `Tests/ZTronSearchEngineTests/ChatTests.swift:463-494`
- What: PromptAssembler sums countTokens(content) per message. The role headers and separators that the runtime's chat template adds are not counted; ChatML-style templates use about 4-6 tokens per message. Those tokens have to fit in the fixed 64-token margin. With a long kept history the overhead grows with the message count (about 150 tokens for 30 messages), so prompt + maxNewTokens can exceed the window. The test sums the same content-only counts.
- Skeptic: PromptAssembler sums content tokens only. The MLX adapter's countTokens encodes content without special tokens, while generation renders the chat template and budgets the reply on the rendered prompt. Past about 12 messages the rendered prompt exceeds contextWindow - maxNewTokens - 64 (14.3 rule 2), and the reply is shortened. The window itself stays guarded by promptTooLong. The test measures the…
- Repro: S/fchat, real assembler, window 4096, maxNewTokens 512, margin 64. 58 messages, content 3502 against budget 3520. A ChatML rendering adds about 293 template tokens, giving about 3795 (275 over budget)…

### C2-m02-query-service-19 — SearchError.missingLocalizedStringResolver is declared but never thrown; keyed fields are silently dropped when no resolver is set

- Verdict: **partly**; severity low; category api; spec 9.2 (localizedStrings 'required when any field is a localized key')
- Where: `Sources/ZTronSearchEngine/Contracts/SearchHit.swift:134-135`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:111-114`
- What: SearchError.missingLocalizedStringResolver is documented but never produced. A missing resolver indexes nothing for keyed fields, as spec rule 3 prescribes for unresolved keys, and is visible only through the diagnostics sink (os_log in debug). API hygiene and discoverability issue, low.
- Skeptic: The public case appears only at its declaration, so it is dead code. But the 'silent' claim is overstated. DiagnosticReporter.debug limits only the os_log line to DEBUG builds and forwards unresolvedLocalizationKey to the host's diagnostics sink in every build. Spec 9.2 rule 3 itself prescribes this handling for an unresolved key ('indexes nothing ... logged in debug'). The spec names no such erro…
- Repro: grep over Sources, Tests and README: the only occurrence is SearchHit.swift:135. No driver needed.

### C2-m03-semantic-05 — A cancelled upsert leaves untracked vectors in the index, which are silently dropped at the quantization refit or not carried at a locale switch

- Verdict: **partly**; severity medium → low; category concurrency; spec 7.3 (runtime upserts), 5 rule 8 / 17 (per-locale vector sets), 11 (cancellation)
- Where: `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:413-439`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:425-426`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:433-436`, `Sources/ZTronSearchEngineSemantic/HNSW/HNSWIndex.swift:178-193`
- What: A cancelled upsert of more than 128 vectors is applied in part (the first 128 multiple) and later rolled back silently: at the provisional refit, the partial rows vanish and replaced ids revert to their old vectors; at a locale switch, the partial rows are not carried. The final state equals the 'refused' outcome core reported, so this is a state-consistency defect (contains, count and search temporarily show part of a refused batch) confined to the cancelled call, not a loss of vectors the host was told were stored. Repeating the upsert heals it.
- Skeptic: The mechanism is real on both paths. A host's SearchService.index runs core's upsertVectors -> SemanticIndex.upsert -> store -> HNSWIndex.insert(contentsOf:) in the host's own task. That insert checks cancellation at positions 128, 256 ... and keeps what it inserted. The throw skips `provisionalVectors = all` and the upsertedAtRuntime/removedAtRuntime updates. The refit rebuilds only from provisio…
- Repro: f05: upsert 10; cancelled upsert of 200 throws CancellationError with 'count 138 contains(cancelled-000) true contains(cancelled-128) false'; upsert 120 gives count 258; upsert 130 (refit) gives 'coun…

### C2-m03-semantic-06 — The 'Not a gate' isotropic HNSW test enforces the latency gate and fails the CI quality-targets step

- Verdict: **partly**; severity medium → low; category test-integrity; spec 15.1 (HNSW ANN top 50: 5 ms p95, recall@10 >= 0.95), 16
- Where: `Tests/ZTronSearchEngineSemanticTests/HNSWRecallTests.swift:117-127`, `Tests/ZTronSearchEngineSemanticTests/HNSWRecallTests.swift:218-226`, `.github/workflows/ci.yml:53-56`
- What: The 'Not a gate' isotropic test carries the scaled 5 ms latency assertion at efSearch 256 (four times the spec breadth, 20k vectors), so it can turn the CI quality-targets step red for a non-gate reason. The failure is intermittent and depends on the host (1 of 8 runs here, while the real 100k gates had large margins), not systematic.
- Skeptic: The code is as described. The test is documented 'Not a gate' and calls measure(count: 20_000, shape: .isotropic, efSearch: 256). measure() asserts coldP95 < ReferenceDevice.scaled(5 ms) = 0.833 ms on every call. ci.yml:53-56 runs the whole semantic test target with ZTRON_SEMANTIC_LARGE=1, so this test is in the gate step, asserting a configuration the spec does not budget. Measured here, it is th…
- Repro: f06 (measure() and the TestSupport corpus copied verbatim, -O, Apple M3 at load 6-10). Isotropic 20k, efSearch 64: cold p95 0.614/0.577/0.588 ms, passes. Efsearch 256: cold p95 0.780, 0.879 (FAILS), 0…

### C2-m03-semantic-07 — Vector and graph files with tombstone bits beyond the row/node count are accepted, and rows appended later are born tombstoned

- Verdict: **confirmed**; severity low; category bug; spec 7.3 (memory-mapped vector and graph files); damaged or hostile file handling
- Where: `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:275`, `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:292-294`, `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:513-532`, `Sources/ZTronSearchEngineSemantic/HNSW/HNSWGraph.swift:423-424`
- What: Both decoders compare the live or deleted count with Bitset.population. That counts every bit of every word, including bits above the row/node count in the last word, and nothing requires those bits to be zero. HNSWIndex(store:graphAt:) compares tombstones only for 0..<store.count. A file with such a bit, and its count adjusted to match, is accepted with a phantom tombstone. The next appended row or node lands on that bit (upsert appends at `count`, and HNSWGraph.insert only reserves words) and is tombstoned from birth.
- Skeptic: Both decoders compare the live/deleted count with Bitset.population, which counts every bit of the last word, including bits above the row count. HNSWIndex(store:graphAt:) compares tombstones only for 0..<store.count. upsert appends at ordinal = count, and HNSWGraph.insert only reserves words, so a phantom bit at the next ordinal tombstones the next appended row. The package's writers never set su…
- Repro: f07, patching product-written files. Vector file of 50 rows with row 10's tombstone moved to bit 50: 'crafted file accepted: count 50, liveCount 49, ids.count 50, tombstoneCount 1'; upsert(late) gives…

### C2-m03-semantic-08 — Id identity differs between mapped rows (byte compare) and the in-memory overlay (canonical equivalence)

- Verdict: **confirmed**; severity low; category bug; spec 7.3 (vector store keyed by SearchableID)
- Where: `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:430-434`, `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:683-700`, `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:156-170`, `Sources/ZTronSearchEngine/Contracts/Searchable.swift:9-38`
- What: SearchableID equality is String equality (canonical equivalence). ordinal(of:) looks base rows up with a byte-wise binary search, while the overlay and build's de-duplication use a Swift dictionary. An id stored in the file as NFC is not found under its NFD spelling. An upsert of the NFD spelling therefore appends a second live row for an id that compares equal. remove() of the NFC spelling then retires the appended row (found through the overlay) and leaves the base row live.
- Skeptic: SearchableID equality is String equality, which is canonical equivalence. ordinal(of:) checks the overlay, a Swift dictionary (canonical), then baseOrdinal, a byte-wise binary search. build de-duplicates canonically and keeps the first spelling. Core's own id lookup (IndexSegment memcmp) and its fusion hash (fnv1a over UTF-8) are byte-wise, so LexicalIndex.resolve drops the spelling it does not ho…
- Repro: f08: 'SearchableID NFC == NFD: true; same hash: true'. A store holding NFC: contains(NFC) true, contains(NFD) false. upsert(NFD): 'ordinal 2, replaced nil; liveCount 3' ('3 rows, 2 distinct Searchable…

### C2-m03-semantic-09 — TokenizerLoader approximates where its contract says unsupported files are refused

- Verdict: **confirmed**; severity low; category false-claim; spec 7.3 / 7.4 (the model's own tokenization)
- Where: `Sources/ZTronSearchEngineSemantic/Tokenization/TokenizerLoader.swift:124-128`, `Sources/ZTronSearchEngineSemantic/Tokenization/TokenizerLoader.swift:264-268`, `Sources/ZTronSearchEngineSemantic/Tokenization/TokenizerLoader.swift:294-296`, `Sources/ZTronSearchEngineSemantic/Tokenization/TokenizerLoader.swift:305-306`
- What: The doc says 'An unsupported file is refused rather than tokenized approximately'. In practice:
- model.byte_fallback is never read, so a byte-fallback Unigram model gets <unk> where the reference emits byte pieces.
- Every Precompiled/Nmt normalizer is replaced by an NFKC reproduction, whatever the charsmap holds (an nmt_nfkc_cf or identity map tokenizes differently).
- A WordPiece file with "normalizer": null gets uncased BERT normalization (lowercase plus accent stripping), where the reference applies none. The Unigram branch correctly uses identity.
- An unknown post-processor type returns…
- Skeptic: The contract at TokenizerLoader.swift:126-128 ('An unsupported file is refused rather than tokenized approximately') is contradicted by each cited case. byte_fallback is never read. Precompiled/Nmt map to an NFKC reproduction whatever the charsmap, and TextNormalization.swift:15-21 admits the map 'is not interpreted'. A WordPiece null normalizer falls back to uncased BERT normalization. An unknown…
- Repro: f09 (product Tokenization files, crafted tokenizer.json; the HF library is not installed, so reference behaviour is the documented semantics). WordPiece with normalizer null: tokenize("Café") = [5] ('…

### C2-m03-semantic-10 — Items embedded on device by embedMissing get the query prefix

- Verdict: **confirmed**; severity low; category bug; spec 7.3 (deterministic item embedding text; only the query is encoded at runtime)
- Where: `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:269`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLEmbeddingProvider.swift:36-38`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLEmbeddingProvider.swift:125-127`, `Sources/ZTronSearchEngineSemantic/EmbeddingProvider.swift`
- What: embedMissing embeds item text through encodeQuery. CoreMLEmbeddingProvider.encode always prepends configuration.queryPrefix, documented as 'Text put in front of every query ... "query: " for the multilingual-e5 family'. The EmbeddingProvider protocol has no way to request a passage embedding, so item vectors made on device carry the query prefix.
- Skeptic: embedMissing embeds item text through encodeQuery, which calls provider.encode. CoreMLEmbeddingProvider.encode always prepends configuration.queryPrefix, documented as text put in front of every query. The protocol has a single encode, so nothing can ask for a passage embedding. Scope note: the package has no passage prefix anywhere and its manifest records only query_prefix, so 'pipeline vectors …
- Repro: f10 (full module copy, the real CoreMLEmbeddingProvider with a scripted loader that records the model's input ids, queryPrefix 'query: '): embedMissing([("item-1", "red apple")]) sends '[CLS] query : …

### C2-m03-semantic-11 — Switching to a locale whose set is unusable reloads, and may rebuild, the base set on every call and then discards it

- Verdict: **confirmed**; severity low; category performance; spec 10 (throttling and memory policy), 5 rule 8
- Where: `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:208-234`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:218`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:385-389`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:404`
- What: setLocale proceeds whenever catalog.resolve(tag).languageTag != activeSet. When the localized set fails, load falls back to open(catalog.base). If the base set is already active, `guard loaded.languageTag != activeSet` then throws the result away. Each call re-maps the base files. When the base ships without a graph file, HNSWIndex.build(over:) rebuilds the whole graph (about 1 ms per vector on the reference device, by the type's doc) only to discard it. Meanwhile `exclusively` holds back every upsert and removal.
- Skeptic: setLocale proceeds because the resolved tag differs from activeSet. load logs the localized failure and opens the base; with no base graph file it runs HNSWIndex.build. The result is then discarded by `guard loaded.languageTag != activeSet`, inside exclusively, which holds back upserts. Core calls semantic.setLocale only on a real change of resolved languages (SearchService.swift:892-901), so the …
- Repro: f11 (base of 5,000 64-d vectors, garbage vectors.de.ztvec). Base without graph: each setLocale(de) takes 0.333/0.334/0.335 s, stays on base, and an upsert issued 1 ms into a switch returns after 0.333…

### C2-m03-semantic-12 — Removals are recorded only for ids present in the active vector set

- Verdict: **confirmed**; severity low; category bug; spec 5 rule 8 / 17 (per-locale vector sets)
- Where: `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:189-202`, `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:222-224`
- What: remove() adds to removedAtRuntime only the ids the current set held, because index.remove(contentsOf:) returns only those. An id that exists only in another locale's set is not recorded, so it is live again after setLocale switches to that set.
- Skeptic: remove records in removedAtRuntime only what the active set held, because index.remove(contentsOf:) returns only those ids. An id held only by another locale's set is therefore live again after setLocale. Core forgets removed items and rebuilds its lexical index on a locale change, so resolve drops the id: the effect is a wasted neighbour slot and wrong contains/count. It needs per-locale sets who…
- Repro: f12: base with item-0..99, 'it' with the same plus 'it-only', base active. remove([it-only, item-5]), then setLocale(it): 'active it, count 100, contains(it-only) true, contains(item-5) false'; neares…

### C2-m03-semantic-13 — Constrained queries request 200 HNSW neighbours; spec 10 bounds the work at 50, and the ANN gate is measured only at 50

- Verdict: **partly**; severity low; category spec-deviation; spec 10 (bounded work: 50 HNSW neighbours), 7.3 (top 50, efSearch 64), 15.1
- Where: `Sources/ZTronSearchEngine/Service/SearchService.swift:552-558`, `Sources/ZTronSearchEngineSemantic/HNSW/HNSWGraph.swift:192`, `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:33-36`
- What: Constrained queries request 200 HNSW neighbours (breadth 200), exceeding the section 10 bound of 50. The departure is documented in SearchLimits, and this query shape is not covered by the latency gate. The measured extra cost is about 1.5x the budgeted search, not 3x, and fits the scaled budget on an M3.
- Skeptic: The deviation is real. requested = min(n*4, max(n, 200)) = 200 for constrained queries, and HNSWGraph.search widens the breadth to 200, against section 10's 'Bounded work: ... 50 HNSW neighbours' and 7.3's top 50. Neither 16 nor 17 relaxes it, and section 8 ('hard constraints applied before retrieval') would still return 50. The departure is documented in SearchLimits, and HNSWRecallTests measures…
- Repro: f13 (HNSWRecallTests corpus and cold-cache protocol, diffuse 100k x 384, two rounds). Limit 50: cold p50 0.292/0.301 ms, p95 0.399/0.429 ms. Limit 200: cold p50 0.443/0.442 ms, p95 0.562/0.563 ms (all…

### C2-m03-semantic-14 — Documentation drift in the semantic scripts and adapters (wrong script paths, truncation wording, pruning test not run in CI)

- Verdict: **confirmed**; severity low; category false-claim; spec 7.3 / 7.4 (conversion pipeline)
- Where: `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLEmbeddingProvider.swift:4`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLCrossEncoder.swift:5`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLCrossEncoder.swift:10`, `Scripts/semantic/convert_embedding_model.py:8`
- What: The scripts live in Scripts/semantic/, but the docs, usage lines and the missing-module error message point to Scripts/convert_*.py and 'pip install -r Scripts/requirements.txt', which does not exist. CoreMLCrossEncoder's doc says 'the passage giving way when the pair is too long', but PairTruncation is longest-first and also cuts a query that is longer than its passage. test_vocabulary_pruning.py covers the pruning that the 80/60 MB budgets depend on, and CI does not run it.
- Skeptic: Scripts/ holds only generate_ui_assets.py and semantic/. The docs, usage lines and require() exit message point at Scripts/convert_embedding_model.py, Scripts/convert_cross_encoder.py, Scripts/requirements.txt and Scripts/test_vocabulary_pruning.py, and none of those paths exists; README.md:127 is correct. The CoreMLCrossEncoder doc says the passage gives way, but PairTruncation is longest-first a…
- Repro: test -e: 'no such file' for all four documented paths. f14: PairTruncation.lengths(first: 200, second: 10, budget: 125) gives 'query keeps 115, passage keeps 10'. Grep of .github/workflows finds Pytho…

### C2-m04-ui-03 — Ending editing drops the token selection and fires onSelectionChanged, while the UIKit reference keeps the token selected (recorded in both samples, checked by nothing)

- Verdict: **partly**; severity medium → low; category spec-deviation; spec 12.2 rules 2 and 12, 12.3 (modifiers fire once per UIKit callback), 12.5
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:483-505`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:499-501`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:637`, `Tests/ZTronSearchEngineUITests/SearchFieldCoreTests.swift:504-511`
- What: When the field ends editing, the clone clears a selected token, writes [] to the host's tokenSelection binding and fires onSelectionChanged. The UIKit reference's selectedTextRange still covers the token after didEndEditing, and it reports no selection change. This is a state and callback divergence only; the samples show no user-visible effect.
- Skeptic: The divergence itself is real. In the current core, focusChanged(false) at Core.swift:495-504 sets selection = [] and selectionChanged = true but logs no didChangeSelection. apply then writes the host's tokenSelection binding and calls onSelectionChanged, so the callback fires with no UIKit counterpart, against 12.3 and section 16's 'fires exactly once per UIKit callback'. The core file (22:56) pr…
- Repro: profilediff.py, which applies EventLogComparator's filters to all 32 sampled actions, printed: 'STATE DIFF blur-with-selected-token | ref: text "", tokens ["Maps"], selected ["Maps"], not editing | cl…

### C2-m04-ui-04 — On iOS 18, tapping the text to deselect a token logs two extra caret moves that the reference does not log

- Verdict: **partly**; severity medium → low; category spec-deviation; spec 12.2 rule 2, 12.5 (text selection compared from iOS 18), 15.7 (event log identical)
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:684-689`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:417-426`, `ParityHost/Samples/ios-18.json`
- What: On iOS 18, a tap on the text that deselects a token produces two extra caret reports (touch point, then word end) after the reference's single deselection report. This is recorded in the committed sample, which predates the field's last edit. The current code still has the path. The effect is transient, and the final state matches.
- Skeptic: My replay of the samples with the harness filters confirms the auditor's analysis. tap-text-deselects is the only 18.6 log difference: the clone appends didChangeSelection(tokens: [], text: 4+0) and then (6+0). 17.5 has no difference. The matrix cannot see it, because tap-select's second tap lands on an empty text point. The current code still contains the mechanism. tappedInput deselects, which l…
- Repro: profilediff.py printed for ios-18.json 'LOG DIFF tap-text-deselects', with the clone ending in '... didChangeSelection(tokens: [], text: 6+0)', 'didChangeSelection(tokens: [], text: 4+0)', 'didChangeS…

### C2-m04-ui-06 — The @EnvironmentObject lint is vacuous over the repository and treats any attachment anywhere as attaching every screen

- Verdict: **partly**; severity medium → low; category test-integrity; spec 13.1 / UI tests ('a screen that reads a model through @EnvironmentObject without an attaching modifier fails the lint test')
- Where: `Tests/ZTronSearchEngineUITests/LintTests.swift:154-161`, `Sources/ZTronSearchFixtures/SourceLint.swift:211-236`
- What: The lint passes every model once any scanned file contains an attaching modifier or any `.environmentObject(` call. It runs only over ParityHost and the nonexistent Examples directory, which contain no @EnvironmentObject, so its repository check is vacuous. It cannot run on host code, so it could not have caught a crash there in any case.
- Skeptic: Both mechanisms are real. SourceLint treats a model as attached when any scanned file contains one of its modifiers or any `.environmentObject(` call for any object. The repository-level test scans ParityHost and Examples. Examples does not exist, and no ParityHost .swift file contains EnvironmentObject or `.environmentObject(` (grep exits 1), so that test checks nothing. The failure scenario cann…
- Repro: lint.swift, a copy of unattachedEnvironmentObjects, printed: reader alone -> ['Rows.swift:2 reads ZTronSearchResultsModel without an attaching modifier']; reader + unrelated .environmentObject(setting…

### C2-m04-ui-09 — Smart-quote/dash undo is incomplete for locale quotes and rewrites characters the user entered on purpose

- Verdict: **confirmed**; severity low; category spec-deviation; spec 12.2 ('smart quotes and smart dashes are off'); reference sets smartQuotesType/smartDashesType = .no
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:91-105`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:228`, `ParityHost/Sources/ZTronSearchEngineUIParity/ReferenceField.swift:45-46`
- What: plain() runs on every input change and maps only U+2018/2019, U+201C/201D, U+2014 and U+2013. Locale smart punctuation (German/Polish „“, ‚‘, French « ») is left half-substituted. Characters entered deliberately (long-press en/em dash, pasted curly quotes) are rewritten, an em dash becoming two characters. With substitution off, the reference keeps both as typed, so the text binding and shouldChange payloads differ.
- Skeptic: plain() maps only U+2018/2019, U+201C/201D, U+2014 (to '--') and U+2013, and it runs over the whole proposed text on every input change. The reference sets smartQuotesType and smartDashesType to .no, so it keeps deliberately entered characters as typed. That makes this a rule-12 deviation in both directions: locale quotes are left half-substituted, and deliberate dashes and curly quotes are rewrit…
- Repro: textlogic.swift printed: „Hallo“ -> „Hallo"; ‚x‘ -> ‚x'; « bonjour » -> « bonjour »; 1–3 -> 1-3; a—b -> a--b; “curly” -> "curly".

### C2-m04-ui-10 — shouldChange payloads and textInputPolicy changes are computed per grapheme, not per UTF-16 edit

- Verdict: **confirmed**; severity low; category spec-deviation; spec 12.3 (shouldChangeCharactersIn mapping), 15.7 (identical payloads)
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldTypes.swift:101-112`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:241`
- What: ZTronTextChange.between diffs Array(old) against Array(new), which are Characters. When a keystroke extends the previous grapheme (a combining mark, Thai tone mark or emoji modifier), the change is reported as replacing the base character instead of inserting the new scalar. UIKit reports the inserted scalar at the caret. The matrix types only ASCII, so this is never exercised.
- Skeptic: ZTronTextChange.between diffs Characters. A keystroke that extends the previous grapheme is reported as a replacement of the base character, not as an insertion at the caret, and the textInputPolicy sees the same wrong change. Thai tone marks and Devanagari vowel signs are real keystrokes that do this. The emoji-modifier example is contrived, because the iOS emoji keyboard inserts the modified emo…
- Repro: textlogic.swift printed: cafe -> cafe\u{301}: clone shouldChange(3, 1, "e\u{301}") vs UTF-16 diff (4, 0, "\u{301}"); \u{E01} -> \u{E01}\u{E48}: clone (0, 1, ...) vs (1, 0, "\u{E48}"); \u{915} -> \u{91…

### C2-m04-ui-11 — 'Not runnable' overrides comparison failures already recorded, hiding 203 failing cells from the failure counts

- Verdict: **confirmed**; severity low; category test-integrity; spec 15.7 (every cell), 12.5
- Where: `ParityHost/Sources/ZTronSearchEngineUIParity/ParitySession.swift:216-229`, `ParityHost/App/ParityHostUITests/ParityRemote.swift:105-114`
- What: When every driver problem is an undelivered or missing key, the cell becomes not-runnable even if checkpoints reached earlier failed, including the key-independent initial checkpoint. The rule does not require both fields to have failed: a key counts as undelivered when that field's own log does not grow, so a clone that ignores a hardware delete is reported as a driver limitation. The reason text says 'to either field' even when only one side is listed. gate.py still blocks not-runnable cells, so the gate is not falsely opened, but summary.md understates failures.
- Skeptic: finish() sets notRunnable whenever every driver problem is a missing or undelivered key, overriding failures already recorded. A key counts as undelivered when that side's own log did not grow, so a clone that ignores a delete key is reported as a driver limitation. The reason text says 'to either field' even when only one side failed. gate.py blocks not-runnable cells, so the gate is not falsely …
- Repro: status.swift printed: a clone ignoring the delete key, with an initial pixel failure -> 'notRunnable | the driver could not deliver the script's keys to either field: clone: XCUITest did not deliver t…

### C2-m04-ui-12 — Committed parity results predate the committed localization, and the README overstates what they show

- Verdict: **partly**; severity low; category false-claim; spec 15.7, 12.5 (RTL Arabic locale)
- Where: `ParityHost/Results/summary.md`, `Sources/ZTronSearchEngineUI/Resources/Localizable.xcstrings`, `README.md:216-218`
- What: The committed results (01:45) predate the Arabic localization (xcstrings, 02:09). 735 RTL accessibility differences pair the reference's Arabic labels with the clone's English 'Clear text' or 'Cancel', so they do not describe the current product. README:216-218 overstates the LTR default-size match: iPhone 15 bold-text L/ltr cells give 18 fails and 2 not-runnable per version, and one 18.6 Pro Max hardware type cell fails because of a key dropped on the reference.
- Skeptic: The timestamps support the staleness claim. summary.md and summary.csv date from 2026-11-15 01:45:45 and Localizable.xcstrings from 02:09:15; the xcstrings now has ar for every key ('Clear text' -> 'مسح النص'), and the host's Info.plist declares ar. The RTL results pair the reference's Arabic labels with the clone's English ones. The README overstates the results. Bold text fails on iPhone 15 at L…
- Repro: stat: summary.md 2026-11-15 01:45:45, Localizable.xcstrings 02:09:15. Scan: {'Clear text': 712, 'Cancel': 23}, 735 total in 363 files. type.json: status fail, 'typed state: text: reference "mp", clone…

### C2-m04-ui-13 — iOS 18 caret reports near the end of the text are dropped if TextSelection indices count UTF-8 (plausible)

- Verdict: **uncertain**; severity low; category bug; spec 12.5 (text selection observable and compared from iOS 18)
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:428-441`
- What: utf16Offsets accepts an index only if it is <= the endIndex of a string of N ASCII spaces, where N is the buffer's UTF-16 count. The comment claims this holds 'whichever encoding it counts in'. For a UTF-8-counted index it does not: the 3-byte sentinel alone makes the UTF-8 length exceed the UTF-16 length. Carets in the last positions are then rejected and the move goes unreported. Which encoding SwiftUI's TextSelection indices use was not verified, because no simulator was available.
- Skeptic: The conditional claim holds at the String level. A native string's end index is UTF-8-encoded (9[utf8]) and fails the guard against the 7-unit limit, while a UTF-16 bridged index (7[utf16]) passes. But the only device evidence points the other way. In ios-18.json cloneEventProfile[tap-text-deselects], the last entry, didChangeSelection(tokens: [], text: 6+0) after 4+0, can only come from inputSele…
- Repro: bridge.swift printed: 'native end: 9[utf8] accepted=false'; 'bridged end: 7[utf16] accepted vs native buffer=7..<7'. textlogic.swift: for "​harbor", native indices at UTF-16 offsets 6 and 7 are reject…

### C2-m04-ui-14 — Select-all then entering identical text is treated as backspace-at-start: it selects, then deletes, the last token

- Verdict: **partly**; severity low; category bug; spec 12.2 rule 3 (sentinel backspace), rule 12
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:231-234`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:389-399`
- What: Select-all followed by typing or pasting text identical to the current text is indistinguishable from backspace-at-start. The clone logs shouldChange(-1, 1, "", true) and selects the last token, and a repeat deletes it. What UIKit does here was never sampled, and given its token-spanning selection it probably does not 'keep the token'.
- Skeptic: The misclassification is real. Selecting all in the inner input covers the sentinel, so replacing the content with identical text loses the sentinel while the stripped text stays equal. Both the field and the core then treat it as backspace-at-start, which selects the last token and, on a repeat, deletes it. Replacing the content with different text is an ordinary change. The claimed UIKit behavio…
- Repro: textlogic.swift printed: 'tokens [Maps], text "a", select all, type "a": deleteBackwardAtStart (selects, then deletes, the last token)'. The same output was printed for a real backspace at start and f…

### C2-m05-adapters-01 — The section 15.9 gate over SQLite never runs in CI, and it failed in the one release run

- Verdict: **partly**; severity high → low; category test-integrity; spec 15.9; 17 milestone 2 gate; 18.1 packages 31-32
- Where: `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:68-71`, `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:179`, `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:35-39`, `.github/workflows/adapter-tests.yml:57-63`
- What: The real-SQLite 15.9 test always skips in CI (debug builds only), so adapter-side regressions of the 15.9 rows are not caught. The rows themselves are asserted in CI through core's in-memory fake (quality-targets job). The release-run failure is unverified and was against a host-scaled budget.
- Skeptic: Kept from the first run. testSection159TargetsOverSQLite throws XCTSkip under #if DEBUG (DatabaseTargetsTests.swift:68-71) and adapter-tests.yml runs only debug `swift test` and `swift test --sanitize=thread`, so the real-SQLite 15.9 test skips in every CI run. Overstated: ci.yml quality-targets runs core PerformanceTests in release, and testDatabaseSources (PerformanceTests.swift:571-657) asserts…
- Repro: debugflag/ 1-test SwiftPM package: `swift test` and `swift test --sanitize=thread` both take the #if DEBUG branch ('Executed 1 test, with 1 test skipped'). Only `swift test -c release -Xswiftc -enable…

### C2-m05-adapters-04 — The Qwen3 reference ModelAsset cannot be built from the package, and the documented way to complete it is circular

- Verdict: **partly**; severity medium → low; category spec-missing; spec 2 (package table: 'the Qwen3 asset descriptor'); 14.1 SHA-256 per file; 14.2 reference model
- Where: `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/Qwen3Asset.swift:6-25`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/Qwen3Asset.swift:89-99`, `Adapters/ZTronSearchEngineMLX/README.md:193-245`, `Adapters/ZTronSearchEngineMLX/Scripts/pin-qwen3-asset.swift`
- What: The MLX package ships only a partial Qwen3 manifest. A host must download config.json and tokenizer_config.json at the pinned commit by some means other than the AssetKit bridge, which refuses descriptors without SHA-256, then run Scripts/pin-qwen3-asset.swift once to obtain a usable ModelAsset. The README documents this.
- Skeptic: Real: the package ships no usable reference ModelAsset. Qwen3Asset exposes only the partial verifiedManifest, whose asset() throws missingChecksums, plus constructors that need a complete manifest. No complete manifest is in the repository, yet the README wiring loads 'qwen3-1.7b-4bit.manifest.json'. The integration tests use ModelAsset(files: []) for the runtime, which a host cannot do because Ch…
- Repro: manifest/ (the repo's ModelAssetManifest.swift minus its import, the bridge's 64-hex check): 'verifiedManifest.asset() throws missingChecksums(["config.json", "tokenizer_config.json"])'; 'a host-made …

### C2-m05-adapters-05 — Cancellation during the prompt prefill is not bounded by one token / 150 ms, and no test covers it

- Verdict: **partly**; severity medium → low; category spec-deviation; spec 15.6 'generation stops within one token, at most 150 ms'; 14.1 'honours task cancellation within one decoded token'
- Where: `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:424-442`, `Adapters/ZTronSearchEngineMLX/README.md:140-142`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:358-394`, `mlx-swift-lm@3b339ad6 Libraries/MLXLLM/LLMModel.swift`
- What: Cancelling during the prompt prefill leaves the runtime thread busy for the rest of the prefill chunk in flight, or the whole prompt forward for prompts up to 512 tokens, before .cancelled. No text streams meanwhile, and whether 15.6's 150 ms bound covers prefill is ambiguous; no test covers it.
- Skeptic: Mechanism confirmed against mlx-swift-lm 3b339ad6 (3.32.3, read with git show). The prefill runs in TokenIterator's init (MLXLanguageModel.swift:424-442). LLMModel.prepare hands a prompt of at most 512 tokens to the iterator whole (`guard total > stepSize`), with no cancellation check. The iterator submits it with asyncEval, and the first next() blocks in .item until that forward ends. GenerationL…
- Repro: Not runnable here (no Metal toolchain or device). Confirmed by reading mlx-swift-lm 3b339ad6 LLMModel.prepare, PrefillParameters.forEachChunk and TokenIterator.prepare/next, plus the adapter's code.

### C2-m05-adapters-06 — The 1.8 GB resident-memory test never samples the prefill peak

- Verdict: **partly**; severity medium → low; category test-integrity; spec 15.6 'Resident memory during generation: 1.8 GB'
- Where: `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:523-538`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:129-140`
- What: The 1.8 GB test samples the footprint only when visible deltas arrive, after MLX has already cleared the prefill's buffers. A peak during prefill, which is likely higher than decode but unmeasured, would go undetected.
- Skeptic: Confirmed: the test reads the current ri_phys_footprint only on .delta (Qwen3IntegrationTests.swift:525-538), so the prefill and the first forward are never sampled. Prefill transients are already released by the first delta: load sets MLX.Memory.cacheLimit to 32 MB (MLXLanguageModel.swift:209-210), and TokenIterator.next() calls MLX.Memory.clearCache() at tokenCount 0, right after the prefill. Wh…
- Repro: footprint/main.swift (the test's physicalFootprint() copied, a stand-in generation with a 600 MB mmap'd prefill transient released before 16 deltas): inside prefill 1051 MB; 'peak as the test samples …

### C2-m05-adapters-07 — An UPDATE that changes the rowid leaves a ghost document, and the README's list of unreported writes omits it

- Verdict: **confirmed**; severity low; category bug; spec 9.2 rule 5
- Where: `Adapters/ZTronSearchEngineSQLite/README.md:132-138`, `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/ChangeTracker.swift`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:603-610`
- What: For `UPDATE tools SET id = 30 WHERE id = 3`, where id is an INTEGER PRIMARY KEY (a rowid alias), the update hook reports only rowid 30. Core re-reads rowid 30 and adds tools#30. Rowid 3 is never named, so tools#3 stays in the index. The README lists writes the hook misses and tells the host to call reportUnknownChanges after them, but a rowid change is not on that list.
- Skeptic: Kept from the first run. For an INTEGER PRIMARY KEY renumbering, the update hook reports only the new rowid. Core re-reads rowid 30 and never visits state.rows[3], so tools#3 stays in the index. README.md:132-135 does not list a rowid change among the writes that need reportUnknownChanges. When the document id is not the rowid, the stale state.rows[3] mapping can later remove a live document if ro…
- Repro: hooks/main.swift: `UPDATE tools SET id = 30 WHERE id = 3` -> ['UPDATE tools rowid=30']; `UPDATE tools SET id = id + 100 WHERE id IN (1, 2)` -> ['UPDATE tools rowid=101', 'UPDATE tools rowid=102']. The…

### C2-m05-adapters-08 — ModelAssetManifest.validate(against:) does not tie a new SHA-256 to the Git blob id, as its docs claim

- Verdict: **confirmed**; severity low; category false-claim; spec 14.1 SHA-256 per file
- Where: `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ModelAssetManifest.swift:136-174`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/Qwen3Asset.swift:93-99`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3AssetTests.swift:11-12`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3AssetTests.swift:93-114`
- What: The docs say a SHA-256 that public metadata cannot confirm 'is accepted only together with the matching Git blob id, which ties it to the pinned commit'. validate(against:) only checks that the blob id is present and equal to the reference value. Nothing relates the blob id to the SHA-256, so any SHA-256 is accepted next to a copied blob id. The tie exists only inside Scripts/pin-qwen3-asset.swift, which hashes the local file both ways.
- Skeptic: validate(against:) checks only that the blob id is present and equal to the reference's (ModelAssetManifest.swift:159-173). Nothing relates it to the SHA-256, and nothing could without the bytes. The docs claim a tie: ModelAssetManifest.swift:141-142 says the blob id 'ties the new value to the pinned commit', and so do Qwen3Asset.swift:93-94 and README.md:243-244. The tie exists only in the pin sc…
- Repro: manifest/: a manifest with invented SHA-256 ffff...ffff for config.json and tokenizer_config.json plus copied blob ids -> validate(against:) accepts; the asset carries config.json=ffffffff.... The sam…

### C2-m05-adapters-09 — BundleLocalizedStringResolver returns the uppercased key as a string when NSShowNonLocalizedStrings is set

- Verdict: **partly**; severity low; category bug; spec 9.2 rule 3 (the raw key never enters the index)
- Where: `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/BundleLocalizedStringResolver.swift:64-67`
- What: With NSShowNonLocalizedStrings set, BundleLocalizedStringResolver returns the uppercased sentinel for missing keys, and core indexes it as that language's value (matching 'missing'). The raw key does not enter the index.
- Skeptic: Kept from the first run. The bug is real but the mechanism differs. Under NSShowNonLocalizedStrings, Foundation uppercases the value it would have returned, which is the SENTINEL passed as value:, not the key. The sentinel check fails on case, and the resolver returns '\u{1}ZTRONSEARCHENGINESQLITE.MISSING\u{1}'. Core indexes it because it differs from the key. So the uppercased sentinel, not the r…
- Repro: nslocal/: default -> resolver returns nil, not indexed; with -NSShowNonLocalizedStrings YES -> returns 'ZTRONSEARCHENGINESQLITE.MISSING' wrapped in \u{1}, core indexes it: true; with value: nil -> 'TO…

### C2-m05-adapters-11 — load() cannot be cancelled, and unload() during a load keeps about 1 GB until the weight read finishes

- Verdict: **confirmed**; severity low; category bug; spec 15.6 (on a memory warning the LLM unloads first)
- Where: `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:167-188`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:233-238`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:263-277`
- What: load() runs performLoad in an unstructured Task, and releaseModel() only clears pendingLoad. The pending task is never cancelled, and mlx-swift-lm's async loadWeights runs to completion on a global queue. A superseded load is thrown away only after the weights are fully read and materialized, and only then is clearCache() called.
- Skeptic: load() runs performLoad in an unstructured Task (MLXLanguageModel.swift:183-187), so the caller's cancellation does not reach it. releaseModel() only sets pendingLoad = nil and never cancels it (:268-277), and the superseded context is dropped only after LLMModelFactory.load returns (:233-238). Cancelling would not help: mlx-swift-lm's async loadWeights runs the whole read on DispatchQueue.global …
- Repro: loadunload/main.swift (the adapter's load, performLoad and releaseModel logic in an actor, the factory replaced by a 300 MB read on a global queue): unload() returned at 0.42 s at 128 MB, while the re…

### C2-m05-adapters-12 — The AssetKit adapter's tests run in no CI workflow

- Verdict: **confirmed**; severity low; category test-integrity; spec 17 milestone 8 gate (tests green in CI)
- Where: `.github/workflows/adapter-tests.yml`, `.github/workflows/ci.yml`, `.github/workflows/parity.yml`, `Adapters/ZTronSearchEngineAssetKit/Package.swift:16`
- What: No workflow mentions ZTronSearchEngineAssetKit, and the package depends on a sibling checkout of ZTronAssetKit that CI never makes. Its 103 tests (all passing locally per c2-assetkit-adapter.log) never run in CI.
- Skeptic: None of the three workflows builds or tests Adapters/ZTronSearchEngineAssetKit. adapter-tests.yml covers only the SQLite adapter, ci.yml covers root plus MLX, and parity.yml covers the parity host. No job checks out ZTronAssetKit, which the adapter needs as a sibling checkout or via ZTRON_ASSETKIT_PATH (Package.swift:16, 28). The root README lists the run only as a manual command (README.md:193). …

### C2-m05-adapters-13 — The asset's max_new_tokens can only lower the 512-token cap

- Verdict: **partly**; severity low; category spec-deviation; spec 14.2 'the asset's generation_config.json wins when present'
- Where: `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/SamplingPlan.swift:154-157`
- What: The asset's max_new_tokens can only lower the 512 default. This is documented in SamplingPlan and the README and consistent with core's non-optional maxNewTokens budget. It departs only from a literal reading of 14.2 and cannot reach the reference model.
- Skeptic: The behavior is confirmed: SamplingPlan.swift:154-157 lets the asset's max_new_tokens only lower the 512 default, against a literal reading of 14.2 ('the asset's generation_config.json wins when present'). 'Undocumented' is wrong: SamplingPlan.swift:118-119 and README.md:124-129 state that the asset can lower the default but never raise it. The choice is also defensible against core's own contract…

### C2-m05-adapters-14 — Calibration measures to the first visible delta, and the rate counts hidden leading tokens

- Verdict: **confirmed**; severity low; category spec-deviation; spec 14.4 calibration (TTFT <= 3 s, >= 8 tokens/s)
- Where: `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ChatCalibration.swift:23-24`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ChatCalibration.swift:163-202`
- What: TTFT is taken at the first .delta event. Tokens that the think filter or the detokenizer swallow before it push TTFT later, and the rate (generated - 1) / (finished - firstDelta) still counts them in the numerator, which overstates tokens/s. The effect is small with thinking off.
- Skeptic: TTFT is taken at the first .delta, and the rate is (generated - 1) / (end - firstDelta), with generated from .usage, which counts hidden tokens (ChatCalibration.swift:22-24, 175-178, 201-206). Tokens with no visible text before the first delta push TTFT later and inflate the rate. The effect is small in practice, as the auditor says. The calibration request is fixed with thinking off, so Qwen3's t…
- Repro: calibration/main.swift (the init arithmetic copied, a device at 2.0 s TTFT and a true 7.5 tok/s, 64 tokens): first visible delta at token 1 -> 2.00 s, 7.50 tok/s, fail (exact); token 3 -> 2.27 s, 7.75…

### C2-m05-adapters-15 — Stale 'expected to fail against core' comment in EndToEndTests

- Verdict: **confirmed**; severity low; category false-claim; spec 9.2 rule 5 (change stream tests)
- Where: `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/EndToEndTests.swift:383-392`
- What: The comment says three tests 'are expected to fail against the core this adapter was built with'. They pass, carry no XCTExpectFailure, depend on a commit landing inside a page read, and waitForFirstPage can skip. A reader cannot tell whether core was fixed or the race simply did not happen.
- Skeptic: Kept from the first run. EndToEndTests.swift:383-392 says three tests 'are expected to fail against the core this adapter was built with', but they carry no XCTExpectFailure and their doc comments describe passing behavior. Core now re-reads a table that changed during a read (SearchService+Context.swift:466-495, 516-528), so the comment is stale. The writes share the serial queue with the page re…

### C2-m05-adapters-16 — The SQLite README host-wiring sample is not the code ReadmeSampleTests runs

- Verdict: **partly**; severity low; category false-claim; spec 18.1 package 32 (host wiring sample)
- Where: `Adapters/ZTronSearchEngineSQLite/README.md:49-81`, `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/ReadmeSampleTests.swift:6-7`, `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/ReadmeSampleTests.swift:96-101`
- What: ReadmeSampleTests runs the README sample except for two argument lists (the resolver's bundles and the service's configuration). The guard misses drift only in those two calls.
- Skeptic: Kept from the first run and re-checked. The test differs from the README in two argument lists only. It uses BundleLocalizedStringResolver(bundles: [.main: strings]) (explained at :38) and an explicit SearchEngineConfiguration (:96-102). The README (:73, :76) uses BundleLocalizedStringResolver() and SearchService(context:), both of which compile with defaults. Every other line (schema, connect, Se…

### C2-m05-adapters-17 — MLX README drift: 'absolute path' note and the unit-test count

- Verdict: **confirmed**; severity low; category false-claim; spec none (documentation)
- Where: `Adapters/ZTronSearchEngineMLX/README.md:54-55`, `Adapters/ZTronSearchEngineMLX/README.md:251`, `Adapters/ZTronSearchEngineMLX/Package.swift:20-23`
- What: The README says 'Package.swift points at core with an absolute path. It becomes ../..', but it is already "../..". It also says '149 tests', while the unit-test files contain 150 test methods (Qwen3IntegrationTests excluded).
- Skeptic: README.md:54-55 says Package.swift uses an absolute path that 'becomes ../..', but Package.swift:20-23 already has path: "../..". README.md:251 says '149 tests', but the unit-test files (Qwen3IntegrationTests excluded) hold 150 no-argument test methods, all inside XCTestCase classes. The two #if blocks in MLXLanguageModelTests sit inside test bodies and remove no method. This is documentation drif…
- Repro: Per-file counts of no-argument test methods: ChatCalibration 17, Executor/Cancellation 11, GenerationLoop 19, JSONConfig 6, LocalTokenizer 16, MLXLanguageModel 24, Qwen3Asset 17, SamplingPlan 19, Thin…

### C2-m06-tests-gates-05 — The engine-level stale-snapshot test over 10,000 changes cannot detect the property its doc comment states

- Verdict: **partly**; severity medium → low; category test-integrity; spec 15.4 (zero stale snapshots over 10,000 randomized query changes); 16 (stale-result suppression with randomized query sequences)
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:157-221`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:167-178`
- What: The engine-level 10,000-change test checks consistency, not ordering. The ordering property is covered at the UI boundary and by testAnObsoleteProducerNeverYields, and the stated regression would not reopen late publication.
- Skeptic: Real: the Ledger compares each snapshot only with its own stream's query and first generation, so the doc comment's 'never yields again' is not checked by this test. Overstated on three counts. The spec property concerns published snapshots, which ResultsModelTests checks over 10,000 randomized changes. Engine-side suppression is asserted by testAnObsoleteProducerNeverYields. The failure scenario …

### C2-m06-tests-gates-06 — The release quality suites failed on this Mac in every run (RRF fusion and the 15.9 database targets), and the SQLite release targets failed too

- Verdict: **partly**; severity medium → low; category performance; spec 15.1 (RRF fusion 0.5 ms); 15.9 (10k-row context 1.5 s, 500-row page 40 ms, upsert of 100 rows 50 ms)
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:173`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:590`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:616`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:638`
- What: At moderate load the fusion and page targets pass with margin, and context creation almost always passes. The only check that still fails is the 15.9 incremental-upsert p95, intermittently and with a median under half the 8.33 ms allowance, because of scheduling tails in a busy-polled second-worst-of-40 measurement. The quality-targets job is plausibly flaky because of that check; no target is shown to be missed.
- Skeptic: The auditor's failures came from runs at load 370 and 8.4 with 12 simulators booted. Re-measured at load 5.2-7.4 on 8 cores. RRF fusion passes (0.068-0.069 ms vs 0.083 ms allowed; wall time equals thread CPU time). Scaled by 6 that is 0.41 ms, under the 0.5 ms budget, so the 0.66 ms device extrapolation is refuted. One page of 500 rows passes in every run (4.0-6.35 ms vs 6.67 ms). Context creation…
- Repro: Unmodified release PerformanceTests in a scratch copy: 2 failures, creation 262.0 ms and upsert 20.8 ms; fusion 0.068 ms passed. testDatabaseSources repeated 5 times: creation 187-214 ms, page 4.2-6.3…

### C2-m06-tests-gates-07 — The filter/kind precision gate and the hard-constraint test pass when the engine returns nothing

- Verdict: **partly**; severity medium → low; category test-integrity; spec 15.3 (filter and kind tokens: precision 1.0); 16 (filters and kind tokens as hard constraints)
- Where: `Sources/ZTronSearchFixtures/RelevanceMetrics.swift:67-72`, `Tests/ZTronSearchEngineTests/GoldenGates.swift:38-39`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:185`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:196`
- What: The filterAndKind gate passes vacuously for empty lists, so a regression that empties some golden constrained queries is invisible to it. Emptying all of them is caught by CoreCorrectnessTests.
- Skeptic: Real: precision([]) is 1, the filterAndKind gate is precision alone, the hard-constraint test inspects only returned hits, and no gate uses the golden filterAndKind judgments. Overstated: an engine that returned empty lists for every kind or filter query would turn the unit job red through CoreCorrectnessTests (testFiltersAndKindTokensAreHardConstraints and others, not skipped in debug). What slip…
- Repro: Probe at 5,000 and 100,000 distractors: 'gate value if every filterAndKind list were empty: 1.0000'. Today 0 of 69 constrained lists are empty, the source item is returned for all 69, and recall@10 is…

### C2-m06-tests-gates-08 — 'Relevance gates among 100,000 distractors' adds no competition: distractors are built never to match a golden query, and the numbers are identical at 5,000 and 100,000

- Verdict: **partly**; severity medium → low; category false-claim; spec 15.3; section 15 preamble (100k items)
- Where: `Sources/ZTronSearchFixtures/SyntheticCorpus.swift:14-23`, `Sources/ZTronSearchFixtures/SyntheticVocabulary.swift:53`, `README.md:179-180`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:43-46`
- What: By construction the distractors are easy negatives that almost never outrank judged hits, so the gated means stop moving after 5,000. They still compete: they match through body and localized lemmas, typo neighbours and filters, fill more top-10 slots at 100,000, and move typo recall and several ungated NDCG figures. What the gates cannot see is title-level near-miss competition beyond the 420 golden items.
- Skeptic: Confirmed in code: distractor titles and keywords are pseudo-words; no pseudo-word starts with the first three letters of any lemma, synonym or Italian/German form; base-body lemmas appear only from word 24; synonyms and reserved translations never appear. The gated RELEVANCE rows are identical at 5,000 and 100,000. Refuted: 'adds no competition' and 'built never to match a golden query'. Distract…
- Repro: Probe (release, scratch copy). From 0 to 5,000 distractors, lexical typo recall falls 1.0000 to 0.9855. Queries with a distractor in the top 10, 5,000 to 100,000: lexical exactTitle 12 to 51 of 60, ty…

### C2-m06-tests-gates-10 — CI never runs the SQLite adapter's release DatabaseTargetsTests, and run here it fails the upsert target

- Verdict: **confirmed**; severity medium → low; category spec-missing; spec 15.9; 17 milestone 2 gate (adapter integration tests and the 15.9 targets)
- Where: `.github/workflows/adapter-tests.yml:56-63`, `README.md:188-191`, `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:70`, `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:179`
- What: The adapter workflow runs swift test and swift test --sanitize=thread, both debug builds. In debug, DatabaseTargetsTests throws XCTSkip. No job runs it in release. README:188-191 presents that release command as the place where the adapter 'asserts the section 15.9 targets against a real database'.
- Skeptic: The CI gap is confirmed: adapter-tests.yml runs only debug `swift test` and `--sanitize=thread`, where DatabaseTargetsTests throws XCTSkip, and no workflow runs the adapter in release. Severity is lowered because the same 15.9 budgets run in CI against the in-memory fake, as spec 16 prescribes for core tests, and README:188-191 claims nothing about CI. 'One target is already failing' is intermitte…
- Repro: SQLite release DatabaseTargetsTests built offline in a scratch copy and run 5 times at load about 7.3: upsert p95 OVER once (13.545 ms, p50 2.7 ms), within four times (2.674-5.447 ms); all other targe…

### C2-m06-tests-gates-11 — The semantic, cross-language and rerank gates are reached only with oracle fakes built from the queries' own lexicon; the rerank stage changes no metric, so 'never below fused' holds by equality

- Verdict: **partly**; severity low; category test-integrity; spec 15.3 (paraphrase recall 0.75, cross-language recall 0.70, reranked NDCG 0.85 and never below fused)
- Where: `Sources/ZTronSearchFixtures/FakeEmbeddingProvider.swift`, `Sources/ZTronSearchFixtures/FakeReranker.swift`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:217-224`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:265-281`
- What: The rerank gates rest on oracle fakes, and the reranked-NDCG gate would pass with the fused order. 'Never below fused holds by equality' is true only at 100,000 distractors; at the default 5,000 the reranker improves NDCG@10 for paraphrase and cross-language. The fused-order bug is caught by SnapshotPipelineTests.
- Skeptic: Revised from the first run's 'confirmed', using the probe that run wrote for this finding. What stands: the semantic, cross-language and rerank gates are reached only with oracle fakes built from the queries' own lexicon. testRerankedHeadNDCG would pass with the fused order unchanged, because fused NDCG@10 is already at or above 0.85 and the 'never below fused' check holds by equality. The gated R…
- Repro: PROBE11 at 5,000 distractors (the size the debug unit job uses): the reranked top 10 differs in 45 of 483 queries; NDCG@10 rises for paraphrase (0.9696 to 0.9939) and crossLanguage (0.9745 to 0.9806).…

### C2-m06-tests-gates-12 — The 'timeout-guarded' deadlock test cannot time out, because withTaskGroup waits for the hung child

- Verdict: **partly**; severity low; category test-integrity; spec Section 11 liveness table (no deadlock: Thread Sanitizer in CI; timeout-guarded tests)
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:19-30`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:248-296`
- What: The guard catches cancellable hangs, such as a stuck stream or a sleep, but not the lost-continuation or blocked-thread hangs its message names. Those are ended only by the CI job timeout.
- Skeptic: withTaskGroup waits for every child, so the timeout works only for hangs that respond to cancellation. A lost continuation or a blocked thread in the directly awaited call hangs the test until the CI job timeout.
- Repro: with_timeout_skeptic.swift (verbatim copy of withTimeout): with a lost continuation and with a blocked semaphore, it was still waiting 3.1 s after a 0.5 s timeout. An unfinished AsyncStream and a one-…

### C2-m06-tests-gates-13 — Several bounded-work and context tests check proxies that cannot fail for the property they name

- Verdict: **partly**; severity low; category test-integrity; spec Sections 10 and 11 (bounded work: 2,000 candidates); 16 (no disk I/O for a context; no growth over 1,000 create-and-release cycles); 15.1 (cold start)
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:328-348`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:143`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:279-299`, `Tests/ZTronSearchEngineTests/SearchContextTests.swift:294-309`
- What: (b) and (d) as described. (a) The cap mechanism and the default are covered by the limit-50 sub-check and :143. (c) Only a non-retaining, id-keyed leak would slip past the test.
- Skeptic: (a) The first two assertions hold without a 2,000 cap, but the limit-50 sub-check exercises the cap and PerformanceTests:143 fails if the default is raised, so 'cannot fail' is too strong. (b) True: only the directory's existence is checked, so a read is invisible. (c) The id is reused and 2 MB is tolerated, but the weak-reference check catches any registry that retains the service; only an id-key…

### C2-m06-tests-gates-14 — README and CI comments the configuration does not keep

- Verdict: **confirmed**; severity low; category false-claim; spec 16 (performance tests record baselines on the reference device); CI documentation
- Where: `README.md:209-210`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:57-61`, `.github/workflows/ci.yml:64-67`, `.github/workflows/parity.yml:67`
- What: (a) README says PerformanceTests 'carries XCTClockMetric and XCTMemoryMetric baselines to record there', meaning on the device. But setUpWithError skips the whole class in DEBUG, which is Xcode's default test configuration for a device run, and nothing explains how to run a Release build with testability on the device. (b) ci.yml calls ['15.5', '18.6'] 'The floor and the current release', while parity.yml and ParityHost/ReferenceSnapshots already use iOS 27.0. (c) The 'strictly: the day it is met' comment is covered in finding 01.
- Skeptic: setUpWithError skips all 17 PerformanceTests under DEBUG, and the README does not say how to run Release with testability on a device to record the baselines. ci.yml calls 15.5 and 18.6 'the floor and the current release', while parity.yml and ParityHost already target iOS 27.0, and 15.5 is not the package floor (.iOS(.v15)). These are documentation issues only.


## None

### C2-m05-adapters-10 — A public initializer can trap the process: preconditionFailure in SearchBindingValue.init(_:)

- Verdict: **partly**; severity low → none; category api; spec 9.2 rule 8 (adapter maps bindings)
- Where: `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteBindings.swift:36-37`
- What: SearchBindingValue.init(_:) traps only for a Binding conformance that SQLite.swift's own documentation forbids and that SQLite.swift would trap on anyway. It is a documented precondition, not a defect.
- Skeptic: Kept from the first run. The trap at SQLiteBindings.swift:36-37 exists, but it is a documented precondition (:17-19). SQLite.swift 0.17.0 itself says 'Do not conform custom types to the Binding protocol' (Value.swift:25-30) and fatalErrors on the same value (Statement.swift:121). Its own conformances (Double, Int64, String, Blob, Bool, Int) are all mapped, and Date, Data and UUID reach bindings as…


## What the auditors did not get to

- **m01-text-index**: No device-only budgets: there is no device. Not read: the rest of the Service, Database, Chat and Semantic code; most test bodies in CoreCorrectnessTests and IndexMaintenanceTests (names and some parts were read); HighlighterTests beyond the fast path. Findings -08 and -09 come from code reading only and were not executed. Two issues were noted but not reported because they seem unreachable in practice: a DocumentCodec language-count mismatch on hand-written JSON, and TokenSpan.piece being a UIn…
- **m02-query-service**: I did not run the package's own test targets, because that is forbidden. I also made no device, simulator or release-build measurement of the section 15 budgets. The performance numbers come from two sources: a debug-build copy of the library (finding 11), and an optimized standalone copy of SearchDateParser (finding 09). Both ran on a Mac that other jobs may have been using at the same time. For confirmations, I copied the engine and fixture sources into the scratchpad and compiled them there w…
- **m03-semantic**: Nothing was run against a real Core ML model or real Hugging Face tokenizer files. So Core ML load and prediction, the resident memory of a loaded model, reload time, and token-id parity of the Swift WordPiece/Unigram tokenizers with the reference tokenizers are unverified. The Python conversion scripts were read, not executed (no coremltools or torch), so vocabulary pruning was not exercised. There were no device or simulator runs: iOS 15 behaviour of NotificationCenter.notifications(named:) an…
- **m04-ui**: ParityHost Sources not read: ReferenceSampler.swift (654 lines, how metrics and colors are sampled), most of ReferenceField.swift, ReferenceField+Layout.swift, ParityStage.swift, ParityProtocol.swift, Diagnostics.swift, SymbolLab.swift, ParitySchema.swift, ParityHost.swift. App not read: AppMain.swift, ParityMatrixUITests.swift, DiagnosticsUITests.swift, Xcode project/scheme. Tools: sample.py and matrix.py after line 120 not read. Tests: ComparatorTests bodies and the rest of HostCapabilityTests…
- **m05-adapters**: The AssetKit adapter's scripted-client tests were not read line by line: AvailabilityTests, FetchTests, PlanAndLaneTests, PolicyTests, SharingAndEvictionTests, Support/MemoryOrigin and Support/ScriptedAssetClient. I only grepped them for test names and weak-assertion patterns. I read about half of RealClientTests. Of the MLX unit tests, I read four files in full (ExecutorAndCancellation, MLXLanguageModel, Qwen3Asset, Qwen3Integration); the rest (GenerationLoop, ThinkBlockFilter, SamplingPlan, Ch…
- **m06-tests-gates**: Not read:
- Fixtures: FakeChatBoundaries, CatalogSchema, FixtureLexicon, FixtureLexiconData, GoldenPhrases.
- Fixture tests: GoldenCorpusTests, FakeEmbeddingTests, LexiconTests.
- Engine test suites: ChatTests, CoreCorrectnessTests, FuzzyChannelTests, HighlighterTests, IndexMaintenanceTests, RankingTests, SmokeTests, TextPipelineTests. DatabaseSourceTests was only grepped.

Not determined:
- Whether GitHub's macos-latest image has the iOS 15.5 simulator runtime that the ios job requests.
- Wheth…

STATUS: complete
