# Verification report — ZTronSearchEngine

Two independent, skeptical verification cycles against commit `cee4620`, run 2026-11-17 and 18.

- **Cycle 1, requirement-centric.** Six auditors each took one slice of the 58-page specification and traced every requirement into the code and tests. A skeptic per slice then tried to refute each finding.
- **Cycle 2, code-centric.** Six auditors each read one module line by line and held it against the spec. A skeptic per module then traced each finding concretely and tried standalone repros.

Cycle 2's prompts were written before any cycle 1 result came back, and no agent saw the other cycle's notes. Nothing in the repository was modified: agents worked read-only, and repro builds ran in scratch copies.

## Bottom line

The package is real and substantially built:
- `swift test` passes with no compiler warnings: 580 tests, in debug and under Thread Sanitizer.
- It builds for the iOS 15 simulator.
- The SQLite (78 tests) and AssetKit (103 tests) adapters pass.
- Cycle 1 traced 479 requirements: 351 met, 78 partly met, 5 missing, 14 contradicted, and 31 that cannot be checked on this Mac.

What does not hold up is the claim that the quality gates are demonstrated:
- `PerformanceTests` cannot fail on several of the budgets it states, because an unscoped `XCTExpectFailure` absorbs both the miss and every later assertion in the test.
- Three budgets are missed by the package's own scaled estimate. At a load average of about 6, the 100k-item locale rebuild took 853 ms against 333 ms allowed, and upserts ran 3.0–3.9x over.
- The UI parity gate is not met. The README says so, but it overstates where the field matches.
- Several other gates rest on tests that cannot fail, or that never run in CI.

Both cycles also found real defects in normal use. The most important: a persisted search-context index is reused after its content changes, so results go stale across launches.

The skeptics refuted only 1 of 154 findings. Their main correction was severity: they downgraded 14 of 64 findings in cycle 1 and 25 of 90 in cycle 2, and upgraded none. Each finding had one skeptic, not a panel. That is why the 23 issues both cycles reached on their own are the strongest results.

## Fix first

1. **Stale persisted indexes.** The memory-context fingerprint ignores keywords, filters, localizations and same-length edits (both cycles, high). Database-backed contexts adopt a persisted index without reading their rows, so writes made while nothing was subscribed are never indexed (cycle 2, high).
2. **Performance gates that cannot fail.** Scope `XCTExpectFailure` to the one assertion it excuses (both cycles, high). Then decide what to do about the missed locale-rebuild, upsert and catalog-sized scan budgets (cycle 2, high, matching the release runs above).
3. **Model download and chat readiness.**
   - A retry restarts the 968 MB weights file from byte 0 (both cycles, high).
   - Calling `prepare()` during a download restarts it or leaves readiness stuck (cycle 1, high).
   - An interrupted calibration persists a failing verdict, so chat stays off on a capable device (cycle 1, high).
4. **Writes racing a rebuild.** `index`, `remove` and `replace` calls that race a rebuild are silently undone (cycle 1, high).
5. **UI parity.** The gate is not met, and iOS 15 and 16, the package floor, were never sampled (both cycles, high).
6. **Local chat target.** The grounded-answers target has no 100-question golden set and no measurement (cycle 1, high).

## Evidence from running the suites

| Run | Result | Log (`_runs/`) |
|---|---|---|
| `swift test`, debug | 580 tests, 0 failures, 22 skipped (all budget or large-corpus tests), 0 warnings | `c1-debug-swift-test.log` |
| `swift test --sanitize=thread` | 580 tests, 0 failures, no TSan report | `c2-tsan-swift-test.log` |
| iOS Simulator `build-for-testing` | succeeded | `c2-ios-build.log` |
| `generate_ui_assets.py --check` | no drift | `c2-ui-assets-check.log` |
| SQLite adapter, debug | 78 tests, 1 skipped (its §15.9 targets need release) | `c2-sqlite-adapter.log` |
| SQLite adapter §15.9 targets, release | 1 failure: incremental 10.2 ms vs 8.3 ms allowed on this Mac | `c2-sqlite-release-targets.log` |
| AssetKit adapter | 103 tests, 0 failures | `c2-assetkit-adapter.log` |
| Release `PerformanceTests` | Failed in both of my runs, at load averages of 370 and about 10, with 12 simulators booted by other work, so those timings are unreliable. A cycle 2 skeptic re-measured at load 5–7: fusion and page targets pass, and only the §15.9 incremental-upsert p95 fails, intermittently. Every run absorbed 4–5 budget misses through `XCTExpectFailure` | `c2-release-performance*.log` |
| Release `RelevanceTests`, 100k distractors | 21 tests passed. The semantic and rerank gates use fakes built from the golden judgments | `c2-release-relevance-full.log` |
| Release semantic suite, large HNSW | 1 failure in both runs: the isotropic test, documented as "not a gate", enforces cache-cold p95 (0.95 ms vs 0.83 ms) | `c2-release-semantic-large.log`, `c2-release-hnsw-recall-rerun.log` |
| MLX adapter | not run: no Metal toolchain, and its dependency set is not cached | — |

## What this verification does not cover

- Nothing ran on a device. Budgets for the reference device (iPhone 6s, iOS 15.8) are approximated by scaling. The iOS 15 and 16 simulators cannot boot on this Mac, and the parity matrix was not rerun.
- No real embedding model, cross-encoder or language model was evaluated: the package ships none.
- Five of the six cycle 2 skeptics were cut off by the weekly usage limit on 2026-11-17. They were resumed on 2026-11-18 from their own partial notes, with unchanged instructions.
- Cost: cycle 1 took 12 agents and 2.6M subagent tokens. Cycle 2 took 17 agent runs and 4.8M tokens.

Per-finding detail: `cycle-1/SUMMARY.md` and `cycle-2/SUMMARY.md`, by id. Agents' own notes: `cycle-N/find-*.md` and `verify-*.md`.

## Totals

- Cycle 1: 64 findings; cycle 2: 90 findings.
- Found and confirmed by both cycles: 23 issues (0 critical, 4 high, 14 medium, 5 low).
- Confirmed by one cycle only: 87 issues (0 critical, 6 high, 21 medium, 59 low).
- Found by both cycles but confirmed by only one skeptic: 0. One cycle confirmed, the other refuted: 0.
- Uncertain or unverified: 1. Refuted: 1.

## Found independently by both cycles

Each row is one defect that cycle 1 (from the spec) and cycle 2 (from the code) reached on their own, and that each cycle's skeptic failed to refute. These are the highest-confidence results.

| # | Severity | Issue | Cycle 1 (verdict/severity) | Cycle 2 (verdict/severity) |
|---:|---|---|---|---|
| 1 | high | A retry of the model download restarts the in-transit file (968 MB of weights) from byte 0 | s05-chat-03 partly/medium | m05-adapters-02 confirmed/high |
| 2 | high | Budget checks call an unscoped XCTExpectFailure, so a missed budget and every later assertion in the test pass | s01-contracts-04 partly/medium, s06-quality-02 confirmed/high | m01-text-index-01 partly/medium, m06-tests-gates-01 confirmed/high |
| 3 | high | Persisted context index reused after content edits: the fingerprint ignores keywords, filters, localizations and same-length edits | s01-contracts-01 partly/high, s03-engine-api-03 confirmed/high | m01-text-index-04 confirmed/medium, m02-query-service-02 confirmed/high |
| 4 | high | UI parity gate of 12.5/15.7 not met; iOS 15 and 16, the floor, were never sampled and reuse iOS 17 values | s04-ui-01 confirmed/high, s04-ui-02 confirmed/high, s06-quality-01 confirmed/high | m04-ui-01 confirmed/high |
| 5 | medium | Attachment / EnvironmentObject lint cannot fail over the repository | s04-ui-06 confirmed/medium, s06-quality-10 confirmed/low | m04-ui-06 partly/low |
| 6 | medium | Cancellation-latency tests accept far more than the 10 ms target, or time only the consumer's exit | s03-engine-api-10 partly/low | m02-query-service-10 partly/low, m06-tests-gates-04 partly/medium |
| 7 | medium | Changing pageSize during a search drops its snapshots and leaves the previous query's hits | s03-engine-api-08 confirmed/low, s04-ui-05 confirmed/medium | m04-ui-02 partly/medium |
| 8 | medium | Chat prompt budget counts message contents only, not the template's per-message tokens | s05-chat-05 confirmed/medium | m02-query-service-18 confirmed/low |
| 9 | medium | Citations of ids containing ':' are never recognised; the raw marker leaks into the reply | s05-chat-07 confirmed/medium | m02-query-service-08 confirmed/medium |
| 10 | medium | Paging arithmetic overflows (trap) with a huge limit and a cursor | s03-engine-api-05 confirmed/medium | m01-text-index-07 confirmed/low |
| 11 | medium | Public setters bypass the initializers' clamps: zero or negative limits crash or hang | s02-retrieval-02 confirmed/medium, s02-retrieval-03 partly/low, s03-engine-api-06 confirmed/low | m01-text-index-05 confirmed/medium, m02-query-service-13 confirmed/low |
| 12 | medium | Randomized stale-snapshot test cannot detect a stale snapshot | s06-quality-08 confirmed/low | m02-query-service-03 partly/medium, m06-tests-gates-05 partly/low |
| 13 | medium | Resident-memory budgets of 15.2 are not asserted; model budgets are checked as on-disk size | s06-quality-05 confirmed/medium | m03-semantic-01 partly/medium, m06-tests-gates-09 partly/medium, m05-adapters-06 partly/low |
| 14 | medium | Section 15.9 database targets over real SQLite never run in CI (and fail here in release) | s06-quality-04 confirmed/medium | m05-adapters-01 partly/low, m06-tests-gates-10 confirmed/low |
| 15 | medium | Semantic-snapshot latency test checks a weaker gate; the reranked-snapshot target has no test | s06-quality-06 partly/low | m06-tests-gates-03 partly/medium |
| 16 | medium | Smart-punctuation emulation rewrites characters the user typed | s04-ui-04 confirmed/medium | m04-ui-09 confirmed/low |
| 17 | medium | Source truncation splits on whitespace, so unspaced scripts (Japanese, Chinese, Thai) lose the whole source | s05-chat-06 confirmed/medium | m02-query-service-07 confirmed/medium |
| 18 | medium | With an editingPolicy set, the host's .focused binding cannot begin editing | s04-ui-10 confirmed/medium | m04-ui-07 confirmed/medium |
| 19 | low | A send during a model fetch waits uncancellably for the download while holding the generation lock | s05-chat-12 partly/low | m02-query-service-16 partly/low |
| 20 | low | Cancellation during the prompt prefill is not bounded as specified, and no test covers it | s05-chat-08 partly/low | m05-adapters-05 partly/low |
| 21 | low | Canonically equivalent ids (NFC/NFD) are one id to Swift collections but two to the index | s01-contracts-11 confirmed/low | m01-text-index-06 partly/low, m03-semantic-08 confirmed/low |
| 22 | low | Filter/kind precision gate passes when the engine returns nothing | s06-quality-09 partly/low | m06-tests-gates-07 partly/low |
| 23 | low | README overstates where the field matches the UIKit reference | s04-ui-11 confirmed/low | m04-ui-12 partly/low |

**1. A retry of the model download restarts the in-transit file (968 MB of weights) from byte 0** (high). Where: `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchOperation.swift:260-264`, `Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchOperation.swift:279-284`. On any failure the bridge fails the fetch and withdraws every ZTronAssetKit request through group.cancelAll(). Failures include .offline, .policy when the device leaves Wi-Fi under .wifiOnly, and any resolve error. A cancelled reader has the same effect. With no interest left, ZTronAssetKit retires the job: it cancels the transfer ('Stop, discarding the partial') and removeJob drops the job's state. A new job in the same process adopts a resume point only from launchResumes, so earlier partials are found only at launch. Stored files are kept, so resume works per file only. For the reference mo…

**2. Budget checks call an unscoped XCTExpectFailure, so a missed budget and every later assertion in the test pass** (high). Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:70-87`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:301-328`. As stated. In addition, the waiver also applies on the reference device itself, where the milestone gate is supposed to be settled. The comment claiming strictness is wrong.

**3. Persisted context index reused after content edits: the fingerprint ignores keywords, filters, localizations and same-length edits** (high). Where: `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:181-199`, `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:122-141`. An indexed memory context (custom id, no database source, over 500 items or .indexed) with the default .files(Caches/ZTronSearchEngine) storage adopts the previous launch's index file whenever the weak content fingerprint is unchanged. The fingerprint is item count plus each item's id, kind, text and title UTF-8 byte counts and updatedAt. Updates that only add or change localizations, keywords, filters, caption, OCR text or same-length text are therefore served stale on every launch until refresh() or a cache purge. Severity high: silent and persistent, but it needs that update pattern and is …

**4. UI parity gate of 12.5/15.7 not met; iOS 15 and 16, the floor, were never sampled and reuse iOS 17 values** (high). Where: `ParityHost/Results/summary.md:7-29`, `ParityHost/Results/summary.csv`. The matrix needs 5 iOS x 4 devices x 800 = 16,000 cells. The committed run has 7,440 results: 179 pass, 602 fail, 6,659 not runnable. iOS 15.5 and 16.4 never ran (3,200 each not runnable). No RTL cell passes, no bold-text cell passes, and no iPhone SE, iPad or iOS 27 cell passes.

**5. Attachment / EnvironmentObject lint cannot fail over the repository** (medium). Where: `Sources/ZTronSearchFixtures/SourceLint.swift:211-240`, `Tests/ZTronSearchEngineUITests/LintTests.swift:154-161`. Attachment is decided per model type across all scanned files, and any .environmentObject( call, for any object, counts as attaching every model. A screen that reads a model without being under an attaching modifier passes as long as another file attaches that type or injects anything at all. The in-repo test scans ParityHost and a non-existent Examples directory, which contain no @EnvironmentObject reader.

**6. Cancellation-latency tests accept far more than the 10 ms target, or time only the consumer's exit** (medium). Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:34-47`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:49-80`. No test detects a producer that keeps running after the consumer cancels, for example with onTermination removed. Removing the IndexSearcher checkpoints is caught by testTheScoringLoopChecksCancellation. The 10 ms + full/4 bound is not a relaxation of the spec.

**7. Changing pageSize during a search drops its snapshots and leaves the previous query's hits** (medium). Where: `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:78-81`, `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:65-70`. The pageSize setter changes query.limit without bumping the revision or restarting the search. Snapshots from the in-flight stream carry the old limit, fail snapshot.query == query and are dropped. When the stream ends, isLoading is cleared. A later update() with the same text returns early because the query is equal. reset() builds SearchQuery(text: "") and silently goes back to the default page size.

**8. Chat prompt budget counts message contents only, not the template's per-message tokens** (medium). Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:132-162`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:461-473`. PromptAssembler checks the 3,520-token budget (4096 - 512 - 64) against message contents only. The runtime renders every message through the chat template, adding role markers and separators plus a generation prompt. For ChatML I estimate about 5 tokens per message plus 7; this was not measured on the real tokenizer. The 64-token margin absorbs about 11 messages.

Beyond that, MLX silently shortens the reply budget to min(512, window - prompt). Once the rendered prompt reaches 4,096, it throws promptTooLong, which surfaces as generationFailed. History is trimmed against the same content-only c…

**9. Citations of ids containing ':' are never recognised; the raw marker leaks into the reply** (medium). Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:76-81`, `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:74-76`. When consume() meets a second ':' inside a pending marker, it checks whether the text between '[' and that ':' is a kind. For [map:region:1] that text is 'map:region', which is not a kind, so the pending text is flushed as plain text. The marker reaches the transcript verbatim, with no .citation and no unknownCitation report. Such ids are legal: SearchRowProjector's .verbatim and .prefixed(prefix) strategies can produce them; the default tablePrefixed uses '#'.

**10. Paging arithmetic overflows (trap) with a huge limit and a cursor** (medium). Where: `Sources/ZTronSearchEngine/Scan/ScanIndex.swift:77`, `Sources/ZTronSearchEngine/Service/SearchService.swift:466`. Both slice computations use `let end = min(count, start + max(0, query.limit))`. limit and cursor are public settable values, and SearchCursor(offset:) is public. With limit near Int.max and an offset > 0 the addition overflows and traps instead of clamping. This affects ScanIndex.hits/snapshot, results(for:) with a cursor, and page(after:generation:) for a retained query with such a limit.

**11. Public setters bypass the initializers' clamps: zero or negative limits crash or hang** (medium). Where: `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:75`, `Sources/ZTronSearchEngine/Contracts/RankingProfile.swift:78-80`. EditorialPolicy.maximumPins, RerankSpec.topN and RerankSpec.blend are public vars whose clamps exist only in init. ResultRanker.applyingPins, SearchService (prefix(spec.topN)) and SearchPipeline.reranked read the stored values without re-clamping. Mutating a profile with the usual Swift idiom (var p = RankingProfile.default; p.editorial.maximumPins = 6) breaks the documented and specified ceilings. RankingTests.swift:64-65 checks only the initializer path.

**12. Randomized stale-snapshot test cannot detect a stale snapshot** (medium). Where: `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:157-219`, `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:175-176`. As described. Impact: the 15.4 and section 11 gate is unverified against regressions. Currently correct code and the UI model's own check prevent stale results today.

**13. Resident-memory budgets of 15.2 are not asserted; model budgets are checked as on-disk size** (medium). Where: `Sources/ZTronSearchFixtures/ReferenceDevice.swift`, `Sources/ZTronSearchEngineSemantic/SemanticError.swift:78-83`. Several 15.2 budgets have no test: the 110 MB steady state with models unloaded, the 200 MB peak during a semantic query, the 320 MB peak during a reranked query, and the 800 ms or less model reload after unload. The 80 MB and 60 MB model budgets are enforced on the on-disk size of the model files, not the loaded footprint. Item vectors and the HNSW graph are checked as file sizes, and only when ZTRON_SEMANTIC_LARGE is set.

**14. Section 15.9 database targets over real SQLite never run in CI (and fail here in release)** (medium). Where: `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:68-70`, `.github/workflows/adapter-tests.yml:58`. The only test that measures the 15.9 targets against SQLite skips itself in debug builds, and the adapter CI workflow runs only debug builds. The core performance test measures the dictionary-backed FakeSearchDatabaseConnection, not SQLite, and does not assert that context creation never blocks a query on the existing generation.

**15. Semantic-snapshot latency test checks a weaker gate; the reranked-snapshot target has no test** (medium). Where: `Tests/ZTronSearchEngineTests/PerformanceTests.swift:244-275`, `Tests/ZTronSearchEngineTests/PerformanceTests.swift:270`. The test holds an unscaled 20 ms residual, which also contains debounce-timer overshoot, and never asserts the 500 ms total. A 6x engine regression inside 20 ms passes, and so does a total over 500 ms (504.6 ms was seen passing). The 556-599 ms device extrapolation is not supported.

**16. Smart-punctuation emulation rewrites characters the user typed** (medium). Where: `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:89-105`, `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:228`. On every input change, plain() maps U+2018/2019, U+201C/201D, U+2014 and U+2013 to ASCII anywhere in the text. Typographic characters that are already there (set by the host, pasted, or typed by long-press) get rewritten as a side effect of the next keystroke, and the logged change becomes a multi-character replacement instead of an insertion.

**17. Source truncation splits on whitespace, so unspaced scripts (Japanese, Chinese, Thai) lose the whole source** (medium). Where: `Sources/ZTronSearchEngine/Chat/CitationParser.swift:165-180`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:564-579`. PromptAssembler.truncate binary-searches over whitespace-split words. An unspaced caption counts as a single word, so when marker, title and caption exceed 80 tokens the whole caption is cut. What remains is only the marker and title, or an empty string when the first word alone is over the limit. The model is then grounded on titles only. The only test uses Latin text.

**18. With an editingPolicy set, the host's .focused binding cannot begin editing** (medium). Where: `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:345`, `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:484-490`. With a policy set, the inner TextField stays .disabled until a tap passes the gate. Only the tap gate calls requestFocus. Setting the host FocusState targets a disabled TextField, which SwiftUI does not focus, so neither the policy check nor focus happens. UIKit's becomeFirstResponder asks textFieldShouldBeginEditing first. PLAUSIBLE: needs a device; no unit test or parity script uses editingPolicy.

**19. A send during a model fetch waits uncancellably for the download while holding the generation lock** (low). Where: `Sources/ZTronSearchEngine/Chat/ChatService.swift:435`, `Sources/ZTronSearchEngine/Chat/ChatService.swift:533-539`. A turn cancelled while it waits for a running preparation does not end until that preparation finishes. A consumer that cancels through ChatService.cancel(session) therefore sees its stream stay open. Other sessions are not delayed beyond the wait they already have for the same preparation.

**20. Cancellation during the prompt prefill is not bounded as specified, and no test covers it** (low). Where: `.github/workflows/ci.yml:76-89`, `Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:25-45`. Real-weight MLX tests run only on demand, which is consistent with spec section 16 and the milestone 8 gate. The real but minor issue is that, with the default tuning, cancellation during prefill is observed once per 512-token chunk. On long prompts that can exceed 15.6's 150 ms target. prefillStepSize exists as a knob for this.

**21. Canonically equivalent ids (NFC/NFD) are one id to Swift collections but two to the index** (low). Where: `Sources/ZTronSearchEngine/Contracts/Searchable.swift:35-37`, `Sources/ZTronSearchEngine/Index/IndexSegment.swift:428-445`. Equality and hashing follow Swift canonical equivalence. '<' compares UTF-8 bytes, and the index locates ids with a byte-exact memcmp.

**22. Filter/kind precision gate passes when the engine returns nothing** (low). Where: `Sources/ZTronSearchFixtures/RelevanceMetrics.swift:66-71`, `Tests/ZTronSearchEngineTests/GoldenGates.swift:38-39`. The filterAndKind class gate and the no-violation test pass on empty lists. Filtered recall is checked only in the reranked stage over the golden set and on the small catalog. A regression that empties filtered results only in the lexical or semantic stage at golden-set scale, and is masked in the reranked stage, would pass.

**23. README overstates where the field matches the UIKit reference** (low). Where: `README.md:216-218`. README says the field matches on iOS 17.5 and 18.6 on 3x iPhones, LTR, at the default content size. At that size and direction, bold-text cells fail 18/18 on both versions on iPhone 15, 2 of 20 cells per group are not runnable, and 18.6 iPhone 15 Pro Max has 1 failure. That failure is a harness flake: the reference dropped a hardware keystroke (reference 'mp', clone 'map').

## Confirmed by one cycle only

Real by its own cycle's skeptic, not reached by the other cycle. Full detail in `cycle-N/SUMMARY.md` under the id.

| Severity | Cycle | Issue | Ids | Where |
|---|---|---|---|---|
| high | 1 | index/remove/replace racing a rebuild are silently undone | s03-engine-api-01 | `Sources/ZTronSearchEngine/Service/SearchService.swift:199-207` |
| high | 1 | An interrupted calibration persists a failing verdict, so chat stays off on a capable device until the next app or OS update | s05-chat-01 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:303-350` |
| high | 1 | Calling prepare() again during a download cancels and restarts the download, or leaves readiness stuck | s05-chat-02 | `Sources/ZTronSearchEngineUI/ZTronChatModel.swift:80-92` |
| high | 1 | Local chat grounded-answers target has no 100-question golden set and no measurement | s06-quality-03 | `Sources/ZTronSearchFixtures` |
| high | 2 | Locale-rebuild, incremental-upsert and catalog-sized scan-creation budgets are missed by the package's own scaled estimate | m01-text-index-02, m06-tests-gates-02 | `Tests/ZTronSearchEngineTests/PerformanceTests.swift:301-328` |
| high | 2 | Database-backed contexts adopt a persisted index without reading their rows, so writes made while no context is subscribed are never indexed | m02-query-service-01 | `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:156-166` |
| medium | 1 | A localization key equal to its resolved value is treated as unresolved and the string is dropped | s01-contracts-02, s03-engine-api-02 | `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:124-136` |
| medium | 1 | Two-character CJK words miss exact-title queries when the query is segmented in a different CJK language than the field | s01-contracts-03 | `Sources/ZTronSearchEngine/Text/SearchTokenizer.swift:152-171` |
| medium | 1 | Secondary languages de-duplicated by primary subtag: zh-Hant, sr-Latn and pt-BR never reach localizedAlt, even via .explicit | s01-contracts-05 | `Sources/ZTronSearchEngine/Text/LanguageTag.swift:68-81` |
| medium | 1 | Id collisions not debug-asserted for contexts; cross-kind collisions across index batches unchecked above 512 documents | s01-contracts-07 | `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:97` |
| medium | 1 | Indexed semantic channel applies hard constraints after ANN retrieval; filtered queries lose their semantic matches and disagree with the scan strategy | s02-retrieval-01 | `Sources/ZTronSearchEngine/Service/SearchService.swift:554-558` |
| medium | 1 | Concurrent upsert lost while an .automatic context is promoted to an index | s03-engine-api-04 | `Sources/ZTronSearchEngine/Service/SearchService+Context.swift:227-237` |
| medium | 1 | Host cannot override the return-key label | s04-ui-03 | `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:342` |
| medium | 1 | Bold Text is not modelled; text uses fixed-size system fonts instead of .body | s04-ui-07 | `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:337` |
| medium | 1 | No RTL (Arabic) cell passes: clear and Cancel labels stay English and tokens are 2 pt shorter | s04-ui-09 | `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:768-773` |
| medium | 1 | Downloads do not continue through ZTronAssetKit's background session while the engine only observes; core cancels an unobserved download | s05-chat-04 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:157-163` |
| medium | 1 | Latency targets are timed on English golden queries only, and bigram-fallback lookups are never timed | s06-quality-07 | `Tests/ZTronSearchEngineTests/PerformanceTests.swift:56` |
| medium | 2 | Segments are validated only at the outer layer; corrupt cached files that pass crash, hang or return wrong results at every launch, and the header check itself can trap before the file is discarded | m01-text-index-03 | `Sources/ZTronSearchEngine/Index/IndexSegment.swift:107-196` |
| medium | 2 | A row with a literal and a localized key in the same role loses the literal from its field: it is moved to localizedAlt, even under the base language | m02-query-service-04 | `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:132-147` |
| medium | 2 | ChatService.load is not reentrancy-safe: unload() or a memory warning during a load is undone, and prepare() during a send-triggered load loads the weights twice | m02-query-service-06 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:282-298` |
| medium | 2 | Text date columns cost up to two ISO8601DateFormatter constructions per row | m02-query-service-09 | `Sources/ZTronSearchEngine/Database/SearchSQLComposer.swift:190-209` |
| medium | 2 | QuantizedVectorStore.build writes out of bounds when the quantization has more dimensions than the space | m03-semantic-02 | `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:172` |
| medium | 2 | A large `limit` crashes the HNSW search (Int.max) or pins scratch memory proportional to the limit | m03-semantic-03 | `Sources/ZTronSearchEngineSemantic/HNSW/HNSWGraph.swift:192-194` |
| medium | 2 | WordPiece misfiles '##' continuation pieces that start with a combining mark, so words that need them become [UNK] | m03-semantic-04 | `Sources/ZTronSearchEngineSemantic/Tokenization/WordPieceTokenizer.swift:121-122` |
| medium | 2 | The parity suite does not check what the spec places under it: three token scripts, the public modifiers' callback counts, and the sampled clone profile | m04-ui-05 | `ParityHost/Sources/ZTronSearchEngineUIParity/ParityScript.swift:12-88` |
| medium | 2 | On iOS 18+, text set through the binding while editing keeps the caret at its old UTF-16 offset (possibly inside a surrogate pair), and the field pushes that caret into the input (plausible) | m04-ui-08 | `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:180-187` |
| medium | 2 | View and virtual-table sources are never refreshed by the change stream | m05-adapters-03 | `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteExpressions.swift:204-207` |
| low | 1 | setLocale cancels the in-flight search instead of letting it finish on the old index | s01-contracts-06 | `Sources/ZTronSearchEngine/Service/SearchService.swift:892-903` |
| low | 1 | Field fallback chain treats a script variant as a language match, unlike Bundle.preferredLocalizations | s01-contracts-08 | `Sources/ZTronSearchEngine/Text/LanguageTag.swift:32-51` |
| low | 1 | Shadowed base surfaces always indexed into localizedAlt, even with SecondaryLanguages.none | s01-contracts-09 | `Sources/ZTronSearchEngine/Projection/SearchProjector.swift:109-113` |
| low | 1 | Typed filters never rebuilt at query time; unknown filter records in loaded or persisted indexes never logged | s01-contracts-10 | `Sources/ZTronSearchEngine/Service/SearchService.swift:994-998` |
| low | 1 | Core consults Bundle.main.infoDictionary | s01-contracts-12 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:624` |
| low | 1 | 1-2 character CJK/Thai queries run the semantic phase (and rerank on gated devices) despite the 3-character rule | s02-retrieval-04 | `Sources/ZTronSearchEngine/Service/SearchPipeline.swift:61-63` |
| low | 1 | Rerank passage for untitled unspaced-script text is the whole text, not the first 64 tokens | s02-retrieval-05 | `Sources/ZTronSearchEngine/Service/SearchPipeline.swift:196-200` |
| low | 1 | Scan scoring checks cancellation every 256 documents, not every 1,000 postings | s03-engine-api-07 | `Sources/ZTronSearchEngine/Scan/ScanEngine.swift:147-172` |
| low | 1 | Suggestions run on their own timer, not the lexical timer | s03-engine-api-09 | `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:226` |
| low | 1 | Parity metrics capture records the reference's hidden glyph, so every accessibility-size cell with content fails | s04-ui-08 | `ParityHost/Sources/ZTronSearchEngineUIParity/ReferenceField+Layout.swift:10-12` |
| low | 1 | Token drawn as a radius-4 rounded rectangle, not a capsule | s04-ui-12 | `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:493-512` |
| low | 1 | A stream that ends without a final snapshot leaves stale or partial hits shown as settled | s04-ui-13 | `Sources/ZTronSearchEngineUI/ZTronSearchResultsModel.swift:149-152` |
| low | 1 | The spec's minimal host does not type-check against textToToken | s04-ui-14 | `Sources/ZTronSearchEngineUI/ZTronSearchFieldEnvironment.swift:120` |
| low | 1 | Core calibration can pass without measuring a decode rate | s05-chat-09 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:303-350` |
| low | 1 | ZTronChatModel.prepare can lose its reference to the running preparation task | s05-chat-10 | `Sources/ZTronSearchEngineUI/ZTronChatModel.swift:80-92` |
| low | 1 | An Int64 overflow trap is reachable through public API with huge byte counts | s05-chat-11 | `Sources/ZTronSearchEngine/Contracts/ChatBoundary.swift:38-40` |
| low | 2 | Filter-only queries on the indexed strategy keep the first 2,000 live documents in segment order, so the hits depend on upsert/merge history | m01-text-index-08 | `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:680-692` |
| low | 2 | Plans with more than 64 clauses (bigram fallback) give later clauses match bit 0, so documents matching only those clauses are dropped | m01-text-index-09 | `Sources/ZTronSearchEngine/Query/QueryPlanner.swift:122, :150-157` |
| low | 2 | Normalization adds a dotless-i to i step beyond the spec recipe | m01-text-index-10 | `Sources/ZTronSearchEngine/Text/SearchNormalizer.swift` |
| low | 2 | Weak or nondeterministic tests: unseeded trigram property test, locale-change test that does not prove overlap with the rebuild, corrupt-file test that only fails the magic check | m01-text-index-11 | `Tests/ZTronSearchEngineTests/TextPipelineTests.swift:160-163` |
| low | 2 | admitCandidates comment claims 'heaviest field first', but fields are visited in fixed ordinal order regardless of the profile's field weights | m01-text-index-12 | `Sources/ZTronSearchEngine/Index/IndexSearcher.swift:694-695` |
| low | 2 | The chat idle-unload timer can fire while a new turn is retrieving or assembling its prompt, and cancels that turn | m02-query-service-05 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:377-400` |
| low | 2 | Every keyed field resolves the key in every catalog language, though only the active, fallback and secondary languages are used | m02-query-service-11 | `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:116-147` |
| low | 2 | A row's literal fields lose their declared language unless every field of the row agrees on one language | m02-query-service-12 | `Sources/ZTronSearchEngine/Database/SearchRowProjector.swift:157-161` |
| low | 2 | A non-finite cross-encoder score puts NaN into the published hits and silently disables the rerank for the head | m02-query-service-14 | `Sources/ZTronSearchEngine/Service/SearchService.swift:716-719` |
| low | 2 | Wiring chat through ZTronSearch creates a retain cycle; neither the search service nor the chat service is ever freed | m02-query-service-15 | `Sources/ZTronSearchEngine/Chat/ChatService.swift:679-684` |
| low | 2 | query.limit = 0 yields a cursor that never advances | m02-query-service-17 | `Sources/ZTronSearchEngine/Service/SearchService.swift:464-479` |
| low | 2 | SearchError.missingLocalizedStringResolver is declared but never thrown; keyed fields are silently dropped when no resolver is set | m02-query-service-19 | `Sources/ZTronSearchEngine/Contracts/SearchHit.swift:134-135` |
| low | 2 | A cancelled upsert leaves untracked vectors in the index, which are silently dropped at the quantization refit or not carried at a locale switch | m03-semantic-05 | `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:413-439` |
| low | 2 | The 'Not a gate' isotropic HNSW test enforces the latency gate and fails the CI quality-targets step | m03-semantic-06 | `Tests/ZTronSearchEngineSemanticTests/HNSWRecallTests.swift:117-127` |
| low | 2 | Vector and graph files with tombstone bits beyond the row/node count are accepted, and rows appended later are born tombstoned | m03-semantic-07 | `Sources/ZTronSearchEngineSemantic/Vector/QuantizedVectorStore.swift:275` |
| low | 2 | TokenizerLoader approximates where its contract says unsupported files are refused | m03-semantic-09 | `Sources/ZTronSearchEngineSemantic/Tokenization/TokenizerLoader.swift:124-128` |
| low | 2 | Items embedded on device by embedMissing get the query prefix | m03-semantic-10 | `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:269` |
| low | 2 | Switching to a locale whose set is unusable reloads, and may rebuild, the base set on every call and then discards it | m03-semantic-11 | `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:208-234` |
| low | 2 | Removals are recorded only for ids present in the active vector set | m03-semantic-12 | `Sources/ZTronSearchEngineSemantic/SemanticIndex.swift:189-202` |
| low | 2 | Constrained queries request 200 HNSW neighbours; spec 10 bounds the work at 50, and the ANN gate is measured only at 50 | m03-semantic-13 | `Sources/ZTronSearchEngine/Service/SearchService.swift:552-558` |
| low | 2 | Documentation drift in the semantic scripts and adapters (wrong script paths, truncation wording, pruning test not run in CI) | m03-semantic-14 | `Sources/ZTronSearchEngineSemantic/CoreML/CoreMLEmbeddingProvider.swift:4` |
| low | 2 | Ending editing drops the token selection and fires onSelectionChanged, while the UIKit reference keeps the token selected (recorded in both samples, checked by nothing) | m04-ui-03 | `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:483-505` |
| low | 2 | On iOS 18, tapping the text to deselect a token logs two extra caret moves that the reference does not log | m04-ui-04 | `Sources/ZTronSearchEngineUI/ZTronSearchField.swift:684-689` |
| low | 2 | shouldChange payloads and textInputPolicy changes are computed per grapheme, not per UTF-16 edit | m04-ui-10 | `Sources/ZTronSearchEngineUI/ZTronSearchFieldTypes.swift:101-112` |
| low | 2 | 'Not runnable' overrides comparison failures already recorded, hiding 203 failing cells from the failure counts | m04-ui-11 | `ParityHost/Sources/ZTronSearchEngineUIParity/ParitySession.swift:216-229` |
| low | 2 | Select-all then entering identical text is treated as backspace-at-start: it selects, then deletes, the last token | m04-ui-14 | `Sources/ZTronSearchEngineUI/ZTronSearchFieldCore.swift:231-234` |
| low | 2 | The Qwen3 reference ModelAsset cannot be built from the package, and the documented way to complete it is circular | m05-adapters-04 | `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/Qwen3Asset.swift:6-25` |
| low | 2 | An UPDATE that changes the rowid leaves a ghost document, and the README's list of unreported writes omits it | m05-adapters-07 | `Adapters/ZTronSearchEngineSQLite/README.md:132-138` |
| low | 2 | ModelAssetManifest.validate(against:) does not tie a new SHA-256 to the Git blob id, as its docs claim | m05-adapters-08 | `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ModelAssetManifest.swift:136-174` |
| low | 2 | BundleLocalizedStringResolver returns the uppercased key as a string when NSShowNonLocalizedStrings is set | m05-adapters-09 | `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/BundleLocalizedStringResolver.swift:64-67` |
| low | 2 | load() cannot be cancelled, and unload() during a load keeps about 1 GB until the weight read finishes | m05-adapters-11 | `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:167-188` |
| low | 2 | The AssetKit adapter's tests run in no CI workflow | m05-adapters-12 | `.github/workflows/adapter-tests.yml` |
| low | 2 | The asset's max_new_tokens can only lower the 512-token cap | m05-adapters-13 | `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/SamplingPlan.swift:154-157` |
| low | 2 | Calibration measures to the first visible delta, and the rate counts hidden leading tokens | m05-adapters-14 | `Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ChatCalibration.swift:23-24` |
| low | 2 | Stale 'expected to fail against core' comment in EndToEndTests | m05-adapters-15 | `Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/EndToEndTests.swift:383-392` |
| low | 2 | The SQLite README host-wiring sample is not the code ReadmeSampleTests runs | m05-adapters-16 | `Adapters/ZTronSearchEngineSQLite/README.md:49-81` |
| low | 2 | MLX README drift: 'absolute path' note and the unit-test count | m05-adapters-17 | `Adapters/ZTronSearchEngineMLX/README.md:54-55` |
| low | 2 | The release quality suites failed on this Mac in every run (RRF fusion and the 15.9 database targets), and the SQLite release targets failed too | m06-tests-gates-06 | `Tests/ZTronSearchEngineTests/PerformanceTests.swift:173` |
| low | 2 | 'Relevance gates among 100,000 distractors' adds no competition: distractors are built never to match a golden query, and the numbers are identical at 5,000 and 100,000 | m06-tests-gates-08 | `Sources/ZTronSearchFixtures/SyntheticCorpus.swift:14-23` |
| low | 2 | The semantic, cross-language and rerank gates are reached only with oracle fakes built from the queries' own lexicon; the rerank stage changes no metric, so 'never below fused' holds by equality | m06-tests-gates-11 | `Sources/ZTronSearchFixtures/FakeEmbeddingProvider.swift` |
| low | 2 | The 'timeout-guarded' deadlock test cannot time out, because withTaskGroup waits for the hung child | m06-tests-gates-12 | `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:19-30` |
| low | 2 | Several bounded-work and context tests check proxies that cannot fail for the property they name | m06-tests-gates-13 | `Tests/ZTronSearchEngineTests/ConcurrencyTests.swift:328-348` |
| low | 2 | README and CI comments the configuration does not keep | m06-tests-gates-14 | `README.md:209-210` |
| none | 2 | A public initializer can trap the process: preconditionFailure in SearchBindingValue.init(_:) | m05-adapters-10 | `Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteBindings.swift:36-37` |

## Related findings that are not the same defect

- Hard constraints are applied after ANN retrieval: cycle 1 says filtered queries lose semantic matches; cycle 2 says the 200-neighbour over-fetch breaks the work bound of 50: s02-retrieval-01 partly/medium; m03-semantic-13 partly/low.
- Preparation and load reentrancy, in different layers (ZTronChatModel.prepare vs ChatService.load): s05-chat-02 confirmed/high, s05-chat-10 partly/low; m02-query-service-06 confirmed/medium.
- Decode-rate calibration, in the core (can pass without a rate) vs the MLX adapter (counts hidden tokens): s05-chat-09 confirmed/low; m05-adapters-14 confirmed/low.
- Right-to-left cells show English labels (cycle 1) vs committed parity results that predate the localization (cycle 2): s04-ui-09 partly/medium; m04-ui-12 partly/low.
- Gates reached only with fakes that agree with the judgments (cycle 1 refuted the narrower reranker claim): s06-quality-11 refuted/none; m06-tests-gates-11 partly/low.
- Persisted index adopted without checking content: memory contexts (the shared finding above) and database-backed contexts (cycle 2 only): s01-contracts-01 partly/high; m02-query-service-01 partly/high.

## Uncertain or unverified

- m04-ui-13 (uncertain, low): iOS 18 caret reports near the end of the text are dropped if TextSelection indices count UTF-8 (plausible)

## Refuted (do not chase these)

- s06-quality-11: Exact-title-inside-the-head on the full golden set is only tested with a reranker that agrees with titles. Skeptic: The facts are right: 'position < 16' at RankingTests.swift:334 is vacuous, and the golden-set reranked stage uses FakeReranker, which scores an exact title at the maximum. The claimed gap does not exist, though. Spec 7.4 (p13) defines the head as the reranked top 16: 'Only the reranked head is reordered; hits below position 16 keep their fused order'. SearchPipeline.reranked (SearchPipeline.swift:…

STATUS: complete
