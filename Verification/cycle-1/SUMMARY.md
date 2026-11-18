# Cycle 1 summary — requirement-centric

Six auditors traced the specification into the code and tests, one slice each; one skeptic per slice then tried to refute every finding (re-reading the spec and code, with standalone repro programs where useful). Workflow run `wf_b8497706-638`: 12 agents, 2.58M subagent tokens, 47 minutes. Full per-agent notes: `find-<slice>.md` (requirement tables) and `verify-<slice>.md` (verdicts). Machine-readable: `result.json`.

## Requirements traced

| Slice | Requirements | Met | Partial | Missing | Contradicted | Unverifiable here |
|---|---:|---:|---:|---:|---:|---:|
| s01-contracts | 80 | 67 | 12 | 0 | 0 | 1 |
| s02-retrieval | 52 | 45 | 5 | 0 | 0 | 2 |
| s03-engine-api | 69 | 61 | 5 | 0 | 1 | 2 |
| s04-ui | 66 | 45 | 17 | 0 | 3 | 1 |
| s05-chat | 47 | 33 | 9 | 0 | 2 | 3 |
| s06-quality | 165 | 100 | 30 | 5 | 8 | 22 |
| **total** | **479** | **351** | **78** | **5** | **14** | **31** |

## Findings: 64 reported, 36 confirmed, 27 partly confirmed, 1 refuted, 0 uncertain

Surviving findings by verified severity: 0 critical, 10 high, 25 medium, 28 low.

Found independently by two slices (counted once in the cross-cycle report): s01-01 = s03-03 (persisted-index fingerprint), s01-02 = s03-02 (localized key equal to its value), s03-08 = s04-05 (pageSize change during a search), s04-01 = s06-01 (UI parity gate), s01-04 ⊂ s06-02 (XCTExpectFailure budgets).


## High

### C1-s01-contracts-01 — Persisted context index adopted after item content changes: fingerprint ignores keywords, filters, localizations, caption, OCR and text content

- Verdict: **partly**; severity critical → high; category bug; spec 6 p10 (document built once from item + active locale); 5 p8; 1 p1
- Where: `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:181-199`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:122-141`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:187-207`, `Sources/ZTronSearchEngine/Contracts/SearchContext.swift:24-28`
- What: An indexed memory context (custom id, no database source, over 500 items or .indexed) with the default .files(Caches/ZTronSearchEngine) storage adopts the previous launch's index file whenever the weak content fingerprint is unchanged. The fingerprint is item count plus each item's id, kind, text and title UTF-8 byte counts and updatedAt. Updates that only add or change localizations, keywords, filters, caption, OCR text or same-length text are therefore served stale on every launch until refresh() or a cache purge. Severity high: silent and persistent, but it needs that update pattern and is …
- Skeptic: The defect is real. I reproduced it with my own swiftc build of unmodified copies of core and fixtures (probe p01). With 600 tools, locale it and .files(dir), v2 changed t0's keyword (alpha to bravo) and filter (ios to mac) and added an Italian title, keeping lengths. Results: fingerprint v1 == v2 true; 'bravo' -> []; 'martello' -> []; 'alpha' -> [t0]; hammer+platform=mac -> []; hammer+platform=io…

### C1-s03-engine-api-01 — index/remove/replace racing a rebuild are silently undone

- Verdict: **partly**; severity critical → high; category concurrency; spec Section 11 rule 5 (p24: every await inside SearchService is followed by a generation check before state is touched); section 9 rule 9 (p17: upsert/remove take effect for the next query); section 9.2 rule 5 (p22)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService.swift:199-207`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService.swift:242-255`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService.swift:892-903`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService+Context.swift:239-259`
- What: Host mutations (index, remove, replace(items:)) that run while a rebuild is suspended are silently undone when the rebuild installs its stale snapshot of memoryItems. A rebuild is suspended during database reads of any size, or the >= 2,000-item off-actor projection of refresh() and the narrow setLocale path. Effects: upserts vanish, removed items reappear, and the service's memoryItems disagree with the index.

With .files storage the stale index is persisted under a fingerprint of the post-mutation items, so it is adopted again at the next launch. It persists until the items change or refres…
- Skeptic: The mechanism is confirmed by reading the code. upsert (SearchService.swift:242-255), remove (199-207) and replaceMemory (SearchService+Context.swift:239-259) neither take rebuildLock nor bump sourceRevision; rebuildLock is taken only by rebuild and the change-stream apply. rebuildLocked snapshots memoryItems at line 362 and later installs that snapshot wholesale, either through LexicalIndex.repla…

### C1-s03-engine-api-03 — Persisted index adopted on a fingerprint that ignores most content

- Verdict: **confirmed**; severity high; category bug; spec Section 9.1 rule 6 (p19, indexed context persists under its own file); section 9 rule 9; section 15.3 filter precision (no hit may violate a hard constraint)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService+Context.swift:122-141`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService+Context.swift:181-199`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Index/LexicalIndex.swift:204-206`
- What: On init an indexed context with .files storage memory-maps <id>.v<projectionVersion>.ztsi and adopts it when LexicalIndex.validate passes. The contentFingerprint it validates against (fingerprint(of:)) mixes only id, kind, the UTF-8 length of searchText, the UTF-8 length of the title and updatedAt. Keywords, caption, OCR text, localizations, filters, embeddings and the text content itself beyond its byte length are ignored. After an app update that edits any of them (same ids, same text/title lengths, no TemporalSearchable), the stale index is served, including stale filter postings, until the…
- Skeptic: Code read: prepare (SearchService+Context.swift:122-141) adopts the mapped .ztsi file when validate passes. fingerprint(of:) (181-199) mixes only id, kind, the UTF-8 lengths of text and title, and updatedAt. The limitation is documented only in that internal comment; there is nothing in the README, the public refresh() doc or the spec. Spec section 6 requires discarding only on a projection, norma…

### C1-s04-ui-01 — Parity gate of 12.5/15.7 not met; most of the matrix never ran

- Verdict: **confirmed**; severity high; category spec-missing; spec 12.5 p31-32, 15.7
- Where: `ParityHost/Results/summary.md:7-29`, `ParityHost/Results/summary.csv`, `ParityHost/Tools/gate.py`, `README.md:216-218`
- What: The matrix needs 5 iOS x 4 devices x 800 = 16,000 cells. The committed run has 7,440 results: 179 pass, 602 fail, 6,659 not runnable. iOS 15.5 and 16.4 never ran (3,200 each not runnable). No RTL cell passes, no bold-text cell passes, and no iPhone SE, iPad or iOS 27 cell passes.
- Skeptic: I re-tallied summary.csv: 7,440 rows, with 179 pass, 602 fail and 6,659 not runnable. iOS 15.5 and 16.4 have 3,200 not-runnable cells each. Zero cells pass for RTL, bold-text, iPhone SE, iPad, iOS 27.0, XS, XXXL or AX5; only L passes. I ran a scratch copy of gate.py and summarize.py on the committed results. It printed '16000 cells: 179 pass, 602 fail, 6659 not-runnable, 0 not-applicable, 8560 mis…

### C1-s04-ui-02 — Metrics and behavior sampled only for iOS 17 and 18; iOS 15/16 floor and iOS 26+ silently reuse the nearest version

- Verdict: **confirmed**; severity high; category spec-deviation; spec 12.2 rule 5, 12.4 p31
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics+Sampled.swift:8`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics+Sampled.swift:394-400`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics.swift:218-240`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics.swift:271-273`
- What: sampledVersions is [17, 18]. metrics(forMajorVersion:contentSize:) and behavior(forMajorVersion:) fall back to the nearest sampled version. On the iOS 15/16 floor, every metric and recorded behavior is iOS 17's, including clearRemovesTokens, which the spec says must be 'recorded per iOS version from the reference, never assumed'. On iOS 26/27, the field gets iOS 18's values.
- Skeptic: sampledVersions is [17, 18] (Sampled.swift:8), and the behavior table has only 17 and 18 (:394-400). nearestSampledVersion, metrics(forMajorVersion:) and behavior(forMajorVersion:) fall back to the nearest sampled version (Metrics.swift:224-241, 271-273). The field reads both through runningMajorVersion (ZTronSearchField.swift:70, :581), and the package floor is .iOS(.v15). Only ios-17.json and io…

### C1-s05-chat-01 — An interrupted calibration persists a failing verdict, so chat stays off on a capable device until the next app or OS update

- Verdict: **confirmed**; severity high; category bug; spec 14.4 p40: one-time calibration after first load, verdict persisted, recomputed after app/OS update; .auto gate
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:303-350`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:335-341`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:282-298`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:276`
- What: calibrationPasses ignores the stop reason of .finished. It treats a thrown error, or a run with no delta, as a measured failure and writes false to the verdict store. A run has no delta when it is cancelled during the 512-token prefill, which happens on:
- the stop button;
- a second send in the same session;
- the .zTronChat view disappearing, since it calls cancel;
- the consumer dropping the stream;
- a memory warning or unload() during the first load (MLX unload calls cancelAll, which finishes the stream with .cancelled).

Under .auto, load() then unloads and settles .unavailable(.device),…
- Skeptic: I reproduced this independently. I used the repository's own FakeLanguageModel and fresh copies of the core sources, not the auditor's MLX-like model. Setup: availability .auto, files on disk, gate() = ready, and the first send calibrates on the turn path.
- A: ChatService.cancel 0.15 s into a 0.6 s prefill persisted [...fake-llm-4bit@0123abcd: false]. prepare() in the same process gave [unavailab…

### C1-s05-chat-02 — Calling prepare() again during a download cancels and restarts the download, or leaves readiness stuck

- Verdict: **confirmed**; severity high; category concurrency; spec 14.1 p38: .downloading attaches to the running fetch; 14.4 p40-41: the engine only observes; 14.5 p41: .zTronChat prepares on appear
- Where: `Sources/ZTronSearchEngineUI/ZTronChatModel.swift:80-92`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:146-148`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:157-163`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:180-187`
- What: ZTronChatModel.prepare cancels its previous consumer task and starts a new one. Cancelling the old consumer ends its stream, and onTermination schedules removeObserver in an unstructured Task. Nothing orders that Task against the new prepare() call on the actor, so two outcomes are possible.

(a) removeObserver runs first. There are no observers while .fetching, so the preparation is cancelled. The adapter detaches and cancels the AssetKit transfer, which discards the partial. Lifecycle goes to .idle, and the new prepare() starts another fetch.

(b) The new observer attaches first, but the old…
- Skeptic: I reproduced this in 24 trials with the repository's FakeModelAssetProvider and a fresh copy of ZTronChatModel, calling prepare twice while a fetch was running.
- Main actor idle after the second call: 3 of 6 attached correctly. The other 3 of 6 were cancelled and stuck: lifecycle idle, fetchCalls 1, cancelledFetches 1, and UI readiness frozen at downloading(300 of 1000).
- Main actor busy for 1, …

### C1-s06-quality-01 — Section 15.7 UI parity gate is not met on the 12.5 matrix

- Verdict: **confirmed**; severity high; category spec-deviation; spec 15.7 p45; 16 p48 (parity suite); 17 milestone 4 gate
- Where: `ParityHost/Results/summary.md:1-30`, `README.md:216-218`, `.github/workflows/parity.yml`, `ParityHost/Tools/gate.py`
- What: As stated. In addition, 8,560 of the 16,000 cells of the 12.5 matrix (800 per iOS and device) were never attempted (no result file on 17.5, 18.6 or 27.0). The worst values are 98.367% of pixels and 890 pt, on iOS 27.0.
- Skeptic: Recounted ParityHost/Results: 7,440 result files (3,200 for 15.5, 3,200 for 16.4, 440 for 17.5, 440 for 18.6, 160 for 27.0). Of these, 781 ran, 179 passed, 602 failed and 6,659 were not runnable. No iPad or iPhone SE cell passes on any iOS, and iOS 27.0 passes nothing. Every pass is at content size L, left to right, on iPhone 15 or 15 Pro Max. The failures are real comparator failures in the initi…

### C1-s06-quality-02 — PerformanceTests turn missed budgets into XCTExpectFailure, and the unscoped expectation also absorbs later assertions

- Verdict: **confirmed**; severity high; category test-integrity; spec 15.1 p42-43 (locale rebuild 2 s never blocking a query; upsert 0.1 ms); 15.8 p46
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:301-328`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:330-398`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:527-537`
- What: As stated. In addition, the waiver also applies on the reference device itself, where the milestone gate is supposed to be settled. The comment claiming strictness is wrong.
- Skeptic: PerformanceTests.swift:77-81 calls XCTExpectFailure(knownGap) without a block only when the measurement is over budget. The knownGap call sites are at 323-326, 396-397 and 534. In the same tests, line 327 (XCTAssertLessThan(worstQuery, 0.25), 'a query never waits for the rebuild') and line 535 (scan-query check with no knownGap) come after. My own scratch XCTest (xfail2/, swift test) recorded both…

### C1-s06-quality-03 — Local chat grounded-answers target has no 100-question golden set and no measurement

- Verdict: **confirmed**; severity high; category spec-missing; spec 15.6 p45 (grounded answers); 17 milestone 8 gate
- Where: `Sources/ZTronSearchFixtures`, `Tests/ZTronSearchEngineTests/ChatTests.swift`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift`, `Sources/ZTronSearchEngine/Chat/CitationParser.swift:104-140`
- What: The spec requires a 100-question golden set over the corpus, with at least 90% of answers citing a correct source, 100% of unknown citations dropped, and at least 80% declining when the sources do not cover the question. The repository has no such fixture and no test or harness that computes citation accuracy or decline rate, whether with fakes or with Qwen3.
- Skeptic: The fixtures contain no chat golden set; only GoldenSet/GoldenCorpus for 15.3 exist. Grep of the chat sources, ChatTests, FakeChatBoundaries and the MLX adapter finds no question set, no expected-source or should-decline labels, and no computation of citation accuracy or decline rate. Qwen3IntegrationTests covers load, TTFT and decode, cancellation, footprint, seeds, thinking mode and the context …


## Medium

### C1-s01-contracts-02 — Localization key equal to its resolved value is treated as unresolved; the base-language string is dropped and another language becomes the base

- Verdict: **partly**; severity high → medium; category bug; spec 5.12 p9; 9.2; 5 p8
- Where: `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:124-136`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:148-150`, `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/BundleLocalizedStringResolver.swift`, `Tests/ZTronSearchEngineTests/DatabaseSourceTests.swift:45-53`
- What: SearchRowProjector drops every resolved string equal to its key. This defends 9.2 rule 3 against resolvers that echo missing keys, because the protocol never defines nil as missing. As a side effect, hosts whose keys equal a resolved value (source-text keys with explicit values, or a key-echoing resolver) lose that language's value. The next differing language becomes the base surface, and keys equal in every language index nothing. With String Catalogs' implicit source values, the reference adapter already returns nil for the development language. Fixing the English case therefore also needs …
- Skeptic: Reproduced (probe p02, fake DB and resolver, order [en, de, it], English locale with .none). 'Bluetooth' has no title and is reported as an unresolved key. 'Settings' is indexed as Einstellungen, language de. 'bluetooth' and 'settings' both return []. A dotted-key control works. The same happens under .all and under locale it. The cause is the guard `string != value` at SearchRowProjector.swift:12…

### C1-s01-contracts-03 — Two-character CJK words miss exact-title queries when the query is segmented in a different CJK language than the field

- Verdict: **partly**; severity high → medium; category bug; spec 5.5 p9; 5.10 p9; 1 p1
- Where: `Sources/ZTronSearchEngine/Text/SearchTokenizer.swift:152-171`, `Sources/ZTronSearchEngine/Text/SearchTokenizer.swift:244`, `Sources/ZTronSearchEngine/Query/QueryParser.swift:76-77`, `Sources/ZTronSearchEngine/Query/QueryParser.swift:145`
- What: Two-character CJK words, the commonest Chinese word length, miss exact queries typed in a different CJK variety than the active locale. Examples are Simplified in a zh_TW engine, Traditional in a zh_CN or ja engine, and Japanese 図 forms in a Chinese engine. The query segmenter splits the word into single characters; the parser drops query bigrams, and its fallback needs 3+ characters. Same-language queries work. This affects 5.3 secondary-language hits for CJK bilinguals. Medium.
- Skeptic: The mechanism is as described, and I reproduced it with probe p03, the same for indexed and scan strategies. '地圖' gives [地, 圖, bigram] under zh-Hans and [地圖] under zh-Hant. Parsed in zh-Hans, it gives clauses 地 and 圖 with no fallback, because QueryParser drops query bigrams (76-77) and the fallback needs 3+ characters (145). Exact-title misses: zh_CN 地圖 (zh-Hant) and 地図 (ja); zh_TW 地图 and 地図; ja 地…

### C1-s01-contracts-04 — The 2 s / 100k locale-rebuild budget test cannot fail: an over-budget result becomes XCTExpectFailure

- Verdict: **partly**; severity high → medium; category test-integrity; spec 5.7 p9 (Budget: 2 s for 100k items); 15.1
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-86`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:301-328`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:58-62`, `Sources/ZTronSearchFixtures/ReferenceDevice.swift:72`
- What: check() registers XCTExpectFailure(knownGap) only when over budget, so the 2 s locale-rebuild check passes at any speed. Over budget, the expectation also absorbs the test's later 'never blocking a query' assertion (PerformanceTests.swift:327). The CI release job runs the test, but it cannot fail on either target; the 'strictly' comment is false. Call sites 396, 397 and 534 share the pattern. Medium test-integrity issue.
- Skeptic: Confirmed with a scratch SwiftPM package holding a verbatim copy of check(), run as async tests that hop actors first (probe p04). 10x over budget with a knownGap passes as an expected failure. Within budget it passes. A control without knownGap fails. The 'strictly' comment is false. Corrections: .github/workflows/ci.yml has a 'Section 15 targets (release build)' job that runs the PerformanceTest…

### C1-s01-contracts-05 — Secondary languages de-duplicated by primary subtag: zh-Hant, sr-Latn and pt-BR never reach localizedAlt, even via .explicit

- Verdict: **partly**; severity medium; category spec-deviation; spec 5.3 p9
- Where: `Sources/ZTronSearchEngine/Text/LanguageTag.swift:68-81`, `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:4-13`
- What: Secondary languages are de-duplicated by primary subtag, so script and regional variants of the active language (zh-Hant under zh-Hans, sr-Latn under sr-Cyrl, pt-BR under pt-PT) never reach localizedAlt, even via .explicit. Example: a pt-PT user with pt-BR, or a sr-Cyrl user with sr-Latn, cannot find an item by the other variant's title. For zh-Hans/zh-Hant, finding 03 must also be fixed before Traditional queries hit.
- Skeptic: The code claim holds. ResolvedLanguages.init (LanguageTag.swift:68-81) de-duplicates secondaries by primary subtag, also for .explicit, although the projector's consumed-tag set already removes duplicate tags. Probe p05: pt_PT with [pt-PT, pt-BR] gives secondary [] and 'onibus' -> [] under preferred and explicit, and a hit under .all. sr_Cyrl_RS with [sr-Cyrl-RS, sr-Latn-RS] gives secondary [] and…

### C1-s01-contracts-07 — Id collisions not debug-asserted for contexts; cross-kind collisions across index batches unchecked above 512 documents

- Verdict: **confirmed**; severity medium; category bug; spec 4 p6 (SearchableID unique across kinds; collision is a debug assertion)
- Where: `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:97`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:242`, `Sources/ZTronSearchEngine/Service/SearchService.swift:1002-1004`, `Sources/ZTronSearchEngine/Service/SearchService.swift:1017-1030`
- What: Context prepare and replace(items:) run lastOccurrences before projection, so the duplicate check never sees the collision. There is no diagnostic and no assertionFailure, and the earlier item is silently replaced, even across kinds. reportKindCollisions returns early when 'documents.count > 512', so a later large index(_:) batch that reuses an id under another kind replaces the document silently.
- Skeptic: Probe p07 used assertsOnProgrammerError at its default (true). A context (scan and indexed) holding Tool 'dup' and MapItem 'dup' gives 'hammer' -> [] and 'harbor' -> [dup:map], with no diagnostic and no trap, also after replace(items:). A second index batch of 600 with a cross-kind clash gives no diagnostic, and the kind silently becomes map. A single batch with both items traps ('SearchableID dup…

### C1-s02-retrieval-01 — Indexed semantic channel applies hard constraints after ANN retrieval; filtered queries lose their semantic matches and disagree with the scan strategy

- Verdict: **partly**; severity high → medium; category spec-deviation; spec Section 8 p14 (filters and kind tokens are hard constraints applied before retrieval); section 7.3 p12 (HNSW returns top 50); section 10 p23 (50 HNSW neighbours); section 15 scan/indexed parity
- Where: `Sources/ZTronSearchEngine/Service/SearchService.swift:554-558`, `Sources/ZTronSearchEngine/Service/SearchService.swift:605`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:293-317`, `Sources/ZTronSearchEngine/Contracts/SemanticBoundary.swift:33`
- What: In indexed contexts the semantic channel applies kind, filter and phrase constraints only after an unconstrained ANN fetch of 200 neighbours (ef raised to 200), contrary to section 8's 'applied before retrieval' and above the 50-neighbour bounded work. Constrained semantic recall falls to about 200 x (constrained share) items: 1-2 hits instead of up to 50 at a 1% share, and none when more than 200 non-matching items outrank every match. Precision and the lexical and fuzzy channels are unaffected. The scan strategy pre-filters and keeps them. Medium.
- Skeptic: Mechanism confirmed in code. With constraints, SearchService.swift:557-558 asks nearest(to:limit:) for 200 neighbours. SemanticBoundary.swift:33 takes no constraint. LexicalIndex.resolve (293-317) drops violators afterwards and keeps 50. HNSWGraph.swift:192 raises ef to 200. Core has no exhaustive or constrained fallback for indexed contexts. ScanEngine.nearest (335-361) effectively pre-filters. T…

### C1-s02-retrieval-02 — RankingProfile caps (3 pins, rerank topN <= 32, blend 0...1) enforced only in initializers; public property setters bypass them

- Verdict: **confirmed**; severity medium; category api; spec Section 8 p15 (pins limited to 3 per query); section 7.4 p13 (top 16, configurable, at most 32; blend 0.7/0.3 so one confident pass cannot push an exact-title hit out of the head)
- Where: `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:75`, `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:78-80`, `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:90-97`, `Sources/ZTronSearchEngine/Query/Fusion.swift:197`
- What: EditorialPolicy.maximumPins, RerankSpec.topN and RerankSpec.blend are public vars whose clamps exist only in init. ResultRanker.applyingPins, SearchService (prefix(spec.topN)) and SearchPipeline.reranked read the stored values without re-clamping. Mutating a profile with the usual Swift idiom (var p = RankingProfile.default; p.editorial.maximumPins = 6) breaks the documented and specified ceilings. RankingTests.swift:64-65 checks only the initializer path.
- Skeptic: RankingProfile.swift:75, 90 and 92 are plain public vars with no didSet. Their clamps exist only in the inits (78-80, 94-97). The consumers read the raw values: Fusion.swift:197/205, SearchService.swift:449 and SearchPipeline.swift:156/165. The engine does clamp other bounded profile values at use: kindBoost(for:) at RankingProfile.swift:166-169, affinity at Fusion.swift:239 and popularity weight …

### C1-s03-engine-api-02 — Localized key whose string equals the key is treated as unresolved

- Verdict: **partly**; severity high → medium; category bug; spec Section 9.2 rule 3 (p21-22): keys are resolved through LocalizedStringResolving with the section 5 fallback chain; only an unresolved key indexes nothing
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:125-126`
- What: SearchRowProjector treats a resolved string equal to its key as unresolved (SearchRowProjector.swift:125-126). This deliberately guards against resolvers that echo the key for missing entries, the naive Bundle.localizedString implementation the spec hints at, but it contradicts the resolver contract (nil means unresolved).

The cost falls on key-as-source-text catalogs with explicit identity entries ('Settings' = 'Settings'). The development-language surface of such database fields is dropped: another language becomes the base surface, or, in a single-language catalog, the field indexes nothin…
- Skeptic: The behaviour is reproduced (scenario B, FakeLocalizedStringResolver, locale en, key 'Settings'):
- en+it catalog with the identity entry: the title becomes 'Impostazioni' and 'settings' finds nothing.
- en-only catalog: the title is nil.

The finding's claim that the check 'only drops real translations' is wrong. The spec itself suggests a host resolver built on Bundle.localizedString(forKey:valu…

### C1-s03-engine-api-04 — Concurrent upsert lost while an .automatic context is promoted to an index

- Verdict: **confirmed**; severity medium; category concurrency; spec Section 11 rule 5 (p24); section 9.1 SearchStrategy.automatic (p17)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService+Context.swift:227-237`
- What: rebalanceStrategy builds a LexicalIndex from engine.documents, awaits index.replaceAll, then only checks `case .scan(let current) = storage, current.count == engine.count` before switching storage to the new index. An upsert that replaced an existing document during the await keeps the count unchanged, so the promoted index is built from the pre-upsert documents and the update is lost. No generation or revision is checked.
- Skeptic: Code read: rebalanceStrategy (SearchService+Context.swift:227-237) awaits replaceAll over engine.documents, then checks only `current.count == engine.count`. ScanEngine.init (ScanEngine.swift:32-44) de-duplicates by id with the last occurrence winning, so an edit of an existing id during the await keeps the count. The promoted index then carries the pre-edit document, and the second caller's rebal…

### C1-s03-engine-api-05 — Int overflow trap in snapshot slicing with a large limit and a cursor

- Verdict: **confirmed**; severity medium; category bug; spec Section 9 (SearchQuery.limit/cursor, page(after:generation:), p15-17); section 9.1 ScanIndex.hits(for:) (p18)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Scan/ScanIndex.swift:77`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Service/SearchService.swift:466`
- What: Both slice computations use `let end = min(count, start + max(0, query.limit))`. limit and cursor are public settable values, and SearchCursor(offset:) is public. With limit near Int.max and an offset > 0 the addition overflows and traps instead of clamping. This affects ScanIndex.hits/snapshot, results(for:) with a cursor, and page(after:generation:) for a retained query with such a limit.
- Skeptic: Code read: ScanIndex.swift:76-77 and SearchService.swift:465-466 compute `start + max(0, query.limit)` with an unbounded public limit, and SearchCursor(offset:) is public. Overflow traps in -O builds too.

Each path crashed with SIGTRAP (exit 133) in its own process:
- D1: ScanIndex.hits with limit .max and cursor 1.
- D2: results(for:) with the same query.
- D3: page(after: SearchCursor(offset: 1…

### C1-s04-ui-03 — Host cannot override the return-key label

- Verdict: **confirmed**; severity medium; category spec-deviation; spec 12.1 p27
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:342`
- What: The field applies .submitLabel(.search) directly to the inner TextField. SubmitLabel is an environment value and the innermost one wins, so a host's .submitLabel(.go) on ZTronSearchField never reaches the TextField. The spec says the host may override the default.
- Skeptic: ZTronSearchField.swift:342 applies .submitLabel(.search) directly to the inner TextField. Nothing else in Sources handles submitLabel or returnKey. My own macOS SwiftUI probe printed type(of: Text("x").submitLabel(.go)) == ModifiedContent<Text, _EnvironmentKeyWritingModifier<SubmitLabel>>, which is an environment write. A view under an inner .search and an outer .go sees search first. The control …

### C1-s04-ui-04 — Smart-punctuation emulation rewrites the whole text on every keystroke

- Verdict: **confirmed**; severity medium; category bug; spec 12.1 p27, 12.3 p30
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:89-105`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:228`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:241`
- What: On every input change, plain() maps U+2018/2019, U+201C/201D, U+2014 and U+2013 to ASCII anywhere in the text. Typographic characters that are already there (set by the host, pasted, or typed by long-press) get rewritten as a side effect of the next keystroke, and the logged change becomes a multi-character replacement instead of an insertion.
- Skeptic: Line :228 computes proposed = plain(strip(raw)) on every input change, and plain() (:91-105) maps the typographic characters wherever they appear in the text. Line :241 diffs the old text against that. Host text enters the core unfiltered through adopt() (:180-188). The UIKit reference sets smartQuotesType and smartDashesType to .no (ReferenceField.swift:45-46), so it keeps such characters. My rep…

### C1-s04-ui-05 — Setting pageSize during a search keeps the previous query's hits on screen; reset() drops pageSize

- Verdict: **confirmed**; severity medium; category bug; spec 13 p34
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:78-81`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:65-70`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:130-131`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:149-152`
- What: The pageSize setter changes query.limit without bumping the revision or restarting the search. Snapshots from the in-flight stream carry the old limit, fail snapshot.query == query and are dropped. When the stream ends, isLoading is cleared. A later update() with the same text returns early because the query is equal. reset() builds SearchQuery(text: "") and silently goes back to the default page size.
- Skeptic: The pageSize setter writes only query.limit (:78-81). SearchQuery's synthesized == includes limit (SearchQuery.swift:24-35), and service snapshots carry the query they were started with (SearchService.swift:469-470). As a result apply() drops them (:131), streamEnded() clears isLoading (:149-152), and update() with the same text returns early (:65-70). reset() builds SearchQuery(text: "") (:89), w…

### C1-s04-ui-06 — Attach lint checks the whole repository at once, and its in-repo run cannot fail

- Verdict: **confirmed**; severity medium; category test-integrity; spec 13.1 rule 3 p36; 16 p49
- Where: `Sources/ZTronSearchFixtures/SourceLint.swift:211-240`, `Tests/ZTronSearchEngineUITests/LintTests.swift:154-161`
- What: Attachment is decided per model type across all scanned files, and any .environmentObject( call, for any object, counts as attaching every model. A screen that reads a model without being under an attaching modifier passes as long as another file attaches that type or injects anything at all. The in-repo test scans ParityHost and a non-existent Examples directory, which contain no @EnvironmentObject reader.
- Skeptic: SourceLint.swift:222-227 treats a model as attached if any scanned file contains its modifier, or contains the text '.environmentObject(' for any object at all. My probe compiled the real SourceLint.swift verbatim. A detail reader alone gives ['Detail.swift:2']; adding another screen that attaches gives []. Adding an unrelated .environmentObject(appSettings) gives []. With a chat reader and that u…

### C1-s04-ui-07 — Bold Text is not modelled; text uses fixed-size system fonts instead of .body

- Verdict: **partly**; severity medium; category spec-deviation; spec 12.4 p31, 12.2 rule 9, 12.5
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:337`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:163`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:502`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics.swift:237-240`
- What: The sampled metrics have no Bold Text variant. The clone does apply the bold weight (SwiftUI resolves .system(size:) with legibilityWeight), but its glyph, clear-button and token frames keep the regular-weight geometry. Under Bold Text they differ from UIKit by up to about 1 pt (5.67 pt after token overflow), so every bold-text cell fails on pixels and metrics.
- Skeptic: What is real: metrics are keyed only by iOS version and content size (Metrics.swift:237-240, ZTronSearchField.swift:69-71), and nothing in the UI product reads legibilityWeight. All 62 bold-text cells fail. At L/LTR on iPhone 15 (36 cells) every one fails pixels and metrics, while event log, accessibility and state pass. The worst metric deviation is 1.0 pt (5.67 pt in token-overflow), and the 18.…

### C1-s04-ui-09 — No RTL (Arabic) cell passes: clear and Cancel labels stay English and tokens are 2 pt shorter

- Verdict: **partly**; severity medium; category bug; spec 12.1 p27, 12.2 rules 7-8
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:768-773`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:509-524`, `ParityHost/App/ParityHostUITests/ParityRemote.swift:28`
- What: RTL (Arabic) cells fail for two reasons. First, the clone's token geometry is sampled under English only and is 2 pt shorter than UIKit's in Arabic; this is a real clone limitation. Second, in the parity host build the clear and Cancel accessibility labels came out English. That may be a host build or packaging artifact, because the package's Bundle.module lookup returns the Arabic strings when the app declares Arabic. The claim that Arabic VoiceOver users in real apps hear English is unverified.
- Skeptic: What is confirmed: 0 of 315 RTL results pass. On iPhone 15 L RTL the failures are dominated by token.0.height and token.0.y (230 checkpoints) and by the clear-button label ('مسح النص' vs 'Clear text'; Cancel 'إلغاء' vs 'Cancel'). Token height is fixed by English-sampled metrics: ZTronSearchField.swift:508 sets .frame(height: metrics.tokenHeight), which is 24.33, against 26.33 in the Arabic-locale …

### C1-s04-ui-10 — With an editingPolicy set, the host's .focused cannot start editing and the policy is never consulted

- Verdict: **confirmed**; severity medium; category bug; spec 12.1 p27, 12.3 p30
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:345`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:484-490`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:652`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:691-699`
- What: With a policy set, the inner TextField stays .disabled until a tap passes the gate. Only the tap gate calls requestFocus. Setting the host FocusState targets a disabled TextField, which SwiftUI does not focus, so neither the policy check nor focus happens. UIKit's becomeFirstResponder asks textFieldShouldBeginEditing first. PLAUSIBLE: needs a device; no unit test or parity script uses editingPolicy.
- Skeptic: I saw this in the code; the end-to-end symptom was not observed on a device. synchronize() runs onAppear (:84) and sets allowsInput = editingPolicy == nil || core.isEditing (:652). That is false while idle with a policy, and :345 then disables the inner TextField. The only code that asks the policy and then enables and focuses the input is requestFocus() (:691-699). It is reached only from taps: t…

### C1-s05-chat-03 — With the shipped AssetKit adapter, retry and resume restart the in-transit model file from byte 0; resume is proven only against a fake

- Verdict: **partly**; severity high → medium; category spec-deviation; spec 14.1 p38: fetch is resumable; 14.4 p40: a retry re-verifies and resumes instead of starting over; 15.6 (section 18 lists this as open)
- Where: `Adapters/ZTronSearchEngineAssetKit/README.md`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/AssetKitModelAssetProvider.swift:181-215`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchOperation.swift`, `Sources/ZTronSearchFixtures/FakeChatBoundaries.swift:263-279`
- What: With the AssetKit adapter, an in-process fetch started after the previous job ended restarts the in-transit file (model.safetensors, about 968 MB) from byte 0. The previous job may have ended by being cancelled, by all observers leaving, or by a terminal .offline or .policy failure. A .checksum retry re-downloading the rejected file is what the spec requires. Resume within a job and across a relaunch works, and completed files are never re-downloaded. Core tests prove resume only against a fake. The limit is documented in the adapter README.
- Skeptic: This is real for the shipped adapter. Its own doc comment and README limit 1 say so. In ZTronAssetKit (commit 1baccd6), the path is retire, then abandon, then handle.cancel(), which 'Stops and discards the partial'. removeJob drops kept staged files. A new job gets resume data only from launchResumes, which is filled at launch (EngineJobs.swift:167, EngineLifecycle.swift:427).

ChatTests:202 and :…

### C1-s05-chat-04 — Downloads do not continue through ZTronAssetKit's background session while the engine only observes; core cancels an unobserved download

- Verdict: **partly**; severity medium; category spec-deviation; spec 14.4 p40-41: downloads continue in the background through ZTronAssetKit's own session; the engine only observes
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:157-163`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchCoordinator.swift`, `Adapters/ZTronSearchEngineAssetKit/README.md`, `Tests/ZTronSearchEngineTests/ChatTests.swift:239`
- What: Core stops a download as soon as no prepare() stream is observing it, for example when a screen-owned ZTronChatModel is released. With the AssetKit adapter, that discards the in-transit partial. Separately, the adapter cannot continue a download in ZTronAssetKit's background session while still reporting progress. App suspension by itself causes no core cancellation. Spec section 16 ('cancel during download') and the section 17 open question partly blur the 14.4 sentence.
- Skeptic: This is real. ChatService.swift:157-163 cancels the preparation when the last observer leaves during .fetching, and ChatTests:239 asserts that. FetchCoordinator.detach then cancels the AssetKit session. The lanes that report progress use the foreground session (README limit 3). This contradicts 14.4: 'downloads continue in the background ... and the engine only observes progress'.

What the descri…

### C1-s05-chat-05 — The prompt budget counts content tokens only; template overhead caps replies below 512 and makes long chats fail with promptTooLong for good

- Verdict: **confirmed**; severity medium; category bug; spec 14.2 p38: system prompt, sources, history and a 512-token reply fit in 4,096; 14.3 p39: prompt inside contextWindow - maxNewTokens - 64
- Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:132-162`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:461-473`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:396-414`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/SamplingPlan.swift`
- What: PromptAssembler checks the 3,520-token budget (4096 - 512 - 64) against message contents only. The runtime renders every message through the chat template, adding role markers and separators plus a generation prompt. For ChatML I estimate about 5 tokens per message plus 7; this was not measured on the real tokenizer. The 64-token margin absorbs about 11 messages.

Beyond that, MLX silently shortens the reply budget to min(512, window - prompt). Once the rendered prompt reaches 4,096, it throws promptTooLong, which surfaces as generationFailed. History is trimmed against the same content-only c…
- Skeptic: I ran this myself with the verbatim PromptAssembler, counting one token per word, and the Qwen3 ChatML overhead of 5 tokens per message plus 7 for the assistant generation prompt with thinking off (the <think> and </think> markers). All sessions were grounded on 6 sources of 80 tokens, with 10-token questions:
- 40-token replies: the reply cap starts shrinking at turn 52, and promptTooLong is thro…

### C1-s05-chat-06 — Source truncation splits on whitespace, so unspaced captions (Japanese, Chinese, Thai) are dropped whole

- Verdict: **confirmed**; severity medium; category bug; spec 14.3 p39: each source rendered [kind:id] title, caption from the localized surface, at most 80 tokens
- Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:165-180`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:564-579`, `Tests/ZTronSearchEngineTests/ChatTests.swift:445`
- What: PromptAssembler.truncate binary-searches over whitespace-split words. An unspaced caption counts as a single word, so when marker, title and caption exceed 80 tokens the whole caption is cut. What remains is only the marker and title, or an empty string when the first word alone is over the limit. The model is then grounded on titles only. The only test uses Latin text.
- Skeptic: I ran truncate verbatim with a stand-in tokenizer that counts one token per CJK character.
- A 100-token Japanese source was cut to 12 tokens: '[tip:tip-tokyo] 東京の地下鉄の乗り方,'.
- A 108-token Latin control kept 80 tokens.

The binary search runs over whitespace-split words, so an unspaced caption counts as one word and is dropped whole. render() runs after ensureLoaded, so the counts come from the rea…

### C1-s05-chat-07 — Citations whose id contains ':' are never emitted; the raw marker leaks into the reply and nothing is logged

- Verdict: **confirmed**; severity medium; category bug; spec 14.3 p40: incremental [kind:id] parsing; .citation for ids among the sources; unknown ids dropped and logged
- Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:76-81`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:74-76`
- What: When consume() meets a second ':' inside a pending marker, it checks whether the text between '[' and that ':' is a kind. For [map:region:1] that text is 'map:region', which is not a kind, so the pending text is flushed as plain text. The marker reaches the transcript verbatim, with no .citation and no unknownCitation report. Such ids are legal: SearchRowProjector's .verbatim and .prefixed(prefix) strategies can produce them; the default tablePrefixed uses '#'.
- Skeptic: I ran the verbatim CitationParser.
- 'See [map:region:1] here.' came out as one .text with the raw marker.
- '[tip:' followed by 'tip:42].' also stayed raw text.
- An unknown id containing ':' is neither dropped nor reported.
- Control: '[map:region-1]' produced a .citation.

Lines 76-81 test the text before the latest ':' and flush the pending text. marker() at :95-101 would have split at the fir…

### C1-s06-quality-04 — Section 15.9 targets over real SQLite never run in CI

- Verdict: **confirmed**; severity medium; category test-integrity; spec 15.9 p46; 17 milestone 2 gate; 18.1 WP31/WP32
- Where: `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:68-70`, `.github/workflows/adapter-tests.yml:58`, `.github/workflows/adapter-tests.yml:63`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:571-657`
- What: The only test that measures the 15.9 targets against SQLite skips itself in debug builds, and the adapter CI workflow runs only debug builds. The core performance test measures the dictionary-backed FakeSearchDatabaseConnection, not SQLite, and does not assert that context creation never blocks a query on the existing generation.
- Skeptic: DatabaseTargetsTests.swift:69-70 skips under DEBUG. adapter-tests.yml runs only 'swift test' (58) and 'swift test --sanitize=thread' (63), and no other workflow builds the adapter in release; README.md:188-191 lists it as a manual command. The core release test (PerformanceTests.swift:571-657) runs against FakeSearchDatabaseConnection, which says itself that its read 'is no SQLite'. Its upsert goe…

### C1-s06-quality-05 — Section 15.2 resident-memory budgets are untested, and model budgets are checked on disk size only

- Verdict: **confirmed**; severity medium; category spec-missing; spec 15.2 p43; 15.5 p44; 16 p50 (index size and resident memory assertions)
- Where: `Sources/ZTronSearchFixtures/ReferenceDevice.swift`, `Sources/ZTronSearchEngineSemantic/SemanticError.swift:78-83`, `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLEmbeddingProvider.swift:149-153`, `Tests/ZTronSearchEngineSemanticTests/HNSWRecallTests.swift:56-58`
- What: Several 15.2 budgets have no test: the 110 MB steady state with models unloaded, the 200 MB peak during a semantic query, the 320 MB peak during a reranked query, and the 800 ms or less model reload after unload. The 80 MB and 60 MB model budgets are enforced on the on-disk size of the model files, not the loaded footprint. Item vectors and the HNSW graph are checked as file sizes, and only when ZTRON_SEMANTIC_LARGE is set.
- Skeptic: PerformanceBudget has no constant for steady state (110 MB), semantic peak (200 MB), reranked peak (320 MB) or reload time (800 ms). itemVectorBytes, graphBytes, embeddingModelBytes and rerankerModelBytes are referenced only where they are defined. CoreMLEmbeddingProvider.load compares loader.footprint(modelURL) against SemanticLimits, which are documented as on-disk budgets; footprint is FileAcce…

### C1-s06-quality-07 — Latency targets are timed on English golden queries only, and bigram-fallback lookups are never timed

- Verdict: **confirmed**; severity medium; category spec-deviation; spec 15 p42 (p95 measured over the golden query set); 15.1 prefix lookup 3 ms
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:56`, `Sources/ZTronSearchEngine/Query/QueryPlanner.swift:133-162`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:668`
- What: PerformanceTests takes its queries from GoldenSet.queries filtered to locale "en", so the Japanese and other non-English golden queries are never timed. Separately, in QueryPlanner a clause that matches through the CJK bigram fallback executes `continue` before `timings.lookup += ...`. Its exact, prefix and bigram lookup time therefore never reaches response.timings.prefixLookup.
- Skeptic: PerformanceTests.swift:56 keeps only locale 'en' queries, and every 15.1 stage and end-to-end test uses them on a single 'en' engine. The crossLanguage and localizedTitle classes (GoldenSet.swift:213-214: up to 120 of 483 queries in it, de and ja, including every Japanese query) are never timed. RelevanceTests already builds one engine per locale (68-72), so timing them was feasible, and no other …


## Low

### C1-s01-contracts-06 — setLocale cancels the in-flight search instead of letting it finish on the old index

- Verdict: **partly**; severity medium → low; category spec-deviation; spec 5.7 p9 (in-flight and new searches keep using the old index until the swap); 1 p1
- Where: `Sources/ZTronSearchEngine/Service/SearchService.swift:892-903`, `Sources/ZTronSearchEngine/Service/SearchService.swift:311-316`, `Sources/ZTronSearchEngine/Service/SearchService.swift:793-803`, `Tests/ZTronSearchEngineTests/InternationalizationTests.swift:285-292`
- What: setLocale (and the locale observer) cancels the interactive search in flight, contrary to 5.7. Its stream ends without a final snapshot, and the results model stops loading while showing whatever it last displayed: the previous query's hits, or the current query's lexical hits. It is a rare race (a locale change during an in-flight search) that the next keystroke recovers. Low.
- Skeptic: The deviation is real and deliberate. setLocale calls cancel() before the rebuild (SearchService.swift:892-903), and so does the observer at 793-803. The stream task then finishes without a final snapshot (286-292). Tests codify this as 'by design' (InternationalizationTests.swift:285-292). Spec 5.7 and 16 say in-flight searches keep using the old index, and nothing requires the cancel, since page…

### C1-s01-contracts-08 — Field fallback chain treats a script variant as a language match, unlike Bundle.preferredLocalizations

- Verdict: **confirmed**; severity low; category spec-deviation; spec 5.2 p8
- Where: `Sources/ZTronSearchEngine/Text/LanguageTag.swift:32-51`
- What: chain() keeps every Apple match whose primary language subtag equals the wanted language, then appends the bare-language entry. Apple does not cross scripts when another localization (the base) exists.
- Skeptic: Probe p08. Apple gives [en] for zh-Hant-TW over [zh-Hans, en], zh-HK over [zh-Hans, en], sr-Cyrl-RS over [sr-Latn, en] and sr-Latn-RS over [sr, en]. The engine's chains give [zh-Hans], [zh-Hans], [sr-Latn] and [sr]. zh-Hant-TW over [zh, zh-Hant] gives Apple [zh-Hant] and the engine [zh-Hant, zh]. pt-PT over pt-BR agrees. A zh_TW projection of base en plus zh-Hans gives title 地图, language zh-Hans. …

### C1-s01-contracts-09 — Shadowed base surfaces always indexed into localizedAlt, even with SecondaryLanguages.none

- Verdict: **partly**; severity low; category spec-deviation; spec 5 p8 (base surface is only a fallback); 5.3 p9; 5.6 p9
- Where: `Sources/ZTronSearchEngine/Projection/SearchProjector.swift:109-113`, `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:9`
- What: Shadowed base surfaces always feed localizedAlt, even under SecondaryLanguages.none or when the base language is not a preferred language. This is deliberate and documented in code. It conflicts with a strict reading of 'the base surface is only a fallback' (5) and of the localizedAlt definition (6), not with 5.6. Low: extra low-weight matches.
- Skeptic: The code does this deliberately. SearchProjector.swift:109-113 appends shadowed base surfaces whatever the policy, the .none doc comment says so, and tests codify it (InternationalizationTests.swift:29-39 and 134-153 under TestSupport's default .none; DatabaseSourceTests.swift:288-290). Spec support exists in the 5 intro ('the base surface is only a fallback') and section 6 (localizedAlt holds 'se…

### C1-s01-contracts-10 — Typed filters never rebuilt at query time; unknown filter records in loaded or persisted indexes never logged

- Verdict: **partly**; severity low; category spec-deviation; spec 4.1 p8
- Where: `Sources/ZTronSearchEngine/Service/SearchService.swift:994-998`, `Sources/ZTronSearchEngine/Query/BM25F.swift:82-117`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:163-172`
- What: Unknown filter records in a loaded or adopted index are never logged (4.1), and typed filters are not rebuilt at query time. For typed queries the raw equality is harmless. Only a typed schema's .string escape-hatch query with the same key and value can match stale records, for example after finding 01's stale-file adoption. ZTronStringSchema cannot produce unknown records. Low.
- Skeptic: The code claim is right. unknownFilter is reported only during projection (SearchService.swift:994-998; SearchRowProjector.swift:163-172). HardConstraints.allows (BM25F.swift:105-116) compares raw records, and no load or adoption path decodes or logs them. Unknown kinds, by contrast, are logged at query time (SearchPipeline.swift:106-117). For typed queries, raw equality already acts as 'ignored',…

### C1-s01-contracts-11 — NFC/NFD-equivalent ids are one id to Swift collections but two to the index; SearchableID '<' is inconsistent with '=='

- Verdict: **confirmed**; severity low; category bug; spec 4 p5 (SearchableID Hashable, Comparable)
- Where: `Sources/ZTronSearchEngine/Contracts/Searchable.swift:35-37`, `Sources/ZTronSearchEngine/Index/IndexSegment.swift:428-445`, `Sources/ZTronSearchEngine/Index/LexicalIndex.swift:449-456`
- What: Equality and hashing follow Swift canonical equivalence. '<' compares UTF-8 bytes, and the index locates ids with a byte-exact memcmp.
- Skeptic: Probe p11 with NFC 'café' and NFD 'cafe+U+0301'. == is true and the hashes are equal, while a<b is false and b<a is true, so Comparable is inconsistent with ==. In an indexed context, remove(NFD) of the NFC item leaves count 1 and the item still hits; index(NFD) gives count 2 and two hits. The cause is byte-exact id lookup (IndexSegment.swift:428-445) against String equality. Extra point: a scan c…

### C1-s01-contracts-12 — Core consults Bundle.main.infoDictionary

- Verdict: **confirmed**; severity low; category spec-deviation; spec 4 p6 (core does no bundle lookups); 5.12 p9 (resolver is the only bundle consumer)
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:624`
- What: ChatDeviceProfile.current reads Bundle.main.infoDictionary. It is not a localization lookup, but it is a bundle consultation in core, which the contract excludes.
- Skeptic: ChatService.swift:624 reads Bundle.main.infoDictionary for the app version and build in ChatDeviceProfile.current. This literally contradicts 4 p6 ('core stays bundle-free') and 5.12 ('The resolver is the only place a bundle is consulted'). Mitigations: the read is only the default of an injectable profile (ChatService.swift:252, `configuration.device ?? ChatDeviceProfile.current`), and tests inje…

### C1-s02-retrieval-03 — SearchLimits setters bypass init clamps; lexicalCandidates = 0 crashes lexical search, negative fusion/retained limits trap

- Verdict: **partly**; severity medium → low; category bug; spec Section 8 p13-14 (at most 200 entries per channel, 200 hits retained); section 7.1 lexical bounded work (2,000 candidates)
- Where: `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:28-55`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:673-674`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:731-742`, `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:796`
- What: SearchLimits clamps only in init. Assigning 0 to lexicalCandidates through the setter makes IndexSearcher.admitCandidates write past an empty slot array (crash on the first indexed query with postings). Negative fusionEntriesPerChannel or retainedHits trap in prefix(_:), and 0 for either returns no hits. This is a robustness gap reachable only with nonsensical values, not a spec deviation. Low.
- Skeptic: Mechanism confirmed. SearchEngineConfiguration.swift:28-40 are public vars whose clamps exist only in init (50-55). SearchPipeline.swift:76, 101 and 103 pass them through unchanged. IndexSearcher sizes the grow-only slots array to the limit (prepareScratch 731-742). admitCandidates writes slots[slotCount] at line 796 before the slotCount >= limit check at 799; it is an out-of-range write, not a re…

### C1-s02-retrieval-04 — 1-2 character CJK/Thai queries run the semantic phase (and rerank on gated devices) despite the 3-character rule

- Verdict: **partly**; severity medium → low; category spec-deviation; spec Section 9 snapshot rule 2 p16 (semantic snapshot skipped with degraded set when the query is shorter than 3 characters); section 10 p23 (queries shorter than 3 characters skip semantic and rerank); section 7 table p11 semantic trigger
- Where: `Sources/ZTronSearchEngine/Service/SearchPipeline.swift:61-63`, `Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:133-134`, `Sources/ZTronSearchEngine/Service/SearchService.swift:520-525`, `Sources/ZTronSearchEngine/Service/SearchService.swift:627-648`
- What: Queries containing any CJK or Thai character are semantic- and rerank-eligible at 1-2 characters (SearchPipeline.swift:62-63), contrary to sections 9 rule 2 and 10. They publish a non-degraded semantic (and, on gated devices, reranked) snapshot instead of a degraded final lexical one. The config doc comment also omits the exception. Cost: one embedding pass (and one rerank) behind the normal pause and caps. Low.
- Skeptic: Mechanism confirmed. SearchPipeline.swift:62-63 makes a query semantic-eligible when characterCount >= minimumSemanticQueryLength || containsUnspacedScript (QueryParser.swift:58-59). rerankAvailability (SearchService.swift:646) follows that eligibility. The spec has no unspaced-script exception: section 9 rule 2 p16 says 'skipped, with degraded set, when the query is shorter than 3 characters', an…

### C1-s02-retrieval-05 — Rerank passage for untitled unspaced-script text is the whole text, not the first 64 tokens

- Verdict: **confirmed**; severity low; category spec-deviation; spec Section 7.4 p13 (passage = title plus caption, or the first 64 tokens of text)
- Where: `Sources/ZTronSearchEngine/Service/SearchPipeline.swift:196-200`, `Sources/ZTronSearchEngineSemantic/Tokenization/TextTokenizing.swift:124-125`
- What: passage(for:) takes text.split(whereSeparator: \.isWhitespace).prefix(64). CJK and Thai text has no whitespace, so the whole text is one 'word' and passes through untruncated. The cross-encoder tokenizes the full string before windowing it to 128 tokens. Tokenization cost grows with text length inside the 400 ms rerank cap, and the model sees about 120 passage tokens instead of 64. RankingTests.swift:342-347 covers Latin text only.
- Skeptic: SearchPipeline.passage(for:) (196-200) splits on whitespace and keeps 64 pieces. Unspaced text has no whitespace, so the passage is the whole text. I reproduced it independently: Japanese text of 2400 chars gives a 2400-char passage (1 whitespace word), Thai 2100 gives 2100, Japanese with a space per sentence is cut at 64 pieces (831 chars), and Latin is cut at 64 words. Titled or captioned docume…

### C1-s03-engine-api-06 — databasePageSize <= 0 set after init makes the row reader loop forever

- Verdict: **confirmed**; severity low; category bug; spec Section 9.2 rule 1 (p21: pages read as LIMIT 500 OFFSET n)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Database/SearchSQLComposer.swift:131-143`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:142`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Contracts/SearchEngineConfiguration.swift:195`
- What: The max(1, ...) clamp on databasePageSize runs only in SearchEngineConfiguration.init, but the property is a public var. With pageSize 0 the composer issues LIMIT 0, `rows.count < pageSize` is never true and `offset += pageSize` never advances, so the read loop opens read transactions forever and the context never becomes ready.
- Skeptic: Code read: the clamp `max(1, ...)` runs only in SearchEngineConfiguration.init (line 195), while databasePageSize is a public var (142). SearchRowReader.pages (SearchSQLComposer.swift:131-143) exits only when rows.count < pageSize and advances by pageSize, and nothing re-clamps the value.

Scenario E (value set after init, one-row table):
- pageSize 1: 2 transactions, then ready.
- pageSize 0: 60,…

### C1-s03-engine-api-07 — Scan scoring checks cancellation every 256 documents, not every 1,000 postings

- Verdict: **confirmed**; severity low; category spec-deviation; spec Section 11 rule 4 (p24: Task.checkCancellation() at least every 1,000 postings in scoring loops)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngine/Scan/ScanEngine.swift:147-172`
- What: ScanEngine.search checks cancellation with `if document % 256 == 0 { try Task.checkCancellation() }` (line 149), while the inner loop walks every (term, field) entry of each document. With catalog-sized documents that is far more than 1,000 postings between checkpoints in a context forced to .scan. The indexed IndexSearcher checks every 1,000 postings (lines 685, 789, 852).
- Skeptic: Code read: ScanEngine.swift:149 checks `document % 256 == 0`, while the inner loop (155-170) walks every (term, field) entry of each document, including terms the query does not use. These entries are the scan's transposed postings, and spec rule 4 speaks of scoring loops. IndexSearcher checks every 1,000 units of work (685, 789, 852).

Measured in scenario G (debug build, forced .scan, 5,000 docu…

### C1-s03-engine-api-08 — Changing pageSize during a search leaves the previous query's hits on screen

- Verdict: **confirmed**; severity low; category bug; spec Section 11 rule 6 and liveness 'No stale results' (p24-25)
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:78-81`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:130-131`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:65-69`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:150-152`
- What: The pageSize setter mutates query.limit of the query in flight without restarting the search. Every snapshot of the running stream then fails `snapshot.query == query` in apply and is dropped. streamEnded clears isLoading, and hits still hold the previous query's results. A repeated update(text:tokens:) with the same text returns early, because the merged query equals the mutated one, so nothing refreshes until the text changes.
- Skeptic: Code read: the pageSize setter (ZTronSearchResultsModel.swift:78-81) rewrites query.limit of the query in flight. The service's snapshots carry the original query, so apply (130-131) rejects every one of them. streamEnded (149-152) clears isLoading, and update (65-70) copies the new limit into the next query and returns early for the same text.

Reproduced in scenario H (verbatim copies of ZTronSe…

### C1-s03-engine-api-09 — Suggestions run on their own timer, not the lexical timer

- Verdict: **confirmed**; severity low; category spec-deviation; spec Section 10 table (p23): Suggestions, prefix of 2 or more characters, 'Shares the lexical timer'
- Where: `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:226`, `/Users/admin/Documents/ZTronSearchEngine/Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:235-259`, `/Users/admin/Documents/ZTronSearchEngine/Tests/ZTronSearchEngineUITests/ResultsModelTests.swift:317-329`
- What: ZTronSuggestionsModel has its own debounce parameter (default 0.120) and its own Task.sleep. These are independent of SearchEngineConfiguration.lexicalDebounce, which drives the lexical phase inside SearchService. The two timers fire independently and diverge as soon as the host tunes lexicalDebounce. The test named testSuggestionsShareTheLexicalTimer passes debounce: 0.12 itself and asserts only that one debounced request is made, so it would pass with any independent timer.
- Skeptic: Code read: ZTronSuggestionsModel sleeps on its own debounce (default 0.120; ZTronSearchResultsModel.swift:226, 235-259). SearchService.suggestions has no timer, and the service's lexicalDebounce lives in an internal configuration the UI module cannot read. The spec's init (p33) has no debounce parameter, which is consistent with sharing the service's timer. testSuggestionsShareTheLexicalTimer pass…

### C1-s03-engine-api-10 — During-search cancellation test accepts far more than 10 ms

- Verdict: **partly**; severity low; category test-integrity; spec Section 11 liveness table (p25): cancellation honoured within 10 ms at the next checkpoint, verified by cancellation tests before, during and after index search
- Where: `/Users/admin/Documents/ZTronSearchEngine/Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:49-80`
- What: The during-search cancellation test asserts on how quickly the consumer's stream ends after cancellation. That happens immediately whatever the producer does, so the test passes even with every IndexSearcher checkpoint removed (scratch variant: consumer 0.02 ms while the producer kept running 16 ms), not merely with a coarser cadence.

The only check that checkpoints exist is testTheScoringLoopChecksCancellation, which uses an already-cancelled task. No test verifies the every-1,000-postings cadence or the 10 ms producer-side figure that section 11 says the cancellation tests verify.
- Skeptic: The test-integrity problem is real, and worse than described. ConcurrencyTests.swift:49-80 times the consuming task: from cancel to `await task.value`. Once that task is cancelled, the AsyncStream iterator returns nil without waiting for the producer, so the measurement does not depend on the search checkpoints at all.

Scenario T replicates the test (RandomCorpus seed 4242, 30,000 items, the same…

### C1-s04-ui-08 — Parity metrics capture records the reference's hidden glyph, so every accessibility-size cell with content fails

- Verdict: **partly**; severity medium → low; category test-integrity; spec 12.5 p31, 15.7
- Where: `ParityHost/Sources/ZTronSearchEngineUIParity/ReferenceField+Layout.swift:10-12`, `ParityHost/Sources/ZTronSearchEngineUIParity/ReferenceField+Layout.swift:111`, `ParityHost/Sources/ZTronSearchEngineUIParity/ReferenceSampler.swift:165-168`
- What: At accessibility sizes with content, the reference metrics capture records UIKit's glyph view, which the sampler counts as 'not shown'. The cell then fails with 'glyph (reference only)'. The reference still exposes that glyph as an accessibility element, while the clone removes it entirely, so the same cells also fail the accessibility comparator. The harness is inconsistent (sampler versus capture), but the failure points at a real accessibility-tree difference in the clone, and fixing it may belong in the clone rather than the harness.
- Skeptic: The mechanism is real. glyphView takes the first UIImageView with no visibility test (ReferenceField+Layout.swift:10-12, :111), while clearButton and cancelButton do filter with isVisible. MetricsComparator fails any '(reference only)' frame (:52-55, :81). The sampler records glyphShownWithContent 0 at accessibility1-5, and the clone drops the glyph there (ZTronSearchField.swift:125-127). But the …

### C1-s04-ui-11 — README overstates where the field matches the reference

- Verdict: **confirmed**; severity low; category false-claim; spec 12.5 / 15.7
- Where: `README.md:216-218`
- What: README says the field matches on iOS 17.5 and 18.6 on 3x iPhones, LTR, at the default content size. At that size and direction, bold-text cells fail 18/18 on both versions on iPhone 15, 2 of 20 cells per group are not runnable, and 18.6 iPhone 15 Pro Max has 1 failure. That failure is a harness flake: the reference dropped a hardware keystroke (reference 'mp', clone 'map').
- Skeptic: README.md:216-218 claims a match on 17.5/18.6, 3x iPhones, LTR, default size. At L/LTR on iPhone 15, bold-text fails 18 cells with 2 not runnable on each version. Every other appearance group is 18 pass with 2 not runnable (hardware backspace scripts where XCUITest did not deliver the delete key). iPhone 15 Pro Max ran only the light appearance, and on 18.6 it had 1 failure: hardware type, with st…

### C1-s04-ui-12 — Token drawn as a radius-4 rounded rectangle, not a capsule

- Verdict: **confirmed**; severity low; category spec-deviation; spec 12 p25, 12.4 p31
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:493-512`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldMetrics+Sampled.swift:21-34`
- What: The token uses RoundedRectangle(cornerRadius: metrics.tokenCornerRadius), which is 4 pt, following the UIKit sample, while the spec says Capsule. This is drift between spec text and implementation only; it matches the reference in the passing cells.
- Skeptic: ZTronSearchField.swift:510 draws the token with RoundedRectangle(cornerRadius: metrics.tokenCornerRadius, style: .continuous). tokenCornerRadius is 4 with a continuous curve in every sampled size on iOS 17 and 18. There is no Capsule anywhere in the UI sources. Reference images (18.6 AX5, bold-text, 27.0) show UIKit tokens as small-radius rounded rectangles, so a Capsule would itself break 12.2 ru…

### C1-s04-ui-13 — A stream that ends without a final snapshot leaves stale or partial hits shown as settled

- Verdict: **partly**; severity low; category bug; spec 13 p34
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:149-152`, `Sources/ZTronSearchEngine/Service/SearchService.swift:892-903`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:194-205`
- What: When the service ends a stream without a final snapshot (a locale-change cancel or a swallowed lexical error), isLoading goes false, as section 13 prescribes for a cancellation. The model then keeps the last lexical or previous-query hits with no error and no re-run, and re-sending the same text cannot recover. This is a robustness gap with a rare trigger, not a direct contradiction of section 13.
- Skeptic: What is real: setLocale calls cancel() (SearchService.swift:892-903, 311-316), triggered by NSLocale.currentLocaleDidChangeNotification when followsSystemLocale is true, which is the default. The producer then calls continuation.finish() (:284-288). A thrown lexical search returns silently (:397-401). The model's stream loop then ends normally. streamEnded() only clears isLoading (:149-152), error…

### C1-s04-ui-14 — The spec's minimal host does not type-check against textToToken

- Verdict: **partly**; severity low; category api; spec 12.2 p29
- Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldEnvironment.swift:120`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldEnvironment.swift:125`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldEnvironment.swift:134`
- What: The minimal host example in spec 12.2 p29 cannot compile against the textToToken declared in spec 12.1 p26, and so not against the package either. Inside a View extension, Schema can be inferred only from the closure's result, and .filter($0) constrains only Schema.Filter. Hosts must write ZTronSearchToken<CatalogSchema>(...). This is a defect in the spec's example, with a low-cost workaround; the implementation follows the spec's API.
- Skeptic: My probe mirrors SearchSchema, ZTronSearchToken and the exact signature at ZTronSearchFieldEnvironment.swift:120. The spec's p29 closure fails with 'generic parameter Schema could not be inferred'. Spelling it ZTronSearchToken<CatalogSchema>(...) type-checks. onTokenDelete (:125) and tokenCopyProvider (:134) have the same shape. However, the code implements the spec's own declaration. 12.1 p26 dec…

### C1-s05-chat-08 — MLX real-model tests never run in CI; prefill cancellation is per 512-token chunk

- Verdict: **partly**; severity low; category test-integrity; spec 14.1 p38: cancellation within one decoded token; section 16: MLX suites
- Where: `.github/workflows/ci.yml:76-89`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:25-45`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:424`
- What: Real-weight MLX tests run only on demand, which is consistent with spec section 16 and the milestone 8 gate. The real but minor issue is that, with the default tuning, cancellation during prefill is observed once per 512-token chunk. On long prompts that can exceed 15.6's 150 ms target. prefillStepSize exists as a knob for this.
- Skeptic: The facts hold:
- The ci.yml mlx-runtime job runs 'swift test --build-system native' without ZTRON_QWEN3_DIR.
- Qwen3IntegrationTests skip when that variable or default.metallib is missing.
- prefillStepSize is nil, which keeps mlx-swift-lm's default. At the pinned 3.32.3, LLMModel.swift documents 'default 512', and PrefillParameters.swift:137 checks cancellation once per chunk (read from the loca…

### C1-s05-chat-09 — Core calibration can pass without measuring a decode rate

- Verdict: **confirmed**; severity low; category bug; spec 14.4 p40: decode 64 tokens at >= 8 tok/s
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:303-350`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:346`
- What: rate is infinity when generated <= 1 or decodeSeconds is 0. A run that ends after one token, or delivers all its text in one delta, therefore passes the decode gate without being measured.

Core samples with configuration.options (0.7 / 0.8 unless set) and a repeated sentence. It does not use MLX ChatCalibration's greedy long-answer request, whose passes() rejects fewer than 2 tokens (ChatCalibrationTests.swift:159), so an early end of turn is plausible. The decode window also ends at the last delta rather than at .finished.
- Skeptic: ChatService.swift:346 computes `rate = generated > 1 && decodeSeconds > 0 ? ... : .infinity`. A 1-token run, or one whose text arrives in a single delta, therefore passes the decode gate without being measured.

Core's request is sampled from configuration.options and uses a repeated sentence. MLX ChatCalibration instead uses a greedy request and requires at least 2 tokens and a stop that was not …

### C1-s05-chat-10 — ZTronChatModel.prepare can lose its reference to the running preparation task

- Verdict: **partly**; severity low; category bug; spec 14.5 p41: ZTronChatModel prepare/cancel
- Where: `Sources/ZTronSearchEngineUI/ZTronChatModel.swift:80-92`
- What: After a second prepare(), the model always loses its reference to the new preparation task. As a result, deinit or a later prepare() cannot cancel that consumer. It stops observing at the next readiness event after the model is released, which is indefinitely only for a stalled download. A later prepare() leaves two consumers publishing identical states.
- Skeptic: Real, and more systematic than 'can'. Through Mirror, ZTronChatModel.preparation was nil after the second prepare() in 24 of 24 trials. That includes the 6 trials where the new consumer was still attached and observing. The cancelled T1's stream ends with nil, and its trailing `self?.preparation = nil` runs after T2 has been stored.

The consequence is bounded, though. The orphaned consumer captur…

### C1-s05-chat-11 — An Int64 overflow trap is reachable through public API with huge byte counts

- Verdict: **partly**; severity low; category bug; spec 14.1 p36-37: ModelAsset.totalBytes; 14.4 p40: disk check
- Where: `Sources/ZTronSearchEngine/Contracts/ChatBoundary.swift:38-40`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:209`, `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ModelAssetManifest.swift`
- What: An absurd byte count in host-supplied configuration (over about 4.6e18) traps in totalBytes or in prepare()'s disk check. This is a fail-fast on a programmer error, with no path from untrusted input.
- Skeptic: It is true that totalBytes (reduce with +) and `2 * asset.totalBytes` (evaluated only for .missing with a known free-disk figure) trap on Int64 overflow. ModelAssetManifest.validate rejects only negative counts.

However, the byte counts come only from the host's own ModelAsset or a manifest the host ships: the pin script's output, or Qwen3Asset's static values. Nothing in these packages reads a m…

### C1-s05-chat-12 — ensureLoaded waits on an in-flight preparation while holding the generation lock and ignores cancellation

- Verdict: **partly**; severity low; category concurrency; spec 14.3 p40: one generation at a time, other sessions queue; cancel
- Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:435`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:533-539`
- What: A turn cancelled while it waits for a running preparation does not end until that preparation finishes. A consumer that cancels through ChatService.cancel(session) therefore sees its stream stay open. Other sessions are not delayed beyond the wait they already have for the same preparation.
- Skeptic: Both facts in the title are true. runTurn takes the AsyncLock before ensureLoaded waits on preparationWaiters through withCheckedContinuation, which a cancel does not wake.

The failure scenario, however, is not caused by this. While a preparation runs, the model is never ready, because prepare() starts a preparation only when lifecycle is not .ready or .generating. Any send in any session must th…

### C1-s06-quality-06 — Semantic snapshot test checks a weaker gate, and the 750 ms reranked snapshot has no test

- Verdict: **partly**; severity medium → low; category test-integrity; spec 15.1 p42 (semantic snapshot 500 ms incl. 300 ms debounce; final reranked snapshot 750 ms)
- Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:244-275`, `Sources/ZTronSearchFixtures/ReferenceDevice.swift`
- What: The semantic-snapshot proxy holds the engine's share to an unscaled 20 ms on the Mac. That is 6x weaker than the scaled convention: up to about 120 ms on the reference device passes, where the target leaves 20 ms. A 60 ms overhead would fail. No test times the 750 ms reranked snapshot.
- Skeptic: Two parts are real. First, PerformanceTests.swift:270-273 holds the overhead (total minus the 300 ms debounce minus the measured encode time) to an unscaled 20 ms. That remainder is engine CPU work (nearest over 5,000 fake items, fusion, ranking, snapshot) plus timer slack, while the class's own method divides CPU budgets by 6. Second, PerformanceBudget.rerankedSnapshot is referenced only where it…

### C1-s06-quality-08 — Service-level randomized stale-snapshot test does not check the property its doc comment claims

- Verdict: **confirmed**; severity low; category test-integrity; spec 15.4 p44; 16 p48 (stale-result suppression with randomized sequences)
- Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:157-219`
- What: The doc comment says that once a newer query has been issued, an older stream never yields again. The ledger only checks that each snapshot matches its own stream's query and generation, which a late snapshot of a superseded query also satisfies. The bound `finals <= changes + 20` is loose.
- Skeptic: In ConcurrencyTests.swift:171-177, Ledger.received flags a snapshot only when its query differs from its own stream's query, or its generation from the stream's first generation. A late snapshot from a superseded stream passes both checks. The bound 'finals <= changes + 20' cannot catch superseded streams either, since there is at most one final per stream. So the doc comment's second clause goes …

### C1-s06-quality-09 — Filter/kind precision gate passes vacuously on empty result lists

- Verdict: **partly**; severity low; category test-integrity; spec 15.3 p44 (filter and kind tokens: precision 1.0)
- Where: `Sources/ZTronSearchFixtures/RelevanceMetrics.swift:66-71`, `Tests/ZTronSearchEngineTests/GoldenGates.swift:38-39`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:185`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:196`
- What: The filterAndKind class gate and the no-violation test pass on empty lists. Filtered recall is checked only in the reranked stage over the golden set and on the small catalog. A regression that empties filtered results only in the lexical or semantic stage at golden-set scale, and is masked in the reranked stage, would pass.
- Skeptic: Three claims are true. RelevanceMetrics.precision returns 1 for an empty list (documented), GoldenGates.swift:38-39 gates on precision alone, and testNoHitEverViolatesAHardConstraint accepts empty lists. This matches 15.3's own definition ('Precision 1.0; no hit may violate a hard constraint'). The claim 'Nothing checks that filtered queries still return their judged items' is false. RelevanceTest…

### C1-s06-quality-10 — Environment-object lint treats any .environmentObject( as attaching every model

- Verdict: **confirmed**; severity low; category test-integrity; spec 16 p49 (a screen that reads a model via @EnvironmentObject without an attaching modifier fails the lint test); 13.1
- Where: `Sources/ZTronSearchFixtures/SourceLint.swift:211-240`, `Tests/ZTronSearchEngineUITests/LintTests.swift:154-161`
- What: For each of the three package models, SourceLint.unattachedEnvironmentObjects counts the model as attached if any scanned file contains `.environmentObject(` for any object. One unrelated injection therefore disables the check for all three models.
- Skeptic: SourceLint.swift:224-226 counts a model as attached when any scanned file contains '.environmentObject('. I compiled the repository's SourceLint.swift unchanged against two scratch files (lint/). A Chat.swift that reads @EnvironmentObject ZTronChatModel gives one finding on its own, and none once a Settings.swift calling .environmentObject(settings) is added. Spec 13.1 rule 3 (p36) and 16 p49 requ…


## None

### C1-s06-quality-11 — Exact-title-inside-the-head on the full golden set is only tested with a reranker that agrees with titles

- Verdict: **refuted**; severity low → none; category test-integrity; spec 16 p49 (reranker: the blend keeps an exact-title hit inside the head on the full golden set)
- Where: `Tests/ZTronSearchEngineTests/RankingTests.swift:325-336`, `Tests/ZTronSearchEngineTests/RelevanceTests.swift:283-292`, `Sources/ZTronSearchFixtures/FakeReranker.swift`
- What: The adversarial case, where the cross-encoder ranks the exact title last, is a single constructed 16-document list. Its `XCTAssertLessThan(position, 16)` is always true for a 16-element list, so only the `< 11` check carries weight. Over the golden set the reranked stage uses FakeReranker, which scores by lexicon overlap and never opposes an exact title.
- Skeptic: The facts are right: 'position < 16' at RankingTests.swift:334 is vacuous, and the golden-set reranked stage uses FakeReranker, which scores an exact title at the maximum. The claimed gap does not exist, though. Spec 7.4 (p13) defines the head as the reranked top 16: 'Only the reranked head is reordered; hits below position 16 keep their fused order'. SearchPipeline.reranked (SearchPipeline.swift:…


## What the auditors could not check

- **s01-contracts**: Not checked:
- Reference-device budgets (R4, and the 2 s / 100k locale-rebuild timing): no iPhone 6s, PerformanceTests are skipped in DEBUG, and there is no release performance log in Verification/_runs.
- Spec PDF tables and figures: pdftoppm is missing, so I used spec.txt.
- iOS 15.5 / 18.6 simulator and TSan results: no simulators were booted, and the TSan log was still .partial.
- Behavior of sections 7-14 beyond existence (BM25F, fuzzy, RRF, semantic quality, chat): these belong to other sl…
- **s02-retrieval**: Device-only properties were not checked: whether the Core ML embedding and cross-encoder models load on iOS 15.8, their 8-bit weights and 6-layer limit (no model artifact is in the repo, and there is no iOS 15/16 simulator or device on this Mac), and real calibration p95 timings. Release-only tests were not run: PerformanceTests, the 100k HNSW recall tests (ZTRON_SEMANTIC_LARGE) and SignalTuningTests.testSweep all skip in the debug log, and the ground rules forbid swift build/test in the repo. H…
- **s03-engine-api**: Device figures cannot be checked here: the lexical budget in R8, 10 ms cancellation (R64), 1 ms publishing on the main actor (R68) and the section 15 p95 targets. PerformanceTests skip in the debug log and run only in the release CI job. Semantic product internals were only spot-checked by reading: lazy model loading, INT8 vector store mapping (R50) and the HNSW cancellation cadence (64 visits). None of the following were run, and adapter behaviour (R30, R42, R43) was traced by reading only: the…
- **s04-ui**: Anything that needs a device or simulator: real rendering, VoiceOver behavior, keyboard traits (spell checking and smart punctuation actually off), hardware-keyboard onKeyPress(.delete), focus with an editingPolicy (finding 10). iOS 15/16 runtime behavior (no runtimes; those parity cells are not runnable). Root cause of the English labels in Arabic cells (finding 09). R23: whether the core keeps tokens out of fuzzy and prefix matching (core matcher, other slice). ZTronTextChange.between grapheme…
- **s05-chat**: Not checked:
- The page 40 lifecycle figure. The PDF could not be rendered (pdftoppm missing), so only the text layer was read.
- On-device behaviour:
  - how 6 GB iPhones report physical memory against the 6 x 1024^3 threshold;
  - TTFT, decode rate, the 150 ms cancellation bound and resident memory with real weights;
  - golden-set citation and decline rates.
- Whether the MLX package builds against the pinned mlx-swift 0.32.3, mlx-swift-lm 3.32.3 and swift-transformers 1.4.0, and whether thos…
- **s06-quality**: Reference-device p95 latency and memory targets (no iPhone 6s; release builds not allowed here and no release log in Verification/_runs), so R1-R7, R13, R14, R18, R19, R60 and R61 rest on proxy tests that were not seen to run. Model-dependent targets: query embedding 180 ms, rerank 250 ms, and paraphrase, cross-language and reranked relevance with a production model (the package ships no model; the tests use oracle fakes). 15.6 local-chat targets on an A17 Pro iPhone or M-series Mac (need Qwen3 …

STATUS: complete
