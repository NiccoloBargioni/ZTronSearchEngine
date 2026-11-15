import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

final class GenerationLoopTests: XCTestCase {
    /// The end-of-sequence token of the scripts below.
    private let eos = 0

    /// A scripted vocabulary: token id → the text it decodes to.
    private let vocabulary: [Int: String] = [
        1: "Hello",
        2: " world",
        3: "<think>",
        4: "plan",
        5: "</think>",
        6: "\n\n",
        7: "<",
        8: "thi",
        9: "nk>",
        10: " a",
    ]

    private struct Run {
        var outcome: GenerationLoop.Outcome
        var emitted: [String]
        var tokensRequested: Int
    }

    /// Runs the loop over scripted tokens.
    ///
    /// - Parameters:
    ///   - cancelAfterTokens: The cancellation flag turns `true` once this many tokens have been produced.
    ///   - cancelAfterEmissions: The cancellation flag turns `true` once this many pieces have been emitted.
    ///   - consumerLeavesAfter: `emit` returns `false` from this emission on.
    private func run(
        tokens: [Int],
        budget: Int = 512,
        cancelAfterTokens: Int? = nil,
        cancelAfterEmissions: Int? = nil,
        consumerLeavesAfter: Int? = nil
    ) -> Run {
        var position = 0
        var emitted: [String] = []
        let outcome = GenerationLoop.run(
            tokenBudget: budget,
            nextToken: {
                guard position < tokens.count else { return nil }
                defer { position += 1 }
                return tokens[position]
            },
            isStopToken: { $0 == self.eos },
            detokenize: { self.vocabulary[$0] },
            isCancelled: {
                if let cancelAfterTokens, position >= cancelAfterTokens { return true }
                if let cancelAfterEmissions, emitted.count >= cancelAfterEmissions { return true }
                return false
            },
            emit: { text in
                emitted.append(text)
                if let consumerLeavesAfter { return emitted.count < consumerLeavesAfter }
                return true
            }
        )
        return Run(outcome: outcome, emitted: emitted, tokensRequested: position)
    }

    // MARK: - Stop reasons

    func testEndOfSequenceTokenEndsTheTurn() {
        let result = run(tokens: [1, 2, eos, 1])
        XCTAssertEqual(result.outcome, .init(generatedTokens: 2, stopReason: .endOfTurn))
        XCTAssertEqual(result.emitted, ["Hello", " world"])
        XCTAssertEqual(result.tokensRequested, 3, "nothing is requested after the end-of-sequence token")
    }

    func testImmediateEndOfSequenceGeneratesNothing() {
        let result = run(tokens: [eos])
        XCTAssertEqual(result.outcome, .init(generatedTokens: 0, stopReason: .endOfTurn))
        XCTAssertEqual(result.emitted, [])
    }

    func testBudgetEndsWithMaxTokens() {
        let result = run(tokens: [1, 2, 1, 2, 1, 2], budget: 3)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 3, stopReason: .maxTokens))
        XCTAssertEqual(result.emitted, ["Hello", " world", "Hello"])
        XCTAssertEqual(result.tokensRequested, 3, "the token after the budget is never requested")
    }

    func testEndOfSequenceExactlyAtTheBudgetIsStillMaxTokens() {
        // The budget is spent before the model could say it was done.
        let result = run(tokens: [1, 2, eos], budget: 2)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 2, stopReason: .maxTokens))
    }

    func testSourceRunningDryIsMaxTokens() {
        let result = run(tokens: [1, 2], budget: 10)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 2, stopReason: .maxTokens))
    }

    func testZeroBudgetRequestsNothing() {
        let result = run(tokens: [1, 2], budget: 0)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 0, stopReason: .maxTokens))
        XCTAssertEqual(result.tokensRequested, 0)
    }

    // MARK: - Cancellation

    func testCancellationBeforeTheFirstTokenRequestsNothing() {
        let result = run(tokens: [1, 2, eos], cancelAfterTokens: 0)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 0, stopReason: .cancelled))
        XCTAssertEqual(result.tokensRequested, 0)
        XCTAssertEqual(result.emitted, [])
    }

    func testCancellationStopsWithinOneToken() {
        // The flag turns true while the third token is being computed.
        let result = run(tokens: [1, 2, 1, 2, 1, 2, eos], cancelAfterTokens: 3)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 3, stopReason: .cancelled))
        XCTAssertEqual(result.tokensRequested, 3, "no token is requested once cancellation is seen")
        XCTAssertEqual(result.emitted, ["Hello", " world"], "the token that was in flight is not emitted")
    }

    func testConsumerGoingAwayCancels() {
        let result = run(tokens: [1, 2, 1, 2, eos], consumerLeavesAfter: 2)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 2, stopReason: .cancelled))
        XCTAssertEqual(result.tokensRequested, 2)
    }

    func testCancellationDuringTheLastTokenIsReportedAsCancelled() {
        // The flag turns true while the second and last token is being computed.
        let result = run(tokens: [1, 2, 1], budget: 2, cancelAfterTokens: 2)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 2, stopReason: .cancelled))
        XCTAssertEqual(result.emitted, ["Hello"])
    }

    func testCancellationAfterTheBudgetIsSpentChangesNothing() {
        // Both tokens were generated and emitted before the flag turned true.
        let result = run(tokens: [1, 2, 1], budget: 2, cancelAfterEmissions: 2)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 2, stopReason: .maxTokens))
        XCTAssertEqual(result.emitted, ["Hello", " world"])
        XCTAssertEqual(result.tokensRequested, 2)
    }

    // MARK: - Text

    func testThinkBlockIsStrippedAndItsTokensStillCount() {
        let result = run(tokens: [3, 4, 4, 5, 6, 1, 2, eos])
        XCTAssertEqual(result.outcome, .init(generatedTokens: 7, stopReason: .endOfTurn))
        XCTAssertEqual(result.emitted.joined(), "Hello world")
    }

    func testThinkTagSplitAcrossTokensIsStripped() {
        let result = run(tokens: [7, 8, 9, 4, 5, 1, eos])
        XCTAssertEqual(result.outcome, .init(generatedTokens: 6, stopReason: .endOfTurn))
        XCTAssertEqual(result.emitted, ["Hello"])
    }

    func testUnterminatedThinkBlockAtTheBudgetEmitsNothing() {
        let result = run(tokens: [3, 4, 4, 4, 4], budget: 4)
        XCTAssertEqual(result.outcome, .init(generatedTokens: 4, stopReason: .maxTokens))
        XCTAssertEqual(result.emitted, [])
    }

    func testHeldTailIsFlushedWhenTheTurnEnds() {
        // "<" could have started a tag; at the end of the turn it is ordinary text.
        let result = run(tokens: [1, 10, 7, eos])
        XCTAssertEqual(result.emitted, ["Hello", " a", "<"])
        XCTAssertEqual(result.outcome.stopReason, .endOfTurn)
    }

    func testHeldTailIsNotFlushedAfterCancellation() {
        let result = run(tokens: [1, 7, 1, 1], cancelAfterTokens: 2)
        XCTAssertEqual(result.emitted, ["Hello"])
        XCTAssertEqual(result.outcome.stopReason, .cancelled)
    }

    func testTokensWithoutCompleteTextEmitNothingButCount() {
        // Token 99 is not in the vocabulary: the detokenizer has no complete character yet.
        let result = run(tokens: [99, 99, 1, eos])
        XCTAssertEqual(result.outcome, .init(generatedTokens: 3, stopReason: .endOfTurn))
        XCTAssertEqual(result.emitted, ["Hello"])
    }

    // MARK: - Stop tokens

    func testStopTokensCollectEverySource() {
        let stopTokens = StopTokens(configured: [151_645], eosTokenID: 151_643, unknownTokenID: 3, extraTokenIDs: [7, 8])
        XCTAssertEqual(stopTokens.ids, [151_645, 151_643, 3, 7, 8])
        XCTAssertTrue(stopTokens.contains(151_645))
        XCTAssertFalse(stopTokens.contains(1))
    }

    func testStopTokensWithoutTokenizerTokens() {
        let stopTokens = StopTokens(configured: [2], eosTokenID: nil, unknownTokenID: nil)
        XCTAssertEqual(stopTokens.ids, [2])
    }
}
