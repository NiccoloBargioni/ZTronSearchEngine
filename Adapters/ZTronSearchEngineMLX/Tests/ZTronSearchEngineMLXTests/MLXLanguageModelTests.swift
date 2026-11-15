import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

// These tests need no weights and never reach MLX: every load fails at the directory check, and
// an instance that never loaded a model must leave MLX untouched.

extension MLXLanguageModel {
    /// Occupies the runtime's thread until `gate` is signalled, so a test can line up work behind it.
    fileprivate func hold(onStart: @Sendable () -> Void, until gate: DispatchSemaphore) {
        onStart()
        gate.wait()
    }

    /// The name of the thread actor-isolated code runs on.
    fileprivate var currentThreadName: String? {
        Thread.current.name
    }

    /// Drives the token loop from isolated code the way a generation does, with scripted tokens
    /// in place of the model: closures that capture local state, each inside its own pool.
    fileprivate func runScriptedLoop(tokens: [Int], texts: [Int: String], stop: Int) -> (text: String, outcome: GenerationLoop.Outcome, thread: String?) {
        var position = 0
        var text = ""
        let outcome = GenerationLoop.run(
            tokenBudget: 64,
            nextToken: {
                autoreleasepool {
                    guard position < tokens.count else { return nil }
                    defer { position += 1 }
                    return tokens[position]
                }
            },
            isStopToken: { $0 == stop },
            detokenize: { token in autoreleasepool { texts[token] } },
            isCancelled: { Task.isCancelled },
            emit: { text += $0; return true }
        )
        return (text, outcome, Thread.current.name)
    }
}

final class MLXLanguageModelTests: XCTestCase {
    private let asset = ModelAsset(
        id: "test-asset",
        revision: "v1",
        files: [ModelFile(name: "model.safetensors", byteCount: 11, sha256: String(repeating: "0", count: 64))]
    )

    private func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func assertLoadFails(
        _ model: MLXLanguageModel,
        from directory: URL,
        with expected: MLXLanguageModelError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await model.load(from: directory)
            XCTFail("load succeeded", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MLXLanguageModelError, expected, file: file, line: line)
        }
        let isLoaded = await model.isLoaded
        XCTAssertFalse(isLoaded, file: file, line: line)
    }

    // MARK: - Descriptor

    func testDescriptorValues() {
        let model = MLXLanguageModel(asset: asset)
        XCTAssertEqual(model.descriptor.asset, asset)
        XCTAssertEqual(model.descriptor.contextWindow, 4_096)
        XCTAssertEqual(model.descriptor.minimumPhysicalMemory, 6 * 1_024 * 1_024 * 1_024)
        // iOS 17.0 is the floor the specification names. A Mac reports its macOS version, and
        // there the floor of mlx-swift is 14.0.
        #if os(macOS)
            XCTAssertEqual(model.descriptor.minimumOS.majorVersion, 14)
        #else
            XCTAssertEqual(model.descriptor.minimumOS.majorVersion, 17)
        #endif
        XCTAssertEqual(model.descriptor.minimumOS.minorVersion, 0)
        XCTAssertEqual(model.descriptor.minimumOS.patchVersion, 0)
        XCTAssertEqual(model.descriptor, MLXLanguageModel.descriptor(for: asset))
    }

    func testThisMachinePassesTheOSFloor() {
        // The package cannot even load below its floor, so the process always satisfies it.
        let floor = MLXLanguageModel.descriptor(for: asset).minimumOS
        XCTAssertTrue(ProcessInfo.processInfo.isOperatingSystemAtLeast(floor))
    }

    func testDescriptorIsWhatTheCallerPasses() {
        let descriptor = LanguageModelDescriptor(
            asset: asset,
            contextWindow: 2_048,
            minimumPhysicalMemory: 8 * 1_024 * 1_024 * 1_024,
            minimumOS: OperatingSystemVersion(majorVersion: 18, minorVersion: 1, patchVersion: 0)
        )
        XCTAssertEqual(MLXLanguageModel(descriptor: descriptor).descriptor, descriptor)
        XCTAssertEqual(MLXLanguageModel(asset: asset, contextWindow: 8_192).descriptor.contextWindow, 8_192)
    }

    func testReferenceDeviceOfTheSpecificationFailsTheMemoryFloor() {
        // The iPhone 6s (2 GB, iOS 15.8) must never get past the gate (specification section 14.4).
        let descriptor = MLXLanguageModel.descriptor(for: asset)
        let device = ChatDeviceProfile.iPhone6s
        XCTAssertLessThan(device.physicalMemory, descriptor.minimumPhysicalMemory)
        #if !os(macOS)
            XCTAssertLessThan(device.operatingSystem.majorVersion, descriptor.minimumOS.majorVersion)
        #endif
    }

    func testTuningDefaults() {
        XCTAssertEqual(MLXLanguageModel.Tuning.default.bufferCacheLimit, 32 * 1_024 * 1_024)
        XCTAssertNil(MLXLanguageModel.Tuning.default.prefillStepSize)
        let tuning = MLXLanguageModel.Tuning(bufferCacheLimit: nil, prefillStepSize: 128)
        XCTAssertEqual(MLXLanguageModel(asset: asset, tuning: tuning).tuning, tuning)
    }

    // MARK: - Loading

    func testLoadFailsForAMissingDirectory() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        await assertLoadFails(MLXLanguageModel(asset: asset), from: missing, with: .directoryNotFound(missing.standardizedFileURL.path))
    }

    func testLoadFailsForAFileInsteadOfADirectory() async throws {
        let directory = try ModelDirectoryFixture.make(for: self)
        let file = directory.appendingPathComponent("config.json")
        await assertLoadFails(MLXLanguageModel(asset: asset), from: file, with: .directoryNotFound(file.standardizedFileURL.path))
    }

    func testLoadNamesTheMissingFiles() async throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.tokenizer = false
        layout.tokenizerConfig = false
        let directory = try ModelDirectoryFixture.make(layout, for: self)
        await assertLoadFails(
            MLXLanguageModel(asset: asset),
            from: directory,
            with: .missingFiles(["tokenizer.json", "tokenizer_config.json"])
        )

        var withoutConfig = ModelDirectoryFixture.Layout()
        withoutConfig.config = false
        await assertLoadFails(
            MLXLanguageModel(asset: asset),
            from: try ModelDirectoryFixture.make(withoutConfig, for: self),
            with: .missingFiles(["config.json"])
        )
    }

    func testLoadFailsForAnEmptyDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        await assertLoadFails(
            MLXLanguageModel(asset: asset),
            from: directory,
            with: .missingFiles(["config.json", "tokenizer.json", "tokenizer_config.json"])
        )
    }

    func testLoadFailsWithoutWeights() async throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.weights = false
        await assertLoadFails(
            MLXLanguageModel(asset: asset),
            from: try ModelDirectoryFixture.make(layout, for: self),
            with: .missingWeights
        )
    }

    func testLoadFailsWithoutAChatTemplate() async throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.inlineChatTemplate = nil
        await assertLoadFails(
            MLXLanguageModel(asset: asset),
            from: try ModelDirectoryFixture.make(layout, for: self),
            with: .missingChatTemplate
        )
    }

    func testLoadFailsForAMalformedGenerationConfig() async throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.generationConfig = "[\"not an object\"]"
        await assertLoadFails(
            MLXLanguageModel(asset: asset),
            from: try ModelDirectoryFixture.make(layout, for: self),
            with: .invalidGenerationConfig("the top level is not a JSON object")
        )
    }

    func testFailedLoadCanBeRetried() async throws {
        let model = MLXLanguageModel(asset: asset)
        var layout = ModelDirectoryFixture.Layout()
        layout.weights = false
        let directory = try ModelDirectoryFixture.make(layout, for: self)
        await assertLoadFails(model, from: directory, with: .missingWeights)
        // The failure left no half-loaded state behind: the same call fails the same way.
        await assertLoadFails(model, from: directory, with: .missingWeights)
    }

    func testConcurrentLoadsOfTheSameDirectoryShareOneFailure() async throws {
        let model = MLXLanguageModel(asset: asset)
        var layout = ModelDirectoryFixture.Layout()
        layout.weights = false
        let directory = try ModelDirectoryFixture.make(layout, for: self)
        await withTaskGroup(of: MLXLanguageModelError?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    do {
                        try await model.load(from: directory)
                        return nil
                    } catch {
                        return error as? MLXLanguageModelError
                    }
                }
            }
            for await error in group {
                XCTAssertEqual(error, .missingWeights)
            }
        }
    }

    // MARK: - Without a model

    func testUnloadWithoutAModelIsHarmless() async {
        let model = MLXLanguageModel(asset: asset)
        await model.unload()
        await model.unload()
        let isLoaded = await model.isLoaded
        XCTAssertFalse(isLoaded)
    }

    func testGenerateWithoutAModelThrowsNotLoaded() async {
        let model = MLXLanguageModel(asset: asset)
        let stream = model.generate(GenerationRequest(messages: [ChatMessage(role: .user, content: "Hello")]))
        do {
            let events = try await collect(stream)
            XCTFail("the stream ended without an error: \(events)")
        } catch {
            XCTAssertEqual(error as? MLXLanguageModelError, .notLoaded)
        }
    }

    func testCountTokensBeforeAnyLoadIsTheUTF8UpperBound() async {
        let model = MLXLanguageModel(asset: asset)
        let empty = await model.countTokens("")
        XCTAssertEqual(empty, 0)
        let ascii = await model.countTokens("hello")
        XCTAssertEqual(ascii, 5)
        let accented = await model.countTokens("città")
        XCTAssertEqual(accented, 6)
    }

    func testCalibrationWithoutAModelThrowsNotLoaded() async {
        let model = MLXLanguageModel(asset: asset)
        do {
            _ = try await model.calibrate()
            XCTFail("calibration succeeded without a model")
        } catch {
            XCTAssertEqual(error as? MLXLanguageModelError, .notLoaded)
        }
    }

    // MARK: - Thread

    func testActorRunsOnItsOwnThread() async {
        let model = MLXLanguageModel(asset: asset)
        let name = await model.currentThreadName
        XCTAssertEqual(name, "ZTronSearchEngineMLX.MLXLanguageModel")
    }

    func testTokenLoopRunsOnTheRuntimeThread() async {
        let model = MLXLanguageModel(asset: asset)
        let result = await model.runScriptedLoop(
            tokens: [1, 2, 3, 4, 0],
            texts: [1: "<think>", 2: "hm", 3: "</think>", 4: "Hi"],
            stop: 0
        )
        XCTAssertEqual(result.text, "Hi")
        XCTAssertEqual(result.outcome, .init(generatedTokens: 4, stopReason: .endOfTurn))
        XCTAssertEqual(result.thread, "ZTronSearchEngineMLX.MLXLanguageModel")
    }

    // MARK: - Cancellation

    func testGenerationCancelledBeforeItStartsFinishesAsCancelled() async throws {
        let model = MLXLanguageModel(asset: asset)
        let gate = DispatchSemaphore(value: 0)
        // Occupy the runtime's thread so the generation has to wait behind this job.
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            Task {
                await model.hold(onStart: { started.resume() }, until: gate)
            }
        }

        let stream = model.generate(GenerationRequest(messages: [ChatMessage(role: .user, content: "Hello")]))
        XCTAssertEqual(model.generations.count, 1)
        model.cancelGenerations()
        gate.signal()

        let events = try await collect(stream)
        XCTAssertEqual(events, [.usage(prompt: 0, generated: 0), .finished(.cancelled)])
    }

    func testUnloadCancelsWaitingGenerations() async throws {
        let model = MLXLanguageModel(asset: asset)
        let gate = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            Task {
                await model.hold(onStart: { started.resume() }, until: gate)
            }
        }

        let stream = model.generate(GenerationRequest(messages: [ChatMessage(role: .user, content: "Hello")]))
        // `unload()` flags every generation before it queues behind the held thread; the gate
        // opens only after that, so the generation sees the flag when it finally runs.
        let unload = Task { await model.unload() }
        let deadline = Date().addingTimeInterval(5)
        while !model.generations.isEveryGenerationCancelled, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(model.generations.isEveryGenerationCancelled)
        gate.signal()

        let events = try await collect(stream)
        XCTAssertEqual(events, [.usage(prompt: 0, generated: 0), .finished(.cancelled)])
        await unload.value
    }

    func testFinishedGenerationsAreForgotten() async throws {
        let model = MLXLanguageModel(asset: asset)
        for _ in 0 ..< 3 {
            let stream = model.generate(GenerationRequest(messages: [ChatMessage(role: .user, content: "Hello")]))
            _ = try? await collect(stream)
        }
        let deadline = Date().addingTimeInterval(5)
        while model.generations.count > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.generations.count, 0)
    }

    func testAbandonedStreamCancelsItsGeneration() async throws {
        let model = MLXLanguageModel(asset: asset)
        let gate = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            Task {
                await model.hold(onStart: { started.resume() }, until: gate)
            }
        }

        // The consumer drops the stream without ever iterating it.
        _ = model.generate(GenerationRequest(messages: [ChatMessage(role: .user, content: "Hello")]))
        let deadline = Date().addingTimeInterval(5)
        while !model.generations.isEveryGenerationCancelled, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(model.generations.isEveryGenerationCancelled)
        gate.signal()
    }
}
