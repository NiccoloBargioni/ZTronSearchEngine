# Cycle 1 / s03-engine-api — skeptic verification

Skeptic for findings C1-s03-engine-api-01..10 (sections 9, 10, 11; spec pages 15-25). Repository commit cee4620.
Scratch work (never in the repository): /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s03-engine-api-skeptic/

## Verdicts

### C1-s03-engine-api-01 — index/remove/replace racing a rebuild are undone
Verdict: partly (real and reproduced independently; severity lowered critical -> high; durability is worse than described; the window needs a suspension inside the rebuild).
- Code read: `upsert` (SearchService.swift:242-255), `remove` (199-207) and `replaceMemory` (SearchService+Context.swift:239-259) take neither `rebuildLock` nor bump `sourceRevision`; `rebuildLocked` (336-418) snapshots `memoryItems` at 362 and later calls `install` -> `LexicalIndex.replaceAll` (LexicalIndex.swift:212-223, `removingAbsent: true`) or a wholesale `ScanEngine`. Only `apply` (change stream) takes the lock.
- Own harness (`harness/Main.swift`, `harness/Extra.swift`; byte-identical copy of the core sources, built as a module):
  - A1 mixed context, mutations during the initial load: before `zeppelin=["mem-2"] obsolete=[]`, after `zeppelin=[] obsolete=["mem-3"]`, `memoryItems` = mem-1, mem-2; still wrong 2.5 s later. Control A1c (mutations after the load): correct.
  - A2 `refresh()` race on the mixed context: same loss. A5 `replace(items:)` during the initial load: replacement undone (`zeppelin=[]`, old `harbor` back).
  - A3 memory-only `.indexed`, 2,501 items, `refresh()` race: upsert lost 10/10, removal undone 10/10. A4 memory-only 300-item scan context: 0/10 (no suspension inside the rebuild below 2,000 items in scan storage).
  - A8 same as A3 with `.files` storage, then a new service ("relaunch") over the host's current items: still `zeppelin=[] obsolete=["victim"]`. The persisted metadata fingerprint is computed in `install` from the post-mutation `memoryItems` while the content is the pre-mutation set, so the stale index validates and is adopted at the next launch. "Until the next full rebuild" understates it: it survives relaunches until the items change or `refresh()` runs.
  - setLocale: with the shipped `SemanticIndex.setLocale` (FIFO via `exclusively`, SemanticIndex.swift:208-234, 459-473) "the older of two locale changes finishes last" needs a semantic that does not serialize (A7 stub: requested it then de -> active `it`). A stronger variant needs no semantic: A6 `setLocale(it)` then `setLocale(en)` (back to the committed locale) returns early at `guard resolved != languages` (SearchService.swift:897) while the `it` rebuild is in flight; indexed context left in `it` with `configuration.locale = en` in 8/10 runs (scan 0/10).
  - A9 the auditor's by-reading memory-only setLocale variant (2,503 items, `.indexed`, narrow locale-change path): over 24 runs, a localized item's edit was lost 11 times and a localized item's removal undone 6 times. New items and non-localized removals were never affected (0/24), because the narrow path re-upserts only the localized items of its stale snapshot. The window is short: it lasts only while the >= 2,000-item filter runs off the actor (0/8 with a 2 ms delay).
- Severity: high, not critical. Wrong results in a derived index (missing upserts, resurrected removals), durable across relaunch, no crash and no host-data loss; requires a host mutation inside a rebuild window (database reads of any size, or >= 2,000 memory items); `refresh()` heals it.

### C1-s03-engine-api-04 — concurrent upsert lost while an .automatic context is promoted
Verdict: confirmed (medium).
- Code read: `rebalanceStrategy` (SearchService+Context.swift:227-237) awaits `index.replaceAll(with: engine.documents ...)` and then checks only `current.count == engine.count`. `ScanEngine.init` (ScanEngine.swift:32-44) de-duplicates by id (last wins), so an upsert that edits an existing id during the await leaves the count unchanged and the promoted index is built from the pre-edit documents. The second caller's own `rebalanceStrategy` then sees `.indexed` and returns.
- Own harness scenario F (500-item `.automatic` memory context, two concurrent `index` calls: add i500, retitle i7 to Quokka): promoted 30/30, retitle lost 27/30; `document(for: "i7")?.title == "Item 7"` while `memoryItems` hold "Quokka". Controls: sequential calls and a single call with both items find i7.
- Reach: only at the moment the context crosses the threshold, with concurrent `index` calls on one service. For a memory context with `.files` the promoted index carries an empty fingerprint, so the next launch rejects it and rebuilds; the loss lasts until the item is upserted again, a rebuild, or a relaunch. Medium is fair.

### C1-s03-engine-api-02 — localized key whose string equals the key is treated as unresolved
Verdict: partly (behaviour real and reproduced; the "only drops real translations" detail is wrong and the severity is inflated: high -> medium).
- Code read: SearchRowProjector.swift:125-126 skips any resolved string equal to the key; with no language resolving, the field indexes nothing and `unresolvedLocalizationKey` is reported at debug level (148-150).
- Own harness scenario B (FakeLocalizedStringResolver, active locale en, key "Settings"):
  - en+it catalog with the identity entry `en: Settings -> Settings`: stored title "Impostazioni"; 'settings' -> [], 'impostazioni' -> screens#1.
  - en-only catalog with the identity entry: title nil; 'settings' -> [].
- Knock-down attempt, partly successful: the check is not dead code. The spec's own suggested resolver ("Bundle.localizedString(forKey:value:table:) on the language bundle", spec p21) echoes the key for a missing entry when `value` is nil. Run "naive resolver, key missing": title nil, so the check is what keeps the raw key out of the index ("the raw key never enters the index", spec p22 and the testing list p47). Only the reference adapter (BundleLocalizedStringResolver, sentinel) makes it redundant. For key-as-source-text catalogs the spec's two sentences conflict (resolved string vs raw key). Without the identity entry, the adapter's nil gives the same empty field by design (run "en only, en entry absent").
- Corrected description: core treats a resolved string equal to its key as unresolved. This deliberately guards against resolvers that echo the key, at the cost of identity entries in key-as-source-text catalogs (another language becomes the base surface, or the field indexes nothing). It affects only database fields declared `.localizedKey` / `.perRow` whose catalog keys are the development-language text and carry explicit identity entries. Dotted keys are unaffected. Medium.

### C1-s03-engine-api-03 — persisted index adopted on a fingerprint that ignores most content
Verdict: confirmed (high). One detail is off: embeddings are listed as ignored, but they need not be in the fingerprint because the adoption path re-reads every item's vector (SearchService+Context.swift:134-139 -> `finishSetup` -> `upsertVectors`).
- Code read: `prepare` (SearchService+Context.swift:122-141) memory-maps `<id>.v<projectionVersion>.ztsi` and adopts it when `LexicalIndex.validate` passes (LexicalIndex.swift:187-207). `fingerprint(of:)` (181-199) mixes only id, kind, UTF-8 length of `searchText`, UTF-8 length of the title and `updatedAt`. The limitation is noted only in that internal doc comment ("Edits that keep all of them need an explicit refresh()"). Neither the public `refresh()` doc (line 42), the README nor the spec tells hosts this.
- Spec check: section 6 (p10) requires discarding on a projection, normalizer or model mismatch, and 9.1 rule 6 keys the file by contextID + projectionVersion. Content validation is not specified, but `init(context:)` is "ready on return" over the context's items, so serving content other than those items is a defect of the optimisation.
- Own harness scenario C (600 Tool items, `.indexed`, `.files(dir)`; v2 keeps ids, titles and text lengths, changes keyword alpha->omega, category trackers->calculators, text word cat->dog): v2 `omega=0 alpha=20 dog=0 cat=20`, filter calculators=0, trackers=200. Stored t5 still has keywords ["alpha"] and category=trackers. Control v3 with a text-length change is rebuilt (`omega=20`); `refresh()` heals v2.
- Scenario C2, the most realistic trigger: an app update that adds Italian translations to existing items. For an Italian user, v2 'porto' gives 0 hits against 20 for a fresh service; the stored title is still "Frozen Harbor 3". Caches survive app updates, so this persists until `refresh()` or a length-changing edit.

### C1-s03-engine-api-05 — Int overflow trap in snapshot slicing
Verdict: confirmed (medium).
- Code read: ScanIndex.swift:76-77 and SearchService.swift:465-466 both compute `start + max(0, query.limit)` with `start` clamped to `0...count`. Nothing bounds `limit` (SearchQuery.swift:34, public var), and `SearchCursor(offset:)` is public. Overflow traps in `-O` builds too; only `-Ounchecked` removes the check.
- Own harness (one process per path, each SIGTRAP = exit 133): D1 `ScanIndex.hits` with limit .max and cursor 1; D2 `results(for:)` with the same; D3 `page(after: SearchCursor(offset: 1), generation:)` after a limit-.max query; D4 page 1 at limit 1, then the cursor it returned with the limit widened to .max ("load the rest"). Controls: limit .max without a cursor returns all hits, and D5 limit `Int(Int32.max)` with cursor 1 returns ["b","c"].
- A crash from public API with legal values. Medium is fair: it needs a sentinel-sized limit (within `offset` of Int.max) together with a non-zero offset.

### C1-s03-engine-api-06 — databasePageSize <= 0 set after init loops the row reader forever
Verdict: confirmed (low).
- Code read: the clamp `max(1, databasePageSize)` runs only in `SearchEngineConfiguration.init` (SearchEngineConfiguration.swift:195), while the property is a public var (142). `SearchRowReader.pages` (SearchSQLComposer.swift:131-143) stops only on `rows.count < pageSize` and advances by `pageSize`. Nothing in SearchService clamps it again.
- Own harness scenario E (one-row table, value set after init): pageSize 1 -> 2 transactions, ready. pageSize 0 -> 60,362 read transactions after 1 s and 123,828 after 2 s, never ready. pageSize -1 -> 52,525 and 93,796, never ready. Against real SQLite, `LIMIT -1` means no limit, so a negative value would also append the whole table to the result on every pass, an unbounded memory growth.
- Low is fair: it needs a nonsensical value assigned after init (someone might read 0 as "no paging"). Other init-only clamps (scanThreshold, minimumQueryLength, SearchLimits fields) share the pattern.

### C1-s03-engine-api-07 — scan scoring checks cancellation every 256 documents, not every 1,000 postings
Verdict: confirmed (low). A literal deviation with little practical effect.
- Code read: ScanEngine.swift:147-149 checks `document % 256 == 0`, and the inner loop (155-170) walks every (term, field) entry of the document, including terms the query does not use. IndexSearcher.swift checks every 1,000 units of work (685, 789, 852) and every 16 visits at 956. The scan has no postings, but its entries are the transposed postings, and spec rule 4 (p24) speaks of "scoring loops".
- Measured in the own harness, scenario G (debug build; forced `.scan`; 5,000 documents x 200 random words; 8-term query): full search about 90 ms, so about 4.7 ms of scoring per 256-document gap. That is about 51,000 entries per gap, 51 times the spec's figure, yet still under the 10 ms liveness target even unoptimised. With 1,000-word documents the gap would be about 5 times longer. Reach: `.automatic` keeps scan contexts at <= 500 documents, i.e. at most 2 gaps. Low is right.

### C1-s03-engine-api-10 — during-search cancellation test accepts far more than 10 ms
Verdict: partly (real, and weaker than described). The test does not merely have a loose bound: what it measures does not depend on the checkpoints at all. The finding's claim that it "still catches the complete absence of checkpoints" is wrong for this test. Severity stays low.
- Code read: ConcurrencyTests.swift:49-80 measures `cancelledAt -> await task.value` of the consuming task. Once that task is cancelled, the `AsyncStream` iterator's `next()` returns nil without waiting for the producer, so the time reflects stream termination, not the producer's checkpoint cadence. `interrupted` is also consumer-side.
- Own harness scenario T, a replica of the test (RandomCorpus(seed: 4242), 30,000 items, same query and attempts) that also awaits the producer (`activeTask`) after the cancel:
  - Verbatim core: full search 21.4 ms, bound 15.3 ms; consumer-side worst 0.35 ms (passes); producer-side worst 8.88 ms.
  - Scratch variant with every `Task.checkCancellation()` removed from IndexSearcher (core-nocheck, scratch only): full 12.3 ms, bound 13.1 ms; consumer-side worst 0.02 ms, so the test still PASSES, while the producer ran 16.21 ms after the cancel.
- What does catch a total absence: `testTheScoringLoopChecksCancellation` (ConcurrencyTests.swift:82-107) runs `index.search` in an already-cancelled task and expects CancellationError, so it fails without any checkpoint. No test verifies the cadence (every 1,000 postings) or the 10 ms figure on the producer side.
- Corrected description: the during-search test asserts on the consumer's stream termination, which is immediate whatever the producer does. A coarser cadence, or no checkpoint at all in IndexSearcher, still passes it. Only the existence of a checkpoint is covered, by the already-cancelled test. Low: a test-integrity gap; the measured producer-side latency with the shipped checkpoints was under 10 ms even in a debug build.

### C1-s03-engine-api-08 — changing pageSize during a search leaves the previous query's hits on screen
Verdict: confirmed (low).
- Code read (UI model, Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift):
  - The `pageSize` setter (78-81) rewrites `query.limit` of the query in flight, while the service's snapshots carry the limit the query was started with (SearchService.run -> Retained.query).
  - `apply` (130-131) then rejects every snapshot (`snapshot.query == query` is false). `streamEnded` (149-152) clears `isLoading`.
  - `update` (65-70) copies the new limit into `next` and returns early for the same text. Only `submit()` or a text change recovers.
  - `pageSize` is an addition of the implementation: the spec's ZTronSearchResultsModel API (p33) has no such member. The violated rules are the model's own "isLoading ... until the final snapshot or a cancellation" (p34) and the stale-results liveness row (p25).
- Own harness scenario H (verbatim copies of ZTronSearchResultsModel.swift and ZTronSearchToken.swift compiled into the harness; indexed service with a 120 ms lexical debounce; items Harbinger and Harbor map):
  - Control: 'harb' -> [a, b], then 'harbor' -> [b].
  - With `pageSize = 30` set right after `update("harbor")`: hits stay [a, b] under the text 'harbor' with `isLoading == false`, and a repeated `update("harbor")` changes nothing.
- Low is fair: it needs a pageSize change while a stream is in flight; the stale list persists until the text changes or a submit.

### C1-s03-engine-api-09 — suggestions run on their own timer, not the lexical timer
Verdict: confirmed (low).
- Code read: ZTronSuggestionsModel (ZTronSearchResultsModel.swift:226, 235-259) sleeps on its own `debounce` (default 0.120), and `SearchService.suggestions(for:limit:)` (SearchService.swift:818) has no timer. The only lexical timer is `configuration.lexicalDebounce` inside `run` (SearchService.swift:394), and `configuration` is internal, so the UI module cannot even read it. The spec's init (p33) has no debounce parameter, which is consistent with sharing the service's timer. The test `testSuggestionsShareTheLexicalTimer` (ResultsModelTests.swift:317-329) passes `debounce: 0.12` itself.
- Own harness scenario S: with `lexicalDebounce = 0.400`, the suggestions request goes out after 125 ms. The two timers diverge as soon as the host tunes either one; with the defaults they coincide. Low.

## Summary

| id | verdict | severity (skeptic) | auditor severity |
|----|---------|--------------------|------------------|
| 01 | partly | high | critical |
| 02 | partly | medium | high |
| 03 | confirmed | high | high |
| 04 | confirmed | medium | medium |
| 05 | confirmed | medium | medium |
| 06 | confirmed | low | low |
| 07 | confirmed | low | low |
| 08 | confirmed | low | low |
| 09 | confirmed | low | low |
| 10 | partly | low | low |

Side observation, outside the assigned list (reproduced, scenario X): a mixed context (memory plus a table) with `.files` storage adopts its persisted index at relaunch through `adoptPersistedIndex` (SearchService+Context.swift:673-703, fingerprint ""), with no content check. The memory items handed at launch are ignored: relaunched with [mem-2 Zeppelin] instead of [mem-1 Harbor], 'zeppelin' gave [] and 'harbor' gave ["mem-1"]. A row changed while the app was not running is not seen ('quokka' -> []). This is the same family as -03 and weaker still for database contexts.

Harness: /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s03-engine-api-skeptic/harness/{Main,Extra,UIRepro}.swift, binary `repro <scenario>`. The core is a byte-identical copy of Sources/ZTronSearchEngine; `repro-nocheck` links core-nocheck (IndexSearcher checkpoints removed, used only for -10). Nothing was built or run in the repository.

STATUS: complete
