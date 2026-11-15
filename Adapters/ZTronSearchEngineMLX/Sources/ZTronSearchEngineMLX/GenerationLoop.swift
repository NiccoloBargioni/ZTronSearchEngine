import Foundation
import ZTronSearchEngine

/// The token loop of one generation, free of MLX types so it can be tested with scripted tokens.
///
/// The loop pulls tokens from a source, stops at an end-of-sequence token, at the token budget or
/// on cancellation, turns tokens into text through a streaming detokenizer, strips `<think>`
/// blocks, and hands the visible text to a sink.
enum GenerationLoop {
    /// How a loop ended.
    struct Outcome: Sendable, Hashable {
        /// Tokens the model produced, the end-of-sequence token excluded. Tokens inside a
        /// `<think>` block count: they were generated even though they are not shown.
        let generatedTokens: Int
        let stopReason: StopReason
    }

    /// Runs the loop to its end.
    ///
    /// Cancellation is checked before every token is requested and again before its text is
    /// emitted. Once `isCancelled` reports `true`, no further token is requested and no further
    /// text is emitted: at most the token that was already being computed completes.
    ///
    /// - Parameters:
    ///   - tokenBudget: Most tokens to generate. Reaching it ends the loop with `.maxTokens`.
    ///   - nextToken: Produces the next token id; `nil` when the source has nothing more to give.
    ///   - isStopToken: `true` for a token that ends the model's turn.
    ///   - detokenize: Feeds one token to a streaming detokenizer and returns the text that is
    ///     complete so far, or `nil` when the token does not complete a character.
    ///   - isCancelled: `true` once the consumer no longer wants the generation.
    ///   - emit: Receives visible text. Returns `false` when the consumer is gone.
    static func run(
        tokenBudget: Int,
        nextToken: () -> Int?,
        isStopToken: (Int) -> Bool,
        detokenize: (Int) -> String?,
        isCancelled: () -> Bool,
        emit: (String) -> Bool
    ) -> Outcome {
        var filter = ThinkBlockFilter()
        var generated = 0
        var stopReason: StopReason?

        while stopReason == nil {
            if generated >= tokenBudget {
                // The reply is complete as far as the budget goes; a cancellation that arrives
                // now has nothing left to stop.
                stopReason = .maxTokens
                break
            }
            if isCancelled() {
                stopReason = .cancelled
                break
            }
            guard let token = nextToken() else {
                // The source enforces the same budget; running dry means the budget is spent.
                stopReason = .maxTokens
                break
            }
            if isStopToken(token) {
                stopReason = .endOfTurn
                break
            }
            generated += 1

            if isCancelled() {
                stopReason = .cancelled
                break
            }
            guard let piece = detokenize(token) else { continue }
            let visible = filter.consume(piece)
            if !visible.isEmpty && !emit(visible) {
                stopReason = .cancelled
            }
        }

        let reason = stopReason ?? .cancelled
        if reason != .cancelled {
            // Text held back as a possible tag start is ordinary text once the stream ends.
            let tail = filter.finish()
            if !tail.isEmpty {
                _ = emit(tail)
            }
        }
        return Outcome(generatedTokens: generated, stopReason: reason)
    }
}

/// The tokens that end a model's turn.
struct StopTokens: Sendable, Hashable {
    let ids: Set<Int>

    /// Collects the end-of-sequence ids of the model configuration, the tokenizer's own
    /// end-of-sequence and unknown tokens, and any extra end-of-sequence tokens given by name.
    init(configured: Set<Int>, eosTokenID: Int?, unknownTokenID: Int?, extraTokenIDs: [Int] = []) {
        var ids = configured
        if let eosTokenID { ids.insert(eosTokenID) }
        if let unknownTokenID { ids.insert(unknownTokenID) }
        ids.formUnion(extraTokenIDs)
        self.ids = ids
    }

    func contains(_ token: Int) -> Bool {
        ids.contains(token)
    }
}
