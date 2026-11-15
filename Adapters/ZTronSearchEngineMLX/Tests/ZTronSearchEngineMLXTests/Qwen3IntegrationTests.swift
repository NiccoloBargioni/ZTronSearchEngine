import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

/// Runs the real model against the targets of specification section 15.6.
///
/// These tests need the files of `mlx-community/Qwen3-1.7B-4bit` at the pinned revision and a
/// build with MLX's Metal shaders, so they run through `xcodebuild` on an Apple-silicon Mac:
///
///     TEST_RUNNER_ZTRON_QWEN3_DIR=/path/to/Qwen3-1.7B-4bit \
///       xcodebuild test -scheme ZTronSearchEngineMLX -destination 'platform=macOS'
///
/// Without `ZTRON_QWEN3_DIR` every test is skipped.
final class Qwen3IntegrationTests: XCTestCase {
    private static let directoryVariable = "ZTRON_QWEN3_DIR"

    /// The runtime never reads the asset's file list, so an empty one keeps these tests
    /// independent of whether the two small checksums have been pinned yet.
    private static let asset = ModelAsset(id: Qwen3Asset.id, revision: Qwen3Asset.revision, files: [])

    private let clock = ContinuousClock()

    // MARK: - Support

    /// The directory named by `ZTRON_QWEN3_DIR`; skips the test when the variable is not set.
    private func localCopy() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[Self.directoryVariable], !path.isEmpty else {
            throw XCTSkip(
                "Set \(Self.directoryVariable) to a local copy of \(Qwen3Asset.repository) at revision "
                    + "\(Qwen3Asset.revision) to run the integration tests "
                    + "(with xcodebuild: TEST_RUNNER_\(Self.directoryVariable)=<directory>)."
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The directory to load the model from; also skips when this build cannot evaluate MLX.
    private func modelDirectory() throws -> URL {
        let directory = try localCopy()
        guard Self.metalLibraryIsBuilt else {
            throw XCTSkip(
                "MLX's Metal shaders (default.metallib) are not part of this build, so MLX cannot evaluate. "
                    + "SwiftPM's legacy build system skips them: run the integration tests through xcodebuild."
            )
        }
        return directory
    }

    /// Whether the compiled Metal library MLX needs is where MLX looks for it: inside
    /// `mlx-swift_Cmlx.bundle` in the resources of a loaded bundle, or next to the test binary.
    /// Without it the first MLX call ends the process, which would hide every other result.
    private static let metalLibraryIsBuilt: Bool = {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        let resourceRoots = [Bundle.main.bundleURL]
            + Bundle.allBundles.compactMap(\.resourceURL)
            + Bundle.allFrameworks.compactMap(\.resourceURL)
        for root in resourceRoots {
            if let resources = Bundle(url: root.appendingPathComponent("mlx-swift_Cmlx.bundle"))?.resourceURL {
                candidates.append(resources.appendingPathComponent("default.metallib"))
            }
        }
        if let binaryDirectory = Bundle(for: Qwen3IntegrationTests.self).executableURL?.deletingLastPathComponent() {
            candidates += ["mlx.metallib", "Resources/mlx.metallib", "Resources/default.metallib", "default.metallib"]
                .map { binaryDirectory.appendingPathComponent($0) }
        }
        return candidates.contains { fileManager.fileExists(atPath: $0.path) }
    }()

    private func loadedModel(tuning: MLXLanguageModel.Tuning = .default) async throws -> MLXLanguageModel {
        let directory = try modelDirectory()
        let model = MLXLanguageModel(asset: Self.asset, tuning: tuning)
        try await model.load(from: directory)
        addTeardownBlock {
            await model.unload()
        }
        return model
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// The outcome of one generation, with its events in order.
    private struct Reply {
        var events: [GenerationEvent] = []
        var text = ""
        var promptTokens = 0
        var generatedTokens = 0
        var stopReason: StopReason?
    }

    private func reply(
        from model: MLXLanguageModel,
        to prompt: String,
        system: String? = nil,
        options: GenerationOptions = .default
    ) async throws -> Reply {
        var messages: [ChatMessage] = []
        if let system {
            messages.append(ChatMessage(role: .system, content: system))
        }
        messages.append(ChatMessage(role: .user, content: prompt))

        var reply = Reply()
        for try await event in model.generate(GenerationRequest(messages: messages, options: options)) {
            reply.events.append(event)
            switch event {
            case .delta(let text):
                reply.text += text
            case .usage(let prompt, let generated):
                reply.promptTokens = prompt
                reply.generatedTokens = generated
            case .finished(let reason):
                reply.stopReason = reason
            }
        }
        return reply
    }

    /// The value below which `fraction` of the sorted samples fall (nearest rank).
    private func percentile(_ fraction: Double, of samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    #if os(macOS)
        /// The footprint the OS charges to this process, GPU buffers included.
        private func physicalFootprint() -> UInt64? {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0 ? usage.ri_phys_footprint : nil
        }
    #endif

    // MARK: - The asset

    /// The local copy is the pinned revision, byte for byte. The log carries the complete
    /// manifest, including the two SHA-256 values Hugging Face does not publish.
    ///
    /// This test only hashes files, so it also runs in a build without the Metal shaders.
    func testDirectoryIsThePinnedRevision() throws {
        let directory = try localCopy()
        let files = try Qwen3Asset.verifiedManifest.files.map { file -> ModelAssetManifest.File in
            let url = directory.appendingPathComponent(file.name)
            let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, file.name)
            return ModelAssetManifest.File(
                name: file.name,
                byteCount: Int64(size),
                sha256: try FileDigests.sha256(of: url),
                gitBlobSHA1: file.gitBlobSHA1 == nil ? nil : try FileDigests.gitBlobSHA1(of: url)
            )
        }
        let manifest = ModelAssetManifest(
            id: Qwen3Asset.id,
            repository: Qwen3Asset.repository,
            revision: Qwen3Asset.revision,
            files: files
        )

        let asset = try Qwen3Asset.asset(pinnedBy: manifest)
        XCTAssertEqual(asset.totalBytes, 979_513_507)
        XCTAssertEqual(asset.revision, Qwen3Asset.revision)
        print("Complete manifest of \(Qwen3Asset.repository)@\(Qwen3Asset.revision):")
        print(String(decoding: try manifest.jsonData(), as: UTF8.self))
    }

    // MARK: - Section 15.6: load

    /// Model load from disk: 4 s cold, 1 s warm.
    ///
    /// The first load of the process stands in for the cold one: the test cannot empty the
    /// file cache, so a run right after a reboot is the honest cold measurement.
    func testLoadTimes() async throws {
        let directory = try modelDirectory()
        let model = MLXLanguageModel(asset: Self.asset)
        addTeardownBlock { await model.unload() }

        let first = try await clock.measure { try await model.load(from: directory) }
        let isLoaded = await model.isLoaded
        XCTAssertTrue(isLoaded)
        await model.unload()
        let isUnloaded = await !model.isLoaded
        XCTAssertTrue(isUnloaded)

        var warm: [Double] = []
        for _ in 0 ..< 3 {
            let duration = try await clock.measure { try await model.load(from: directory) }
            warm.append(seconds(duration))
            await model.unload()
        }

        print("Load: first \(seconds(first)) s, warm \(warm) s")
        XCTAssertLessThanOrEqual(seconds(first), 4, "first load of the process")
        XCTAssertLessThanOrEqual(try XCTUnwrap(warm.max()), 1, "warm load")
    }

    func testLoadingTheLoadedDirectoryAgainIsFree() async throws {
        let directory = try modelDirectory()
        let model = try await loadedModel()
        let again = try await clock.measure { try await model.load(from: directory) }
        XCTAssertLessThan(seconds(again), 0.05)
    }

    // MARK: - Generation

    func testGenerationStreamsTextThenUsageThenFinished() async throws {
        let model = try await loadedModel()
        let reply = try await reply(
            from: model,
            to: "Name the capital of France in one short sentence.",
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 64, seed: 0)
        )

        XCTAssertTrue(reply.text.localizedCaseInsensitiveContains("Paris"), reply.text)
        XCTAssertFalse(reply.text.contains("<think>"))
        XCTAssertFalse(reply.text.contains("</think>"))
        XCTAssertFalse(reply.text.hasPrefix("\n"), "an empty think block must not leave blank lines behind")

        // Deltas first, then exactly one usage and one finished, in that order, and nothing after.
        let tail = Array(reply.events.suffix(2))
        XCTAssertEqual(tail.count, 2)
        guard case .usage(let prompt, let generated) = tail[0], case .finished(let reason) = tail[1] else {
            return XCTFail("the stream must end with .usage and .finished: \(tail)")
        }
        XCTAssertTrue(reply.events.dropLast(2).allSatisfy { if case .delta = $0 { true } else { false } })
        XCTAssertGreaterThan(prompt, 10)
        XCTAssertGreaterThan(generated, 0)
        XCTAssertLessThanOrEqual(generated, 64)
        XCTAssertEqual(reason, .endOfTurn)
    }

    func testMaxNewTokensEndsWithMaxTokens() async throws {
        let model = try await loadedModel()
        let reply = try await reply(
            from: model,
            to: "Count from one to one hundred in words.",
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 12, seed: 0)
        )
        XCTAssertEqual(reply.generatedTokens, 12)
        XCTAssertEqual(reply.stopReason, .maxTokens)
    }

    func testSystemPromptAndHistoryGoThroughTheTemplate() async throws {
        let model = try await loadedModel()
        let request = GenerationRequest(
            messages: [
                ChatMessage(role: .system, content: "You answer with a single word."),
                ChatMessage(role: .user, content: "My favourite colour is teal. Remember it."),
                ChatMessage(role: .assistant, content: "Understood."),
                ChatMessage(role: .user, content: "Which colour did I say is my favourite?"),
            ],
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 32, seed: 0)
        )
        var text = ""
        for try await event in model.generate(request) {
            if case .delta(let piece) = event {
                text += piece
            }
        }
        XCTAssertTrue(text.localizedCaseInsensitiveContains("teal"), text)
    }

    func testThinkingModeNeverLeaksThinkBlocks() async throws {
        let model = try await loadedModel()
        let options = GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 512, seed: 0, thinking: true)
        let thinking = try await reply(from: model, to: "What is 17 times 23? Answer with the number.", options: options)

        XCTAssertFalse(thinking.text.contains("<think>"))
        XCTAssertFalse(thinking.text.contains("</think>"))
        XCTAssertFalse(thinking.text.hasPrefix("\n"))
        if thinking.stopReason == .endOfTurn {
            XCTAssertFalse(thinking.text.isEmpty, "the answer after the think block must be shown")
        }

        // The reasoning was generated and counted, just not shown.
        let visibleTokens = await model.countTokens(thinking.text)
        XCTAssertGreaterThan(thinking.generatedTokens, visibleTokens)
    }

    func testExplicitSeedReproducesTheOutput() async throws {
        let model = try await loadedModel()
        let prompt = "Write four lines of verse about the sea."
        func sample(seed: UInt64) async throws -> Reply {
            try await reply(
                from: model,
                to: prompt,
                options: GenerationOptions(temperature: 1.0, topP: 0.95, maxNewTokens: 48, seed: seed)
            )
        }

        let first = try await sample(seed: 7)
        let second = try await sample(seed: 7)
        let other = try await sample(seed: 8)

        XCTAssertFalse(first.text.isEmpty)
        XCTAssertEqual(first.text, second.text)
        XCTAssertEqual(first.generatedTokens, second.generatedTokens)
        XCTAssertNotEqual(first.text, other.text, "a different seed should sample a different reply")
    }

    func testGreedyDecodingIsDeterministic() async throws {
        let model = try await loadedModel()
        let options = GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 32)
        let first = try await reply(from: model, to: "List three fruits.", options: options)
        let second = try await reply(from: model, to: "List three fruits.", options: options)
        XCTAssertEqual(first.text, second.text)
    }

    // MARK: - Section 15.6: speed

    /// Time to first token for a 512-token prompt: 2 s at the 95th percentile.
    /// Decode rate: 12 tokens/s at the median, 8 tokens/s at the slow tail.
    func testTimeToFirstTokenAndDecodeRate() async throws {
        let model = try await loadedModel()

        // The first generation after a load also compiles the GPU kernels. It is what the
        // device gate measures, so it must pass the gate; the percentiles are taken afterwards.
        let first = try await model.calibrate()
        print("Calibration after load: \(first)")
        XCTAssertGreaterThanOrEqual(first.promptTokens, 512)
        XCTAssertLessThanOrEqual(first.promptTokens, 512 + 32)
        XCTAssertEqual(first.generatedTokens, 64)
        XCTAssertEqual(first.stopReason, .maxTokens)
        XCTAssertTrue(first.passes(), "time to first token <= 3 s and >= 8 tokens/s")

        var timeToFirstToken: [Double] = []
        var tokensPerSecond: [Double] = []
        for _ in 0 ..< 20 {
            let calibration = try await model.calibrate()
            timeToFirstToken.append(calibration.timeToFirstToken)
            tokensPerSecond.append(calibration.tokensPerSecond)
        }

        let ttftP95 = percentile(0.95, of: timeToFirstToken)
        let rateP50 = percentile(0.50, of: tokensPerSecond)
        let rateSlowTail = percentile(0.05, of: tokensPerSecond)
        print("Time to first token: p50 \(percentile(0.5, of: timeToFirstToken)) s, p95 \(ttftP95) s")
        print("Decode rate: p50 \(rateP50) tokens/s, slowest 5% \(rateSlowTail) tokens/s")

        XCTAssertLessThanOrEqual(ttftP95, 2)
        XCTAssertGreaterThanOrEqual(rateP50, 12)
        XCTAssertGreaterThanOrEqual(rateSlowTail, 8)
    }

    // MARK: - Section 15.6: cancellation

    /// Generation stops within one token, at most 150 ms after the consumer goes away.
    ///
    /// The runtime is idle again when a call to the actor returns: the generation is one job on
    /// the runtime's thread, and the call waits behind it.
    func testCancellationStopsGenerationWithin150Milliseconds() async throws {
        let model = try await loadedModel()
        let request = GenerationRequest(
            messages: [ChatMessage(role: .user, content: "Write a very long story about a lighthouse keeper.")],
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 512, seed: 0)
        )

        var latencies: [Double] = []
        for _ in 0 ..< 5 {
            let (reached, signal) = AsyncStream<Void>.makeStream()
            let consumer = Task {
                var deltas = 0
                for try await event in model.generate(request) {
                    if case .delta = event {
                        deltas += 1
                        if deltas == 8 {
                            signal.yield()
                        }
                    }
                }
                return deltas
            }
            var iterator = reached.makeAsyncIterator()
            _ = await iterator.next()

            let cancelledAt = clock.now
            consumer.cancel()
            _ = await model.isLoaded
            latencies.append(seconds(clock.now - cancelledAt))

            let deltas = try await consumer.value
            XCTAssertLessThan(deltas, 100, "the generation must not have run on to its 512 tokens")
        }

        print("Cancellation latency: \(latencies) s")
        XCTAssertLessThanOrEqual(try XCTUnwrap(latencies.max()), 0.150)
    }

    func testCancelGenerationsKeepsTheStreamAndReportsUsage() async throws {
        let model = try await loadedModel()
        let request = GenerationRequest(
            messages: [ChatMessage(role: .user, content: "Write a very long story about a lighthouse keeper.")],
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 512, seed: 0)
        )

        var events: [GenerationEvent] = []
        var deltas = 0
        var latency: Double?
        var cancelledAt: ContinuousClock.Instant?
        for try await event in model.generate(request) {
            events.append(event)
            switch event {
            case .delta:
                deltas += 1
                if deltas == 8 {
                    cancelledAt = clock.now
                    model.cancelGenerations()
                }
            case .usage:
                break
            case .finished:
                latency = cancelledAt.map { seconds(clock.now - $0) }
            }
        }

        guard case .usage(let prompt, let generated) = events.dropLast().last, case .finished(let reason) = events.last else {
            return XCTFail("the stream must end with .usage and .finished: \(events.suffix(2))")
        }
        XCTAssertEqual(reason, .cancelled)
        XCTAssertGreaterThan(prompt, 0)
        XCTAssertGreaterThanOrEqual(generated, 8)
        XCTAssertLessThan(generated, 64, "generation went on long after it was cancelled")
        XCTAssertLessThanOrEqual(try XCTUnwrap(latency), 0.150)
        let isLoaded = await model.isLoaded
        XCTAssertTrue(isLoaded, "cancelling leaves the model loaded")
    }

    func testUnloadDuringGenerationFinishesTheStreamAsCancelled() async throws {
        let directory = try modelDirectory()
        let model = try await loadedModel()
        let request = GenerationRequest(
            messages: [ChatMessage(role: .user, content: "Write a very long story about a lighthouse keeper.")],
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 512, seed: 0)
        )

        var events: [GenerationEvent] = []
        var deltas = 0
        var unloading: Task<Void, Never>?
        for try await event in model.generate(request) {
            events.append(event)
            if case .delta = event {
                deltas += 1
                if deltas == 8 {
                    unloading = Task { await model.unload() }
                }
            }
        }
        await unloading?.value

        guard case .usage(let prompt, let generated) = events.dropLast().last, case .finished(let reason) = events.last else {
            return XCTFail("the stream must end with .usage and .finished: \(events.suffix(2))")
        }
        XCTAssertEqual(reason, .cancelled)
        XCTAssertGreaterThan(prompt, 0)
        XCTAssertGreaterThanOrEqual(generated, 8)
        XCTAssertLessThan(generated, 512)
        let isLoaded = await model.isLoaded
        XCTAssertFalse(isLoaded)

        // The files are still there: the next load brings the model back.
        try await model.load(from: directory)
        let reply = try await reply(from: model, to: "Say hello.", options: GenerationOptions(temperature: 0, maxNewTokens: 16))
        XCTAssertFalse(reply.text.isEmpty)
    }

    // MARK: - Tokens and the context window

    func testTokenCountsAreExactAndSurviveAnUnload() async throws {
        let model = try await loadedModel()
        let text = "Offline search finds the map of Naples, even with a typo."

        let loaded = await model.countTokens(text)
        XCTAssertGreaterThan(loaded, 5)
        XCTAssertLessThan(loaded, text.utf8.count / 2, "a real count, not the byte bound")

        // `.usage` counts the same text plus the template around it.
        let reply = try await reply(from: model, to: text, options: GenerationOptions(temperature: 0, maxNewTokens: 1))
        XCTAssertGreaterThan(reply.promptTokens, loaded)
        XCTAssertLessThan(reply.promptTokens, loaded + 32)

        await model.unload()
        let unloaded = await model.countTokens(text)
        XCTAssertEqual(unloaded, loaded, "the tokenizer is reloaded on its own after an unload")
    }

    func testPromptThatLeavesNoRoomIsRefused() async throws {
        let model = try await loadedModel()
        let prompt = Array(repeating: "lighthouse", count: 6_000).joined(separator: " ")
        do {
            _ = try await reply(from: model, to: prompt)
            XCTFail("a prompt beyond the context window was accepted")
        } catch MLXLanguageModelError.promptTooLong(let promptTokens, let contextWindow) {
            XCTAssertEqual(contextWindow, 4_096)
            XCTAssertGreaterThanOrEqual(promptTokens, 4_096)
        }
    }

    func testReplyStopsAtTheEdgeOfTheContextWindow() async throws {
        let directory = try modelDirectory()
        // A window of 96 tokens leaves this prompt about 60 tokens of room.
        let model = MLXLanguageModel(asset: Self.asset, contextWindow: 96)
        try await model.load(from: directory)
        addTeardownBlock { await model.unload() }

        let reply = try await reply(
            from: model,
            to: "Write a very long story about a lighthouse keeper.",
            options: GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 512, seed: 0)
        )
        XCTAssertEqual(reply.stopReason, .maxTokens)
        XCTAssertEqual(reply.promptTokens + reply.generatedTokens, 96)
    }

    // MARK: - Section 15.6: memory

    #if os(macOS)
        /// Resident memory during generation: 1.8 GB.
        func testFootprintDuringGenerationStaysWithinBudget() async throws {
            let model = try await loadedModel()
            let request = await ChatCalibration.request(for: model, promptTokens: 3_000, decodeTokens: 256)

            var peak: UInt64 = 0
            for try await event in model.generate(request) {
                if case .delta = event, let footprint = physicalFootprint() {
                    peak = max(peak, footprint)
                }
            }
            print("Peak footprint during generation: \(Double(peak) / 1e9) GB")
            XCTAssertGreaterThan(peak, 0)
            XCTAssertLessThanOrEqual(Double(peak), 1.8e9)
        }
    #endif
}
