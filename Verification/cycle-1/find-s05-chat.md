# Cycle 1 / slice s05-chat: section 14 (local language model and chat), spec pages 36-42

Auditor: cycle-1 s05-chat. Commit audited: cee4620. Method: requirement-centric trace (spec -> code -> test),
then defect hunt; every finding below survived an attempt to knock it down. Comments, doc strings,
READMEs and test names are not counted as evidence. Suite results taken from
Verification/_runs/c1-debug-swift-test.log (complete): all 33 ChatTests and the 6 chat tests in
AttachmentModifierTests pass. Scratch programs (copies of product logic, run with swiftc) live in
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s05-chat/
(calib/, parser/, sim/). Nothing in the repository was modified apart from this file.

Paths: core = Sources/ZTronSearchEngine, UI = Sources/ZTronSearchEngineUI, MLX = Adapters/ZTronSearchEngineMLX,
AK = Adapters/ZTronSearchEngineAssetKit, CT = Tests/ZTronSearchEngineTests/ChatTests.swift,
UT = Tests/ZTronSearchEngineUITests/AttachmentModifierTests.swift, MT = MLX/Tests/ZTronSearchEngineMLXTests.

Totals: 47 requirements; met 33, partial 9, missing 0, contradicted 2, unverifiable-here 3.

## Requirement table

| R# | sec/page | requirement | status | code | test |
|---|---|---|---|---|---|
| R1 | 14 / p36 | Chat only through two host-injected boundaries (asset provider, runtime) via the facade | met | core/Contracts/ChatBoundary.swift:66-71, 183-189; core/Chat/ChatService.swift:666-689 | CT:90 |
| R2 | 14 / p36 | Core never links ZTronAssetKit or MLX | met | core Package.swift has no such dependency; grep of Sources/ finds no `import ZTronAssetKit`/`import MLX*`/`Tokenizers`/`Hub` | none (structural, grep) |
| R3 | 14 / p36 | MLX runtime is a separate package, iOS 17 / macOS 14 floor | met | MLX/Package.swift (platforms iOS 17, macOS 14) | none (structural) |
| R4 | 14.1 / p36 | `ZTronSearch<Schema>` final class, Sendable, init(search:assets:languageModel:chat:) with defaults; `chat` nil when either boundary absent | met | core/Chat/ChatService.swift:666-689 | CT:90-100 |
| R5 | 14.1 / p36-37 | `ModelAsset` Hashable/Sendable/Codable: id, revision (pinned, never "main"), files (name, bytes, SHA-256), totalBytes | met (note: "never main" enforced only by MLX ModelAssetManifest.validate, not by core's ModelAsset) | core/Contracts/ChatBoundary.swift:8-41; MLX/Sources/ZTronSearchEngineMLX/ModelAssetManifest.swift (validate) | MT/Qwen3AssetTests.swift:53 |
| R6 | 14.1 / p37 | `ModelAssetAvailability` available/downloading/missing/failed; `ModelAssetError` offline/checksum/diskFull/policy | met | core/Contracts/ChatBoundary.swift:43-56 | CT:161, CT:202 |
| R7 | 14.1 / p37 | `ModelAssetProviding` availability / fetch (resumable, ends .available) / evict | met (resumability: see R13) | core/Contracts/ChatBoundary.swift:66-71; AK/Sources/ZTronSearchEngineAssetKit/AssetKitModelAssetProvider.swift:120-163, 190-215, 229-252 | CT:161 (fake); AK tests exist, not run here, not in CI |
| R8 | 14.1 / p37 | `LanguageModelDescriptor` asset, contextWindow, minimumPhysicalMemory, minimumOS | met | core/Contracts/ChatBoundary.swift:75-106 | MT/MLXLanguageModelTests.swift:77 |
| R9 | 14.1 / p37 | `GenerationRequest`; `GenerationEvent` delta/usage/finished | met | core/Contracts/ChatBoundary.swift:154-177 | CT:370 |
| R10 | 14.1 / p37 | `LocalLanguageModel` descriptor/load/unload/countTokens/generate | met | core/Contracts/ChatBoundary.swift:183-189; MLX/.../MLXLanguageModel.swift:167-188, 263-266, 293-299, 327-339 | MT/MLXLanguageModelTests.swift:130-354 (paths without weights only) |
| R11 | 14.1 / p38 | Core knows neither AssetKit nor MLX; ZTronAssetKit imported only in the adapter | met | grep: only files under AK import ZTronAssetKit | none (structural, grep) |
| R12 | 14.1 / p38 | Revision pinned; same id at another revision is another asset, fetched and verified again | met | core/Contracts/ChatBoundary.swift:8-41 (equality over id, revision, files) | MT/Qwen3AssetTests.swift:53 (pin only); no test for the "another asset" half |
| R13 | 14.1 / p38 | fetch resumable, SHA-256 per file, mismatched file deleted before failing .checksum | partial (resume is per file; the in-transit file restarts, C1-s05-chat-03) | AK/.../AssetKitModelAssetProvider.swift:181-215; AK/.../FetchOperation.swift; ZTronAssetKit AssetStore+Publish.swift:437-444 (rejectIntegrity -> discardClaimed) | CT:202, CT:223 against FakeModelAssetProvider, which resumes at byte level by construction (Sources/ZTronSearchFixtures/FakeChatBoundaries.swift:263-279) |
| R14 | 14.1 / p38 | prepare(): .available loads, .missing fetches under policy, .downloading attaches to the running fetch | met (attach races on re-prepare: C1-s05-chat-02) | core/Chat/ChatService.swift:129-155, 180-249 | CT:146, CT:161, CT:266 |
| R15 | 14.1 / p38 | generate streams, honours cancellation within one decoded token, never blocks the cooperative pool | partial (prefill cancels only per 512-token chunk; real-model tests skip in CI, C1-s05-chat-08) | MLX/.../MLXLanguageModel.swift:327-339, 424; MLX/.../GenerationLoop.swift (checks before each token); dedicated-thread executor | MT/GenerationLoopTests.swift:115, 123; MT/ExecutorAndCancellationTests.swift:48; MT/Qwen3IntegrationTests.swift skip without ZTRON_QWEN3_DIR |
| R16 | 14.2 / p38 | ZTronSearchEngineMLX: separate SwiftPM package, iOS 17 / macOS 14, Swift 6, deps core + mlx-swift (MLX, MLXNN, MLXFast) + mlx-swift-lm | partial (adds swift-transformers 1.4.0 Tokenizers + Hub, not in the spec's list; build against pins not verifiable here) | MLX/Package.swift | none |
| R17 | 14.2 / p38 | Reference model mlx-community/Qwen3-1.7B-4bit, mlx-lm 0.24.0, 4-bit, 968 MB, Apache-2.0, safetensors + tokenizer + chat template | unverifiable-here (revision 3b1b1768..., model.safetensors 968,080,210 B, total 979,513,507 B match the text; hashes, licence, converter version need the network. Note: the shipped verifiedManifest has no SHA-256 for config.json and tokenizer_config.json, so `verifiedManifest.asset()` throws `.missingChecksums` until the host runs Scripts/pin-qwen3-asset.swift against a downloaded copy) | MLX/.../Qwen3Asset.swift | MT/Qwen3AssetTests.swift:44-116 (internal consistency only; :71 asserts the two missing hashes) |
| R18 | 14.2 / p38 | Asset's chat template applied by the runtime, never hand-written in core; thinking off by default; `<think>` stripped before .delta | met | MLX/.../MLXLanguageModel.swift:396-414; MLX/.../ThinkBlockFilter.swift; core/Contracts/ChatBoundary.swift:129-152 (thinking false) | MT/GenerationLoopTests.swift:146-171; MT/ThinkBlockFilterTests.swift; MT/Qwen3IntegrationTests.swift:270 (skips in CI) |
| R19 | 14.2 / p38 | 4,096-token window by default; system prompt, sources, history and a 512-token reply fit inside it | partial (template overhead not budgeted, C1-s05-chat-05) | core/Contracts/ChatBoundary.swift:320-367; core/Chat/CitationParser.swift:132-162; MLX/.../MLXLanguageModel.swift:396-414 | CT:463 (fake counts content words, renders no template: vacuous for overhead) |
| R20 | 14.2 / p38 | Sampling temp 0.7, top-p 0.8, max 512 new tokens; asset's generation_config.json wins; fixed seed in tests | met | MLX/.../SamplingPlan.swift; core/Contracts/ChatBoundary.swift:129-152 | MT/SamplingPlanTests.swift:11, 21, 29, 107 |
| R21 | 14.2 / p39 | No API or code copied from mlx-swift-examples | unverifiable-here | - | - |
| R22 | 14.3 / p39 | `ChatService` actor: prepare(policy: = .wifiOnly), newSession(system:grounding: = .corpus(topK: 6, kinds: nil)), send, cancel, unload | met | core/Chat/ChatService.swift:23-24, 129, 354, 377, 403, 409 | CT:370, CT:412 |
| R23 | 14.3 / p39 | `ChatReadiness` checking/downloading/loading/ready/unavailable(reason) | met | core/Contracts/ChatBoundary.swift:232-238 | CT:161, CT:239 |
| R24 | 14.3 / p39 | `ChatEvent` sources/delta/citation/finished; sources before generation | met | core/Contracts/ChatBoundary.swift:252-259; core/Chat/ChatService.swift:429-529 | CT:370 |
| R25 | 14.3 / p39 | Retrieval through SearchService, waits for the final snapshot, top K restricted to the session's kinds | met (uses `retrieve`, a detached-lane equivalent of results(for:) returning the final snapshot) | core/Service/SearchService.swift:320-327; core/Chat/ChatService.swift:429-529 | CT:412 |
| R26 | 14.3 / p39 | Each source rendered `[kind:id] title, caption` from the localized surface, at most 80 tokens | partial (whitespace truncation drops unspaced captions, C1-s05-chat-06) | core/Chat/ChatService.swift:564-579; core/Chat/CitationParser.swift:165-180 | CT:434, CT:445 (Latin only) |
| R27 | 14.3 / p39 | Prompt inside contextWindow - maxNewTokens - 64: system, grounding instructions, sources, history, message | partial (content-only count, C1-s05-chat-05) | core/Chat/CitationParser.swift:132-162; core/Chat/ChatService.swift:461-473 | CT:463, CT:511 |
| R28 | 14.3 / p39 | Message and sources never trimmed; history trimmed oldest-first | met | core/Chat/CitationParser.swift:132-162 | CT:463, CT:496, CT:511 |
| R29 | 14.3 / p40 | Incremental `[kind:id]` parsing; .citation only for ids among the turn's sources; unknown ids dropped and logged | partial (ids containing ':' never parsed, C1-s05-chat-07) | core/Chat/CitationParser.swift:36-85 (76-81); core/Chat/ChatService.swift:493 | CT:561, CT:576, CT:590 |
| R30 | 14.3 / p40 | One generation at a time; a new send in the same session cancels the one in flight; other sessions queue | met | core/Chat/ChatService.swift:377-400 (384), 429-435; core/Support/FileIO.swift:58-80 | CT:608, CT:640 |
| R31 | 14.3 / p40 | Lazy load on first send; unload after 120 s idle, on memory warning, on unload(); history kept | met | core/Chat/ChatService.swift:532-561, 583-614, 409-420 | CT:712, CT:731, CT:759, CT:779 |
| R32 | 14.4 / p40 | Gate under .auto (default): OS >= minimumOS and RAM >= minimumPhysicalMemory (6 GB for Qwen3) | met (6 x 1024^3 against what 6 GB devices report not checked) | core/Chat/ChatService.swift:100-121, 265-279, 617-639; MLX/.../MLXLanguageModel.swift:63-76 | CT:102, CT:123; MT/MLXLanguageModelTests.swift:111 |
| R33 | 14.4 / p40 | Free disk >= 2 x totalBytes before a download starts | met | core/Chat/ChatService.swift:209 | CT:187 |
| R34 | 14.4 / p40 | One-time calibration after the first load (prefill 512, decode 64; TTFT <= 3 s, >= 8 tok/s), persisted, recomputed after an app or OS update | contradicted (aborted runs persist a failing verdict, C1-s05-chat-01; unmeasured pass, -09) | core/Chat/ChatService.swift:282-298, 303-350 | CT:297, CT:334 (prepare path, uninterrupted only; harness default availability .on) |
| R35 | 14.4 / p40 | iPhone 6s -> unavailable(.device); .on / .off override the gate | met | core/Contracts/ChatBoundary.swift:262-312; core/Chat/ChatService.swift:100-121, 265-279 | CT:102; UT:384 |
| R36 | 14.4 / p40 | fetch is a no-op when verified on disk; a retry re-verifies and resumes instead of starting over; unload keeps files and history | partial (retry restarts the in-transit file with the shipped adapter, C1-s05-chat-03) | core/Chat/ChatService.swift:100-121, 409-420; AK as in R13 | CT:146, CT:202, CT:223, CT:731 (fake) |
| R37 | 14.4 / p40 | DownloadPolicy .wifiOnly (default), .allowCellular, .never | partial (.wifiOnly fails .policy under AK's default NetworkPolicy unless the host configures its lanes; acknowledged in AK README) | core/Contracts/ChatBoundary.swift:58-63; core/Chat/ChatService.swift:129, 180-249 | CT:161, CT:179 |
| R38 | 14.4 / p40-41 | UI discloses the size before the first fetch; downloads continue in the background through ZTronAssetKit's own session; the engine only observes | contradicted (core cancels the download when unobserved; no background session with progress, C1-s05-chat-04; size disclosure is the host's job since no view ships) | core/Chat/ChatService.swift:157-163; AK/.../FetchCoordinator.swift (detach) | CT:239 asserts the cancellation |
| R39 | 14.4 / p40 | Figure "chat lifecycle" (7 states) | unverifiable-here (figure text lost; the PDF cannot be rendered here; code has idle, unavailable, fetching, onDisk, loading, ready, generating, failed) | core/Chat/ChatService.swift (lifecycle) | - |
| R40 | 14.5 / p41 | `ZTronChatModel` @MainActor ObservableObject: readiness, transcript (role, text, sources, citations), isGenerating; init(chat:), prepare, send, cancel | met | UI/ZTronChatModel.swift:53-133 | UT:362, UT:384, UT:406 |
| R41 | 14.5 / p41 | `.zTronChat(_:prepare:)` injects, prepares on appear under the policy (nil = never), cancels generation on disappear | met (re-appear during a download: C1-s05-chat-02) | UI/ZTronAttachmentModifiers.swift:62-72, 104-108 | UT:301, UT:314, UT:328 |
| R42 | 14.5 / p41 | No chat view ships | met | UI has no chat view type | none (structural) |
| R43 | 14.5 / p41 | Sources are `SearchHit<Schema.Kind>` | met | core/Contracts/ChatBoundary.swift:252-259; UI/ZTronChatModel.swift | UT:362 |
| R44 | 14.5 / p41 | Model and modifier are iOS 15 API; readiness .unavailable(.device) below iOS 17 or on a gate-failing device | met | UI/ZTronChatModel.swift:53-71; core/Chat/ChatService.swift:617-639 | UT:384 |
| R45 | 14.6 / p41 | Everything on device; the only network traffic is the model download through ZTronAssetKit | met (no URLSession/HubApi use in core or MLX sources; LocalTokenizer reads local files; mlx-swift-lm internals not checked) | grep of Sources/ and MLX/Sources; MLX/.../LocalTokenizer.swift | none |
| R46 | 14.6 / p41 | Prompts contain only localized surfaces and user messages; no analytics or popularity data | met | core/Chat/ChatService.swift:429-529, 564-579 | CT:434 |
| R47 | 14.6 / p41 | Grounding instructions make the model decline when sources do not answer; host may append policy text to the system prompt | met (prompt content only; decline rate not measurable here) | core/Chat/CitationParser.swift:109-112; core/Chat/ChatService.swift:354 | CT:402 |

## Findings

### C1-s05-chat-01 (high, bug): an interrupted calibration persists a failing verdict and disables chat on a capable device until the next app or OS update

Spec: 14.4 p40 (one-time calibration after the first load, verdict persisted, recomputed after an app or OS update; .auto gate).

Locations: core/Chat/ChatService.swift:303-350 (calibrationPasses), 335-341 (`guard let first else { setVerdict(false) }`), 346; ChatService.swift:282-298 (load: .auto + failed calibration -> unload, `.unavailable(.device)`, not retryable); ChatService.swift:265-279 (stored false -> `.device` at 276); ChatService.swift:532-561 (ensureLoaded runs load, hence calibration, inside the first send's turn task); ChatService.swift:409-420 (unload calls model.unload even while `.loading`); MLX/.../MLXLanguageModel.swift:263-266 (unload -> cancelAll -> `.finished(.cancelled)`).

What goes wrong: calibrationPasses ignores the stop reason of `.finished` and treats a thrown error, or a run that produced no delta, as a measured failure, writing `false` to the store. A run produces no delta when it is cancelled during the 512-token prefill: the stop button (ZTronChatModel.cancel -> ChatService.cancel), a second send in the same session, the `.zTronChat` view disappearing (it calls cancel), the consumer dropping the stream, or a memory warning / unload() during the first load (MLX ends the stream with `.finished(.cancelled)`). Under `.auto` the service then settles `.unavailable(.device)` and every later gate()/prepare() answers `.unavailable(.device)` from the stored verdict, keyed by build fingerprint, so only an app or OS update clears it. When the model was not preloaded, calibration runs inside the first send, so the first stop tap is enough. The MLX package's own ChatCalibration.passes() rejects cancelled runs (MT/ChatCalibrationTests.swift:169); core does not use it. No test interrupts calibration (CT:297, CT:334 run it uninterrupted on the prepare path; the harness default is `.on`).

Evidence (scratch, run): calib/main.swift copies calibrationPasses with a slow-prefill fake and printed:
- "case 1 (cancel during prefill): calibrationPasses = false; persisted verdict = Optional(false)"
- "case 2 (later, uncancelled run on the same fast device): calibrationPasses = false"
- "case 3 (fresh store, uncancelled): true"

sim/ (all 40 core files + FakeChatBoundaries + ZTronChatModel copied, MLX-like model whose unload cancels generations):
- S1: gate() before anything: ready; first send cancelled during calibration: turn ended `notReady(unavailable(device))`; persisted `[chat-calibration|app-1.0(1)|os-18.2|fake-llm-4bit@0123abcd: false]`; prepare() afterwards `[unavailable(device)]`; next launch, same build: `[checking, unavailable(device)]`.
- S1b (memory warning during prepare-path calibration): states `[checking, loading, unavailable(device)]`; persisted false; prepare() again `[unavailable(device)]`.

Failure scenario: an iPhone 15 Pro (passes the gate), availability .auto, model on disk but not loaded. The user sends a first message and taps Stop (or leaves the screen) during the first seconds. Chat reports "unavailable on this device" from then on, until the app is updated.

### C1-s05-chat-02 (high, concurrency): calling prepare() again during a download cancels and restarts the download, or leaves readiness stuck

Spec: 14.1 p38 (.downloading attaches to the running fetch); 14.4 p40-41 (engine only observes); 14.5 p41 (.zTronChat prepares on appear).

Locations: UI/ZTronChatModel.swift:80-92; core/Chat/ChatService.swift:146-148 (onTermination spawns a Task calling removeObserver), 157-163 (no observers while .fetching -> cancel the preparation), 180-187 (defer clears preparation, finishObservers()), 232-234 (CancellationError -> .idle); UI/ZTronAttachmentModifiers.swift:68 (onAppear -> prepare); AK/.../FetchCoordinator.swift (detach cancels the session when the last stream leaves).

What goes wrong: ZTronChatModel.prepare cancels its previous consumer task and starts a new one. Cancelling the old consumer terminates its stream; onTermination schedules removeObserver in an unstructured Task whose order relative to the new prepare() on the actor is not defined. (a) removeObserver first: no observers while `.fetching`, so the preparation is cancelled; the fetch stream ends, the adapter cancels the AssetKit transfer (which discards the partial, ZTronAssetKit TransferUpdate.swift:84), lifecycle goes `.idle`, and the new prepare() starts another fetch. (b) New prepare() attaches first but the old preparation still ends: its defer finishObservers() closes the new observer's stream, so the model's readiness freezes. Triggers: the `.zTronChat` view re-appearing during a download (tab switch, navigation pop), a retry button, a policy change.

Evidence (scratch, run): sim/ S2, ZTronChatModel.prepare twice during a fake download:
- main actor idle, 3 trials: trials 1 and 3 no cancel; trial 2 lifecycle idle, cancelledFetches 1, fetchCalls 1, model readiness stuck at "downloading(bytes: 300, of: 1000)".
- main actor busy 5 ms, 5 of 5 trials: readiness "checking", lifecycle fetching, fetchCalls 2, cancelledFetches 1, resumeOffsets [0, 300]: the download was cancelled and restarted. The fake resumes at 300; with the AssetKit adapter the in-transit 968 MB file restarts at 0 (C1-s05-chat-03).

Tests: CT:266 (testASecondPrepareAttachesToTheRunningFetch) never cancels a consumer; UT:301 never re-appears during a download.

Failure scenario: a chat tab with `.zTronChat(model, prepare: .wifiOnly)`; the user opens it (download starts), switches tabs and back: the transfer is cancelled and restarted, or the progress UI freezes at its last value.

### C1-s05-chat-03 (high, spec-deviation): with the shipped AssetKit adapter, retry and resume restart the in-transit model file from byte 0; core tests prove resume only against a fake

Spec: 14.1 p38 (fetch is resumable); 14.4 p40 (a retry re-verifies and resumes instead of starting over); 15.6. Section 18 lists the matter as open.

Locations: AK/README.md (limit 1); AK/.../AssetKitModelAssetProvider.swift:181-215; AK/.../FetchOperation.swift; /Users/admin/Documents/ZTronAssetKit TransferUpdate.swift:84 (cancel discards the partial), EngineJobs.swift (launchResumes only at launch, ~167; retire/abandon ~440-480), AssetStore+Publish.swift:437-444; Sources/ZTronSearchFixtures/FakeChatBoundaries.swift:263-279; CT:202-237.

What goes wrong: the asset is essentially one file (model.safetensors, 968,080,210 of 979,513,507 bytes). ZTronAssetKit resumes inside a file only within the same transfer job or across a relaunch; a cancelled or failed job discards its partial. So an in-process retry after `.offline`, after `.checksum`, after cancel or after all observers left starts the big file again at 0; only completed files are kept. CT:202 and CT:223 pass because FakeModelAssetProvider records and resumes byte offsets by construction, so they say nothing about the shipped adapter, whose tests are not in CI (adapter-tests.yml covers SQLite only; the AssetKit path dependency is outside the repository).

Evidence: code reading of AK and ZTronAssetKit as listed; the AK README states the same limit. Not run (AK tests may not be run here).

Failure scenario: 900 MB into the download Wi-Fi drops, fetch fails `.offline`, the user taps Retry: model.safetensors is fetched from byte 0 again.

### C1-s05-chat-04 (medium, spec-deviation): downloads do not continue through ZTronAssetKit's background session with the engine only observing; core cancels an unobserved download

Spec: 14.4 p40-41.

Locations: core/Chat/ChatService.swift:157-163; AK/.../FetchCoordinator.swift (detach); AK/README.md (limit 2); CT:239.

What goes wrong: when the last observer of prepare() leaves while `.fetching`, core cancels the preparation and the adapter cancels the AssetKit session, so the engine owns the download rather than observing it. The adapter uses AssetKit's background URLSession only on its bulk lane, which reports no progress (README: background continuation or progress, not both). CT:239 asserts the cancellation as intended. Mitigated by the spec's own open question in section 18.

Evidence: code reading; sim/ S2 shows cancelledFetches 1 once the only observer is cancelled.

Failure scenario: the user starts the download and leaves the chat screen (the model's prepare task is cancelled) or the app is suspended: the download stops and, with C1-s05-chat-03, loses the partial file.

### C1-s05-chat-05 (medium, bug): the prompt budget counts content tokens only; chat-template overhead shrinks the reply below 512 tokens and long chats of short messages fail with promptTooLong for good

Spec: 14.2 p38 (system prompt, sources, history and a 512-token reply fit inside 4,096); 14.3 p39 (prompt inside contextWindow - maxNewTokens - 64).

Locations: core/Chat/CitationParser.swift:132-162 (assemble sums countTokens(content)); core/Chat/ChatService.swift:461-473; MLX/.../MLXLanguageModel.swift:396-414 (template applied, promptTooLong when the rendered prompt reaches the window, budget min(maxNewTokens, window - prompt)); MLX/.../SamplingPlan.swift (tokenBudget); CT:463.

What goes wrong: the 3,520-token budget (4096 - 512 - 64) is checked against message contents only. The runtime renders every message through the chat template (role markers and separators, plus the generation prompt; for Qwen3's ChatML I estimate about 5 tokens per message plus 7, not measured on the real tokenizer). The 64-token margin absorbs about 11 messages. Past that, MLX silently shortens the reply budget, and once the rendered prompt reaches 4,096 it throws promptTooLong -> generationFailed. History is trimmed against the same content-only count, so every later send in that session fails too. CT:463 uses FakeLanguageModel, which counts content words and renders no template, so it cannot see the overhead.

Evidence (scratch, run): sim/ S3 with an MLX-like model (5 tokens per message + 7; promptTooLong and tokenBudget as in MLX):
- short messages (6-word user, 12-word replies): turn 129 rendered 3612 tokens, reply budget 484; turn 147 `generationFailed("promptTooLong(promptTokens: 4112, contextWindow: 4096)")`; with 292 history messages the next send also fails (4108).
- typical messages (15-word user, 150-word replies): from turn 22 rendered 3712, reply budget 384, unchanged through turn 200, no failure.

Failure scenario: in an ordinary long chat replies are capped near 384 tokens instead of 512; a long session of short exchanges becomes permanently unusable (every send fails).

### C1-s05-chat-06 (medium, bug): source truncation splits on whitespace, so captions in unspaced scripts (Japanese, Chinese, Thai) are dropped whole

Spec: 14.3 p39 (each source `[kind:id] title, caption` from the localized surface, at most 80 tokens).

Locations: core/Chat/CitationParser.swift:165-180 (truncate binary-searches over whitespace-split words); core/Chat/ChatService.swift:564-579; CT:445.

What goes wrong: an unspaced caption is a single "word"; when marker + title + caption exceed 80 tokens the whole caption is cut, leaving only the marker and title, or "" when the first word alone is over the limit. The model is grounded on titles only. The only test is Latin.

Evidence (scratch, run): parser/ holds a verbatim CitationParser.swift with shims and a stand-in tokenizer (one token per CJK character, one per Latin word). It printed: D: "Japanese source of 101 tokens truncated to 80: result = "[tip:tip-tokyo] 東京の地下鉄の乗り方," (11 tokens)"; E (Latin control): 80 tokens kept.

Failure scenario: a Japanese-localized app with a 150-character caption: the prompt carries "[tip:tip-tokyo] <title>," and the model declines or answers without the content.

### C1-s05-chat-07 (medium, bug): citations whose id contains ':' are never emitted; the raw marker leaks into the reply and nothing is logged

Spec: 14.3 p40 (incremental `[kind:id]` parsing; .citation for ids among the sources; unknown ids dropped and logged).

Locations: core/Chat/CitationParser.swift:76-81; core/Database/SearchRowProjector.swift:74-76.

What goes wrong: on a second ':' inside a pending marker, consume() asks whether the text between '[' and that ':' is a kind; for "[map:region:1]" it tests "map:region", which is not a kind, so the pending text is flushed as plain text. The marker reaches the transcript verbatim, with no .citation and no unknownCitation report. Such ids are legal: SearchRowProjector's `.verbatim` and `.prefixed(prefix)` id strategies can produce them (the default `tablePrefixed` uses '#').

Evidence (scratch, run): parser/ printed A: `[text("See [map:region:1] here.")]`; B: `[text("Use [tip:tip:42].")]`; C (control, id without ':'): a citation for region-1.

Failure scenario: a database source with `.prefixed("tip:")` ids; the model cites `[tip:tip:42]` correctly; the user sees the raw bracket text and no citation.

### C1-s05-chat-08 (low, test-integrity): MLX real-model tests never run in CI, and prefill cancellation is per 512-token chunk

Spec: 14.1 p38 (cancellation within one decoded token); section 16 (MLX suites).

Locations: .github/workflows/ci.yml:76-89; MT/Qwen3IntegrationTests.swift:25-45; MLX/.../MLXLanguageModel.swift:424.

What goes wrong: the mlx-runtime job runs `swift test --build-system native` with no ZTRON_QWEN3_DIR and no Metal library, so Qwen3IntegrationTests skip; template application, think stripping, TTFT and cancellation latency with real weights have no CI evidence. GenerationLoopTests prove per-token cancellation on a scripted source only. During prefill, cancellation is seen only between chunks (prefill.stepSize nil -> 512 tokens).

Evidence: ci.yml lines 85-89 and the skip guards at Qwen3IntegrationTests.swift:25-45.

Failure scenario: a regression in template use or think-block stripping with real weights ships green.

### C1-s05-chat-09 (low, bug): core calibration can pass without measuring a decode rate

Spec: 14.4 p40 (decode 64 tokens, >= 8 tok/s).

Locations: core/Chat/ChatService.swift:303-350, 346.

What goes wrong: rate = infinity when generated <= 1 or decodeSeconds is 0, so a run that ends after one token, or delivers its text in a single delta, passes the decode gate unmeasured. Core samples with configuration.options (0.7 / 0.8 unless set) and a repeated sentence, not the greedy long-answer request of MLX ChatCalibration (whose passes() rejects fewer than 2 tokens, MT/ChatCalibrationTests.swift:159), so an early end of turn is plausible. The decode window also ends at the last delta, not at `.finished`.

Evidence: code reading.

Failure scenario: a device too slow for 8 tok/s whose calibration reply ends after one token is enabled with rate = infinity.

### C1-s05-chat-10 (low, bug): ZTronChatModel.prepare can lose its reference to the running preparation task

Locations: UI/ZTronChatModel.swift:80-92 (line 90).

What goes wrong: the cancelled old task, on leaving its loop, sets `self?.preparation = nil` on the main actor; if that runs after the new task was stored, it clears the new task's reference, and a later prepare() or deinit cannot cancel the running observer (which keeps the download observed and keeps updating readiness).

Evidence: code reading; not isolated in a scratch run.

Failure scenario: prepare(.wifiOnly) then prepare(.allowCellular) in quick succession; the model is released, but the second observer keeps running.

### C1-s05-chat-11 (low, bug): Int64 overflow trap reachable through public API with huge byte counts

Locations: core/Contracts/ChatBoundary.swift:38-40 (totalBytes sums with +); core/Chat/ChatService.swift:209 (2 * asset.totalBytes); MLX/.../ModelAssetManifest.swift (validate checks byteCount >= 0 only).

What goes wrong: a descriptor or manifest with byte counts near Int64.max (corrupt or hostile manifest file loaded with ModelAssetManifest(contentsOf:)) traps the process in totalBytes or in prepare()'s disk check.

Evidence: not run; Swift's + and * trap on overflow by definition.

Failure scenario: a manifest with byteCount 5_000_000_000_000_000_000 crashes the app on prepare().

### C1-s05-chat-12 (low, concurrency): ensureLoaded waits on an in-flight preparation while holding the generation lock and ignores cancellation

Locations: core/Chat/ChatService.swift:435, 533-539.

What goes wrong: a send while the model is downloading waits inside the turn for the whole preparation (possibly the 968 MB download) while holding the AsyncLock; cancelling that turn does not end the wait, and every other session's send queues behind it.

Evidence: code reading.

Failure scenario: download running, the user sends, then taps Stop and opens another session: that session's send hangs until the download finishes.

## Not checked

- The page 40 lifecycle figure: the PDF cannot be rendered here (pdftoppm missing); only the text layer was read.
- Device behaviour: how 6 GB iPhones report physical memory against the 6 x 1024^3 threshold; TTFT, decode rate, the 150 ms cancellation bound and resident memory with real weights; golden-set citation and decline rates.
- Whether the MLX package builds against the pinned mlx-swift 0.32.3, mlx-swift-lm 3.32.3 and swift-transformers 1.4.0 (no checkouts, no network), and whether mlx-swift-lm or swift-transformers Hub reach the network at run time.
- Qwen3 revision, file hashes, mlx-lm 0.24.0, Apache-2.0 licence, and the absence of generation_config.json (needs the network). The shipped verifiedManifest leaves out SHA-256 for config.json and tokenizer_config.json, so a usable ModelAsset needs a host-side pinning step (Scripts/pin-qwen3-asset.swift); not treated as a finding because the spec does not require the package to ship the descriptor.
- Whether any code was copied from mlx-swift-examples.
- AssetKit adapter tests: not run here and not in CI; ZTronAssetKit itself was spot-checked only (resume, discard, background lane).
- UI size disclosure before the first fetch: host responsibility, since no chat view ships.
- Spec-level observation, not scored: SwiftPM will not let an iOS 15 app target depend on an iOS 17 product, so "iOS 15 hosts get chat on iOS 17 devices" needs a host-side workaround.
- Thread Sanitizer and iOS simulator runs of the chat tests (not allowed here; orchestrator logs used for the macOS debug run only).

STATUS: complete
