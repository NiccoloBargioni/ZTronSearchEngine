import os
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

/// A `LocalLanguageModel` that replays a script. Tokens are whitespace-separated words.
private final class ScriptedModel: LocalLanguageModel {
    let descriptor = LanguageModelDescriptor(
        asset: ModelAsset(id: "scripted", revision: "v1", files: []),
        contextWindow: 4_096,
        minimumPhysicalMemory: 0,
        minimumOS: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    )

    private let events: [GenerationEvent]
    private let failure: (any Error)?
    private let recorded = OSAllocatedUnfairLock(initialState: [GenerationRequest]())

    init(events: [GenerationEvent], failure: (any Error)? = nil) {
        self.events = events
        self.failure = failure
    }

    var requests: [GenerationRequest] {
        recorded.withLock { $0 }
    }

    func load(from directory: URL) async throws {}
    func unload() async {}

    func countTokens(_ text: String) async -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        recorded.withLock { $0.append(request) }
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        for event in events {
            continuation.yield(event)
        }
        continuation.finish(throwing: failure)
        return stream
    }
}

/// Seconds handed out one reading at a time.
private final class ScriptedClock {
    private var readings: [TimeInterval]
    private(set) var readCount = 0

    init(_ readings: [TimeInterval]) {
        self.readings = readings
    }

    func now() -> TimeInterval {
        readCount += 1
        return readings.isEmpty ? .nan : readings.removeFirst()
    }
}

final class ChatCalibrationTests: XCTestCase {
    private struct ScriptError: Error, Equatable {}

    private func stream(_ events: [GenerationEvent], failure: (any Error)? = nil) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        for event in events {
            continuation.yield(event)
        }
        continuation.finish(throwing: failure)
        return stream
    }

    /// A stream of `count` deltas followed by usage and a stop reason.
    private func generation(deltas count: Int, prompt: Int = 524, generated: Int, reason: StopReason = .maxTokens) -> [GenerationEvent] {
        Array(repeating: GenerationEvent.delta("x"), count: count)
            + [.usage(prompt: prompt, generated: generated), .finished(reason)]
    }

    // MARK: - Arithmetic

    func testTimeToFirstTokenAndDecodeRate() async throws {
        // Requested at t = 10 s, first text at 11.5 s, finished at 17.8 s.
        let clock = ScriptedClock([10, 11.5, 17.8])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 64, generated: 64)),
            now: clock.now
        )
        XCTAssertEqual(calibration.promptTokens, 524)
        XCTAssertEqual(calibration.generatedTokens, 64)
        XCTAssertEqual(calibration.timeToFirstToken, 1.5, accuracy: 1e-9)
        // 63 tokens after the first one, in 6.3 s.
        XCTAssertEqual(calibration.tokensPerSecond, 10, accuracy: 1e-9)
        XCTAssertEqual(calibration.stopReason, .maxTokens)
        XCTAssertEqual(clock.readCount, 3, "the clock is read at the start, at the first delta and at the end")
        XCTAssertTrue(calibration.passes())
    }

    func testGateThresholdsOfTheSpecification() {
        func calibration(timeToFirstToken: TimeInterval, tokensPerSecond: Double) -> ChatCalibration {
            ChatCalibration(
                promptTokens: 524,
                generatedTokens: 64,
                timeToFirstToken: timeToFirstToken,
                tokensPerSecond: tokensPerSecond,
                stopReason: .maxTokens
            )
        }
        // Enabled only when the first token arrives within 3 s and decoding runs at 8 tokens/s or more.
        XCTAssertTrue(calibration(timeToFirstToken: 3, tokensPerSecond: 8).passes())
        XCTAssertFalse(calibration(timeToFirstToken: 3.01, tokensPerSecond: 20).passes())
        XCTAssertFalse(calibration(timeToFirstToken: 0.5, tokensPerSecond: 7.99).passes())
        XCTAssertTrue(calibration(timeToFirstToken: 4, tokensPerSecond: 5).passes(maximumTimeToFirstToken: 5, minimumTokensPerSecond: 5))
    }

    func testSlowFirstTokenFailsTheGate() async throws {
        let clock = ScriptedClock([0, 3.5, 6.5])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 64, generated: 64)),
            now: clock.now
        )
        XCTAssertEqual(calibration.timeToFirstToken, 3.5, accuracy: 1e-9)
        XCTAssertEqual(calibration.tokensPerSecond, 21, accuracy: 1e-9)
        XCTAssertFalse(calibration.passes())
    }

    func testSlowDecodeFailsTheGate() async throws {
        let clock = ScriptedClock([0, 1, 10])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 64, generated: 64)),
            now: clock.now
        )
        XCTAssertEqual(calibration.tokensPerSecond, 7, accuracy: 1e-9)
        XCTAssertFalse(calibration.passes())
    }

    func testEarlyEndOfTurnIsMeasuredOverTheTokensProduced() async throws {
        let clock = ScriptedClock([0, 1, 2])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 21, generated: 21, reason: .endOfTurn)),
            now: clock.now
        )
        XCTAssertEqual(calibration.tokensPerSecond, 20, accuracy: 1e-9)
        XCTAssertEqual(calibration.stopReason, .endOfTurn)
        XCTAssertTrue(calibration.passes())
    }

    func testNoTextMeansNoRate() async throws {
        let clock = ScriptedClock([0, 4])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 0, generated: 64)),
            now: clock.now
        )
        XCTAssertEqual(calibration.timeToFirstToken, 4, accuracy: 1e-9)
        XCTAssertEqual(calibration.tokensPerSecond, 0)
        XCTAssertFalse(calibration.passes())
        XCTAssertEqual(clock.readCount, 2)
    }

    func testSingleTokenHasNoRate() async throws {
        let clock = ScriptedClock([0, 1, 1.1])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 1, generated: 1, reason: .endOfTurn)),
            now: clock.now
        )
        XCTAssertEqual(calibration.tokensPerSecond, 0)
        XCTAssertFalse(calibration.passes())
    }

    func testCancelledRunDoesNotPass() async throws {
        let clock = ScriptedClock([0, 0.5, 1.5])
        let calibration = try await ChatCalibration.measure(
            events: stream(generation(deltas: 30, generated: 30, reason: .cancelled)),
            now: clock.now
        )
        XCTAssertEqual(calibration.tokensPerSecond, 29, accuracy: 1e-9)
        XCTAssertFalse(calibration.passes())
    }

    func testStreamThatEndsEarlyIsIncomplete() async {
        do {
            _ = try await ChatCalibration.measure(events: stream([.delta("a"), .delta("b")]), now: ScriptedClock([0, 1]).now)
            XCTFail("an incomplete stream produced a measurement")
        } catch {
            XCTAssertEqual(error as? MLXLanguageModelError, .calibrationIncomplete)
        }
        do {
            _ = try await ChatCalibration.measure(
                events: stream([.delta("a"), .usage(prompt: 1, generated: 1)]),
                now: ScriptedClock([0, 1]).now
            )
            XCTFail("a stream without a stop reason produced a measurement")
        } catch {
            XCTAssertEqual(error as? MLXLanguageModelError, .calibrationIncomplete)
        }
    }

    func testStreamErrorIsRethrown() async {
        do {
            _ = try await ChatCalibration.measure(
                events: stream([.delta("a")], failure: ScriptError()),
                now: ScriptedClock([0, 1]).now
            )
            XCTFail("a failing stream produced a measurement")
        } catch {
            XCTAssertEqual(error as? ScriptError, ScriptError())
        }
    }

    // MARK: - The request

    func testRequestIsOneUserMessageOfAtLeast512Tokens() async {
        let model = ScriptedModel(events: [])
        let request = await ChatCalibration.request(for: model)

        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.role, .user)
        let tokens = await model.countTokens(request.messages[0].content)
        XCTAssertGreaterThanOrEqual(tokens, 512)
        XCTAssertLessThan(tokens, 514, "the prompt overshoots by one word at most")
        XCTAssertTrue(request.messages[0].content.hasSuffix("at least two hundred words."))
    }

    func testRequestOptionsAreGreedyAndSeeded() async {
        let request = await ChatCalibration.request(for: ScriptedModel(events: []))
        XCTAssertEqual(request.options, GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 64, seed: 0, thinking: false))
        XCTAssertEqual(ChatCalibration.options(), request.options)
        // Greedy on purpose: neither the specification's defaults nor an asset's sampling apply.
        let plan = SamplingPlan(options: request.options, generationConfig: AssetGenerationConfig(temperature: 0.6, topP: 0.95))
        XCTAssertEqual(plan.temperature, 0)
        XCTAssertEqual(plan.topP, 1)
    }

    func testRequestSizeFollowsTheParameters() async {
        let model = ScriptedModel(events: [])
        let request = await ChatCalibration.request(for: model, promptTokens: 100, decodeTokens: 16)
        let tokens = await model.countTokens(request.messages[0].content)
        XCTAssertGreaterThanOrEqual(tokens, 100)
        XCTAssertLessThan(tokens, 102)
        XCTAssertEqual(request.options.maxNewTokens, 16)
    }

    func testPromptIsTheInstructionAloneWhenTheTargetIsTiny() async {
        let text = await ChatCalibration.promptText(tokens: 1) { $0.split(separator: " ").count }
        XCTAssertEqual(text, "Write a detailed summary of the text above in one long paragraph of at least two hundred words.")
    }

    func testPromptIsDeterministic() async {
        let count: (String) async -> Int = { $0.split(whereSeparator: \.isWhitespace).count }
        let first = await ChatCalibration.promptText(tokens: 512, countTokens: count)
        let second = await ChatCalibration.promptText(tokens: 512, countTokens: count)
        XCTAssertEqual(first, second)
    }

    // MARK: - Through the boundary

    func testMeasureDrivesTheModelThroughGenerateAlone() async throws {
        let model = ScriptedModel(events: generation(deltas: 64, prompt: 530, generated: 64))
        let calibration = try await ChatCalibration.measure(model)

        XCTAssertEqual(calibration.promptTokens, 530)
        XCTAssertEqual(calibration.generatedTokens, 64)
        XCTAssertEqual(calibration.stopReason, .maxTokens)
        XCTAssertGreaterThanOrEqual(calibration.timeToFirstToken, 0)
        XCTAssertGreaterThan(calibration.tokensPerSecond, 0)

        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(model.requests.first?.options, ChatCalibration.options())
    }

    func testMeasureRethrowsTheModelsError() async {
        let model = ScriptedModel(events: [], failure: MLXLanguageModelError.notLoaded)
        do {
            _ = try await ChatCalibration.measure(model)
            XCTFail("a failing model produced a measurement")
        } catch {
            XCTAssertEqual(error as? MLXLanguageModelError, .notLoaded)
        }
    }
}
