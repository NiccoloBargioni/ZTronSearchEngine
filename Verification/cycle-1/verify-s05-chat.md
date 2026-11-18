# Cycle 1 / slice s05-chat: skeptic verification of the auditor's findings (section 14, spec pages 36-42)

Skeptic: cycle-1 s05-chat-skeptic. Commit: cee4620. Scratch programs:
/private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-1/s05-chat-skeptic/
Nothing in the repository was modified apart from this file.

Progress: all 12 findings settled.

## Verdicts

### C1-s05-chat-01: confirmed, high
An interrupted calibration persists a failing verdict. Reproduced independently with the repository's own
FakeLanguageModel (not a custom runtime) over fresh copies of the core sources (sim/Driver.swift, run1.txt).
availability .auto, files on disk, gate() = ready, first send calibrates on the turn path:
- A: ChatService.cancel 0.15 s into a 0.6 s prefill: store `[...fake-llm-4bit@0123abcd: false]`; prepare() in the
  same process `[unavailable(device)]`; a relaunch of the same build `[checking, unavailable(device)]`.
- B: ZTronChatModel.cancel() (stop button / .zTronChat onDisappear): same persisted false. The UI still shows
  `ready` because its consumer was cancelled; the next send fails notReady(unavailable(device)).
- C: a second send in the same session: same persisted false; the second send also fails.
Mechanism (ChatService.swift:322-341): when the consuming task is cancelled, AsyncThrowingStream's next() returns
nil, the loop ends without a delta, `guard let first` writes false. Nothing checks Task.isCancelled or the stop
reason. MLX unload() (MLXLanguageModel.swift:263-266) calls generations.cancelAll(); a cancelled prefill returns
Completion(.cancelled) and the stream yields .usage + .finished(.cancelled) and finishes normally, so a memory
warning or unload() during prepare-path calibration takes the same `first == nil` branch (code reading).
MLX ChatCalibration.passes() rejects cancelled runs and < 2 tokens (ChatCalibration.swift:60-62); core cannot use it.
No test interrupts calibration (ChatTests:297, :334).
Detail that is wrong in the description: a thrown error is NOT persisted. Run D (runtime throws before the first
token): store stays empty; the process is stuck at unavailable(device) (non-retryable, ChatBoundary.swift:224-229)
but a relaunch calibrates again and gets ready. Severity stays high: one stop tap during the first send disables
chat on a capable device until an app or OS update, and lazy load on first send is a spec-described path (14.3 item 5).
Side observation: run E (stop after a few decoded tokens) persisted `true` from 2-4 tokens; the stop reason is
ignored in both directions.

### C1-s05-chat-02: confirmed, high
Reproduced with the repository's FakeModelAssetProvider and a fresh copy of ZTronChatModel (24 trials):
ZTronChatModel.prepare twice while the fetch runs (the second call = .zTronChat re-appearing).
- main actor idle after the call: 3/6 attached (fine), 3/6 CANCELLED+STUCK (lifecycle idle, fetchCalls 1,
  cancelledFetches 1, UI readiness frozen at downloading(300 of 1000)).
- main actor busy 1, 5 or 16 ms after the call (what the rest of a SwiftUI update does): 18/18 CANCELLED+RESTARTED
  (cancelledFetches 1, fetchCalls 2, resumeOffsets [0, 300]).
Mechanism: T1.cancel() runs the stream's onTermination synchronously, which spawns `Task { removeObserver }` on the
global executor before T2 even starts on the main actor (ChatService.swift:146-148, 157-163), so the observer set
is empty while .fetching and the preparation is cancelled. With the AssetKit adapter, FetchCoordinator.detach
cancels the session when no stream is left and ZTronAssetKit discards the in-transit partial
(AssetKitModelAssetProvider.swift:181-186 doc comment; ZTronAssetKit EngineJobs.swift:442-480, TransferUpdate.swift
`cancel`: "Stops and discards the partial").
Small wording fix: the stuck case needs removeObserver first (cancel), then the new observer attaching before the
cancelled preparation runs its defer; if the new observer attached before removeObserver, nothing is cancelled.
Spec 16 explicitly expects the modifier's view to be recreated, and 14.1 says .downloading attaches.

### C1-s05-chat-06: confirmed, medium
Own run (parser/, verbatim CitationParser.swift + PromptAssembler, stand-in tokenizer one token per CJK scalar):
Japanese source of 100 tokens -> kept 12 tokens, "[tip:tip-tokyo] 東京の地下鉄の乗り方,"; Latin control 108 -> 80.
truncate() (CitationParser.swift:165-180) binary-searches over whitespace-split words, so an unspaced caption is one
word and is dropped whole. Minor overstatement: the "empty string" case needs the `[kind:id]` marker alone to
exceed 80 tokens, which practically never happens. render() runs after ensureLoaded, so counts are the real
tokenizer's. Only Latin text is tested (ChatTests:445).

### C1-s05-chat-07: confirmed, medium
Own run: "See [map:region:1] here." -> one .text with the raw marker; "[tip:" + "tip:42]." -> raw text;
an unknown id with ':' is also neither dropped nor reported; control "[map:region-1]" -> .citation.
Cause: CitationParser.swift:76-81 tests the text before the LATEST ':' against isKind and flushes; marker()
(:95-101) would have split at the first ':' correctly. SearchableID is free-form (Searchable.swift:9-14);
spec.txt line 905 (section 9.2): "<table>#<id> unless the host maps it"; DatabaseBoundary.swift:166-172 offers .verbatim and
.prefixed(String). Memory items' ids are host-chosen too ("tip:42" style ids are common). Medium is fair: for such
a host every citation fails and the raw marker shows.

### C1-s05-chat-10: partly, low
Own run: Mirror shows ZTronChatModel.preparation == nil after the second prepare() in 24/24 trials, including the
6 where the second consumer is still attached and observing (lifecycle fetching). So the loss is not occasional:
whenever the cancelled old task's stream ends with nil, its trailing `self?.preparation = nil` (ZTronChatModel.swift:90)
runs after T2 was stored. Corrected consequence: the orphaned consumer is weak-self; once the model is released it
returns at the next readiness event, which drops its stream (removeObserver). While the model lives it publishes the
same service states as any new consumer. So the effect is bounded: deinit does not stop the observation until the next
state arrives (indefinitely only for a stalled download), and a later prepare() leaves two consumers. Low.

### C1-s05-chat-03: partly, medium
Real for the shipped adapter: AssetKitModelAssetProvider.swift:181-186 (its own doc comment) and the adapter README
limit 1 say that when no fetch stream is left every request is withdrawn and ZTronAssetKit discards the part of the
file in transit. Checked in ZTronAssetKit (commit 1baccd6): EngineJobs.swift retire -> abandon -> handle.cancel()
("Stops and discards the partial", TransferUpdate.swift TransferControl.cancel / TransferHandle.cancel), removeJob drops
kept staged files, and a new job gets resume data only from launchResumes (EngineJobs.swift:167), which is filled at
launch (EngineLifecycle.swift:427). ChatTests:202/:223 prove re-calling fetch against FakeModelAssetProvider, which
resumes by construction (FakeChatBoundaries.swift:263-279); no AssetKit adapter test runs in CI (adapter-tests.yml has
only the SQLite job). Corrections: (1) `.checksum` does not belong in the list: spec 14.1 requires the mismatched file
to be deleted, so that file restarts at 0 by design; (2) within one job (lost connection or timeout retried by the
engine) and across a relaunch, resume inside the file works; per-file resume works, so 15.6's "never re-downloads a
verified file" holds. (3) The limit is disclosed in the adapter README, and section 17's open question (printed on
p52) asks exactly who owns resume. Severity: medium rather than high; the frequent triggers (re-appear, leaving the
screen) are already counted under -02 and -04.

### C1-s05-chat-04: partly, medium
Real: ChatService.swift:157-163 cancels the preparation when the last observer leaves while .fetching, and
ChatTests:239 asserts it; the adapter cancels the session (FetchCoordinator.swift:76-83) and ZTronAssetKit's
progress-reporting lanes use the foreground session (README limit 3). That contradicts 14.4 "downloads continue in
the background ... and the engine only observes progress". Corrections: the spec is not one-sided: section 16 lists
"cancel during download" among the lifecycle transitions to test, there is no other cancel API, and section 17 leaves
background downloads open. "The app is suspended" is not a core cancellation (suspension cancels no task); it is the
foreground-session limit of the adapter. The screen case needs the model to be released (deinit cancels its consumer),
which is what a screen-owned @StateObject does. Medium stands.

### C1-s05-chat-05: confirmed, medium
Own run (budget/, verbatim PromptAssembler, tokens = words, Qwen3 ChatML overhead 5 per message + 7 for
`<|im_start|>assistant\n<think>\n\n</think>\n\n`): grounded sessions (6 sources of 80 tokens) with 10-token questions:
40-token replies -> reply cap from turn 52, promptTooLong at turn 61 (122 messages); 60-token replies -> cap falls to
196; 100-token -> 316; 150-token -> 401, never failing. Code: PromptAssembler.assemble sums countTokens(content) only
(CitationParser.swift:144-155); MLX renders the template, throws promptTooLong when rendered >= 4,096
(MLXLanguageModel.swift:396-408) and caps the reply at min(512, window - rendered) (SamplingPlan.swift:173-175);
MLX defaultContextWindow is 4,096, so the runtime does enforce the same window. ChatService maps the error to
generationFailed (ChatService.swift:520-521) and does not record the turn, so the trimmed history stays the same and
every later send fails; ZTronChatModel keeps one session for its life, so the host must recreate the model.
Section 16 asks "no prompt ever exceeds the context window". The 5-per-message figure is an estimate from the
template format, not measured on the tokenizer.

### C1-s05-chat-08: partly, low
Facts hold: ci.yml mlx-runtime job runs `swift test --build-system native` with no ZTRON_QWEN3_DIR; Qwen3IntegrationTests
skip without it and without default.metallib (Qwen3IntegrationTests.swift:25-45). Prefill: prefillStepSize nil keeps
mlx-swift-lm's default; at the pinned 3.32.3 LLMModel.swift documents "default 512" and PrefillParameters.swift:137
checks cancellation per chunk (read from the local SwiftPM cache). Correction: not a test-integrity defect against
the spec: section 16 puts these integration tests on "an Apple-silicon Mac" through xcodebuild, and milestone 8's CI
gate is "fake-runtime tests green in CI". 14.1's "within one decoded token" is about decoding; only 15.6's 150 ms
cancellation target could be exceeded during a long prefill. Low.

### C1-s05-chat-09: confirmed, low
ChatService.swift:343-346: `rate = generated > 1 && decodeSeconds > 0 ? ... : .infinity`, so a 1-token run or a run whose
text arrives in one delta passes the decode gate unmeasured. Core's request is sampled (configuration.options) over a
repeated sentence, not MLX ChatCalibration's greedy request whose passes() needs >= 2 tokens and a non-cancelled stop
(ChatCalibration.swift:60-62, ChatCalibrationTests.swift:159, :169). Related, from run E: a run cancelled after a few
tokens is scored and persisted (true) from 2-4 tokens instead of 64. Unlikely with the MLX runtime (one delta per
token); low.

### C1-s05-chat-11: partly, low
True that ModelAsset.totalBytes (ChatBoundary.swift:38-40) and `2 * asset.totalBytes` (ChatService.swift:209, evaluated
only for `.missing` with a known free-disk figure) trap on Int64 overflow, and ModelAssetManifest.validate only rejects
negative counts. Correction: the values come only from the host's own descriptor (ModelAsset's public init) or a
manifest the host ships (the pin script's output; Qwen3Asset builds it from static values). Nothing in these packages
reads a manifest from the network or the user. It needs byte counts over 4.6e18, so it is a fail-fast on a
programmer error, not a reachable crash from outside. Low at most.

### C1-s05-chat-12: partly, low
True that runTurn takes the AsyncLock (ChatService.swift:435) before ensureLoaded waits on preparationWaiters with
withCheckedContinuation (:534-538), which a cancel does not wake. The described failure is not caused by it: while
a preparation runs the model is never ready (prepare() starts one only when lifecycle is not .ready/.generating), so
any send in any session must wait for that preparation through ensureLoaded anyway. The lock adds no delay beyond
that. What remains: a turn cancelled through cancel(session) keeps its stream open, with no events, until the
preparation ends. ZTronChatModel.cancel() cancels its own consumer task, so its UI is not held. Low.

## Summary

| id | verdict | severity |
|---|---|---|
| C1-s05-chat-01 | confirmed | high |
| C1-s05-chat-02 | confirmed | high |
| C1-s05-chat-03 | partly | medium |
| C1-s05-chat-04 | partly | medium |
| C1-s05-chat-05 | confirmed | medium |
| C1-s05-chat-06 | confirmed | medium |
| C1-s05-chat-07 | confirmed | medium |
| C1-s05-chat-08 | partly | low |
| C1-s05-chat-09 | confirmed | low |
| C1-s05-chat-10 | partly | low |
| C1-s05-chat-11 | partly | low |
| C1-s05-chat-12 | partly | low |

Scratch: sim/ (Driver.swift, run1.txt; fresh copies of 40 core files, FakeChatBoundaries, CatalogSchema,
ZTronChatModel, `import ZTronSearchEngine` removed), parser/ (citations, truncation), budget/ (prompt budget).

STATUS: complete
