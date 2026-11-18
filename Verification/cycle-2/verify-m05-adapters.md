# C2 m05 adapters - skeptic verification

Skeptic: cycle 2, module m05 (ZTronSearchEngineSQLite, ZTronSearchEngineMLX, ZTronSearchEngineAssetKit).
Inputs: the 17 findings of find-m05-adapters.md, spec.txt, the repository at cee4620 (read only), ZTronAssetKit (read only).
Nothing in the repository was built, tested or modified; this file is the only write under the repository.
Repro programs of the first run live in /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m05-adapters-skeptic/;
programs of the resumed run (2026-11-18) live in /private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m05-adapters-skeptic/.
Resumed run: the verdicts for 01, 03, 07, 09, 10, 15, 16 below are from the first run and were kept as written; the rest are added as settled.
Per the task, no file under Verification/ other than find-m05-adapters.md and _inputs/spec.txt was read, so the
run logs the auditor cites (Verification/_runs/*.log) were NOT read: any claim resting only on them is marked unverified.

## Verdicts (filled in as they are settled)

### C2-m05-adapters-01 - PARTLY - severity low (auditor: high)
- Confirmed by reading: DatabaseTargetsTests.swift:68-71 throws XCTSkip under `#if DEBUG`; adapter-tests.yml:57-63 runs
  only `swift test` and `swift test --sanitize=thread` (no `-c release`). Repro (debugflag/, a 1-test SwiftPM package):
  `swift test` and `swift test --sanitize=thread` both take the `#if DEBUG` branch ("Executed 1 test, with 1 test
  skipped"); only `swift test -c release -Xswiftc -enable-testing` runs the body. So the real-SQLite 15.9 test skips in
  every CI run. It is the only test that measures 15.9 through the adapter (grep).
- Overstated: CI does assert the 15.9 rows, through core's in-memory fake: ci.yml quality-targets runs
  `swift test -c release ... --filter PerformanceTests`, and Tests/ZTronSearchEngineTests/PerformanceTests.swift:571-657
  (testDatabaseSources) checks 10k-row creation, the 500-row page, the 100-row upsert, the index round trip AND the
  "resident memory of a 10k-row context" row the finding says is unchecked. Only adapter-side regressions (SQLite read,
  ChangeTracker) escape CI; a core-side 10x regression of a page or an upsert would turn quality-targets red.
- Spec: no text requires the SQLite-backed measurement in CI. 17: milestones are "gated by its tests passing on the
  reference device" and section 15 targets are p95 on the iPhone 6s; 16 has performance baselines recorded on the
  device; 17 milestone 9 is where baselines are locked in CI; 18.1 package 32 asks for "the adapter test target in CI",
  which exists. The root README (lines 188-191, 205-210) documents the SQLite release run as a manual command and says
  only a device run settles a gate; I found no place that reports milestone 2's gate as met.
- "Failed in the one release run": NOT verified - the log is under Verification/_runs, which I was told not to read; I
  did not rerun the full package (a release build of core on this shared, loaded host). Even as quoted, the miss is
  against the host-scaled budget 50 ms / 6 = 8.33 ms, not the spec's device target.
- Secondary claims: the test does inject an in-memory resolver (lines 35-39, 120), true; 15.9 only says "resolver
  cached", which an in-memory dictionary satisfies.

### C2-m05-adapters-03 - CONFIRMED - severity medium
- Trace: SearchTableSource(table: View("published_tools"), ...) -> SQLiteExpressions.swift:231 -> private init :278
  `name: name ?? rendering.name` = "published_tools" (SQLiteTableRendering takes the last quoted name of
  "SELECT * FROM \"published_tools\""), rowID nil (:272). Core subscribes with
  `changes(in: Set(source.tables.map(\.name)))` (SearchService+Context.swift:504) and matches `table.name == change.table`
  (:519, :571). ChangeTracker.rowChanged (ChangeTracker.swift:77-89) routes only reported names whose ASCII fold is
  subscribed. Same for VirtualTable("tool_index") (name "tool_index", rowID "rowid").
- Repro (hooks/main.swift, swiftc + system SQLite 3.54.0, update hook installed exactly as the adapter relies on):
    == UPDATE the base table of a view            hook: ["UPDATE tools rowid=1"]  subscriber of ["published_tools"] receives a change: false
    == UPDATE through the view's INSTEAD OF trigger hook: ["UPDATE tools rowid=2"]  ... receives a change: false
    == INSERT into an FTS5 virtual table  hook: ["INSERT tool_index_content rowid=7", "INSERT tool_index_docsize rowid=7", "INSERT tool_index_data ..."] ... false
    == UPDATE an FTS5 virtual table       hook: [DELETE/INSERT tool_index_docsize, tool_index_content, tool_index_data ...] ... false
    == INSERT into an FTS4 virtual table  hook: ["INSERT tool_index4_content rowid=8", "..._docsize", "..._stat", "..._segdir"] ... false
    == INSERT into an R*Tree virtual table hook: ["INSERT tool_box_rowid rowid=9", "INSERT tool_box_node rowid=1"] ... false
    == UPDATE the base table, subscriber named after the base table -> receives a change: true
- So with the default name a view or virtual-table source never hears a change and stays stale until refresh()/rebuild.
  A workaround exists (`name: "tools"` for the view; the shadow or base table for FTS) but nothing documents it: the
  docs advertise "The table, view or virtual table" (:204), and ExpressionRenderingTests.swift:193 even states "A
  sub-select and a view have none: a change reads the source again as a whole", which is false for a view. Small
  correction: README.md:100-103 is about sub-selects, whose default name is the base table, and is true for them; the
  false statement for views is the test comment and the SQLiteRowID doc (:130-134 "read again as a whole whenever its
  table changes").

### C2-m05-adapters-07 - CONFIRMED - severity low
- Repro (same hooks/main.swift): `UPDATE tools SET id = 30 WHERE id = 3` -> hook ["UPDATE tools rowid=30"];
  `UPDATE tools SET id = id + 100 WHERE id IN (1, 2)` -> ["UPDATE tools rowid=101", "UPDATE tools rowid=102"]. The old
  rowid is never reported.
- Trace in core (SearchService+Context.swift:578-617): change.rowIDs = {30}, incremental; the row read back is tools#30;
  state.rows[3] is never visited, so tools#3 stays in state.ids and in the index (nothing removes it). README.md:132-135
  does not list a rowid change among the writes that need reportUnknownChanges. Extra note: when the document id is not
  the rowid, the stale state.rows[3] mapping can later remove a live document if rowid 3 is reused (:590-594).

### C2-m05-adapters-09 - PARTLY - severity low
- The bug is real but the mechanism and the indexed text differ from the finding. Repro (nslocal/main.swift and
  scalars.swift copy BundleLocalizedStringResolver.swift:64-67 and core's filter SearchRowProjector.swift:126):
    default:                         it tool.sextant.title -> resolver returns nil; core indexes it: false
    -NSShowNonLocalizedStrings YES:  it tool.sextant.title -> resolver returns "ZTRONSEARCHENGINESQLITE.MISSING"; core indexes it: true
    scalars with the default set:    value: sentinel -> \u{1}ZTRONSEARCHENGINESQLITE.MISSING\u{1}; value: nil -> TOOL.SEXTANT.TITLE
- Foundation uppercases what it would have returned: with a non-empty `value:` that is the uppercased SENTINEL, not the
  key. The sentinel check fails on case, the resolver returns "\u{1}ZTRONSEARCHENGINESQLITE.MISSING\u{1}", and core
  indexes it (it differs from the key). So the raw key does not enter the index; the uppercased sentinel does, and every
  row missing a translation gets an Italian surface matching "missing". Still violates 9.2 rule 3 ("An unresolved key
  indexes nothing for that field"). QA-only user default, hence low.

### C2-m05-adapters-10 - PARTLY - severity none
- The trap exists as described (SQLiteBindings.swift:36-37), but it is a documented precondition (:17-19 "Its
  documentation forbids any other conformance to `Binding`, and it traps when asked to bind one; so does this
  initializer"). SQLite.swift 0.17.0 (adapter .build/checkouts, tag 0.17.0): Value.swift:25-30 "Do not conform custom
  types to the Binding protocol"; its own conformances are exactly Double, Int64, String, Blob, Bool, Int (Value.swift
  48-130), all mapped by the adapter; Statement.swift:121 `fatalError("tried to bind unexpected value \(value)")`. Value
  types (Date, Data, UUID) reach bindings as their datatypeValue, one of the six. So only a host that breaks
  SQLite.swift's contract reaches the trap, and SQLite.swift would trap on the same value. The contrast with
  bindingCountMismatch is principled: a placeholder/binding mismatch can come from hand-written SearchSQL at run time.

### C2-m05-adapters-15 - CONFIRMED - severity low
- EndToEndTests.swift:383-392 says the three tests "are expected to fail against the core this adapter was built with";
  no XCTExpectFailure in the target (grep), the tests' own doc comments describe passing behaviour, and core now re-reads
  a table that changed during a read (SearchService+Context.swift:466-495, readsInFlight/changeSerials at :516-528), so
  the comment is stale. The writes go through the same serial queue as the page reads, so they land between pages or
  after all of them; in the latter case the tests pass without exercising the race, as the finding says.
  waitForFirstPage skips only when no SELECT is traced in 10 s (TestSupport.swift:150-162). "They pass" rests on the
  auditor's log, which I did not read; it is consistent with core's code.

### C2-m05-adapters-16 - PARTLY - severity low
- True that the test is not the README text verbatim: ReadmeSampleTests.swift:96 uses
  `BundleLocalizedStringResolver(bundles: [.main: strings])` (explained in its comment at :38), :99-102 passes an
  explicit configuration, and :58-75 creates the table. README.md:73 and :76 use `BundleLocalizedStringResolver()` and
  `SearchService<AppSchema>(context: context)`; both compile (bundles defaults to [:], configuration defaults to
  .default, SearchService+Context.swift:12-18). Every other line (schema, connect, SearchTableSource, context, the
  update in step 5) is the same code, so the guard still catches drift there; it misses only the two argument lists.

### C2-m05-adapters-02 - CONFIRMED - severity high
- Bridge, traced: FetchOperation.download (FetchOperation.swift:254-284) breaks its loop on a refused lane (:260-264,
  `.failed(.policy)`), on the first resolve failure (:279-281) and on a contradicted blob, then `group.cancelAll()` (:284)
  cancels every `client.resolve` task. A cancelled resolve withdraws its waiter (ZTronAssetKit EngineCommands.swift:91-132,
  withTaskCancellationHandler whose onCancel calls `withdraw(token)`). Reader cancellation does the same one level up: FetchCoordinator.detach cancels the
  session task when the last consumer leaves (FetchCoordinator.swift:78-84). The provider's own doc comment states the
  result (AssetKitModelAssetProvider.swift:183-186: "ZTronAssetKit then discards the part of a file that was in transit,
  so a later fetch starts that file again"), and so does README.md:43-51 / :285.
- ZTronAssetKit (read only, commit 1baccd6), traced: dropInterest -> settleRemoval -> holdIfUnwanted (EngineState.swift
  :1098-1104) -> retire (EngineJobs.swift:442-461): a `.downloading` job is abandoned (`handle.cancel()`, :469-480;
  TransferUpdate.swift:62-63 "Stop, discarding the partial"); a `.queued/.failed/.blocked` job is removed directly;
  removeJob (:483-530) drops the job together with its in-memory `resume` point. A new job adopts a resume point only from
  `launchResumes` (EngineJobs.swift:167), which is filled only by launch reconciliation (EngineLifecycle.swift:423-428).
  So the next fetch in the same process starts the file at byte 0.
- Small correction of the mechanism: on the most common interruption (leaving Wi-Fi under .wifiOnly on the prefetch
  lane) the engine itself pauses the transfer on the lane refusal (EngineDispatch.swift:644-653) and keeps the sidecar as
  the job's resume point, parked `.blocked(.policy)` (EngineFailures.swift:14-45). If the bridge kept its interest, that
  job would continue from the partial when Wi-Fi returns; it is the bridge's withdrawal that drops it (the partial file
  is orphaned rather than "discarded" when the attempt had already ended; same outcome). The engine's `.policy` park
  answers no waiter (EngineJobs.swift:894-895), which is why the bridge fails the fetch itself; failing the stream does
  not by itself require withdrawing every request (a PrefetchHandle, AssetClient.swift:203-207, might keep the job alive;
  not verified).
  Transient drops the engine absorbs inside one job (retryLater with resumePoint, EngineFailures.swift:126-133) do resume
  with Range; only failures that reach the fetch stream lose the file.
- Spec: 14.1 "fetch is resumable"; 14.4 "a retry re-verifies and resumes instead of starting over"; 15.6 "968 MB,
  resumable, SHA-256 verified"; milestone 8 gates on the 15.6 targets. The 17 open question ("Does ZTronAssetKit provide
  resumable ... or does the bridge own resume") assigns ownership only; nothing in 16 or 17 relaxes or defers resume.
  Core's own contract relies on it: ChatService.swift:124-127 "cancelling its consumer cancels a download in flight,
  which resumes on the next call", :219-220 "`fetch` is resumable: a retry ... resumes instead of starting over".
- Evidence check: RealClientTests.swift:80-110 asserts per-file resume (each small file requested once) and only
  `attempts.count >= 2` for the weights - no ranged request is asserted, as the auditor says.
- Not run: no executable repro (it needs ZTronAssetKit's engine and a scripted origin); the verdict rests on the code
  trace above plus the author's own statements. Unverified possible amplifier (outside m05, not settled):
  ZTronChatModel.prepare cancels its previous preparation task on every call (ZTronChatModel.swift:83-85) and
  .zTronChat calls it on every onAppear; if ChatService.removeObserver runs before the new observer is added
  (ChatService.swift:157-162) a re-appearing chat view would cancel and restart the fetch.
- Severity kept at high: an explicit, gated requirement stated three times, core's API promise broken by the reference
  bridge, up to 968 MB repeated per retry (on cellular under .allowCellular). Disclosure in the README mitigates surprise,
  not the deviation.

### C2-m05-adapters-04 - PARTLY - severity low (auditor: medium)
- Repro (resumed run, manifest/: the repository's ModelAssetManifest.swift with only `import ZTronSearchEngine` removed
  (diff checked), a stand-in for core's ModelFile/ModelAsset, and the bridge's ModelAssetPlan.swift:45-49 check; run on
  Scripts/qwen3-1.7b-4bit.verified.json):
    04: verifiedManifest.asset() throws missingChecksums(["config.json", "tokenizer_config.json"])
    04: a host-made ModelAsset with the two unknown SHA-256 left empty -> bridge refused: 'config.json' has no SHA-256 of
        64 hexadecimal digits -> availability .failed(.checksum), fetch throws .checksum
  (AssetKitModelAssetProvider.swift:120-122 and :196-198 turn a refused plan into .failed(.checksum) / a .checksum throw.)
- Real: the package ships no usable reference ModelAsset. Qwen3Asset exposes only the partial verifiedManifest and
  asset(pinnedBy:) / asset(pinnedManifestAt:) for a complete manifest (Qwen3Asset.swift:76-104); no complete manifest
  is in the repository (git ls-files); the README's wiring loads a "qwen3-1.7b-4bit.manifest.json" nobody ships
  (README.md:73-76). The integration tests sidestep it with `ModelAsset(..., files: [])` for the runtime
  (Qwen3IntegrationTests.swift:19), which a host cannot do because ChatService fetches `model.descriptor.asset`
  (ChatService.swift:197-222). Spec section 2 lists "the Qwen3 asset descriptor" in the MLX package, and ModelAsset
  files carry "name, byte count, SHA-256" (14.1).
- Overstated: the documented way is not circular. README.md:223-224 says "downloaded by the host's asset provider, or by
  any other means": only the first alternative is circular (shown above); the second works, and needs only the two
  Git-stored files (937 + 9,706 bytes) at the pinned commit, which the script checks by Git blob id
  (pin-qwen3-asset.swift:129-160). The host's catalog needs the same two SHA-256 values for its entries anyway
  (AssetKit README.md:108), so the step is unavoidable for any host and is one-time, scripted and fail-closed (asset()
  throws a clear .missingChecksums). Hence low: a missing convenience/deliverable, not a runtime defect.

### C2-m05-adapters-08 - CONFIRMED - severity low
- Repro (same manifest/ program):
    08: manifest with invented SHA-256 ffff...ffff for config.json and tokenizer_config.json + copied blob ids ->
        validate(against:) accepts; asset files: ["config.json=ffffffff...", "model.safetensors=0e86d967...",
        "tokenizer.json=aeb13307...", "tokenizer_config.json=ffffffff..."]
    08: same values without the blob ids -> unanchoredChecksum(file: "config.json")
- So validate(against:) (ModelAssetManifest.swift:159-173) checks only that the blob id is present and equal to the
  reference's (:167-172); nothing relates it to the SHA-256, and nothing can without the bytes. The docs claim more:
  ModelAssetManifest.swift:141-142 "the blob id is what ties the new value to the pinned commit", Qwen3Asset.swift:93-94
  "accepted only together with the matching Git blob id, which ties it to the pinned commit", README.md:243-244. The tie
  exists only in pin-qwen3-asset.swift, which hashes one read of the file both ways (:52-74). Qwen3AssetTests.swift:11-12
  and :93-114 accept made-up values, as the auditor says.
- Impact is fail-closed in the usual case: a wrong SHA-256 with the catalog's right one -> the stored blob's name differs
  from ModelFile.sha256 -> the bridge purges and rejects with .checksum (FetchOperation.swift:115-134, :266-269).
  "Accepts other bytes" needs the wrong value to be the real SHA-256 of other bytes the origin serves (e.g. a config.json
  of another revision hashed by hand); a random or corrupted value fails ZTronAssetKit's own integrity check. Low.

### C2-m05-adapters-05 - PARTLY - severity low (auditor: medium)
- Mechanism confirmed by reading (mlx-swift-lm 3b339ad6e3b3f44c8121ecff5131c7fd55e075e6 = 3.32.3 per Package.resolved,
  read with git show from the SwiftPM cache): MLXLanguageModel.swift:424-442 runs the prefill inside TokenIterator's
  init. LLMModel.prepare: `guard total > stepSize else { return .tokens(y) }` - a prompt of at most 512 tokens (Tuning
  prefillStepSize nil -> PrefillParameters.defaultStepSize 512) goes to the iterator whole; TokenIterator.prepare then
  submits it with step(previous:) + asyncEval, and the first `iterator.next()` blocks in `.item` until that forward is
  done. GenerationLoop checks `isCancelled` only before/after each `nextToken()` (GenerationLoop.swift:51-69), so a
  cancel during that forward is seen only when it ends. Longer prompts: PrefillParameters.forEachChunk calls
  `try Task.checkCancellation()` before each balanced chunk (<= 512 tokens) and each chunk is submitted with
  asyncEval(cache); after the CancellationError the adapter synchronizes the stream (:438), i.e. waits for the work
  already submitted - at least the rest of the chunk in flight, possibly more since submission runs ahead of the GPU.
  The cancel path from the consumer does reach that check: GenerationCancellation.cancel() cancels the generation's
  task (GenerationCancellation.swift:36-42).
- Test gap confirmed: the only latency test (Qwen3IntegrationTests.swift:358-394) cancels after 8 deltas, during decode,
  with a one-sentence prompt.
- Why partly: (1) the governing text is ambiguous and leans the other way. 14.1 words it "honours task cancellation
  within one decoded token"; 15.6 "generation stops within one token, at most 150 ms" - both are naturally read per
  token of output, and no output is produced during prefill. (2) The user-visible stream already stops at once:
  GenerationLoop never emits after the flag is set, and ZTronChatModel.cancel() clears isGenerating synchronously; what
  lasts is the runtime thread staying busy, which delays the next send or an unload by the rest of the chunk. (3) The
  latency figures (hundreds of ms to ~2 s) are an inference from the 2 s TTFT budget; nothing was measured (no Metal
  toolchain or device here). Side note: README.md:140-142 says cancellation "takes effect between two prefill chunks";
  for a prompt of at most one step there is no check at all until the first token.

### C2-m05-adapters-06 - PARTLY - severity low (auditor: medium)
- Confirmed: testFootprintDuringGenerationStaysWithinBudget (Qwen3IntegrationTests.swift:525-538) reads
  `ri_phys_footprint`, the current value (:131-139), only when a `.delta` arrives (:531), so nothing before the first
  visible token - the prefill and the iterator's first forward - is ever sampled. Prefill transients are gone by then:
  load sets `MLX.Memory.cacheLimit` to 32 MB (MLXLanguageModel.swift:209-210, Tuning default :51), and mlx-swift-lm's
  TokenIterator.next() calls `MLX.Memory.clearCache()` when `tokenCount % 256 == 0`, i.e. on the first token right after
  the prefill ("Matches mlx-lm, which also clears on the first token, after prefill").
- Repro of the sampling logic (footprint/main.swift: the test's physicalFootprint() copied, a stand-in generation that
  keeps 400 MB resident, dirties a transient mmap region during "prefill", munmaps it, then yields 16 deltas):
    600 MB transient: (inside prefill: current 1051 MB) / peak as the test samples it: 439 MB /
                      ri_lifetime_max_phys_footprint: 1051 MB / a 1000 MB budget: test-style assertion PASSES, true peak NO
    300 MB transient: (inside prefill: 736 MB) / test-style peak 439 MB / lifetime max 736 MB
  (A first attempt with malloc'd memory did not drop after free - malloc keeps large regions cached - so mmap stands in
  for MLX releasing Metal buffers above its cache limit.)
- Why partly: that the prefill is "the most memory-hungry phase" is plausible (attention of 500-token chunks against
  ~3,000 cached tokens versus ~29 MB of KV growth over 256 decode tokens) but was not measured: no MLX run is possible
  here. The failure scenario's "(the condition that gets the app jetsammed on an 8 GB phone)" is overstated: 1.8 GB is
  the spec's budget (15.6, 14.4 "about 1.8 GB resident"), not a jetsam threshold. The suggested
  ri_lifetime_max_phys_footprint would also count the load and earlier tests in the same process; an interval maximum
  or a sampler during the whole generate() would be the fix. The test is macOS-only (`#if os(macOS)`), consistent with
  16 ("Integration tests ... run through xcodebuild on an Apple-silicon Mac").

### C2-m05-adapters-11 - CONFIRMED - severity low
- Trace: load() starts performLoad in an unstructured Task (MLXLanguageModel.swift:183-187), so cancelling load's
  caller does not reach it; releaseModel() (:268-277) only sets `pendingLoad = nil` and never cancels the task; the
  superseded result is dropped only after LLMModelFactory.load returns (:233-238). Cancelling would not help either:
  mlx-swift-lm 3b339ad6's async loadWeights runs the whole synchronous read on DispatchQueue.global inside a checked
  continuation (Load.swift:418-438), and neither LLMModelFactory._load nor ModelFactory.load has a cancellation check
  (grep). unload() (:263-266) returns as soon as releaseModel ran. Core reaches this path: ChatService.unload() on a
  memory warning (ChatService.swift:605-613) calls model.unload() also in `.loading` (:409-418).
- Repro (loadunload/main.swift: the adapter's load/performLoad/releaseModel logic copied into an actor, the factory
  replaced by a 300 MB read on a global queue in ten 100 ms pieces, as loadWeights does):
    [0.42 s] memory warning: unload() (footprint 128 MB)
    [0.42 s] unload() returned (footprint 128 MB)            <- the caller's task was cancelled here too
    [0.74 s] 0.3 s after a second load() began (footprint 316 MB)
    [1.11 s] load #1 finished, superseded: its weights are dropped now (footprint 537 MB)
    [1.12 s] load #1 threw loadSuperseded (footprint 222 MB)
    [1.54 s] load #2 returned (footprint 317 MB)
  So unload() returns at once, the read continues and is freed only at its end, as the finding says. Worse than stated:
  a load() issued in that window (pendingLoad is nil, so nothing joins the old one) starts a second read in parallel;
  with the real weights that is up to ~2 x 968 MB resident at once. Window: the cold load, 4 s target (15.6).
- Aside, core (not m05, read but not run): ChatService.load(from:) maps the superseded load's throw to
  `.failed(.loadFailed)` (ChatService.swift:283-287), overwriting the `.onDisk` that unload() set, so a memory warning
  during a load leaves chat reporting unavailable(.loadFailed).
- Low: a narrow window (a memory warning during a 1-4 s cold load), but exactly when memory is short.

### C2-m05-adapters-12 - CONFIRMED - severity low
- .github/workflows has three files; none builds or tests Adapters/ZTronSearchEngineAssetKit: adapter-tests.yml runs
  only Adapters/ZTronSearchEngineSQLite (:30-63, path filters :13-23), ci.yml runs the root package and the MLX adapter
  (:76-89), parity.yml the parity host. No job checks out ZTronAssetKit, which the adapter needs as a sibling checkout
  or ZTRON_ASSETKIT_PATH (Package.swift:16, :28). The root README lists the run only as a manual command
  (README.md:193). 103 test methods counted (PlanAndLaneTests 21, AvailabilityTests 20, RealClientTests 20, FetchTests
  18, PolicyTests 12, SharingAndEvictionTests 12), matching the auditor; "all passing locally" rests on a log I did not
  read.
- Spec: not a deviation. 18.1 package 32 asks for "the adapter test target in CI" for the SQLite adapter (met);
  milestone 8 gates on "fake-runtime tests green in CI" (core's fakes) and places "the ZTronAssetKit adapter in the
  host". So this is a CI coverage gap for an extra package, as the auditor classed it (test-integrity, low).

### C2-m05-adapters-13 - PARTLY - severity low
- Behavior confirmed: SamplingPlan.swift:154-157 applies the asset's max_new_tokens only as `min(...)` and only while
  the request carries the default 512, so an asset asking for more never wins. Spec 14.2: "at most 512 new tokens; the
  asset's generation_config.json wins when present".
- "Undocumented" is wrong: SamplingPlan's precedence doc says it (SamplingPlan.swift:118-119 "The asset's
  `max_new_tokens` can only lower it, and only while the request still carries the default"), and so does README.md
  :124-129 ("wins over those defaults ... the asset can lower the default but never raise it"). It is not labelled as a
  departure from the spec, but a reader is told.
- Defensible against core's own contract: GenerationOptions.maxNewTokens is a non-optional caller budget defaulting
  to 512 (ChatBoundary.swift:134, :143), unlike temperature/topP whose `nil` defers to the asset (:130-133), and 14.2's
  Context row has the chat service fit "a 512-token reply" in the window. Zero reach for the reference model, whose
  repository has no generation_config.json (Qwen3Asset.swift:25-26, README.md:130-131; not re-checked online).

### C2-m05-adapters-14 - CONFIRMED - severity low
- Code: TTFT is taken at the first `.delta` (ChatCalibration.swift:22, :175-178, :202) and the rate is
  `(generated - 1) / (end - firstDelta)` (:23, :204-205) with `generated` from `.usage`, which counts hidden tokens too.
  Tokens that produce no visible text before the first delta (detokenizer returning nil, ThinkBlockFilter holding back a
  possible tag start, a think block) push TTFT later and shrink the rate's denominator without shrinking its numerator.
- Repro (calibration/main.swift, the init arithmetic copied; a device with 2.0 s to the first token and a true
  7.5 tok/s decode, 64 tokens):
    first visible delta at token  1: TTFT 2.00 s, rate 7.50 tok/s -> gate fail   (exact)
    first visible delta at token  3: TTFT 2.27 s, rate 7.75 tok/s -> gate fail
    first visible delta at token  5: TTFT 2.53 s, rate 8.01 tok/s -> gate PASS   (a 7.5 tok/s device enabled)
    first visible delta at token 10: TTFT 3.20 s, rate 8.75 tok/s -> gate fail   (TTFT now over)
- Small in practice, as the auditor says: the calibration request is fixed with thinking off (:16, :76-78), so Qwen3's
  template closes an empty think block in the prompt (README.md:112-114) and an English summary's first token is
  normally visible; then both numbers are exact. Spec 14.4 asks for "time to first token"; the first visible delta is a
  proxy that diverges only when the reply opens with hidden tokens.

### C2-m05-adapters-17 - CONFIRMED - severity low
- README.md:54-55 "`Package.swift` points at core with an absolute path. It becomes `../..` once this package lives at
  `Adapters/ZTronSearchEngineMLX`": Package.swift:20-23 already has `path: "../.."` (and the package does live there).
- README.md:251 "149 tests": the unit-test files (Qwen3IntegrationTests excluded) hold 150 no-argument `test` methods,
  all inside XCTestCase classes (ChatCalibration 17, Executor/Cancellation 11, GenerationLoop 19, JSONConfig 6,
  LocalTokenizer 16, MLXLanguageModel 24, Qwen3Asset 17, SamplingPlan 19, ThinkBlockFilter 21). The two `#if` blocks in
  MLXLanguageModelTests (:84-88, :116-118) sit inside test bodies and remove no method. Documentation drift only.

## Summary

| id | verdict | severity (auditor -> skeptic) |
|---|---|---|
| C2-m05-adapters-01 | partly | high -> low |
| C2-m05-adapters-02 | confirmed | high -> high |
| C2-m05-adapters-03 | confirmed | medium -> medium |
| C2-m05-adapters-04 | partly | medium -> low |
| C2-m05-adapters-05 | partly | medium -> low |
| C2-m05-adapters-06 | partly | medium -> low |
| C2-m05-adapters-07 | confirmed | low -> low |
| C2-m05-adapters-08 | confirmed | low -> low |
| C2-m05-adapters-09 | partly | low -> low |
| C2-m05-adapters-10 | partly | low -> none |
| C2-m05-adapters-11 | confirmed | low -> low |
| C2-m05-adapters-12 | confirmed | low -> low |
| C2-m05-adapters-13 | partly | low -> low |
| C2-m05-adapters-14 | confirmed | low -> low |
| C2-m05-adapters-15 | confirmed | low -> low |
| C2-m05-adapters-16 | partly | low -> low |
| C2-m05-adapters-17 | confirmed | low -> low |

No finding refuted. Programs of the resumed run, all under
/private/tmp/claude-501/-Users-admin-Documents-ZTronSearchEngine/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m05-adapters-skeptic/:
manifest/ (04, 08), footprint/ (06), loadunload/ (11), calibration/ (14), Evaluate.swift (mlx-swift-lm 3b339ad6 source
extracted for reading). Not run anywhere: MLX (no Metal toolchain or device on this host), ZTronAssetKit's engine
(02 rests on the code trace), the repository's own test suites.

STATUS: complete
