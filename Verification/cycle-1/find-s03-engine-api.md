# Cycle 1 / s03-engine-api — sections 9, 10, 11 (pages 15-25)

Auditor: s03-engine-api (requirement-centric). Repository commit cee4620.
Method: every normative statement of sections 9, 9.1, 9.2, 10 and 11 traced to code and tests; suspected
defects confirmed with a standalone build of a verbatim copy of `Sources/ZTronSearchEngine` plus the
`FakeSearchDatabase` fixture, compiled with `swiftc -swift-version 6 -Onone` in
`/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s03-engine-api/`
(harness: `harness/Repro.swift`, binary `repro`, scenarios A-G). Nothing was built in the repository.
Test evidence: `Verification/_runs/c1-debug-swift-test.log` (complete, EXIT 0; ZTronSearchEngineTests 279
tests, 18 skipped: 17 PerformanceTests skip outside release, 1 tuning sweep; 0 failures).

Path conventions: code paths are relative to `Sources/ZTronSearchEngine/` unless they start with
`Sources/`, `Adapters/` or `Tests/`; test paths are relative to `Tests/ZTronSearchEngineTests/` except
`ResultsModelTests.swift` (in `Tests/ZTronSearchEngineUITests/`). "UI model" =
`Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift`.

## Requirement table

| R# | Sec/page | Requirement | Status | Code | Test |
|----|----------|-------------|--------|------|------|
| R1 | 9 p15 | A query yields a stream of snapshots tagged with a generation | met | Service/SearchService.swift:278-296, 464-479 | ConcurrencyTests.swift:159 |
| R2 | 9 p15 | SearchQuery<Schema> fields, defaults (limit 20), token merging, init(text:tokens:filters:kinds:) | met | Contracts/SearchQuery.swift:24-92 | CoreCorrectnessTests.swift:375 |
| R3 | 9 p15 | SearchPhase lexical/semantic/reranked | met | Contracts/SearchDocument.swift:38 | SnapshotPipelineTests.swift:15,300 |
| R4 | 9 p15 | SearchHit<Kind> members (channels incl. .rerank, matchedField, matchedLanguage, highlights) | met | Contracts/SearchHit.swift:4-34 | CoreCorrectnessTests.swift:396 |
| R5 | 9 p16 | SearchSnapshot members; hitsByKind keeps fused order; contextID | met | Contracts/SearchHit.swift:55-92 | CoreCorrectnessTests.swift:182 |
| R6 | 9 p16 | SearchService<Schema> actor API (init, index, results, page, suggestions, setLocale) | met (the spec spelling `[any Searchable<Kind>]` needs the iOS 16 runtime, so it is exposed under @available(iOS 16) with generic overloads on the iOS 15 floor; extra defaulted `trigger:`) | Service/SearchService.swift:154-196, 278, 300, 818, 892 | SearchContextTests.swift:206 |
| R7 | 9 p16 | LexicalIndex actor upsert/remove/load (memory-mapped, versioned)/save | met | Index/LexicalIndex.swift:74-110, 151-207; Support/FileIO.swift:30-36 | StrategyParityTests.swift:99,136,161,187 |
| R8 | 9 s1 p16 | First snapshot .lexical: lexical+fuzzy fused by RRF within the lexical budget | met (budget part unverifiable-here, device figure) | Service/SearchService.swift:396-422; Service/SearchPipeline.swift:84-104 | SnapshotPipelineTests.swift:15; PerformanceTests (release only) |
| R9 | 9 s2 p16 | Second snapshot re-fuses cached lexical lists; skipped+degraded for <3 chars, pure filter/ID, budget breach | met | Service/SearchService.swift:404-441, 520-614; Service/SearchPipeline.swift:51-63 | CoreCorrectnessTests.swift:89,320; SnapshotPipelineTests.swift:33,62,154 |
| R10 | 9 s3 p17 | Third snapshot reorders top 16 past the gate; skipped+degraded when the 2nd is skipped or the cap is breached | met | Service/SearchService.swift:443-461, 627-738; Service/SearchPipeline.swift:155-184 | SnapshotPipelineTests.swift:300,375,391 |
| R11 | 9 s4 p17 | isFinal on the last snapshot the device produces | met | Service/SearchService.swift:420-458 | SnapshotPipelineTests.swift:73; SearchContextTests.swift:124 |
| R12 | 9 s5 p17 | Unknown stored kind dropped and logged; hitsByKind partitions without reordering | met | Service/SearchPipeline.swift:108-141 | CoreCorrectnessTests.swift:182,199 |
| R13 | 9 s6 p17 | Foreign Filter type: debug assertion, filters dropped in release | met | Service/SearchService.swift:984-1001; Support/Diagnostics.swift:20-31 | CoreCorrectnessTests.swift:245 |
| R14 | 9 s7 p17 | Cancelling the consumer terminates the stream and cancels the producer via onTermination | met | Service/SearchService.swift:286-295 | ConcurrencyTests.swift:119 |
| R15 | 9 s8 p17 | Paging continues the final list; stale generation throws staleGeneration | met (overflow trap in the slice arithmetic, -05) | Service/SearchService.swift:300-307, 464-479 | SnapshotPipelineTests.swift:443,473 |
| R16 | 9 s9 p17 | Incremental indexing: upsert/remove take effect for the next query, no rebuild | partial: undone when they race a rebuild (-01) or an .automatic promotion (-04) | Service/SearchService.swift:199-255; Index/LexicalIndex.swift:460-507 | StrategyParityTests.swift:47; ConcurrencyTests.swift:298 (no rebuild in flight) |
| R17 | 9.1 p17 | SearchContext<Schema> value: id, items, locale?, strategy=.automatic, init | met (items as `[any Searchable<Kind>]` on iOS 16+, generic init on iOS 15) | Contracts/SearchContext.swift:57-149 | SearchContextTests.swift:195,206 |
| R18 | 9.1 p17 | SearchStrategy automatic (scan <= 500), scan, indexed | met | Contracts/SearchContext.swift:4-11; Service/SearchService+Context.swift:98-104, 262-268; Contracts/SearchEngineConfiguration.swift:172 | SearchContextTests.swift:97 |
| R19 | 9.1 p18 | init(context:) ready on return, scan touches no disk; replace(items:); contextID | partial: memory contexts ready on return (database contexts load in the background, waitUntilReady); replace(items:) not guarded against an in-flight rebuild (-01) | Service/SearchService+Context.swift:12-63, 239-259; Service/SearchService.swift:14 | SearchContextTests.swift:172,294 |
| R20 | 9.1 p18 | ScanIndex<Schema> value: init(items:locale:profile:), hits(for:) in one pass, count | met (overflow trap, -05) | Scan/ScanIndex.swift:8-98 | SearchContextTests.swift:256,278 |
| R21 | 9.1 r1 p18 | Contexts disjoint; ids unique per context; snapshot.contextID | met | per-actor state, Service/SearchService.swift:12-70; Contracts/SearchHit.swift:66 | SearchContextTests.swift:25,77 |
| R22 | 9.1 r2 p18 | Each context has its own Schema; generic over Schema | met | SearchService<Schema>, SearchContext<Schema> | SearchContextTests.swift:25 |
| R23 | 9.1 r3 p18 | Scan: project once; same BM25F/weights/fuzzy/RRF; identical ranking (property test); DL with length pre-check; direct prefix | met | Scan/ScanEngine.swift:32-251, 376-441; Query/QueryPlanner.swift | StrategyParityTests.swift:16 (36 random corpora of 1..500 documents) |
| R24 | 9.1 r4 p19 | Scan: no debounce, one final snapshot; semantic only with vectors, brute force, never HNSW; encoding behind the pause | met | Service/SearchService.swift:393-395, 520-525, 559, 609-612; Scan/ScanEngine.swift:335-361 | SearchContextTests.swift:124,139 |
| R25 | 9.1 r5 p19 | Localization, filters, kinds, profile, signals apply in every context; own locale | met | Service/SearchService+Context.swift:82-87 | SearchContextTests.swift:234 |
| R26 | 9.1 r6 p19 | Cheap create/discard; scan never touches disk; release frees all; replace rebuilds in place; indexed persists under its own file keyed by contextID + projectionVersion | partial: file keyed correctly, but adopted on a fingerprint that ignores most content (-03) | Service/SearchService+Context.swift:122-153, 181-206, 653-669 | SearchContextTests.swift:294,311,342 |
| R27 | 9.1 r7 p19 | Several contexts at once; the 500 threshold applies per context | met | per-service configuration.scanThreshold | SearchContextTests.swift:97; ResultsModelTests.swift:251 |
| R28 | 9.2 p19 | Core never imports SQLite.swift; the only SQL core composes is the SELECT | met | no `import SQLite` under Sources/; Database/SearchSQLComposer.swift:39-92 | DatabaseSourceTests.swift:170 |
| R29 | 9.2 p19 | SearchSQL, SearchBindingValue, SearchDatabaseLocation, SearchDatabase.open | met | Contracts/DatabaseBoundary.swift:7-64 | DatabaseSourceTests.swift:131 |
| R30 | 9.2 p20 | SearchDatabaseConnection read (deferred) / write (commit/rollback) / changes / close | met | Contracts/DatabaseBoundary.swift:67-75; Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/ConfinedConnection.swift | adapter suites (not run here) |
| R31 | 9.2 p20 | Reader / Writer / SearchRow / SearchDatabaseChange (nil rowIDs = whole table) | met | Contracts/DatabaseBoundary.swift:77-105 | DatabaseSourceTests.swift:540 |
| R32 | 9.2 p20 | SearchStringEncoding literal / localizedKey / perRow; SearchStringField | met | Contracts/DatabaseBoundary.swift:125-149 | DatabaseSourceTests.swift:262 |
| R33 | 9.2 p20-21 | SearchTableSource members; id "<table>#<id>"; updatedAt feeds Temporal | met | Contracts/DatabaseBoundary.swift:176-234; Database/SearchRowProjector.swift:71-77, 174-178 | DatabaseSourceTests.swift:370,382 |
| R34 | 9.2 p21 | SearchSource; context sources, localizedStrings, indexStorage (.files default, .database(tablePrefix:)) | met (adds .inMemory) | Contracts/SearchContext.swift:14-35, 57-83 | DatabaseSourceTests.swift:334,763 |
| R35 | 9.2 p21 | LocalizedStringResolving | met | Contracts/DatabaseBoundary.swift:241-244 | DatabaseSourceTests.swift:297 |
| R36 | 9.2 r1 p21 | One SELECT shape with LIMIT 500 OFFSET n; quoted identifiers; no DDL/DML on host tables | met (adds a `rowid` column and `rowid IN (...)` for change re-reads) | Database/SearchSQLComposer.swift:39-92 | DatabaseSourceTests.swift:102,131,170 |
| R37 | 9.2 r2 p21 | Each page in its own deferred read transaction | met | Database/SearchSQLComposer.swift:124-144 | DatabaseSourceTests.swift:188,205,232 |
| R38 | 9.2 r3 p21-22 | Same projector; literal keeps its tag; keys resolved with the fallback chain; other languages to localizedAlt; unresolved key indexes nothing, logged in debug, raw key never indexed | partial: a key whose string equals the key is treated as unresolved (-02) | Database/SearchRowProjector.swift:70-179 | DatabaseSourceTests.swift:262,297,315 (dotted keys only) |
| R39 | 9.2 r4 p22 | Mixed sources: one set, one strategy by total size, one ranking; filters via init?(key:value:); cross-source id collisions debug-asserted | met | Service/SearchService+Context.swift:362-412; Database/SearchRowProjector.swift:163-172 | DatabaseSourceTests.swift:347,397,464 |
| R40 | 9.2 r5 p22 | Change stream batched per commit; rowids re-read; nil rowids refresh the table; refresh() | met | Service/SearchService+Context.swift:43-45, 502-628 | DatabaseSourceTests.swift:493-739 |
| R41 | 9.2 r6 p22 | .database(tablePrefix:) persistence through a write transaction, atomic generation swap | met | Database/DatabaseIndexStore.swift:65-150; Service/SearchService+Context.swift:662-664 | DatabaseSourceTests.swift:763,793,841,864 |
| R42 | 9.2 r7 p22 | Boundary Sendable and self-serializing; adapter's documented @unchecked Sendable | met | Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteSearchConnection.swift:13-94 | adapter suites (not run here) |
| R43 | 9.2 r8 p22 | Adapter maps file / in-memory / read-only, read/write transactions, update + commit hooks, Expression/Table; no FTS | met (by reading) | Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/ConfinedConnection.swift:18-63, ChangeTracker.swift, SQLiteExpressions.swift | adapter suites (not run here) |
| R44 | 10 p22 | Lexical on every debounced keystroke; semantic after a pause or on submit; a new keystroke cancels both | met | Service/SearchService.swift:278-296, 393-428 | SnapshotPipelineTests.swift:112,132 |
| R45 | 10 p23 | Debounces 120/300 ms; fuzzy when the longest token has >= 3 characters; suggestions at >= 2 on the lexical timer; scan synchronous | met for debounces, fuzzy and scan; suggestions use a separate 120 ms timer (-09) | Contracts/SearchEngineConfiguration.swift:162-170; Query/QueryPlanner.swift:109-110; UI model:226, 235-259 | SnapshotPipelineTests.swift:112; ResultsModelTests.swift:293,317 |
| R46 | 10 p23 | Never encode a query embedding on every keystroke | met | Service/SearchService.swift:424-429 | SnapshotPipelineTests.swift:83 |
| R47 | 10 p23 | Rerank once per query after the semantic snapshot, past the gate only | met | Service/SearchService.swift:443-461, 627-660 | SnapshotPipelineTests.swift:300,338,358 |
| R48 | 10 p23 | <3 characters or tokens only: skip semantic and rerank | met | Service/SearchPipeline.swift:51-63; Service/SearchService.swift:646 | CoreCorrectnessTests.swift:89,320; SnapshotPipelineTests.swift:375 |
| R49 | 10 p24 | Debounce with Task.sleep(nanoseconds:), cancelled per keystroke | met | Service/SearchService.swift:482-490 | ConcurrencyTests.swift:34 |
| R50 | 10 p24 | INT8 vectors <= 384 dimensions, memory-mapped | met (by reading, Semantic product) | Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:113,141 | not traced |
| R51 | 10 p24 | Item vectors precomputed; only the query is encoded | met | Service/SearchService.swift:547-614 | SearchContextTests.swift:139 |
| R52 | 10 p24 | Embedding model lazy; unloaded after 60 s idle or on a memory warning | met (core side; lazy load inside the Semantic product not traced) | Service/SearchService.swift:744-803; Contracts/SearchEngineConfiguration.swift:167 | SnapshotPipelineTests.swift:216,239,249 |
| R53 | 10 p24 | Lexical index files mapped with .mappedIfSafe | met | Support/FileIO.swift:30-36 | StrategyParityTests.swift:99 |
| R54 | 10 p24 | Bounded work 2000 / 8 / 50 / 600 / 16 / 200 | met | Contracts/SearchEngineConfiguration.swift:42-56; Index/IndexSearcher.swift:673-708; Query/QueryPlanner.swift:142,168; Service/SearchPipeline.swift:101-103 | ConcurrencyTests.swift:328,350; SnapshotPipelineTests.swift:505 |
| R55 | 11 p24 | Swift 6 language mode; public types Sendable | met | Package.swift swiftLanguageModes [.v6] | compiles (debug log) |
| R56 | 11 r1 p24 | Mutable state in actors; UI models @MainActor | met | SearchService / LexicalIndex actors; UI model:11, 217 | n/a |
| R57 | 11 r2 p24 | Structured tasks for searches; Task.detached only for index loading at .utility | met (the unstructured Task in results(for:) is inherent to the AsyncStream API) | Service/SearchService+Context.swift:25 | SourceLint fixtures |
| R58 | 11 r3 p24 | A newer query cancels the prior task before any work starts | met | Service/SearchService.swift:280-284 | ConcurrencyTests.swift:142 |
| R59 | 11 r4 p24 | checkCancellation at least every 1,000 postings and every 100 HNSW visits | partial: indexed path every 1,000 postings, HNSW every 64 visits, scan path every 256 documents (-07) | Index/IndexSearcher.swift:685,789,852; Scan/ScanEngine.swift:149; Sources/ZTronSearchEngineSemantic/HNSW/HNSWOperation.swift:106-112 | ConcurrencyTests.swift:49 (indexed only, loose bound -10) |
| R60 | 11 r5 p24 | Every await inside SearchService is followed by a generation check before state is touched | contradicted (-01, -04) | Service/SearchService.swift:199-207, 242-255, 892-903; Service/SearchService+Context.swift:227-259, 336-418 | none |
| R61 | 11 r6 p24 | The UI boundary checks generation and query equality | met (see -08 for a consequence) | UI model:128-142 | ResultsModelTests.swift:119,153 |
| R62 | 11 r7 p24 | Never block the pool; only synchronous file calls are mmap open/close | met | Support/FileIO.swift:8-51; adapter's own queue | SourceLint fixtures |
| R63 | 11 r8 p25 | No @unchecked Sendable outside the HNSW wrapper (plus the adapter connection) | met (only Adapters/.../SQLiteSearchConnection.swift:41) | grep | SourceLint fixtures |
| R64 | 11 liveness p25 | Cancellation honoured within 10 ms at the next checkpoint; tests before, during and after index search | unverifiable-here (10 ms is a device figure); tests exist, the during-search bound is loose (-10) | Index/IndexSearcher.swift checkpoints | ConcurrencyTests.swift:34,49,109 |
| R65 | 11 liveness p25 | No stale results; randomized property test, zero stale | met (UI corner case -08) | Service/SearchService.swift:362-384; UI model:130-131 | ConcurrencyTests.swift:159,223; ResultsModelTests.swift:119 |
| R66 | 11 liveness p25 | No deadlock; TSan in CI; timeout-guarded tests | met | .github/workflows/ci.yml thread-sanitizer job | ConcurrencyTests.swift:248 |
| R67 | 11 liveness p25 | Bounded work: limit unit tests; 100k performance tests | met (performance tests only in the release CI job) | as R54 | ConcurrencyTests.swift:328,350; PerformanceTests (release) |
| R68 | 11 liveness p25 | Search work off the main actor; publishing 20 hits < 1 ms on main | unverifiable-here (device figure); search off main met, scan contexts run on main by design of 9.1 | UI model:100-125 | ResultsModelTests.swift:268 (Mac, scaled budget) |
| R69 | 11 liveness p25 | Search tasks cancelled on dismissal, reset and locale change | met | UI model:56-99; Service/SearchService.swift:892-903 | ResultsModelTests.swift:78,209; SearchContextTests.swift:342 |

Totals: 69 requirements; met 61, partial 5 (R16, R19, R26, R38, R59), missing 0, contradicted 1 (R60),
unverifiable-here 2 (R64, R68).

## Findings

### C1-s03-engine-api-01 — index/remove/replace racing a rebuild are silently undone (critical, concurrency)
Spec: section 11 rule 5 (p24: every await inside SearchService is followed by a generation check before
state is touched); section 9 rule 9 (p17: upsert and remove take effect for the next query); section 9.2
rule 5.
Locations: Sources/ZTronSearchEngine/Service/SearchService.swift:199-207 (remove), 242-255 (upsert),
892-903 (setLocale); Sources/ZTronSearchEngine/Service/SearchService+Context.swift:239-259
(replaceMemory), 330-418 (rebuild / rebuildLocked).
`rebuildLocked` projects `memoryItems` at line 362, then awaits table reads (371), the fingerprint (406)
and `install` (411), and guards only with `revision == sourceRevision`. `upsert`, `remove` and
`replaceMemory` never take `rebuildLock` and never bump `sourceRevision`, so the rebuild installs a
document set computed from the items as they were before the mutation: `install` replaces the scan
engine wholesale, or calls `LexicalIndex.replaceAll`, which removes every id absent from that set.
Failure scenario: a mixed context (memory items + one table) is created; while its rows load in the
background (the normal state after init for a database context, and during every `refresh()` or
`setLocale`), the host calls `service.index([zeppelin])` and `service.remove(["mem-3"])`. When the load
completes, "zeppelin" no longer matches and the removed "mem-3" matches again, while the service's
`memoryItems` say the opposite; the divergence persists until the next full rebuild.
Repro (scratch build, scenario A; 300 ms read delay in the fake connection):
`A: before the load completes: 'zeppelin' -> ["mem-2"]  'obsolete' -> []`
`A: after the load completes:  'zeppelin' -> []  'obsolete' -> ["mem-3"]  count: 4`
`A: memory items held by the service: ["mem-1", "mem-2"]`
Same mechanism by reading only: memory-only contexts large enough for `project` to run in a task group
(chunked projection) during `setLocale`/`refresh()`; and `setLocale` awaits `semantic?.setLocale`
(SearchService.swift:901) without a check, so of two quick locale changes the older can finish last.
Knock-down attempts: no other lock or revision covers these paths (`rebuildLock` is taken only by
`rebuild` and change-stream `apply`); `LexicalIndex`'s own mutation lock serializes calls but does not
stop `replaceAll` from removing the upserted id; `ConcurrencyTests.swift:248` mixes `index` and
`setLocale` but asserts only termination and `count >= 1500`.

### C1-s03-engine-api-02 — a localization key whose string equals the key is dropped (high, bug)
Spec: section 9.2 rule 3 (p21-22): keys are resolved through LocalizedStringResolving with the section 5
fallback chain; only an unresolved key indexes nothing.
Location: Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:125-126
(`SearchProjector.nonEmpty(string) != nil, string != value else { continue }`).
The adapter's resolver already returns nil for a missing key through a sentinel
(Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/BundleLocalizedStringResolver.swift),
but core additionally discards every resolved string equal to its key. With the key-is-the-source-text
convention (the default for strings tables and String Catalogs: `"Settings" = "Settings";`) the
development-language string is discarded: the next language becomes the base surface, or, in a
single-language app, the field indexes nothing and an "unresolved key" diagnostic is reported.
Repro (scenario B, resolver en: Settings->Settings, it: Settings->Impostazioni, active locale en):
`B[en+it]: screens#1 title = Optional("Impostazioni")  language = Optional("it")`
`B[en+it]: query 'settings' -> []   query 'frozen' -> ["screens#2"]`
`B[en only]: screens#1 title = nil  language = nil` and `query 'settings' -> []`.
Tests: DatabaseSourceTests.swift:262, 297, 315 use dotted keys (`map.harbor`) only.

### C1-s03-engine-api-03 — persisted index adopted on a fingerprint that ignores most content (high, bug)
Spec: section 9.1 rule 6 (p19: an indexed context persists under its own file); section 9 rule 9; the
filter precision requirement of section 15.3 (no hit may violate a hard constraint).
Locations: Sources/ZTronSearchEngine/Service/SearchService+Context.swift:122-141 (adopts the mapped file
when the metadata validates), 181-199 (`fingerprint(of:)` mixes only id, kind, UTF-8 length of the text,
UTF-8 length of the title, updatedAt); Sources/ZTronSearchEngine/Index/LexicalIndex.swift:204-206.
Keywords, caption, OCR text, localizations, filters, embeddings and the text content itself (beyond its
byte length) are not part of the fingerprint. After an app update that edits any of them (same ids, same
text and title lengths, no TemporalSearchable), the next launch memory-maps the old file and serves the
old index until the host happens to call `refresh()`.
Repro (scenario C, 600 items, `.indexed`, `.files(dir)`; v2 changes keywords alpha->omega and filter
level 1->2): `C: v2 service: 'omega' hits: 0 (expected 20)  'alpha' hits: 20 (expected 0)`;
`C: v2 service: filter level=2 hits: 0 (expected 20)  filter level=1 hits: 20 (expected 0)` — every hit
of the level=1 query violates the hard constraint against the current items.
Knock-down: a source comment near line 178 says edits that keep the mixed values need an explicit
refresh(), but neither the spec nor the README asks hosts to refresh after content changes;
`SearchContextTests.swift:311` only tests an added item (the count changes).

### C1-s03-engine-api-04 — concurrent upsert lost while an .automatic context is promoted (medium, concurrency)
Spec: section 11 rule 5; section 9.1 strategy `.automatic`.
Location: Sources/ZTronSearchEngine/Service/SearchService+Context.swift:227-237. After
`await index.replaceAll(with: engine.documents …)` the only check is `current.count == engine.count`; an
upsert that replaced an existing document meanwhile keeps the count, so storage switches to an index
built from the pre-upsert documents.
Repro (scenario F): a 500-item `.automatic` context; two concurrent `index` calls, one adding `i500`
(crossing the threshold), one retitling `i7` to "Quokka":
`F: first attempt: 'quokka' -> []  scan strategy: false`, `F: the update of i7 was lost in 40 of 40
attempts`; sequential control (scenario G): `G (sequential control): 'quokka' -> ["i7"]`.

### C1-s03-engine-api-05 — Int overflow trap in snapshot slicing (medium, bug)
Spec: section 9 (SearchQuery.limit / cursor, page(after:generation:)), section 9.1 ScanIndex.hits(for:).
Locations: Sources/ZTronSearchEngine/Scan/ScanIndex.swift:77 and
Sources/ZTronSearchEngine/Service/SearchService.swift:466:
`let end = min(count, start + max(0, query.limit))` overflows when `limit` is near `Int.max` and
`start > 0` (both are public, settable values).
Failure: `var q = SearchQuery<S>(text: "alpha"); q.limit = .max; q.cursor = SearchCursor(offset: 1);
scanIndex.hits(for: q)` traps; the same arithmetic runs in `results(for:)` with a cursor and in
`page(after:generation:)` for a retained query with such a limit.
Repro (scenario D): prints `D: limit .max, no cursor -> ["a", "b", "c"]`, then
`D: limit .max, cursor offset 1 -> (about to call)`, and the process dies with SIGTRAP (exit 133).

### C1-s03-engine-api-06 — databasePageSize <= 0 makes the row reader loop forever (low, bug)
Spec: section 9.2 rule 1 (pages of LIMIT 500 OFFSET n).
Locations: Sources/ZTronSearchEngine/Database/SearchSQLComposer.swift:131-143
(`if rows.count < pageSize { return }; offset += pageSize`); the clamp at
Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:195 runs only in init, while
`databasePageSize` (line 142) is a public var.
Repro (scenario E, `settings.databasePageSize = 0` after init): `E: read transactions after 1 s: 65887
after 2 s: 118275  service ready: false` — unbounded read transactions; `waitUntilReady()` never returns.

### C1-s03-engine-api-07 — scan scoring checks cancellation per 256 documents, not per 1,000 postings (low, spec-deviation)
Spec: section 11 rule 4 (p24).
Location: Sources/ZTronSearchEngine/Scan/ScanEngine.swift:147-172 (check at 149). The check runs every
256 documents while the inner loop walks every (term, field) entry of each document; with large
documents that is far more than 1,000 postings between checkpoints in a context forced to `.scan`.
Only the indexed searcher has a during-search cancellation test (ConcurrencyTests.swift:49). By reading;
limited reach because `.automatic` keeps scan contexts at <= 500 documents.

### C1-s03-engine-api-08 — changing pageSize during a search leaves the previous query's hits on screen (low, bug)
Spec: section 11 rule 6 and liveness "No stale results" (p24-25).
Location: Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:78-81 (the setter mutates
`query.limit` of the query in flight without restarting) and 130-131 (`snapshot.query == query`).
Sequence: user types "harb" (results shown), then "harbor" (stream starts), host sets `pageSize = 30`
before the first snapshot. Every snapshot of the running stream fails the equality check and is dropped;
`streamEnded` (150-152) clears `isLoading`; `hits` still hold the "harb" results under the text "harbor".
A repeated `update(text: "harbor", …)` returns early at line 68 because the merged query now equals
`query`, so nothing refreshes until the text changes. By reading; not reproduced.

### C1-s03-engine-api-09 — suggestions run on their own timer, not the lexical timer (low, spec-deviation)
Spec: section 10 table (p23): Suggestions — "Shares the lexical timer".
Location: Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:226, 235-259: ZTronSuggestionsModel
has its own `debounce` parameter (default 0.120) and its own Task.sleep, independent of
`SearchEngineConfiguration.lexicalDebounce` (Contracts/SearchEngineConfiguration.swift:162-170), which
drives the lexical phase inside SearchService.
Failure: a host that sets `lexicalDebounce = 0.2` gets lexical results after 200 ms and suggestions after
120 ms; even with defaults the two are separate timers firing independently.
Test: `ResultsModelTests.swift:317` `testSuggestionsShareTheLexicalTimer` passes `debounce: 0.12` itself
and asserts only one debounced request; it would pass with any independent timer.
Knock-down: with the default configuration the observed delays match; reach limited to hosts that tune
the lexical debounce.

### C1-s03-engine-api-10 — the during-search cancellation test accepts far more than 10 ms (low, test-integrity)
Spec: section 11 liveness table (p25): cancellation "is honoured within 10 ms at the next checkpoint",
verified by "cancellation tests before, during and after index search".
Location: Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:49-80, assertion at 75:
`XCTAssertLessThan(worst, 0.010 + full / 4, "cancellation is honoured within 10 ms of the next checkpoint …")`.
The bound grows with the measured length of the uncancelled search: any checkpoint cadence that leaves
less than a quarter of the whole search between checks passes, although the message claims 10 ms. It
would still catch the complete absence of checkpoints (worst close to `full`), and a fixed 10 ms bound in
debug builds on shared CI runners would be noisy, hence low.

## Not checked / limits
- Device figures: the lexical budget of R8, 10 ms cancellation (R64), 1 ms publishing (R68) and the
  section 15 p95 targets are unverifiable here; PerformanceTests are skipped in the debug log and run only
  in the release CI job.
- Semantic product internals: lazy model loading, INT8 vector store mapping (R50) and the HNSW
  cancellation cadence were only spot-checked by reading.
- SQLite adapter suites, the parity host and the MLX / AssetKit adapters were not run; adapter
  behaviour (R30, R42, R43) traced by reading only.
- No Thread Sanitizer run (nothing may be built in the repository); only `c1-debug-swift-test.log` was
  consulted.
- Figures and diagrams of the PDF (pdftoppm missing); worked from the text extraction `spec.txt`.
- Index/IndexSearcher.swift read only around the cancellation checkpoints and candidate caps; the
  SearchProjector fallback chain (section 5) belongs to another slice.
- Findings -07, -08, and the setLocale / chunked-projection variants of -01 are by reading only; -01
  (scenario A), -02 (B), -03 (C), -05 (D), -06 (E), -04 (F, control G) were reproduced in the scratch
  build listed at the top.

STATUS: complete
