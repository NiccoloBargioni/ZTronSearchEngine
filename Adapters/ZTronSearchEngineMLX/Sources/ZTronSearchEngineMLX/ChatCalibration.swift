import Foundation
import ZTronSearchEngine

/// The measurement behind the device gate of specification section 14.4: prefill a 512-token
/// prompt, decode 64 tokens, and report the time to the first token and the decode rate.
///
/// Core owns the gate and stores the verdict. This type only measures, and it does so through
/// `LocalLanguageModel` alone: it sends one ordinary `generate` request and times the events.
/// Core can therefore repeat the measurement without importing this package.
///
/// ## The request
///
/// - One `user` message whose text has at least 512 tokens by `countTokens`, overshooting by no
///   more than its last word. The chat template adds about a dozen tokens around it, so slightly
///   more than 512 tokens are prefilled; `.usage` reports the exact number.
/// - Options: `temperature` 0, `topP` 1, `maxNewTokens` 64, `seed` 0, `thinking` false. Greedy
///   decoding makes two runs produce the same tokens.
/// - The message asks for a long summary, so the model does not end its turn before 64 tokens.
///
/// ## The numbers
///
/// - Time to first token: from the call to `generate` until the first `.delta`.
/// - Decode rate: `(generated - 1) / (time of .finished - time of the first .delta)`, with
///   `generated` taken from `.usage`. The first token belongs to the prompt phase.
///
/// Run it once after the first load. That run also pays for compiling MLX's GPU kernels, so it
/// is the slowest generation the device will see.
public struct ChatCalibration: Sendable, Hashable {
    /// Tokens of the rendered prompt, as reported by `.usage`.
    public let promptTokens: Int
    /// Tokens the model generated, as reported by `.usage`.
    public let generatedTokens: Int
    /// Seconds from the request to the first `.delta`; the whole duration when no text arrived.
    public let timeToFirstToken: TimeInterval
    /// Tokens per second after the first token; 0 when fewer than two tokens were generated.
    public let tokensPerSecond: Double
    /// How the generation ended. A run of 64 tokens ends with `.maxTokens`.
    public let stopReason: StopReason

    /// Creates a measurement from its parts.
    public init(
        promptTokens: Int,
        generatedTokens: Int,
        timeToFirstToken: TimeInterval,
        tokensPerSecond: Double,
        stopReason: StopReason
    ) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.timeToFirstToken = timeToFirstToken
        self.tokensPerSecond = tokensPerSecond
        self.stopReason = stopReason
    }

    /// Whether the device is fast enough: the first token within `maximumTimeToFirstToken`
    /// seconds and at least `minimumTokensPerSecond` tokens per second.
    ///
    /// The defaults are the thresholds of specification section 14.4. A cancelled run, or one
    /// that generated fewer than two tokens, measured nothing and does not pass.
    public func passes(maximumTimeToFirstToken: TimeInterval = 3, minimumTokensPerSecond: Double = 8) -> Bool {
        stopReason != .cancelled
            && generatedTokens >= 2
            && timeToFirstToken <= maximumTimeToFirstToken
            && tokensPerSecond >= minimumTokensPerSecond
    }

    // MARK: - The request

    /// Tokens to prefill.
    public static let promptTokenTarget = 512

    /// Tokens to decode.
    public static let decodeTokenTarget = 64

    /// The options of the calibration request.
    public static func options(decodeTokens: Int = decodeTokenTarget) -> GenerationOptions {
        GenerationOptions(temperature: 0, topP: 1, maxNewTokens: decodeTokens, seed: 0, thinking: false)
    }

    /// Builds the calibration request for `model`.
    ///
    /// The prompt is sized with `model.countTokens`, so the model should be loaded: an unloaded
    /// ``MLXLanguageModel`` over-counts and the prompt comes out shorter than intended.
    public static func request(
        for model: any LocalLanguageModel,
        promptTokens: Int = promptTokenTarget,
        decodeTokens: Int = decodeTokenTarget
    ) async -> GenerationRequest {
        let text = await promptText(tokens: promptTokens) { await model.countTokens($0) }
        return GenerationRequest(
            messages: [ChatMessage(role: .user, content: text)],
            options: options(decodeTokens: decodeTokens)
        )
    }

    /// A passage followed by an instruction, with at least `tokens` tokens by `countTokens`.
    ///
    /// The passage grows one word at a time; a binary search finds the shortest one that reaches
    /// the target, which takes about ten calls to `countTokens`.
    static func promptText(tokens: Int, countTokens: (String) async -> Int) async -> String {
        func text(words count: Int) -> String {
            let passage = (0 ..< count).map { passageWords[$0 % passageWords.count] }.joined(separator: " ")
            return passage.isEmpty ? instruction : passage + "\n\n" + instruction
        }

        // Every word is at least one token, so `tokens` words always reach the target.
        var low = 0
        var high = max(0, tokens)
        while low < high {
            let middle = (low + high) / 2
            if await countTokens(text(words: middle)) >= tokens {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return text(words: low)
    }

    private static let instruction =
        "Write a detailed summary of the text above in one long paragraph of at least two hundred words."

    private static let passageWords: [String] = """
        A search engine that runs on the device answers without a network connection. \
        It reads every item once, splits the text into words, and stores for each word the items that contain it. \
        A query is split the same way, and the items that share the most important words come first. \
        Titles count more than descriptions, and a word that is rare in the collection counts more than a common one. \
        When the query has a typing mistake, words that differ by one or two letters are tried as well. \
        Results arrive in pages, so the first screen appears quickly and the rest is computed only when it is needed. \
        The index is saved to disk after each change, which lets the next launch skip the work of building it again. \
        People who use several languages expect the same item to be found under each of its translated names.
        """.split(separator: " ").map(String.init)

    // MARK: - Measuring

    /// Sends `request` to `model` and times the events.
    ///
    /// - Throws: Whatever the stream throws; `CancellationError` when the calling task is
    ///   cancelled; ``MLXLanguageModelError/calibrationIncomplete`` when the stream ends without
    ///   `.usage` and `.finished`.
    public static func measure(_ model: any LocalLanguageModel, request: GenerationRequest) async throws -> ChatCalibration {
        let clock = ContinuousClock()
        let origin = clock.now
        return try await measure(events: model.generate(request)) {
            let elapsed = clock.now - origin
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        }
    }

    /// Builds the calibration request for `model`, sends it and times the events.
    public static func measure(
        _ model: any LocalLanguageModel,
        promptTokens: Int = promptTokenTarget,
        decodeTokens: Int = decodeTokenTarget
    ) async throws -> ChatCalibration {
        let request = await request(for: model, promptTokens: promptTokens, decodeTokens: decodeTokens)
        return try await measure(model, request: request)
    }

    /// Times a stream of generation events.
    ///
    /// `now` returns seconds on any monotonic scale. It is read three times at most: before the
    /// first event is awaited, when the first `.delta` arrives, and when `.finished` arrives.
    static func measure(
        events: AsyncThrowingStream<GenerationEvent, Error>,
        now: () -> TimeInterval
    ) async throws -> ChatCalibration {
        let start = now()
        var firstDelta: TimeInterval?
        var usage: (prompt: Int, generated: Int)?
        var finished: (reason: StopReason, time: TimeInterval)?

        for try await event in events {
            switch event {
            case .delta:
                if firstDelta == nil {
                    firstDelta = now()
                }
            case .usage(let prompt, let generated):
                usage = (prompt, generated)
            case .finished(let reason):
                finished = (reason, now())
            }
        }

        guard let usage, let finished else {
            try Task.checkCancellation()
            throw MLXLanguageModelError.calibrationIncomplete
        }
        return ChatCalibration(
            promptTokens: usage.prompt,
            generatedTokens: usage.generated,
            start: start,
            firstDelta: firstDelta,
            end: finished.time,
            stopReason: finished.reason
        )
    }

    /// The arithmetic of the measurement, from three points in time.
    init(promptTokens: Int, generatedTokens: Int, start: TimeInterval, firstDelta: TimeInterval?, end: TimeInterval, stopReason: StopReason) {
        let timeToFirstToken = max(0, (firstDelta ?? end) - start)
        var tokensPerSecond = 0.0
        if let firstDelta, generatedTokens >= 2, end > firstDelta {
            tokensPerSecond = Double(generatedTokens - 1) / (end - firstDelta)
        }
        self.init(
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            timeToFirstToken: timeToFirstToken,
            tokensPerSecond: tokensPerSecond,
            stopReason: stopReason
        )
    }
}

extension MLXLanguageModel {
    /// Runs the calibration of specification section 14.4 on this model: prefills
    /// `promptTokens` tokens, decodes `decodeTokens`, and reports the time to the first token and
    /// the decode rate. The model must be loaded.
    ///
    /// This is ``ChatCalibration/measure(_:promptTokens:decodeTokens:)`` applied to `self`; it
    /// uses nothing beyond `countTokens` and `generate`.
    public nonisolated func calibrate(
        promptTokens: Int = ChatCalibration.promptTokenTarget,
        decodeTokens: Int = ChatCalibration.decodeTokenTarget
    ) async throws -> ChatCalibration {
        try await ChatCalibration.measure(self, promptTokens: promptTokens, decodeTokens: decodeTokens)
    }
}
