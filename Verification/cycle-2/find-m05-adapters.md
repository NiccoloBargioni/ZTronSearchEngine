# C2 m05 adapters - findings

Auditor: cycle 2, module m05 (the three adapter packages: ZTronSearchEngineSQLite, ZTronSearchEngineMLX,
ZTronSearchEngineAssetKit). Repository at commit cee4620. Spec: Verification/_inputs/spec.txt.
Nothing in the repository was modified except this file. No swift build / swift test / xcodebuild was run;
no simulator was booted. One standalone probe was built and run in the scratchpad (see C2-m05-adapters-03 and -07).

Probe: /private/tmp/claude-501/-Users-admin--claude-spares-spare-8uzMiK/9d753227-1867-465a-bab4-eb68ece6e12f/scratchpad/cycle-2/m05-adapters/hooks/main.swift
(swiftc, linked against the system SQLite3, sqlite 3.54.0). It installs sqlite3_update_hook and prints what
the hook reports. Output (verbatim, abridged to the relevant lines):

    == write to the base table of a view            -> ["UPDATE tools rowid=2"]
    == write through an INSTEAD OF trigger on the view (UPDATE published_tools ...) -> ["UPDATE tools rowid=1"]
    == UPDATE that changes the rowid (UPDATE tools SET id = 30 WHERE id = 3)        -> ["UPDATE tools rowid=30"]
    == INSERT OR REPLACE hitting a UNIQUE column of another row                    -> ["INSERT tools rowid=40"]
    == insert into an FTS5 virtual table  -> ["INSERT tool_index_content rowid=7", "INSERT tool_index_docsize rowid=7", "INSERT tool_index_data ..."]
    == insert into an FTS4 virtual table  -> tool_index4_content / _docsize / _stat / _segdir only (never "tool_index4")

## Findings (ranked, most severe first)

### C2-m05-adapters-01 - HIGH - test-integrity - The section 15.9 gate over SQLite never runs in CI, and failed in the one release run
- Spec: 15.9 (Database sources targets), 17 milestone 2 gate ("... the adapter integration tests, and the section 15.9 targets"), 18.1 packages 31 and 32.
- Locations: Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/DatabaseTargetsTests.swift:68-71, :179;
  .github/workflows/adapter-tests.yml:57-63; Verification/_runs/c2-sqlite-release-targets.log:47,58.
- Description: testSection159TargetsOverSQLite is the only test that measures the 15.9 targets through the reference
  adapter. Under `#if DEBUG` it throws XCTSkip (line 70). The adapter workflow runs only `swift test` and
  `swift test --sanitize=thread` (both debug), so in CI the test always skips and the job is green. The quality-targets
  job of ci.yml runs only the root package's PerformanceTests (in-memory fake), never this test. The orchestrator's
  release run of the test failed the 100-row upsert target.
  Secondary: the test never uses the adapter's BundleLocalizedStringResolver (it injects an in-memory dictionary
  resolver, lines 35-39) and has no check for the 15.9 "6 MB per 10k-row context" row.
- Evidence: c2-sqlite-adapter.log: 78 tests, 1 skipped (testSection159TargetsOverSQLite), exit 0.
  c2-sqlite-release-targets.log:47: "DatabaseTargetsTests.swift:179: error: ... XCTAssertLessThanOrEqual failed: ("0.010154") is greater than ("0.008333333333333333") - incremental upsert of 100 changed rows, after the commit (p95 of 40 commits)"; line 58 "PERF ... 10.154 ms measured; budget 50 ms on the reference device, 8.333 ms here (OVER)"; EXIT: 1.
  Knock-down considered: the run was under heavy host load (load averages 10-80, 12 booted simulators; p50 was 2.7 ms),
  so the miss may be noise. That does not change that CI never asserts this gate.
- Failure scenario: a regression that makes a 500-row page or a 100-row upsert 10x slower over SQLite merges with green CI;
  the milestone 2 gate is reported met without ever having run.

### C2-m05-adapters-02 - HIGH - spec-deviation - A retry in the same process restarts the 968 MB weights file from zero
- Spec: 14.4 "a retry re-verifies and resumes instead of starting over"; 15.6 "Download 968 MB, resumable ..."; the
  open question in 17 explicitly allows "the bridge own[s] resume and verification".
- Locations: Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/FetchOperation.swift:260-264 (refused
  lane -> stop with .policy), :279-281 (first resolve failure -> stop), :284 (group.cancelAll withdraws every request);
  FetchCoordinator.swift:78-84 (last reader gone -> task cancelled); AssetKitModelAssetProvider.swift:183-186;
  README.md:43-51 and :285; ZTronAssetKit Sources/ZTronAssetSync/Engine/EngineJobs.swift:167 (a new job adopts a resume
  point only from launchResumes), :441-460 (retire -> abandon -> handle.cancel()), :483-530 (removeJob drops the job's
  kept state); Sources/ZTronAssetModel/Transfer/TransferUpdate.swift:62-63 (`cancel`: "Stop, discarding the partial").
- Description: on any failure (.offline, .policy when the device leaves Wi-Fi under .wifiOnly, a resolve error) and on
  reader cancellation, the bridge fails the fetch and withdraws every ZTronAssetKit request. With no interest left,
  ZTronAssetKit retires the job, cancels the transfer and discards the partial; a later job in the same process does
  not look for earlier partials (only a launch does). Stored files are kept, so resume is per file only, and for the
  reference model 968,080,210 of 979,513,507 bytes are one file. The README states this itself (limit 1, "In-process
  retries lose the file in transit"). Verified in the ZTronAssetKit sources cited above.
- Evidence: README.md:48-51 "the fetch is started again in the same process, the file that was in transit starts at
  zero. For the reference model that file is model.safetensors, 968 MB of the 980 MB." RealClientTests
  testAFetchThatFailedResumesWithTheFilesTheStoreKept only asserts `attempts.count >= 2` for the weights, not a ranged
  resume; testWifiOnlyStopsItsTransferWhenTheNetworkTurnsCellular asserts the fetch ends with .policy and the weights
  are not stored.
  Knock-down considered: the root cause sits in ZTronAssetKit (no in-process adoption of partials) and is documented;
  the spec's open question leaves ownership undecided. The requirement itself is not deferred anywhere, and the bridge's
  fail-and-withdraw design is what triggers the discard on the most common interruption (leaving Wi-Fi).
- Failure scenario: .wifiOnly fetch, user walks out of Wi-Fi at 900 MB of model.safetensors -> fetch fails .policy,
  requests withdrawn, partial discarded -> back on Wi-Fi, ChatService.prepare retries -> the 968 MB file downloads again
  from byte 0.

### C2-m05-adapters-03 - MEDIUM - bug - View and virtual-table sources are never refreshed by the change stream (confirmed by probe)
- Spec: 9.2 rule 5 (changes are batched per commit, changed rowids re-read, a change without rowids refreshes the table).
- Locations: Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteExpressions.swift:204-207 (docs: "The
  table, view or virtual table"; "name: The name of the table whose changes refresh the source ... nil takes it from
  table"), :218-235, :272 (no rowid for a View), :278 (`name: name ?? rendering.name`); ChangeTracker.swift (changes keyed
  by the table name the update hook reports); SQLiteSearchConnection.swift:135-142 (changes(in:) docs); README.md:100-105.
- Description: core subscribes with `changes(in: Set(tables.map(\.name)))` and matches `table.name == change.table`. For a
  `View` source the default name is the view's name; for a `VirtualTable` (FTS4/FTS5) the virtual table's name. SQLite's
  update hook never reports either: writes to the base table, even through an INSTEAD OF trigger on the view, are
  reported under the base table, and FTS writes under its shadow tables. So such a source receives no change at all and
  stays stale until an explicit refresh. README.md:100-103 even says a source without rowid makes "the engine ... read
  the whole source again on every change", which does not happen for a view. The README's list of what the hook does not
  report (lines 132-135) does not mention views or virtual tables, so a host following it gets no hint to call
  reportUnknownChanges.
- Evidence: probe output above ("write through an INSTEAD OF trigger on the view" -> ["UPDATE tools rowid=1"]; FTS5 ->
  "tool_index_content", never "tool_index").
- Failure scenario: SearchTableSource(table: View("published_tools"), ...) with the default name; the host runs
  `UPDATE tools SET title = 'pocket compass' WHERE id = 1` through withConnection -> the commit yields a change for
  "tools", no subscriber matches "published_tools" -> the index keeps the old title until the service is rebuilt.

### C2-m05-adapters-04 - MEDIUM - spec-missing - The Qwen3 reference ModelAsset cannot be built from the package, and the documented way to complete it is circular
- Spec: section 2 package table ("the Qwen3 asset descriptor"); 14.1 ("verifies SHA-256 per file"); 14.2 reference model;
  ModelAsset.files carry "name, byte count, SHA-256".
- Locations: Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/Qwen3Asset.swift:6-25, :89-99;
  ModelAssetManifest.swift (asset() throws .missingChecksums); README.md:193-245; Scripts/pin-qwen3-asset.swift;
  Adapters/ZTronSearchEngineAssetKit/Sources/ZTronSearchEngineAssetKit/ModelAssetPlan.swift:45-49 (a file without a
  64-hex SHA-256 makes the descriptor unusable -> .failed(.checksum)).
- Description: Qwen3Asset.verifiedManifest has no SHA-256 for config.json and tokenizer_config.json, so
  `Qwen3Asset.verifiedManifest.asset()` throws `.missingChecksums(["config.json", "tokenizer_config.json"])`
  (Qwen3AssetTests.swift:71-80 asserts exactly this). The package therefore ships no usable reference ModelAsset. The
  README says to pin the two values "once the files exist locally (downloaded by the host's asset provider, or by any
  other means)", but the host's asset provider (the AssetKit bridge) refuses a descriptor without a SHA-256 for every
  file, so the files have to come from somewhere else first and a script has to be run by hand.
- Evidence: Qwen3AssetTests.swift:79 `assertThrows(.missingChecksums(["config.json", "tokenizer_config.json"]), try manifest.asset())`;
  ModelAssetPlan.swift:47-48 refuses a file with no 64-hex SHA-256.
  Knock-down considered: the author refused to invent checksums without the files (no download was allowed), which is
  principled; the gap is still a missing deliverable and a documented flow that cannot work as written.
- Failure scenario: a host wires ZTronSearch with AssetKitModelAssetProvider and Qwen3Asset as the README suggests ->
  there is no ModelAsset to pass; building one with the two known LFS files only, or with placeholder hashes, either
  omits files the runtime needs or fails every fetch with .checksum.

### C2-m05-adapters-05 - MEDIUM - spec-deviation - Cancellation during the prompt prefill is not bounded by one token / 150 ms, and is untested
- Spec: 15.6 "Cancellation: generation stops within one token, at most 150 ms"; 14.1 "honours task cancellation within
  one decoded token".
- Locations: Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:424-442;
  README.md:140-142; Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:358-394; mlx-swift-lm 3b339ad6
  Libraries/MLXLLM/LLMModel.swift (prepare: `guard total > stepSize else { return .tokens(y) }`, asyncEval per chunk) and
  Libraries/MLXLMCommon/PrefillParameters.swift (forEachChunk: `try Task.checkCancellation()` between chunks).
- Description: the prefill runs inside `TokenIterator(...)`. With the default step (Tuning.prefillStepSize nil -> 512) a
  prompt of at most 512 tokens is evaluated in one forward with no cancellation check at all; a longer prompt is checked
  only between chunks of up to 512 tokens, the chunks are submitted with asyncEval, and on CancellationError the adapter
  waits for the submitted GPU work (`MLX.Stream.defaultStream.synchronize()`, line 438). A cancel that arrives during the
  prefill therefore takes up to a whole 512-token forward, which 15.6 itself budgets at up to 2 s (TTFT p95 for a
  512-token prompt). The only latency test cancels after 8 deltas, i.e. during decode, with a ~20-token prompt.
- Evidence: MLXLanguageModel.swift:426-427 comment ("mlx-swift-lm checks the task for cancellation between prefill
  chunks"); LLMModel.prepare returns the whole prompt to the iterator when `total <= stepSize`; Qwen3IntegrationTests.swift:373
  `if deltas == 8 { signal.yield() }`.
  Knock-down considered: 14.1's wording ("within one decoded token") can be read as decode-only, and the README discloses
  the chunk granularity. The 15.6 row speaks of "generation" without that restriction.
- Failure scenario: RAG prompt of ~3,000 tokens on the A17 Pro target; the user taps Stop right after sending -> the stream
  keeps the runtime busy for the rest of the current chunk (hundreds of ms to ~2 s) before .finished(.cancelled).

### C2-m05-adapters-06 - MEDIUM - test-integrity - The 1.8 GB resident-memory test never samples the prefill peak
- Spec: 15.6 "Resident memory during generation: 1.8 GB".
- Locations: Adapters/ZTronSearchEngineMLX/Tests/ZTronSearchEngineMLXTests/Qwen3IntegrationTests.swift:523-538 (and
  the helper at :129-140).
- Description: testFootprintDuringGenerationStaysWithinBudget builds a 3,000-token prompt but reads
  `ri_phys_footprint` (the current footprint) only when a .delta arrives, i.e. after the prefill is over. The prefill of
  3,000 tokens (six chunks with full attention against the growing cache, plus MLX's transient buffers) is the most
  memory-hungry phase of a generation and is never sampled. `rusage_info_v4.ri_lifetime_max_phys_footprint` would give
  the true peak.
- Evidence: line 531 `if case .delta = event, let footprint = physicalFootprint() { peak = max(peak, footprint) }`.
- Failure scenario: a prefill peak above 1.8 GB (the condition that gets the app jetsammed on an 8 GB phone) passes the
  test because only the post-prefill decode footprint is compared with 1.8e9.

### C2-m05-adapters-07 - LOW - bug - An UPDATE that changes the rowid leaves a ghost document (confirmed by probe)
- Spec: 9.2 rule 5.
- Locations: Adapters/ZTronSearchEngineSQLite/README.md:132-138 (list of unreported writes);
  ConfinedConnection.swift (update hook) / ChangeTracker.swift; core SearchService+Context.swift ~603-610 (a rowid that
  does not come back is removed only if it was in change.rowIDs).
- Description: for `UPDATE tools SET id = 30 WHERE id = 3` on an INTEGER PRIMARY KEY (rowid alias) the update hook reports
  only rowid 30. Core re-reads rowid 30 and adds tools#30; rowid 3 is never named, so tools#3 stays in the index. The
  README lists writes the hook misses (other connections, WITHOUT ROWID, unqualified DELETE, INSERT OR REPLACE) and tells
  the host to call reportUnknownChanges after them; a rowid change is not on the list.
- Evidence: probe "UPDATE that changes the rowid" -> ["UPDATE tools rowid=30"].
- Failure scenario: host renumbers a row's primary key -> searches return tools#3, whose row no longer exists, next to
  tools#30, until a full refresh.

### C2-m05-adapters-08 - LOW - false-claim - ModelAssetManifest.validate(against:) does not tie a new SHA-256 to the Git blob id
- Locations: Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ModelAssetManifest.swift:136-174;
  Qwen3Asset.swift:93-99; Tests/ZTronSearchEngineMLXTests/Qwen3AssetTests.swift:11-12, :93-114.
- Description: the docs say a SHA-256 that public metadata cannot confirm "is accepted only together with the matching Git
  blob id, which ties it to the pinned commit". validate(against:) only checks that the blob id is present and equal to
  the reference; nothing relates it to the SHA-256. Any SHA-256 is accepted next to a copied blob id. The tie exists only
  inside Scripts/pin-qwen3-asset.swift, which hashes the local file both ways.
- Evidence: Qwen3AssetTests.completeManifest uses the made-up values "000...01" / "000...02" and
  testCompleteManifestBecomesTheModelAsset expects `Qwen3Asset.asset(pinnedBy:)` to accept them (line 112).
- Failure scenario: a hand-edited or corrupted manifest with a wrong SHA-256 for config.json is accepted by
  asset(pinnedManifestAt:) -> every fetch of that file then fails with .checksum (or accepts other bytes, if the catalog
  was built from the same wrong manifest).

### C2-m05-adapters-09 - LOW - bug - BundleLocalizedStringResolver turns missing keys into uppercased "strings" under NSShowNonLocalizedStrings
- Spec: 9.2 rule 3 ("The raw key never enters the index").
- Locations: Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/BundleLocalizedStringResolver.swift:64-67.
- Description: the resolver detects a missing key by passing a sentinel as `value:`. With the NSShowNonLocalizedStrings
  user default set (a common localization-QA switch), Foundation logs and returns the key capitalized instead of `value`,
  so the sentinel check fails and the uppercased key is returned as that language's string. Core's projector only drops a
  string equal to the key (`string != value`), so "TOOL.SEXTANT.TITLE" enters the index as a localized title.
- Failure scenario: QA build with NSShowNonLocalizedStrings=YES and an incomplete it.lproj -> Italian surfaces of those
  rows hold the uppercased key; it ranks for key fragments.

### C2-m05-adapters-10 - LOW - api - A public initializer can trap the process
- Locations: Adapters/ZTronSearchEngineSQLite/Sources/ZTronSearchEngineSQLite/SQLiteBindings.swift:36-37.
- Description: `SearchBindingValue.init(_ binding: Binding?)` ends with
  `preconditionFailure("SQLite.swift cannot bind a value of type ...")` for any other `Binding` conformance. The adapter
  otherwise converts SQLite.swift's traps into thrown errors (bindingCountMismatch); this one stays a crash.
- Failure scenario: a host type conforming to SQLite.swift's `Binding` (it is a public protocol) passed through
  SearchBindingValue(_:) -> process abort instead of an error.

### C2-m05-adapters-11 - LOW - bug - load() cannot be cancelled, and unload() during a load keeps ~1 GB until the read finishes
- Spec: 15.6 ("on a memory warning the LLM unloads before the embedding model").
- Locations: Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/MLXLanguageModel.swift:167-188, :233-238, :263-277.
- Description: load() runs performLoad in an unstructured Task and releaseModel() only clears pendingLoad; the pending task
  is never cancelled, and mlx-swift-lm's loadWeights runs to completion on a global queue. A superseded load is discarded
  only after the weights are fully read (then clearCache()).
- Failure scenario: memory warning during the 1-4 s cold load -> unload() returns at once but the 968 MB read and
  materialization continue, then are freed; under pressure this is the window in which the app is killed.

### C2-m05-adapters-12 - LOW - test-integrity - The AssetKit adapter's tests run in no CI workflow
- Locations: .github/workflows/ (adapter-tests.yml, ci.yml, parity.yml: none mentions ZTronSearchEngineAssetKit);
  Adapters/ZTronSearchEngineAssetKit/Package.swift:16 (depends on a sibling checkout of ZTronAssetKit).
- Description: the 103 tests (c2-assetkit-adapter.log, all passing locally) are never run by CI, and CI has no checkout of
  ZTronAssetKit to build them against.
- Failure scenario: a change in core's ModelAssetProviding contract or in ZTronAssetKit breaks the bridge without any red build.

### C2-m05-adapters-13 - LOW - spec-deviation - The asset's max_new_tokens can only lower the 512 cap
- Spec: 14.2 "the asset's generation_config.json wins when present".
- Locations: Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/SamplingPlan.swift:154-157.
- Description: `if options.maxNewTokens == defaults.maxNewTokens, let assetMaximum = config?.maxNewTokens { maxNewTokens = min(...) }`:
  an asset that asks for more than 512 does not win. Zero reach for the reference model (its repository has no
  generation_config.json) and defensible given the chat budget, but undocumented as a deviation.

### C2-m05-adapters-14 - LOW - spec-deviation - Calibration measures to the first visible delta, not the first token
- Spec: 14.4 calibration (TTFT <= 3 s, >= 8 tokens/s).
- Locations: Adapters/ZTronSearchEngineMLX/Sources/ZTronSearchEngineMLX/ChatCalibration.swift:23-24, :163-202.
- Description: TTFT is taken at the first .delta; tokens swallowed by the think filter or the detokenizer before it push
  TTFT later, and the rate `(generated - 1) / (finished - firstDelta)` still counts them in the numerator, overstating
  tokens/s. Small with thinking off; it skews the gate the other way when a reply opens with hidden tokens.

### C2-m05-adapters-15 - LOW - false-claim - Stale "expected to fail" comment in EndToEndTests
- Locations: Adapters/ZTronSearchEngineSQLite/Tests/ZTronSearchEngineSQLiteTests/EndToEndTests.swift:383-392.
- Description: the comment says three tests "are expected to fail against the core this adapter was built with". They
  pass (c2-sqlite-adapter.log, 78 tests, 1 skip), carry no XCTExpectFailure, depend on a commit landing inside a page
  read, and waitForFirstPage can skip. A reader cannot tell a fixed core from a run where the race did not happen.

### C2-m05-adapters-16 - LOW - false-claim - The SQLite README sample is not what ReadmeSampleTests runs
- Locations: Adapters/ZTronSearchEngineSQLite/README.md:49-81; Tests/ZTronSearchEngineSQLiteTests/ReadmeSampleTests.swift:6-7, :96-101.
- Description: the test says "If this file has to change, so does the README", but it uses
  `BundleLocalizedStringResolver(bundles: [.main: strings])` and an explicit SearchEngineConfiguration (debounce 0, fixed
  locale), while the README uses `BundleLocalizedStringResolver()` and `SearchService(context:)` with defaults. The
  sample as printed is not the code that is compiled and run.

### C2-m05-adapters-17 - LOW - false-claim - MLX README drift
- Locations: Adapters/ZTronSearchEngineMLX/README.md:54-55, :251; Package.swift:20-23.
- Description: README says "Package.swift points at core with an absolute path. It becomes ../.." - it already is "../..".
  README says "149 tests"; the unit-test files hold 150 test methods (Qwen3IntegrationTests excluded).

## Checked and knocked down (not reported)
- MLX API use against mlx-swift-lm 3b339ad6: GenerateParameters(maxTokens:temperature:topP:topK:repetitionPenalty:seed:),
  prefill.stepSize, LLMModelFactory.load(from:using:), eosTokenIds/extraEOSTokens, NaiveStreamingDetokenizer
  (decode with skipSpecialTokens false), swift-transformers applyChatTemplate (addGenerationPrompt true) - all correct.
- MLX work on the cooperative pool: weight loading runs on a global queue inside mlx-swift-lm (Load.swift async loadWeights),
  the tokenizer on a global queue, generation on the dedicated thread. DedicatedThreadExecutor's semaphore protocol is
  correct (exits only after shutdown, drains queued jobs).
- Symlinked model directory: mlx-swift-lm finds weights with contentsOfDirectory + path extension and opens by path, so
  links work.
- AssetKit lanes: DownloadLane matches ZTronAssetKit SyncEngine.access(for:) and LaneAdmission.evaluate; prefetch lane is
  allowed in Low Power Mode by default (PowerPolicy.prefetchInLowPowerMode = true).
- AssetKit verification by blob name: AssetStore+Publish.swift builds BlobKey from the computed digest (verified).
- Background download / .wifiOnly needing host configuration: documented and an open question of the spec.
- Free disk >= 2x totalBytes: implemented in core ChatService.swift:208-209, not the adapter's job.
- generation_config.json "asset wins": the reference repository has none.
- CI mlx job builds with the native build system and skips the integration tests: milestone 8 gates only fake-runtime
  tests in CI; 15.6 targets are measured on an A17 Pro iPhone and an M-series Mac.
- SQLParameterCounter matches sqlite3_bind_parameter_count (test compares 40 statements).

## Files read
- Spec: spec.txt sections 2 (package table), 9.2, 11 rule 7, 14.1-14.6, 15.4-15.9, 16, 17 (milestones, open questions), 18.1.
- SQLite adapter (all 22 files): Package.swift/.resolved, README.md, Sources (SQLiteSearchDatabase, SQLiteSearchConnection,
  ConfinedConnection, ChangeTracker, SQLParameterCounter, SQLiteBindings, SQLiteExpressions, BundleLocalizedStringResolver,
  ...), Tests (TestSupport, ConnectionTests, BindingTests, TransactionTests, ChangeStreamTests, ExpressionRenderingTests,
  IndexStoreTests, ReadmeSampleTests, EndToEndTests, BundleLocalizedStringResolverTests, DatabaseTargetsTests).
- MLX adapter: Package.swift, README.md, all 11 sources, Scripts/pin-qwen3-asset.swift and the verified JSON; tests read in
  full: ExecutorAndCancellationTests, MLXLanguageModelTests, Qwen3IntegrationTests, Qwen3AssetTests; skimmed (grep):
  GenerationLoopTests, ThinkBlockFilterTests, SamplingPlanTests, ChatCalibrationTests, LocalTokenizerTests, JSONConfigTests,
  Support/*.
- AssetKit adapter: Package.swift, README.md, all 8 sources; RealClientTests (about half); other tests by grep only.
- Core: DatabaseBoundary.swift, SearchSQLComposer.swift, SearchRowProjector.swift, DatabaseIndexStore.swift,
  SearchService+Context.swift, SearchService.swift (init), LanguageTag.swift, ChatBoundary.swift, ChatService.swift:200-215.
- CI: .github/workflows/adapter-tests.yml, ci.yml (parity.yml listed).
- Logs: c2-sqlite-adapter.log, c2-sqlite-release-targets.log, c2-assetkit-adapter.log.
- ZTronAssetKit (read only): Package.swift, EngineDispatch.swift:540-580, EngineSupport.swift:220-300,
  AssetStore+Publish.swift:60-140, EngineFailures.swift:30-110, EngineJobs.swift:140-200, :436-530,
  TransferUpdate.swift:55-90, NetworkPolicy.swift (defaults).
- mlx-swift-lm 3b339ad6 (SwiftPM cache, git show): Evaluate.swift (GenerateParameters), PrefillParameters.swift,
  LLMModel.swift, ModelFactory.swift, LLMModelFactory.swift (_load), Load.swift (loadWeights, weight discovery),
  Tokenizer.swift (NaiveStreamingDetokenizer); swift-transformers 1.4.0 Tokenizer.swift (applyChatTemplate).
- SQLite.swift 0.17.0: Statement.bind, Connection.init/sync.

## Not checked
- The AssetKit adapter's scripted-client tests (AvailabilityTests, FetchTests, PlanAndLaneTests, PolicyTests,
  SharingAndEvictionTests, Support/MemoryOrigin, Support/ScriptedAssetClient) were not read line by line; only names and
  weak-assertion patterns were grepped. Half of RealClientTests was not read.
- MLX unit tests other than the four read in full were only skimmed.
- No MLX test run exists in Verification/_runs (neither unit nor integration), so nothing about MLX was observed running;
  the 15.6 targets could not be measured here (no Qwen3 files, no device).
- The SQLite adapter under SQLite.swift 0.16.0 (CI matrix) was not exercised.
- Whether ZTronAssetKit's own claims beyond the lines cited (eviction, maintenance hashing, background session) hold.

STATUS: complete
