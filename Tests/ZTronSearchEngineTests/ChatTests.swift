import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, "Local chat": a fake runtime with a scripted token stream, delays and failures;
/// a fake asset provider scripted as available, missing, downloading, checksum failure and offline.
final class ChatTests: XCTestCase {
    typealias Chat = ChatService<CatalogSchema>

    private static let capable = ChatDeviceProfile(
        operatingSystem: OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 0),
        physicalMemory: 8 * 1024 * 1024 * 1024,
        freeDiskBytes: 64 * 1024 * 1024 * 1024,
        buildFingerprint: "app-1.0(1)|os-18.2"
    )

    private struct Harness {
        let facade: ZTronSearch<CatalogSchema>
        let chat: Chat
        let model: FakeLanguageModel
        let assets: FakeModelAssetProvider
        let store: FakeCalibrationStore
        let recorder: DiagnosticsRecorder
    }

    private func harness(
        available: Bool = true,
        availability: ChatAvailability = .on,
        device: ChatDeviceProfile = ChatTests.capable,
        contextWindow: Int = 4_096,
        maxNewTokens: Int = 512,
        idleUnload: TimeInterval = 120,
        locale: String = "en",
        configure: (inout ChatConfiguration) -> Void = { _ in }
    ) async -> Harness {
        let recorder = DiagnosticsRecorder()
        let search = await TestSupport.indexedService(TestSupport.catalog, configuration: TestSupport.configuration(locale: locale))
        let model = FakeLanguageModel(contextWindow: contextWindow)
        let assets = FakeModelAssetProvider(available: available)
        let store = FakeCalibrationStore()
        var configuration = ChatConfiguration(
            availability: availability,
            contextWindow: contextWindow,
            options: GenerationOptions(maxNewTokens: maxNewTokens),
            idleUnload: idleUnload,
            device: device,
            calibrationStore: store,
            diagnostics: recorder.sink
        )
        configure(&configuration)
        let facade = ZTronSearch(search: search, assets: assets, languageModel: model, chat: configuration)
        return Harness(facade: facade, chat: facade.chat!, model: model, assets: assets, store: store, recorder: recorder)
    }

    private static func readiness(_ chat: Chat, policy: DownloadPolicy = .wifiOnly) async -> [ChatReadiness] {
        var states: [ChatReadiness] = []
        for await state in await chat.prepare(policy: policy) { states.append(state) }
        return states
    }

    private struct Turn {
        var sources: [SearchHit<CatalogKind>] = []
        var text = ""
        var citations: [SearchableID] = []
        var usage: ChatUsage?
        var error: Error?
        var events = 0
    }

    private static func send(_ chat: Chat, _ text: String, in session: ChatSessionID) async -> Turn {
        var turn = Turn()
        do {
            for try await event in await chat.send(text, in: session) {
                turn.events += 1
                switch event {
                case .sources(let hits): turn.sources = hits
                case .delta(let delta): turn.text += delta
                case .citation(let id): turn.citations.append(id)
                case .finished(let usage): turn.usage = usage
                }
            }
        } catch {
            turn.error = error
        }
        return turn
    }

    // MARK: Facade

    func testChatIsNilWhenEitherBoundaryIsAbsent() async {
        let search = await TestSupport.indexedService(TestSupport.catalog)
        XCTAssertNil(ZTronSearch(search: search).chat)
        XCTAssertNil(ZTronSearch(search: search, assets: FakeModelAssetProvider()).chat)
        XCTAssertNil(ZTronSearch(search: search, languageModel: FakeLanguageModel()).chat)
        let wired = ZTronSearch(search: search, assets: FakeModelAssetProvider(), languageModel: FakeLanguageModel())
        XCTAssertNotNil(wired.chat)
        XCTAssertTrue(wired.search === search)
    }

    // MARK: Device gate

    func testTheIPhone6sProfileIsUnavailableWithoutTouchingTheAssetProvider() async {
        let harness = await harness(available: false, availability: .auto, device: .iPhone6s)
        let states = await Self.readiness(harness.chat)
        XCTAssertEqual(states, [.checking, .unavailable(.device)])
        let availabilityCalls = await harness.assets.availabilityCalls
        let fetchCalls = await harness.assets.fetchCalls
        let loadCalls = await harness.model.loadCalls
        XCTAssertEqual(availabilityCalls, 0)
        XCTAssertEqual(fetchCalls, 0)
        XCTAssertEqual(loadCalls, 0)
        let current = await harness.chat.readiness
        XCTAssertEqual(current, .unavailable(.device))

        // Sending is refused too, still without touching the provider.
        let session = await harness.chat.newSession()
        let turn = await Self.send(harness.chat, "where is the harbor", in: session)
        XCTAssertEqual(turn.error as? ChatError, .notReady(.unavailable(.device)))
        let after = await harness.assets.availabilityCalls
        XCTAssertEqual(after, 0)
    }

    func testTheGateNeedsBothTheOSAndTheMemory() async {
        var oldOS = Self.capable
        oldOS.operatingSystem = OperatingSystemVersion(majorVersion: 16, minorVersion: 7, patchVersion: 0)
        var smallMemory = Self.capable
        smallMemory.physicalMemory = 4 * 1024 * 1024 * 1024
        for device in [oldOS, smallMemory] {
            let harness = await harness(availability: .auto, device: device)
            let states = await Self.readiness(harness.chat)
            XCTAssertEqual(states.last, .unavailable(.device))
        }
        // .on and .off override the gate, for QA builds.
        let forced = await harness(availability: .on, device: .iPhone6s)
        let forcedStates = await Self.readiness(forced.chat)
        XCTAssertEqual(forcedStates.last, .ready)
        let off = await harness(availability: .off)
        let offStates = await Self.readiness(off.chat)
        XCTAssertEqual(offStates, [.checking, .unavailable(.disabled)])
        let touched = await off.assets.availabilityCalls
        XCTAssertEqual(touched, 0)
    }

    // MARK: Lifecycle

    func testAvailableLoads() async {
        let harness = await harness(available: true)
        let states = await Self.readiness(harness.chat)
        XCTAssertEqual(states, [.checking, .loading, .ready])
        let fetches = await harness.assets.fetchCalls
        let directory = await harness.model.loadedDirectories
        XCTAssertEqual(fetches, 0, "fetching is a no-op when the files are already on disk and verified")
        XCTAssertEqual(directory, [harness.assets.directory])
        // Preparing again when ready is immediate.
        let again = await Self.readiness(harness.chat)
        XCTAssertEqual(again, [.ready])
        let loads = await harness.model.loadCalls
        XCTAssertEqual(loads, 1)
    }

    func testMissingFetchesUnderTheDownloadPolicyThenLoads() async {
        let harness = await harness(available: false)
        let states = await Self.readiness(harness.chat, policy: .allowCellular)
        XCTAssertEqual(states.first, .checking)
        XCTAssertEqual(states.suffix(2), [.loading, .ready])
        let progress = states.compactMap { state -> Int64? in
            if case .downloading(let bytes, let total) = state {
                XCTAssertEqual(total, 1_000)
                return bytes
            }
            return nil
        }
        XCTAssertEqual(progress, progress.sorted(), "progress only grows")
        XCTAssertEqual(progress.last, 1_000)
        let policies = await harness.assets.policies
        XCTAssertEqual(policies, [.allowCellular])
    }

    func testPolicyNeverDoesNotDownload() async {
        let harness = await harness(available: false)
        let states = await Self.readiness(harness.chat, policy: .never)
        XCTAssertEqual(states, [.checking, .unavailable(.downloadNotAllowed)])
        let fetches = await harness.assets.fetchCalls
        XCTAssertEqual(fetches, 0)
    }

    func testFreeDiskMustBeTwiceTheAssetBeforeADownloadStarts() async {
        var device = Self.capable
        device.freeDiskBytes = 1_999   // the asset is 1,000 bytes
        let tight = await harness(available: false, device: device)
        let states = await Self.readiness(tight.chat)
        XCTAssertEqual(states, [.checking, .unavailable(.insufficientDisk)])
        let fetches = await tight.assets.fetchCalls
        XCTAssertEqual(fetches, 0)

        device.freeDiskBytes = 2_000
        let enough = await harness(available: false, device: device)
        let ready = await Self.readiness(enough.chat)
        XCTAssertEqual(ready.last, .ready)
    }

    func testRetryAfterAChecksumFailureReverifiesAndResumes() async {
        let harness = await harness(available: false)
        await harness.assets.queueFetch([.progress(900), .progress(80), .fail(.checksum)])
        let failed = await Self.readiness(harness.chat)
        XCTAssertEqual(failed.last, .unavailable(.assetFailed(.checksum)))
        XCTAssertEqual(UnavailableReason.assetFailed(.checksum).isRetryable, true)
        // The mismatched file was deleted; what was verified before it stays.
        let kept = await harness.assets.downloadedBytes()
        XCTAssertEqual(kept, 900)

        let retried = await Self.readiness(harness.chat)
        XCTAssertEqual(retried.last, .ready)
        let offsets = await harness.assets.resumeOffsets
        XCTAssertEqual(offsets, [0, 900], "a resumed fetch never re-downloads a verified file")
        let firstProgress = retried.compactMap { state -> Int64? in
            if case .downloading(let bytes, _) = state { return bytes }
            return nil
        }
        XCTAssertGreaterThanOrEqual(firstProgress.first ?? 0, 900)
    }

    func testResumeAfterAnInterruptedFetch() async {
        let harness = await harness(available: false)
        await harness.assets.queueFetch([.progress(400), .fail(.offline)])
        let failed = await Self.readiness(harness.chat)
        XCTAssertEqual(failed.last, .unavailable(.assetFailed(.offline)))
        let current = await harness.chat.readiness
        XCTAssertEqual(current, .unavailable(.assetFailed(.offline)))

        let resumed = await Self.readiness(harness.chat)
        XCTAssertEqual(resumed.last, .ready)
        let offsets = await harness.assets.resumeOffsets
        XCTAssertEqual(offsets, [0, 400])
        let loads = await harness.model.loadCalls
        XCTAssertEqual(loads, 1)
    }

    func testCancelDuringDownload() async {
        let harness = await harness(available: false)
        await harness.assets.queueFetch([.progress(300), .stall])
        let chat = harness.chat
        let task = Task { () -> [ChatReadiness] in
            var states: [ChatReadiness] = []
            for await state in await chat.prepare() { states.append(state) }
            return states
        }
        let downloading = await eventually { await harness.assets.downloadedBytes() == 300 }
        XCTAssertTrue(downloading)
        task.cancel()
        let states = await task.value
        XCTAssertFalse(states.contains(.ready))
        // The provider's stream is cancelled, and nothing is loaded.
        let cancelled = await eventually { await harness.assets.cancelledFetches == 1 }
        XCTAssertTrue(cancelled)
        let loads = await harness.model.loadCalls
        XCTAssertEqual(loads, 0)

        // The next prepare resumes from what was verified.
        let resumed = await Self.readiness(harness.chat)
        XCTAssertEqual(resumed.last, .ready)
        let offsets = await harness.assets.resumeOffsets
        XCTAssertEqual(offsets, [0, 300])
    }

    func testASecondPrepareAttachesToTheRunningFetch() async {
        let harness = await harness(available: false)
        await harness.assets.setStepDelay(seconds: 0.03)
        let chat = harness.chat
        async let first = Self.readiness(chat)
        async let second = Self.readiness(chat)
        async let third = Self.readiness(chat)
        let all = await [first, second, third]
        for states in all {
            XCTAssertEqual(states.last, .ready)
        }
        let fetches = await harness.assets.fetchCalls
        let loads = await harness.model.loadCalls
        XCTAssertEqual(fetches, 1, "attached to the running fetch instead of starting another")
        XCTAssertEqual(loads, 1)
    }

    func testALoadFailureAllowsARetry() async {
        let harness = await harness(available: true)
        await harness.model.setFailsLoad(true)
        let failed = await Self.readiness(harness.chat)
        XCTAssertEqual(failed, [.checking, .loading, .unavailable(.loadFailed)])
        await harness.model.setFailsLoad(false)
        let retried = await Self.readiness(harness.chat)
        XCTAssertEqual(retried.last, .ready)
        let fetches = await harness.assets.fetchCalls
        XCTAssertEqual(fetches, 0)
    }

    // MARK: Calibration

    func testCalibrationEnablesOnlyInsideItsThresholdsAndPersistsTheVerdict() async {
        // Fast enough: enabled, verdict stored.
        let fast = await harness(availability: .auto) { $0.maximumTimeToFirstToken = 1; $0.minimumTokensPerSecond = 8 }
        await fast.model.setReply((0..<64).map { " t\($0)" })
        let fastStates = await Self.readiness(fast.chat)
        XCTAssertEqual(fastStates.last, .ready)
        let stored = await fast.store.all()
        XCTAssertEqual(Array(stored.values), [true])
        let request = await fast.model.requests.first
        XCTAssertEqual(request?.options.maxNewTokens, 64, "decode 64")
        XCTAssertGreaterThanOrEqual(FakeLanguageModel.tokens(in: request?.messages.first?.content ?? ""), 480, "prefill about 512 tokens")

        // Decoding too slowly: 20 ms per token is 50 tokens/s, under a floor of 200.
        let slow = await harness(availability: .auto) { $0.minimumTokensPerSecond = 200 }
        await slow.model.setReply((0..<12).map { " t\($0)" })
        await slow.model.setTokenDelay(seconds: 0.02)
        let slowStates = await Self.readiness(slow.chat)
        XCTAssertEqual(slowStates.last, .unavailable(.device))
        let unloaded = await slow.model.unloadCalls
        XCTAssertEqual(unloaded, 1, "a model that fails calibration does not stay resident")

        // First token too late.
        let late = await harness(availability: .auto) { $0.maximumTimeToFirstToken = 0.05 }
        await late.model.setFirstTokenDelay(seconds: 0.2)
        let lateStates = await Self.readiness(late.chat)
        XCTAssertEqual(lateStates.last, .unavailable(.device))
        let verdicts = await late.store.all()
        XCTAssertEqual(Array(verdicts.values), [false])

        // The stored verdict is the gate from then on: the provider is not touched again.
        let before = await late.assets.availabilityCalls
        let again = await Self.readiness(late.chat)
        XCTAssertEqual(again, [.unavailable(.device)])
        let after = await late.assets.availabilityCalls
        XCTAssertEqual(after, before)
    }

    func testTheVerdictIsMeasuredOnceAndAgainAfterAnAppOrOSUpdate() async {
        let store = FakeCalibrationStore()
        func chat(fingerprint: String) async -> (Chat, FakeLanguageModel) {
            var device = Self.capable
            device.buildFingerprint = fingerprint
            let search = await TestSupport.indexedService(TestSupport.catalog)
            let model = FakeLanguageModel()
            let facade = ZTronSearch(
                search: search, assets: FakeModelAssetProvider(available: true), languageModel: model,
                chat: ChatConfiguration(availability: .auto, device: device, calibrationStore: store)
            )
            return (facade.chat!, model)
        }
        let (first, firstModel) = await chat(fingerprint: "app-1.0|os-18.2")
        _ = await Self.readiness(first)
        let measured = await firstModel.generateCalls
        XCTAssertEqual(measured, 1)

        // Same app and OS: the persisted verdict is reused, nothing is generated.
        let (second, secondModel) = await chat(fingerprint: "app-1.0|os-18.2")
        let reused = await Self.readiness(second)
        XCTAssertEqual(reused.last, .ready)
        let regenerated = await secondModel.generateCalls
        XCTAssertEqual(regenerated, 0)

        // After an update the verdict is measured again.
        let (third, thirdModel) = await chat(fingerprint: "app-1.1|os-18.2")
        _ = await Self.readiness(third)
        let remeasured = await thirdModel.generateCalls
        XCTAssertEqual(remeasured, 1)
        let keys = await store.all().count
        XCTAssertEqual(keys, 2)
    }

    // MARK: Turns

    func testSendRetrievesThenStreamsAndReportsUsage() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        await harness.model.setReply(["The harbor ", "map is ", "[map:map-harbor]", " here."])
        let session = await harness.chat.newSession()
        let turn = await Self.send(harness.chat, "frozen harbor", in: session)

        XCTAssertNil(turn.error)
        // Sources come first, kind-aware.
        XCTAssertEqual(turn.sources.first?.id, "map-harbor")
        XCTAssertEqual(turn.sources.first?.kind, .map)
        XCTAssertLessThanOrEqual(turn.sources.count, 6, "top K, default 6")
        XCTAssertEqual(turn.text, "The harbor map is  here.", "citation markers never reach the transcript text")
        XCTAssertEqual(turn.citations, ["map-harbor"])
        XCTAssertEqual(turn.usage?.generatedTokens, 4)
        XCTAssertEqual(turn.usage?.stopReason, .endOfTurn)

        // The prompt: instructions, the sources block, then the message.
        let request = await harness.model.requests.last
        XCTAssertEqual(request?.messages.first?.role, .system)
        XCTAssertEqual(request?.messages.last, ChatMessage(role: .user, content: "frozen harbor"))
        let system = request?.messages.first?.content ?? ""
        XCTAssertTrue(system.contains("Answer only from the sources"))
        XCTAssertTrue(system.contains("[kind:id]"))
        XCTAssertTrue(system.contains("[map:map-harbor] Frozen Harbor"))

        // History keeps what the model actually wrote.
        let history = await harness.chat.history(of: session)
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
        XCTAssertEqual(history.last?.content, "The harbor map is [map:map-harbor] here.")
    }

    func testHostSystemPromptComesFirstAndTheHostMayAppendPolicy() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        let session = await harness.chat.newSession(system: "You are the catalog guide. Never discuss prices.")
        _ = await Self.send(harness.chat, "harbor", in: session)
        let system = await harness.model.requests.last?.messages.first?.content ?? ""
        XCTAssertTrue(system.hasPrefix("You are the catalog guide. Never discuss prices."))
        XCTAssertTrue(system.contains("Answer only from the sources"))
    }

    func testGroundingHonoursTheSessionsKindsAndTopK() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        // "harbor" matches a map, a tip and an image; this session only reads tips and images.
        let session = await harness.chat.newSession(grounding: .corpus(topK: 1, kinds: [.tip, .image]))
        let turn = await Self.send(harness.chat, "harbor", in: session)
        XCTAssertEqual(turn.sources.count, 1)
        XCTAssertTrue(turn.sources.allSatisfy { $0.kind == .tip || $0.kind == .image })
        let all = await harness.chat.newSession(grounding: .corpus(topK: 6, kinds: [.tip, .image]))
        let wider = await Self.send(harness.chat, "harbor", in: all)
        XCTAssertEqual(Set(wider.sources.map(\.kind)), [.tip, .image])
        XCTAssertFalse(wider.sources.contains { $0.kind == .map })

        // No grounding: no retrieval, no sources block.
        let free = await harness.chat.newSession(grounding: .none)
        let ungrounded = await Self.send(harness.chat, "harbor", in: free)
        XCTAssertTrue(ungrounded.sources.isEmpty)
        XCTAssertEqual(ungrounded.events, 4, "three deltas and the usage; no sources event")
        let system = await harness.model.requests.last?.messages.first?.content ?? ""
        XCTAssertFalse(system.contains("Sources:"))
    }

    func testSourcesUseTheLocalizedSurface() async {
        let harness = await harness(locale: "it")
        _ = await Self.readiness(harness.chat)
        let session = await harness.chat.newSession()
        let turn = await Self.send(harness.chat, "porto ghiacciato", in: session)
        XCTAssertEqual(turn.sources.first?.id, "map-harbor")
        let system = await harness.model.requests.last?.messages.first?.content ?? ""
        XCTAssertTrue(system.contains("[map:map-harbor] Porto Ghiacciato, Mappa del porto"), system)
        XCTAssertFalse(system.contains("Frozen Harbor"))
    }

    func testEachSourceIsAtMostEightyTokens() async {
        let long = (0..<400).map { "word\($0)" }.joined(separator: " ")
        let search = await TestSupport.indexedService([AnySearchable(Tip(id: "long", title: "Lantern essay", text: long))])
        let model = FakeLanguageModel()
        let chat = ZTronSearch(
            search: search, assets: FakeModelAssetProvider(available: true), languageModel: model,
            chat: ChatConfiguration(availability: .on, device: Self.capable)
        ).chat!
        let session = await chat.newSession()
        _ = await Self.send(chat, "lantern", in: session)
        let system = await model.requests.last?.messages.first?.content ?? ""
        let source = system.components(separatedBy: "Sources:\n").last ?? ""
        XCTAssertTrue(source.hasPrefix("[tip:long] Lantern essay, word0 word1"))
        XCTAssertEqual(FakeLanguageModel.tokens(in: source), 80)
    }

    // MARK: Prompt budget

    func testHistoryIsTrimmedOldestFirstAndThePromptNeverExceedsTheWindow() async {
        // A small window: 400 tokens, 100 for the reply, 64 of margin: 236 for the prompt.
        let harness = await harness(contextWindow: 400, maxNewTokens: 100)
        _ = await Self.readiness(harness.chat)
        let session = await harness.chat.newSession(system: "Be brief.")
        await harness.model.setReply((0..<30).map { "reply\($0) " })

        for round in 0..<12 {
            let message = "harbor question number \(round) " + (0..<20).map { "filler\($0)" }.joined(separator: " ")
            let turn = await Self.send(harness.chat, message, in: session)
            XCTAssertNil(turn.error, "round \(round)")

            let request = await harness.model.requests.last!
            let promptTokens = request.messages.reduce(0) { $0 + FakeLanguageModel.tokens(in: $1.content) }
            XCTAssertLessThanOrEqual(promptTokens, 400 - 100 - 64, "round \(round): the prompt fits contextWindow - maxNewTokens - 64")
            XCTAssertLessThanOrEqual(promptTokens + request.options.maxNewTokens, 400, "no prompt ever exceeds the context window")
            // The message and the sources are never trimmed.
            XCTAssertEqual(request.messages.last?.content, message)
            XCTAssertTrue(request.messages.first?.content.contains("[map:map-harbor] Frozen Harbor") ?? false, "round \(round)")
            // History is: whatever is kept is the most recent, in order.
            let kept = request.messages.dropFirst().dropLast()
            let history = await harness.chat.history(of: session)
            let expected = history.dropLast(2).suffix(kept.count)
            XCTAssertEqual(Array(kept), Array(expected), "round \(round): history is trimmed from the oldest end")
            if round >= 4 {
                XCTAssertLessThan(kept.count, history.count - 2, "round \(round): something was trimmed")
            }
        }
        // The session itself keeps everything; only prompts are trimmed.
        let history = await harness.chat.history(of: session)
        XCTAssertEqual(history.count, 24)
    }

    func testAMessageThatCannotFitIsRefusedRatherThanTrimmed() async {
        let harness = await harness(contextWindow: 300, maxNewTokens: 100)
        _ = await Self.readiness(harness.chat)
        let session = await harness.chat.newSession()
        let huge = (0..<500).map { "w\($0)" }.joined(separator: " ")
        let turn = await Self.send(harness.chat, huge, in: session)
        guard case .messageTooLong(let required, let budget)? = turn.error as? ChatError else {
            return XCTFail("expected messageTooLong, got \(String(describing: turn.error))")
        }
        XCTAssertGreaterThan(required, budget)
        XCTAssertEqual(budget, 300 - 100 - 64)
        let generated = await harness.model.generateCalls
        XCTAssertEqual(generated, 0, "nothing over the window ever reaches the runtime")
    }

    func testPromptAssemblerOrderAndTrimming() async throws {
        let count: (String) async -> Int = { FakeLanguageModel.tokens(in: $0) }
        let history = (0..<6).flatMap { [ChatMessage(role: .user, content: "question \($0) a b c"), ChatMessage(role: .assistant, content: "answer \($0) d e f")] }
        let roomy = try await PromptAssembler(budget: 1_000, countTokens: count).assemble(
            system: "Host prompt.", sources: ["[map:a] A", "[tip:b] B"], grounded: true, history: history, message: "now what"
        )
        XCTAssertEqual(roomy.droppedHistory, 0)
        XCTAssertEqual(roomy.messages.count, 14)
        XCTAssertTrue(roomy.messages[0].content.hasPrefix("Host prompt.\n\n"))
        XCTAssertTrue(roomy.messages[0].content.hasSuffix("Sources:\n[map:a] A\n[tip:b] B"))
        XCTAssertEqual(roomy.promptTokens, roomy.messages.reduce(0) { $0 + FakeLanguageModel.tokens(in: $1.content) })

        let fixed = FakeLanguageModel.tokens(in: roomy.messages[0].content) + 2
        // Room for exactly the three most recent history messages (5 tokens each).
        let tight = try await PromptAssembler(budget: fixed + 15, countTokens: count).assemble(
            system: "Host prompt.", sources: ["[map:a] A", "[tip:b] B"], grounded: true, history: history, message: "now what"
        )
        XCTAssertEqual(tight.droppedHistory, 9)
        XCTAssertEqual(Array(tight.messages.dropFirst().dropLast()), Array(history.suffix(3)))
        XCTAssertEqual(tight.promptTokens, fixed + 15)

        do {
            _ = try await PromptAssembler(budget: fixed - 1, countTokens: count).assemble(
                system: "Host prompt.", sources: ["[map:a] A", "[tip:b] B"], grounded: true, history: history, message: "now what"
            )
            XCTFail("the fixed part does not fit")
        } catch let failure as PromptAssembler.Failure {
            XCTAssertEqual(failure, .exceedsBudget(required: fixed, budget: fixed - 1))
        }
    }

    // MARK: Citations

    private func parse(_ deltas: [String], sources: Set<SearchableID> = ["map-harbor", "tip-doors"]) -> [CitationParser.Output] {
        var parser = CitationParser(sources: sources) { CatalogKind(rawValue: $0) != nil }
        var outputs: [CitationParser.Output] = []
        for delta in deltas { outputs.append(contentsOf: parser.consume(delta)) }
        outputs.append(contentsOf: parser.finish())
        // Adjacent text pieces are one piece as far as the transcript is concerned.
        var merged: [CitationParser.Output] = []
        for output in outputs {
            if case .text(let text) = output, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + text)
            } else {
                merged.append(output)
            }
        }
        return merged
    }

    func testCitationsAreParsedIncrementally() {
        XCTAssertEqual(parse(["See [map:map-harbor] now."]), [.text("See "), .citation("map-harbor"), .text(" now.")])
        // The marker straddles every possible boundary.
        let whole = "A [map:map-harbor] and [tip:tip-doors]."
        for size in 1...7 {
            var pieces: [String] = []
            var rest = Substring(whole)
            while !rest.isEmpty {
                pieces.append(String(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            XCTAssertEqual(parse(pieces), [.text("A "), .citation("map-harbor"), .text(" and "), .citation("tip-doors"), .text(".")], "pieces of \(size)")
        }
    }

    func testUnknownIDsAreDroppedAndOrdinaryBracketsPassThrough() {
        // An id that is not among the sources: dropped, reported.
        XCTAssertEqual(parse(["Try [map:atlantis] or [game:nowhere]."]), [.text("Try "), .unknown("atlantis"), .text(" or "), .unknown("nowhere"), .text(".")])
        // Not citations: the kind is not one of the schema's, or there is no kind at all.
        XCTAssertEqual(parse(["Step [1] of [note:x], see [link](http://x) and [a b"]), [.text("Step [1] of [note:x], see [link](http://x) and [a b")])
        XCTAssertEqual(parse(["[", "[map:map-harbor]", "]"]), [.text("["), .citation("map-harbor"), .text("]")])
        // An unterminated marker at the end of the stream is released as text.
        XCTAssertEqual(parse(["ends with [map:map-har"]), [.text("ends with [map:map-har")])
        // A line break ends any marker attempt.
        XCTAssertEqual(parse(["[map:\nmap-harbor]"]), [.text("[map:\nmap-harbor]")])
        // Whitespace inside the marker is tolerated.
        XCTAssertEqual(parse(["[ map : map-harbor ]"]), [.citation("map-harbor")])
    }

    func testOnlySourcesOfTheTurnCanBeCitedAndUnknownOnesAreLogged() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        await harness.model.setReply(["Use ", "[tool:tool-timer]", " or ", "[map:atlantis]", " or ", "[tool:tool-calc]", "."])
        // Only the timer tool is retrieved for this message.
        let session = await harness.chat.newSession(grounding: .corpus(topK: 6, kinds: [.tool]))
        let turn = await Self.send(harness.chat, "timer", in: session)
        XCTAssertTrue(turn.sources.contains { $0.id == "tool-timer" })
        XCTAssertFalse(turn.sources.contains { $0.id == "tool-calc" })
        XCTAssertEqual(turn.citations, ["tool-timer"], "a citation is emitted only when the id is among the sources")
        XCTAssertEqual(turn.text, "Use  or  or .")
        let diagnostics = await harness.recorder.finish()
        XCTAssertEqual(diagnostics.filter { if case .unknownCitation = $0 { return true } else { return false } },
                       [.unknownCitation(id: "atlantis"), .unknownCitation(id: "tool-calc")])
    }

    // MARK: One generation at a time

    func testOtherSessionsQueue() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        await harness.model.setTokenDelay(seconds: 0.01)
        await harness.model.setReply((0..<10).map { "t\($0) " })
        let chat = harness.chat
        var sessions: [ChatSessionID] = []
        for _ in 0..<4 { sessions.append(await chat.newSession()) }
        let ordered = sessions
        let turns = await withTaskGroup(of: (Int, Bool).self, returning: [Bool].self) { group in
            for (index, session) in ordered.enumerated() {
                group.addTask {
                    var finished = false
                    do {
                        for try await event in await chat.send("harbor \(index)", in: session) {
                            if case .finished = event { finished = true }
                        }
                    } catch {}
                    return (index, finished)
                }
            }
            var results = [Bool](repeating: false, count: ordered.count)
            for await (index, finished) in group { results[index] = finished }
            return results
        }
        XCTAssertEqual(turns, [true, true, true, true], "every session completes")
        let concurrent = await harness.model.maximumConcurrentGenerations
        let generations = await harness.model.generateCalls
        XCTAssertEqual(concurrent, 1, "one generation at a time on the device")
        XCTAssertEqual(generations, 4)
    }

    func testANewSendInTheSameSessionCancelsTheOneInFlight() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        await harness.model.setTokenDelay(seconds: 0.05)
        await harness.model.queueReplies([(0..<200).map { "slow\($0) " }, ["fast ", "answer"]])
        let chat = harness.chat
        let session = await chat.newSession()

        let first = Task { await Self.send(chat, "harbor one", in: session) }
        let generating = await eventually { await harness.model.generateCalls == 1 }
        XCTAssertTrue(generating)
        let second = await Self.send(chat, "harbor two", in: session)
        let cancelled = await first.value

        XCTAssertTrue(cancelled.error is CancellationError, "the turn in flight is cancelled")
        XCTAssertNil(cancelled.usage)
        XCTAssertNil(second.error)
        XCTAssertEqual(second.text, "fast answer")
        let cancelledGenerations = await harness.model.cancelledGenerations
        let concurrent = await harness.model.maximumConcurrentGenerations
        XCTAssertEqual(cancelledGenerations, 1)
        XCTAssertEqual(concurrent, 1)
    }

    func testCancelDuringGenerationStopsWithinOneToken() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        await harness.model.setTokenDelay(seconds: 0.02)
        await harness.model.setReply((0..<500).map { "t\($0) " })
        let chat = harness.chat
        let session = await chat.newSession()
        let task = Task { await Self.send(chat, "harbor", in: session) }
        let streaming = await eventually { await harness.model.generateCalls == 1 }
        XCTAssertTrue(streaming)
        try? await Task.sleep(nanoseconds: 80_000_000)

        let cancelledAt = Date()
        await chat.cancel(session)
        let turn = await task.value
        let latency = Date().timeIntervalSince(cancelledAt)
        XCTAssertLessThan(latency, 0.150, "generation stops within one token, at most 150 ms (took \(latency * 1000) ms)")
        XCTAssertTrue(turn.error is CancellationError)
        XCTAssertFalse(turn.text.isEmpty)
        XCTAssertLessThan(turn.text.split(separator: " ").count, 40)
        // What was said before the cancel stays in the session.
        let history = await chat.history(of: session)
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
        // And the service is free again.
        await harness.model.setTokenDelay(seconds: 0)
        await harness.model.setReply(["ok"])
        let next = await Self.send(chat, "harbor again", in: session)
        XCTAssertEqual(next.text, "ok")
    }

    func testAGenerationFailureIsReportedAndTheServiceRecovers() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        await harness.model.setReply((0..<10).map { "t\($0) " })
        await harness.model.setFailsAfterTokens(3)
        let session = await harness.chat.newSession()
        let failed = await Self.send(harness.chat, "harbor", in: session)
        guard case .generationFailed? = failed.error as? ChatError else { return XCTFail("expected generationFailed") }
        XCTAssertEqual(failed.text, "t0 t1 t2 ")
        await harness.model.setFailsAfterTokens(nil)
        let recovered = await Self.send(harness.chat, "harbor", in: session)
        XCTAssertNil(recovered.error)
        let unknown = await Self.send(harness.chat, "harbor", in: ChatSessionID())
        XCTAssertEqual(unknown.error as? ChatError, .unknownSession)
    }

    // MARK: Unloading

    func testTheModelLoadsLazilyOnTheFirstSendAndNeverDownloadsFromThere() async {
        let harness = await harness(available: true)
        let session = await harness.chat.newSession()
        let before = await harness.model.loadCalls
        XCTAssertEqual(before, 0)
        let turn = await Self.send(harness.chat, "harbor", in: session)
        XCTAssertNil(turn.error)
        let after = await harness.model.loadCalls
        XCTAssertEqual(after, 1)

        // Files missing: a send never starts a download; that takes prepare(policy:).
        let missing = await self.harness(available: false)
        let other = await missing.chat.newSession()
        let refused = await Self.send(missing.chat, "harbor", in: other)
        XCTAssertEqual(refused.error as? ChatError, .notReady(.unavailable(.downloadNotAllowed)))
        let fetches = await missing.assets.fetchCalls
        XCTAssertEqual(fetches, 0)
    }

    func testUnloadAfterIdleKeepsFilesAndHistory() async {
        let harness = await harness(idleUnload: 0.15)
        _ = await Self.readiness(harness.chat)
        let session = await harness.chat.newSession()
        _ = await Self.send(harness.chat, "harbor one", in: session)
        let early = await harness.model.unloadCalls
        XCTAssertEqual(early, 0)

        let unloaded = await eventually { await harness.model.unloadCalls == 1 }
        XCTAssertTrue(unloaded, "unloads after the idle interval")
        let historyAfterUnload = await harness.chat.history(of: session)
        XCTAssertEqual(historyAfterUnload.count, 2, "a session keeps its history across unloads")

        // The next message only reloads the weights: no availability check, no fetch.
        let availabilityBefore = await harness.assets.availabilityCalls
        let turn = await Self.send(harness.chat, "harbor two", in: session)
        XCTAssertNil(turn.error)
        let loads = await harness.model.loadCalls
        let availabilityAfter = await harness.assets.availabilityCalls
        let fetches = await harness.assets.fetchCalls
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(availabilityAfter, availabilityBefore)
        XCTAssertEqual(fetches, 0)
        // The reloaded model sees the earlier exchange.
        let request = await harness.model.requests.last
        XCTAssertEqual(request?.messages.map(\.role), [.system, .user, .assistant, .user])
    }

    func testUnloadOnMemoryWarningAndOnDemand() async {
        let harness = await harness()
        _ = await Self.readiness(harness.chat)
        let session = await harness.chat.newSession()
        _ = await Self.send(harness.chat, "harbor", in: session)

        NotificationCenter.default.post(name: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil)
        let warned = await eventually { await harness.model.unloadCalls == 1 }
        XCTAssertTrue(warned, "a memory warning unloads the model")
        let current = await harness.chat.readiness
        XCTAssertEqual(current, .ready, "on disk: the files are kept, and the next message only reloads the weights")

        _ = await Self.send(harness.chat, "harbor", in: session)
        await harness.chat.unload()
        let unloads = await harness.model.unloadCalls
        XCTAssertEqual(unloads, 2)
        let history = await harness.chat.history(of: session)
        XCTAssertEqual(history.count, 4)
    }

    func testTheLanguageModelUnloadsBeforeTheEmbeddingModelOnAMemoryWarning() async {
        actor Order {
            var events: [String] = []
            func note(_ event: String) { events.append(event) }
        }
        let order = Order()
        actor OrderedSemantic: SemanticSearching {
            nonisolated let modelID = "ordered"
            nonisolated let dimensions = 2
            let order: Order
            init(order: Order) { self.order = order }
            func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] { [1, 0] }
            func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] { [] }
            func upsert(_ vectors: [SearchableID: [Float]]) async throws {}
            func remove(_ ids: [SearchableID]) async {}
            func unload() async { await order.note("embedding") }
        }
        let search = await TestSupport.indexedService(TestSupport.catalog, semantic: OrderedSemantic(order: order))
        let model = FakeLanguageModel()
        let facade = ZTronSearch(
            search: search, assets: FakeModelAssetProvider(available: true), languageModel: model,
            chat: ChatConfiguration(availability: .on, device: Self.capable)
        )
        let session = await facade.chat!.newSession()
        _ = await Self.send(facade.chat!, "harbor", in: session)
        // The facade wires the order asynchronously; wait until it is in place.
        _ = await eventually { await search.memoryWarningPredecessor != nil }

        await search.handleMemoryWarning()
        let modelUnloads = await model.unloadCalls
        XCTAssertEqual(modelUnloads, 1)
        let events = await order.events
        XCTAssertEqual(events, ["embedding"])
        // The language model was already unloaded when the embedding model was told to.
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
    }
}
