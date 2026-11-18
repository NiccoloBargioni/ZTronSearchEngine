# Cycle 2 — auditor m02-query-service — findings checkpoint

Scope: Sources/ZTronSearchEngine/{Query, Service, Projection, Database, Chat, Contracts}; tests RankingTests,
SignalTuningTests, SnapshotPipelineTests, SearchContextTests, ConcurrencyTests, DatabaseSourceTests, ChatTests,
SmokeTests (+ TestSupport); spec sections 3, 4, 6, 8, 9, 11, 14.1, 14.3 (Verification/_inputs/spec.txt).

Method: code reading of every file in scope; run logs in Verification/_runs (c1-debug-swift-test.log,
c2-tsan-swift-test.log) grepped (all suites of this module pass). Confirmations were run outside the repository:
the engine and fixture sources were COPIED to
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m02-query-service/src
and compiled there with `swiftc -swift-version 6 -enable-testing -Onone -target arm64-apple-macosx14.0` into
build/libZTronSearchEngine.dylib and build/libZTronSearchFixtures.dylib (module cache in the scratchpad; no .build
directory in the repository; no swift build/test, no xcodebuild, no simulator). Drivers (same scratchpad folder):
driver/main.swift (sections A-F, output run/driver-output.txt), driver2/main.swift (G-J, run/driver2-output.txt),
driver3/main.swift (A2, K-M, run/driver3-output.txt), driver4/main.swift (run/driver4-output.txt),
dateparse/main.swift + extra.swift (optimized verbatim copy of SearchDateParser).

---

## C2-m02-query-service-01 — critical — bug
**Database-backed contexts adopt a persisted index without reading their rows, so writes made while no context is subscribed are never indexed**

- spec_ref: 9.2 rules 4-6 (one document set from the sources; change stream; refresh; index persistence), 9.1 rule 6, section 6 persisted-index rule, 16 "Index-in-database persistence"
- locations:
  - Sources/ZTronSearchEngine/Service/SearchService+Context.swift:156-166 (finishSetup -> rebuild(adoptingPersistedIndex: true))
  - Sources/ZTronSearchEngine/Service/SearchService+Context.swift:351-353 (rebuildLocked returns before reading any table)
  - Sources/ZTronSearchEngine/Service/SearchService+Context.swift:671-703 (adoptPersistedIndex; `fingerprint: ""` at 675)
  - Sources/ZTronSearchEngine/Service/SearchService+Context.swift:123-125 (database contexts never get a content fingerprint)
  - Sources/ZTronSearchEngine/Index/LexicalIndex.swift:204-206 (fingerprint compared only when the expected one is non-empty)
  - Sources/ZTronSearchEngine/Service/SearchService+Context.swift:634-651 (1 s persist debounce; id `.default` never re-persists after a change)
  - Sources/ZTronSearchEngine/Contracts/SearchContext.swift:24-28, 75 (default storage `.files(Caches/ZTronSearchEngine)`)
  - Sources/ZTronSearchEngine/Service/SearchService+Context.swift:6-11, 47 (docs: "waitUntilReady() returns once they are in"; "Returns once every source of the context has been read")
  - Tests/ZTronSearchEngineTests/DatabaseSourceTests.swift:774-778 (test asserts "rows not re-read")
- description: For a context with database sources, finishSetup subscribes to the change stream and calls rebuild(adoptingPersistedIndex: true). adoptPersistedIndex loads the index file (default storage .files in Caches) or the `<prefix>_*` tables and validates only projection/normalizer versions, languages and the embedding model id: the expected content fingerprint is "" and LexicalIndex.validate skips the comparison for an empty expectation. If the adopted index holds more than scanThreshold documents (or the strategy is .indexed) it becomes the storage and the host rows are not read at all. The change stream exists only while a service is alive and only reports commits made after subscription, so every commit made while no context for that database was alive (screen-scoped contexts, which 9.1 rule 6 encourages; a sync at launch before the search screen opens; another process) is never indexed: inserted rows are missing, updated rows keep their old text, deleted rows stay searchable, until a later change touches that table while a context is alive or the host calls refresh(). The same happens when the app is suspended or killed within the 1 s persist debounce after a commit, and with storage .database and id .default the index is never re-persisted after incremental changes (only at full rebuilds), so the next launch adopts an index missing every change since the last rebuild. In a mixed context the memory items handed in at this launch are replaced by the persisted ones. The public docs of init(context:) and waitUntilReady() promise the opposite.
- evidence: `let expected = Self.indexMetadata(languages: target, semantic: semantic, fingerprint: "")` (675); `if !expected.contentFingerprint.isEmpty && found.contentFingerprint != expected.contentFingerprint {` (LexicalIndex.swift:204). Scratch driver section A (900-row table, id "tools-screen", storage .files(scratch dir)): first context read the table and wrote "tools-screen.v1.ztsi"; after release (subscribers 0) the host inserted "Zeppelin Hangar" (row 5000), renamed row 1 to "Lighthouse Keeper" and deleted row 2; a second context over the same SearchContext printed "statements reading tools: 0", 'zeppelin' -> [], 'lighthouse' -> [], tools#1 title "Tool number 1", deleted tools#2 still returned "Tool number 2"; after an explicit refresh() 'zeppelin' -> ["tools#5000"]. driver3 section A2 (one memory tip + 700-row table): the tip handed in at the second launch ('lantern') -> [], the tip no longer handed in ('old bundled') -> ["tip-old"].
- failure_scenario: A notes app keeps 900 notes in SQLite and creates its search context (id "notes", default storage) when the search screen opens. The user searches (index persisted to Caches), closes search, writes a note "Zeppelin hangar", reopens search: the note cannot be found, edited notes are found by their old text, deleted notes still appear, across launches, until that table changes again while the search screen is open.
- repro: scratchpad driver/main.swift section A, driver3/main.swift section A2.

## C2-m02-query-service-02 — high — bug
**Memory-context index files are reused after content edits: the fingerprint ignores keywords, filters, captions, OCR text, localizations and any edit that keeps text and title lengths**

- spec_ref: 9.1 rule 6 (an indexed context persists under its own file), section 6 persisted-index rule, section 5 (localizations)
- locations: Sources/ZTronSearchEngine/Service/SearchService+Context.swift:176-199 (fingerprint), :123-141 (adoption in prepare); Sources/ZTronSearchEngine/Index/LexicalIndex.swift:204-206; Tests/ZTronSearchEngineTests/SearchContextTests.swift:311-340 (only an added item is tested)
- description: An indexed memory context (> 500 items or .indexed) with storage .files (the default) and a non-default id persists its index and, at the next init, memory-maps it when the content fingerprint matches. The fingerprint mixes only the id, kind raw value, UTF-8 length of searchText, UTF-8 length of searchTitle and updatedAt. Changing keywords, filters, caption, OCR text, searchLanguage or searchLocalizations (an app update that ships translations), or editing text/title without changing their byte length (typo fixes), leaves it unchanged, so the stale index is adopted and projection is skipped. Only an internal doc comment on the static helper mentions that such edits "need an explicit refresh()"; the public SearchContext/SearchIndexStorage docs say nothing, and refresh() at every launch defeats persistence. The test comment "Different content under the same id: the stale file is not trusted" is only exercised by appending an item.
- evidence: fingerprint body: `mix(fnv1a(item.searchID.rawValue)); mix(fnv1a(item.searchKind.rawValue)); mix(UInt64(item.searchText.utf8.count))`, title length, updatedAt. Scratch driver section B (600 tools + one item; persisted "catalog.v1.ztsi"; item edited: text "Receive the anchor map." -> "Recieve the anchor map.", keywords ["alpha"] -> ["omega"], filters ios -> mac, added en caption "Lantern caption"): "fingerprints equal: true"; second context: 'omega' -> [], 'alpha' -> ["special"], 'lantern' -> [], document text "Receive the anchor map.", keywords ["alpha"], filters platform=ios.
- failure_scenario: Version 1.1 adds Italian localizations to 3,000 built-in items; Italian users who ran 1.0 keep the 1.0 index (same ids, kinds, lengths, dates) and can never find items by their Italian titles until the cache is purged.
- repro: scratchpad driver/main.swift section B.

## C2-m02-query-service-03 — high — test-integrity
**The randomized "no stale snapshots" test cannot detect a stale snapshot**

- spec_ref: 15.4 "Zero stale snapshots published over a randomized sequence of 10,000 query changes"; 11 "No stale results"; 16 "Stale-result suppression with randomized query sequences"
- locations: Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:157-219 (ledger checks at 175-176, `own` at 191, assertions 211-218); compare :223-243
- description: The doc comment claims "once a newer query has been issued an older stream never yields again", but the ledger only counts a snapshot whose query differs from its own stream's query, or whose generation differs from the first generation seen on the same stream. An obsolete producer that yields its own query's snapshot after a newer results(for:) call satisfies both checks, so staleness increments nothing. The other assertions (published > 0, finals <= changes + 20, generations grow at the probes, the last query completes) cannot fail on staleness either. The only deterministic stale check, testAnObsoleteProducerNeverYields, covers one interleaving (producer parked in a 50 ms semantic phase; no reranker, no debounce, no paging), not the randomized sequence the gate names.
- evidence: `if snapshot.query != expected { mismatched += 1 }` / `if let streamGeneration, snapshot.generation != streamGeneration { mismatched += 1 }`; `if own == nil { own = snapshot.generation }` taken from the same stream; no ordering between a stream's yields and later results(for:) calls is recorded.
- failure_scenario: A regression that drops the isCurrent(lane) check before publishing the lexical snapshot lets obsolete streams publish after newer queries; the 10,000-change test still ends with mismatched == 0 and the 15.4 gate is reported met.

## C2-m02-query-service-04 — medium — spec-deviation
**A row with a literal and a localized key in the same role loses the literal from its field: it is moved to localizedAlt, even under the base language**

- spec_ref: 9.2 rule 3 (literals keep their declared language; only the other preferred languages feed localizedAlt), 9.2 rule 4 / 15.9 (a row ranks like the same memory item), section 5
- locations: Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:132-147, 153-156; Sources/ZTronSearchEngine/Projection/SearchProjector.swift:109 (shadowed base surface -> localizedAlt)
- description: For a keyed field the row projector writes the resolved string for every catalog language, base language included, into searchLocalizations[tag] (for .text into localizedTexts[tag]); literal fields of the same role go only to the base surface. For the active language the localization therefore holds only the key's string, and SearchProjector treats the base surface (literal + key string) as shadowed and demotes it to localizedAlt (BM25F weight 0.5 instead of 1.0 for text, 4.0 for keywords). With the base locale and no secondary languages nothing should be in localizedAlt at all.
- evidence: Scratch driver section F: table notes(id, body literal "en", extra key "map.harbor"), both role .text, resolver languages [en, it], locale en, secondary none -> "text: Frozen Harbor", "localizedAlt: [\"Literal paragraph about lanterns.\nFrozen Harbor\"] [en]". DatabaseSourceTests.swift:262-295 mixes roles but never a literal and a key in the same role.
- failure_scenario: A host indexes a literal `body` and a localized `category_description_key` both as .text (or literal tags plus a keyword key as .keywords); every literal match scores at the localizedAlt weight, so these rows rank below memory items with identical content, contrary to the identical-ranking rule.
- repro: scratchpad driver/main.swift section F.

## C2-m02-query-service-05 — medium — concurrency
**The chat idle-unload timer can fire while a new turn is retrieving or assembling its prompt, and cancels that turn**

- spec_ref: 14.3 rules 4-5 (unload after 120 s idle), 14.4 lifecycle
- locations: Sources/ZTronSearchEngine/Chat/ChatService.swift:377-400 (send does not touch `use`/idleTask), 440-477 (.generating only at 477), 583-602 (noteUse/unloadIfIdle), 409-420 (unload cancels every session task)
- description: send() neither bumps `use` nor cancels idleTask, and runTurn sets the lifecycle to .generating only after retrieval (search.retrieve runs semantic and rerank phases, up to 300 + 400 ms caps), source rendering (several countTokens calls per source) and prompt assembly. If the idle timer set by the previous turn (or by the load) expires in that window, unloadIfIdle sees an unchanged `use` and lifecycle .ready and calls unload(), which unloads the model and cancels every session's task, including the turn that just started.
- evidence: driver2 section G (FakeLanguageModel wrapped so countTokens takes 50 ms; idleUnload 0.6 s; send 0.4 s after prepare): "send outcome: threw CancellationError after 219 ms; text: (none)"; "model unloadCalls: 1 generateCalls: 0".
- failure_scenario: With the default 120 s, a user who sends the next message about two minutes after the previous answer (inside the ~0.5-1 s retrieval window) gets the turn cancelled as if they had pressed stop; a shorter host idleUnload makes it proportionally likelier.
- repro: scratchpad driver2/main.swift section G.

## C2-m02-query-service-06 — medium — concurrency
**ChatService.load is not reentrancy-safe: unload()/a memory warning during a load is undone, and prepare() during a send-triggered load loads the weights twice**

- spec_ref: 14.3 rule 5, 14.4 (unload on memory warning; LLM unloads before the embedding model; 1.8 GB resident)
- locations: Sources/ZTronSearchEngine/Chat/ChatService.swift:282-298 (load), 409-420 (unload), 129-155 (prepare starts runPreparation whenever preparation == nil, even while .loading), 243-248 (sets .onDisk and loads), 543-545 (ensureLoaded loads from .onDisk without a preparation)
- description: (a) unload() while .loading unloads the runtime and sets .onDisk, but the suspended load(from:) resumes and settles .ready with the runtime loaded: the warning that arrived during the load is lost. (b) A send that finds .onDisk loads in ensureLoaded without setting `preparation`; a prepare() arriving meanwhile sees preparation == nil, starts runPreparation, overwrites the lifecycle with .onDisk and calls model.load a second time concurrently.
- evidence: driver2 section H (load 300 ms, unload after 100 ms): "after the warning: readiness ready | runtime isLoaded true | unloadCalls 1". driver3 section K (unload, send, prepare 100 ms later): "runtime loadCalls: 3" where 2 are expected.
- failure_scenario: iOS posts a memory warning while the 968 MB weights are being loaded; the engine unloads, then leaves the model resident (~1.8 GB) and reports ready, and the app is jetsammed. A chat view that calls prepare() on appear while a send reloads after an idle unload loads the weights twice (double peak memory and latency).
- repro: scratchpad driver2/main.swift section H; driver3/main.swift section K.

## C2-m02-query-service-07 — medium — bug
**Source truncation splits on whitespace only, so unspaced scripts (Japanese, Chinese, Thai) lose the whole caption/text of a source**

- spec_ref: 14.3 rule 1 ("[kind:id] title, caption from its localized surface, at most 80 tokens per source"); multilingual/CJK requirements (sections 2, 5)
- locations: Sources/ZTronSearchEngine/Chat/CitationParser.swift:164-180 (PromptAssembler.truncate); Sources/ZTronSearchEngine/Chat/ChatService.swift:564-579 (render)
- description: truncate keeps the longest prefix of whitespace-separated words that fits. A Japanese caption/text is one "word", so a rendered source over 80 tokens is cut to "[kind:id] <title>," and the caption/text disappears although ~60 tokens of budget remain; with a long unspaced title only the marker remains. ChatTests only exercise English.
- evidence: driver section C (internal function via @testable, 1 token per character): a 157-character Japanese source -> "[map:harbor] 凍った港," (18 characters); the English equivalent is cut to 80 characters.
- failure_scenario: Grounded answers in Japanese/Chinese/Thai see only titles for every source longer than 80 tokens; answer quality and citation accuracy drop for those locales.
- repro: scratchpad driver/main.swift section C.

## C2-m02-query-service-08 — medium — bug
**Citations of ids that contain ':' are never recognised and the raw marker leaks into the transcript**

- spec_ref: 14.3 rule 3 (markers parsed incrementally, emitted as .citation when the id is in the sources; never in the text)
- locations: Sources/ZTronSearchEngine/Chat/CitationParser.swift:76-81
- description: After each ':' in a pending marker consume() checks that everything before it is a kind: `isKind(String(pending.dropFirst().dropLast())...)`. For "[map:m:harbor]" the second colon tests "map:m", which is not a kind, so the bracket is released as text; marker(in:), which splits on the first colon and would accept it, is never reached. Such ids are legal and are produced by the engine's own SearchRowIdentity.prefixed (DatabaseSourceTests uses .prefixed("m:")), and the prompt tells the model to cite them verbatim.
- evidence: driver section D: sources {"m:harbor", "harbor"}, input "See [map:m:harbor] and [map:harbor]." -> [.text("See [map:m:harbor] and "), .citation(harbor), .text(".")].
- failure_scenario: A host namespaces ids ("tip:42", or "m:harbor" via .prefixed("m:")); every answer shows raw "[tip:tip:42]" markers and emits no .citation, so source chips never appear.
- repro: scratchpad driver/main.swift section D.

## C2-m02-query-service-09 — medium — performance
**Text date columns cost up to two ISO8601DateFormatter constructions per row**

- spec_ref: 15.9 (one page of 500 rows read, resolved and projected in 40 ms; 10k-row context in 1.5 s, reference device)
- locations: Sources/ZTronSearchEngine/Database/SearchSQLComposer.swift:190-209 (SearchDateParser); Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:175 (per row)
- description: SearchDateParser creates a new ISO8601DateFormatter for each option set it tries, for every value. SQLite.swift stores Date as TEXT ("yyyy-MM-dd'T'HH:mm:ss.SSS"); SQLite's CURRENT_TIMESTAMP yields "YYYY-MM-DD HH:MM:SS" (two constructions, the fractional attempt fails first). The adapter's database target tests use REAL dates, so this path is never measured.
- evidence: optimized verbatim copy (scratchpad dateparse/, swiftc -O) on this Mac: 10,000 SQLite.swift Date texts 2,470 ms; 10,000 "YYYY-MM-DD HH:MM:SS" texts 3,781 ms (3,809 ms first run); same inputs with formatters created once 1,577-1,579 ms; 10,000 constructions alone 986 ms. The machine may have been shared with other jobs; the ratio is the robust part. Against the README's Mac scaling (device budget / 6) a 500-row page has about 7 ms here, while date parsing alone takes 120-190 ms.
- failure_scenario: A host using SQLite.swift `Expression<Date>` for updatedAt loads a 10k-row context; date parsing alone takes seconds on device, far over 1.5 s / 40 ms per page.
- repro: scratchpad dateparse/main.swift + extra.swift.

## C2-m02-query-service-10 — medium — test-integrity
**The cancellation-latency test allows 10 ms plus a quarter of the whole search instead of 10 ms after the next checkpoint**

- spec_ref: 15.4 "Cancellation honoured within 10 ms of the next checkpoint"; 11 (checkpoint every 1,000 postings)
- locations: Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:49-79 (assert at 75), 82-107
- description: The test asserts worst < 0.010 + full / 4, with `full` the duration of an uncancelled run, so the bound grows with the search (a 400 ms debug/TSan search allows 110 ms) and would pass with about four checkpoints per search. testTheScoringLoopChecksCancellation only shows that an already-cancelled task throws (one checkpoint exists), not the 1,000-unit spacing. The assertion message still claims the 10 ms gate.
- evidence: `XCTAssertLessThan(worst, 0.010 + full / 4, "cancellation is honoured within 10 ms of the next checkpoint (worst \(worst * 1000) ms)")`.
- failure_scenario: Moving the checkpoint from every 1,000 postings to every 100,000 keeps both tests green while cancellation latency on device grows to tens of milliseconds.

## C2-m02-query-service-11 — low — performance
**Every keyed field resolves the key in every catalog language, though only the active, fallback and secondary languages are used**

- spec_ref: 15.9 (page and context-creation budgets)
- locations: Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:116-147
- description: For each keyed field of each row the projector calls resolver.string(forKey:...) for every language the catalog lists and stores them all in searchLocalizations; SearchProjector keeps only the active language, its fallback chain and configured secondary languages. Cost is linear in catalog languages; 15.9 is specified and tested with 2.
- evidence: driver2 section J (debug build, fake cached resolver, 2,000 rows x 3 keyed fields): 2 languages ready in 151 ms; 30 languages in 386 ms (2.6x).
- failure_scenario: An app localized into 35 languages with three keyed fields resolves about a million strings for a 10k-row context, nearly all discarded, adding hundreds of milliseconds on device.
- repro: scratchpad driver2/main.swift section J.

## C2-m02-query-service-12 — low — spec-deviation
**A row's literal fields lose their declared language unless every field of the row agrees on one language**

- spec_ref: 9.2 rule 3 ("Literal fields keep their declared language tag")
- locations: Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:157-161
- description: The row item has one searchLanguage for the base surface, set only when the union of literal tags and the keys' first-resolved languages has exactly one element and no literal is untagged. A literal tagged "fr" next to a key whose catalog base is "en" (or two literals with different tags) gets nil, so the literal is tokenized/normalized without its language (DocumentAnalysis passes languages.<field> to the tokenizer) and matchedLanguage is unknown.
- evidence: `let baseLanguages = literalLanguages.union(keyLanguages); if !hasUntaggedLiteral, baseLanguages.count == 1 { item.searchLanguage = baseLanguages.first }`; the only test (DatabaseSourceTests.swift:262-295) uses rows where every field agrees on "en".
- failure_scenario: A table with a French literal description and an English-base localized title: the French text is analyzed with the default language key instead of "fr".

## C2-m02-query-service-13 — low — api
**Public setters bypass the clamps of RerankSpec, EditorialPolicy and SearchLimits; out-of-range values exceed the spec ceilings or trap**

- spec_ref: 7.4 / 8 (rerank top 16, at most 32; at most 3 pins)
- locations: Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:73-85 (maximumPins), 88-101 (topN, blend); Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:40, 54-55 (retainedHits); Sources/ZTronSearchEngine/Service/SearchService.swift:449; Sources/ZTronSearchEngine/Query/Fusion.swift:190, 197
- description: The clamps (topN 1...32, blend 0...1, maximumPins 0...3, retainedHits >= 1) run only in the initializers; the properties are public vars and the README configures profiles by mutation. topN = 64 sends 64 passages to the cross-encoder; maximumPins = 10 pins ten results; a negative topN or retainedHits traps in prefix(_:).
- evidence: driver3 section L: RerankSpec(topN: 64).topN = 32 but after `rerank.topN = 64` -> 64; EditorialPolicy(maximumPins: 10) -> 3 but after assignment -> 10; `limits.retainedHits = -1` -> -1. driver4: a scan context queried with configuration.limits.retainedHits = -1 -> "Fatal error: Can't take a prefix of negative length from a collection", exit status 133.
- failure_scenario: A remote-config value sets maximumPins to 5 and pins hide organic results despite the "at most 3" rule; a value of -1 for retained hits crashes every query.
- repro: scratchpad driver3/main.swift section L; driver4/main.swift.

## C2-m02-query-service-14 — low — bug
**A non-finite cross-encoder score puts NaN into the published hits and silently disables the rerank for the head**

- spec_ref: 7.4 (blend formula), 6 (snapshot semantics)
- locations: Sources/ZTronSearchEngine/Service/SearchService.swift:716-719; Sources/ZTronSearchEngine/Service/SearchPipeline.swift:155-192
- description: rerankPhase accepts any score array of the right length; reranked() min-max normalizes it. +inf becomes NaN for that document and 0 for all others; a NaN breaks the sort comparator and the score mapping. The snapshot carries NaN scores and scores above the head's top, the cross-encoder order is lost, and no degraded flag is set.
- evidence: driver section E: scores [0.1, 0.9, inf, 0.3, 0.2] -> d0=0.05, d1=0.049, d2=nan, d3=0.047, d4=0.046 (d1 should lead); [0.1, nan, 0.4, 0.3, 0.2] -> d0=0.05, d1=nan, d2=0.083 (above the head's top 0.05), d3=0.0645, d4=0.046.
- failure_scenario: An FP16 Core ML cross-encoder overflows on one passage; the final snapshot has a NaN score and an unsorted score column.
- repro: scratchpad driver/main.swift section E.

## C2-m02-query-service-15 — low — bug
**Wiring chat through ZTronSearch creates a retain cycle; neither the search service nor the chat service is ever freed**

- spec_ref: 9.1 rule 6 ("releasing the service frees everything"); 11 predictable cleanup / leak tests
- locations: Sources/ZTronSearchEngine/Chat/ChatService.swift:679-684
- description: The facade installs `{ await service.unload() }` (strong capture of the ChatService) as the search service's memoryWarningPredecessor, while ChatService holds the SearchService strongly. Releasing the facade leaves both alive with their index, observers and change-stream subscriptions.
- evidence: driver2 section I: with chat "search service freed: false | chat service freed: false"; same service without chat "search service freed: true".
- failure_scenario: A host that builds a ZTronSearch per screen or per context leaks one index and one chat service per visit.
- repro: scratchpad driver2/main.swift section I.

## C2-m02-query-service-16 — low — concurrency
**A send that arrives during a model fetch waits, uncancellably, for the whole download while holding the generation lock**

- spec_ref: 14.3 rule 4 (a new send in the same session cancels the one in flight; other sessions queue), 14.4 cancellation target
- locations: Sources/ZTronSearchEngine/Chat/ChatService.swift:435-440, 532-539, 181-187
- description: runTurn takes the generation lock, then ensureLoaded parks on a CheckedContinuation until the running preparation ends. Cancelling the turn (stop, or a new send in the same session) does not resume it; the cancelled turn holds the lock until the download finishes or is cancelled, and every other session queues behind it.
- evidence: `if preparation != nil { await withCheckedContinuation { continuation in preparationWaiters.append(continuation) }; try Task.checkCancellation() }` runs after acquireGenerationLock(); waiters are resumed only in runPreparation's defer.
- failure_scenario: The user starts the 968 MB download, sends a question, presses stop: nothing stops until the download ends, and other sessions cannot start.

## C2-m02-query-service-17 — low — bug
**query.limit = 0 yields a cursor that never advances**

- spec_ref: 6 rule 8 (paging continues the final snapshot's list)
- locations: Sources/ZTronSearchEngine/Service/SearchService.swift:464-479; Sources/ZTronSearchEngine/Contracts/SearchQuery.swift:34
- description: end = start + max(0, limit); with limit 0 every snapshot and page is empty but nextCursor = SearchCursor(offset: start) while documents remain, so page(after:) returns the same cursor forever.
- evidence: driver3 section M: five consecutive pages, each "hits 0, next cursor offset 0".
- failure_scenario: A host that pages until nextCursor is nil loops forever when a caller passes limit 0.
- repro: scratchpad driver3/main.swift section M.

## C2-m02-query-service-18 — low — spec-deviation
**The prompt budget counts message contents only, not the chat template's per-message tokens, and the test measures the same quantity**

- spec_ref: 14.3 rule 2 (prompt inside contextWindow - maxNewTokens - 64)
- locations: Sources/ZTronSearchEngine/Chat/CitationParser.swift:144-161; Tests/ZTronSearchEngineTests/ChatTests.swift:463-494
- description: PromptAssembler sums countTokens(content) per message; role headers and separators of the runtime's chat template (about 4-6 tokens per message for ChatML-style templates) are not counted and share the fixed 64-token margin. With a long kept history the overhead grows with the message count (about 150 tokens for 30 messages), so prompt + maxNewTokens can exceed the window. The test sums the same content-only counts.
- evidence: `let fixed = await countTokens(systemMessage.content) + countTokens(userMessage.content)`; `let cost = await countTokens(entry.content)`; test: `request.messages.reduce(0) { $0 + FakeLanguageModel.tokens(in: $1.content) }`.
- failure_scenario: Long sessions on a 4,096-token window fill 3,520 content tokens plus ~150 template tokens; generation runs out of window before maxNewTokens.

## C2-m02-query-service-19 — low — api
**SearchError.missingLocalizedStringResolver is declared but never thrown; keyed fields are silently dropped when no resolver is set**

- spec_ref: 9.2 (localizedStrings "required when any field is a localized key")
- locations: Sources/ZTronSearchEngine/Contracts/SearchHit.swift:134-135; Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:111-114
- description: The public case documents "A field is declared as a localization key but the context has no resolver", but nothing produces it: the projector emits a debug-only unresolvedLocalizationKey per field per row and indexes nothing for the field. A misconfigured context loads with empty titles; testAContextWithoutAResolverIndexesNothingForKeyedFields enshrines the silent behaviour.
- evidence: the case appears only at SearchHit.swift:135 (grep over Sources/Tests).
- failure_scenario: A host forgets localizedStrings; in release builds every keyed title is silently unsearchable and no error surfaces.

---

## Knocked down (not reported)
- setLocale cancels in-flight searches (SearchService.swift:898): section 11 ("Search tasks are cancelled on ... locale change") requires it; section 5 rule 7 is about which index serves queries.
- Semantic skipped (and marked degraded) for phrase-only / required-only queries: consistent with "skipped, with degraded set, when ... a pure filter".
- reportKindCollisions skips batches > 512 (debug diagnostic; uniqueness is the host's responsibility).
- Kind-boost cache keyed by "" (Fusion.swift:156-157): needs an empty kind raw value.
- Free-disk check only for .missing (ChatService.swift:209): resuming is not starting a download.
- RankingTests.swift:334 `position < 16` is vacuous, but the next assertion (`< 11`) checks the property.
- SmokeTests highlight assertion conditional on unwraps; SignalTuningTests has no assertions but claims no gate.
- QueryPlanner 64-bit requiredMask with bigram fallback: phrases are verified separately (Highlighter.containsPhrases).

## Files read
Sources/ZTronSearchEngine (all, in scope, 25 files / 6,570 lines): Contracts/* (11 files), Query/{BM25F, Fusion, Highlighter, QueryParser, QueryPlanner}.swift, Service/{SearchService, SearchService+Context, SearchPipeline}.swift, Projection/SearchProjector.swift, Database/{SearchRowProjector, SearchSQLComposer, DatabaseIndexStore}.swift, Chat/{ChatService, CitationParser}.swift.
Consulted partially: Text/SearchNormalizer.swift, Text/SearchTokenizer.swift, Index/LexicalIndex.swift, Index/IndexSegment.swift, Index/IndexSearcher.swift, Index/DocumentAnalysis.swift, Scan/ScanEngine.swift, Support/FileIO.swift.
Tests (all, 9 files / 3,835 lines): RankingTests, SignalTuningTests, SnapshotPipelineTests, SearchContextTests, ConcurrencyTests, DatabaseSourceTests, ChatTests, SmokeTests, TestSupport.
Fixtures (partial): ZTronSearchFixtures/{CatalogSchema, FakeSearchDatabase, FakeChatBoundaries}.swift. README.md, Package.swift, spec.txt (sections 3-9, 11, 14, 15.4, 15.9, 16), Verification/_runs logs (grep only), Adapters/ZTronSearchEngineSQLite tests (grep for date columns only).

## Not checked / limits
- No run of the package's own test targets (forbidden); no device, simulator or release-build measurement of the 15.x budgets. Performance numbers are from a debug-build copy of the library (finding 11) and an optimized copy of one function (finding 09) on a possibly shared Mac.
- The section 11 liveness table (PDF page 25) did not survive text extraction and the PDF renderer is not installed; section 11 was read from spec.txt only.
- Chat behaviour was confirmed with the fixtures' FakeLanguageModel, not the MLX runtime (adapter out of scope).
- Index internals (IndexSearcher checkpoint spacing, segment format) belong to another module and were only consulted.
- UI module, Semantic module and adapters were out of scope.

STATUS: complete
