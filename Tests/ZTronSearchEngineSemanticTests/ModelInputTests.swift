import XCTest
@testable import ZTronSearchEngineSemantic

/// Batch assembly, pooling, normalization and scoring: everything between the tokenizer and
/// the model, and between the model and the engine.
final class ModelInputTests: XCTestCase {
    private func wordPiece() throws -> WordPieceTokenizer {
        try WordPieceTokenizer(vocabulary: WordPieceTokenizerTests.vocabulary)
    }

    private func unigram() throws -> UnigramTokenizer {
        try UnigramTokenizer(pieces: UnigramTokenizerTests.pieces, unknownTokenID: 3, padTokenID: 1, template: .roberta(bos: 0, eos: 2))
    }

    // MARK: Batch assembly

    func testATextBatchStacksOneWindowPerText() throws {
        let tokenizer = try wordPiece()
        let batch = ModelInputBatch.texts(["the cat", "sat on the mat", ""], tokenizer: tokenizer, sequenceLength: 8)
        XCTAssertEqual(batch.rowCount, 3)
        XCTAssertEqual(batch.sequenceLength, 8)
        XCTAssertEqual(batch.inputIDs, [
            2, 5, 6, 3, 0, 0, 0, 0,
            2, 7, 8, 5, 9, 3, 0, 0,
            2, 3, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertEqual(batch.attentionMask, [
            1, 1, 1, 1, 0, 0, 0, 0,
            1, 1, 1, 1, 1, 1, 0, 0,
            1, 1, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertEqual(batch.tokenTypeIDs, [Int32](repeating: 0, count: 24))
        XCTAssertEqual(Array(batch.inputIDs(row: 1)), [2, 7, 8, 5, 9, 3, 0, 0])
        XCTAssertEqual(Array(batch.attentionMask(row: 2)), [1, 1, 0, 0, 0, 0, 0, 0])

        // The default window is 128 tokens.
        let window = ModelInputBatch.texts(["the cat"], tokenizer: tokenizer)
        XCTAssertEqual(window.sequenceLength, 128)
        XCTAssertEqual(window.inputIDs.count, 128)
    }

    func testAPairBatchHoldsOneTruncatedPairPerPassage() throws {
        let tokenizer = try wordPiece()
        let passages = ["sat on the mat", "the cat", "", "the mat . the mat . the mat . the mat ."]
        let batch = ModelInputBatch.pairs(query: "the cat", passages: passages, tokenizer: tokenizer, sequenceLength: 10)
        XCTAssertEqual(batch.rowCount, 4)
        XCTAssertEqual(batch.sequenceLength, 10)
        XCTAssertEqual(batch.inputIDs, [
            2, 5, 6, 3, 7, 8, 5, 9, 3, 0,       // [CLS] the cat [SEP] sat on the mat [SEP] pad
            2, 5, 6, 3, 5, 6, 3, 0, 0, 0,
            2, 5, 6, 3, 3, 0, 0, 0, 0, 0,       // an empty passage is still a pair
            2, 5, 6, 3, 5, 9, 18, 5, 9, 3,      // the passage is cut, the query is whole
        ])
        XCTAssertEqual(batch.tokenTypeIDs, [
            0, 0, 0, 0, 1, 1, 1, 1, 1, 0,
            0, 0, 0, 0, 1, 1, 1, 0, 0, 0,
            0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 1, 1, 1, 1, 1, 1,
        ])
        XCTAssertEqual(batch.attentionMask, [
            1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
            1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
            1, 1, 1, 1, 1, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        ])
        // Every row is what the tokenizer makes of that pair on its own.
        for (row, passage) in passages.enumerated() {
            let alone = tokenizer.encode(pair: "the cat", passage, maxLength: 10)
            XCTAssertEqual(Array(batch.inputIDs(row: row)), alone.inputIDs)
            XCTAssertEqual(Array(batch.tokenTypeIDs(row: row)), alone.tokenTypeIDs)
        }
        let none = ModelInputBatch.pairs(query: "the cat", passages: [], tokenizer: tokenizer)
        XCTAssertEqual(none.rowCount, 0)
        XCTAssertTrue(none.inputIDs.isEmpty)
    }

    func testThe16PairsOfARerankFitOneBatchOf128TokenWindows() throws {
        let tokenizer = try unigram()
        let passages = (0..<16).map { String(repeating: "world hello ", count: 10 * ($0 + 1)) }
        let batch = ModelInputBatch.pairs(query: "new york cat", passages: passages, tokenizer: tokenizer)
        XCTAssertEqual(batch.rowCount, 16)
        XCTAssertEqual(batch.sequenceLength, 128)
        XCTAssertEqual(batch.inputIDs.count, 16 * 128)
        for row in 0..<16 {
            let ids = Array(batch.inputIDs(row: row))
            // <s> ▁new ▁york ▁cat </s></s> passage... </s>
            XCTAssertEqual(Array(ids.prefix(6)), [0, 18, 19, 22, 2, 2])
            let tokens = Array(batch.attentionMask(row: row)).reduce(0, +)
            XCTAssertEqual(Int(tokens), min(128, 7 + 20 * (row + 1)))
            XCTAssertEqual(ids[Int(tokens) - 1], 2, "the closing token survives truncation")
            XCTAssertTrue(ids[Int(tokens)...].allSatisfy { $0 == 1 }, "padding follows the last token")
        }
    }

    // MARK: Pooling

    func testMeanPoolingAveragesOnlyTheTokensTheMaskKeeps() throws {
        // Four positions of three dimensions; the last two are padding with garbage in them.
        let embeddings: [Float] = [
            1, 2, 3,
            3, 6, -3,
            900, 900, 900,
            -500, 0, 500,
        ]
        let pooled = try EmbeddingPooling.meanPool(tokenEmbeddings: embeddings, sequenceLength: 4, hiddenSize: 3, attentionMask: [1, 1, 0, 0] as [Int32])
        XCTAssertEqual(pooled, [2, 4, 0])
        let all = try EmbeddingPooling.meanPool(tokenEmbeddings: embeddings, sequenceLength: 4, hiddenSize: 3, attentionMask: [1, 1, 1, 1] as [Int32])
        XCTAssertEqual(all[0], 101, accuracy: 1e-4)
        XCTAssertEqual(all[1], 227, accuracy: 1e-4)
        XCTAssertEqual(all[2], 350, accuracy: 1e-4)

        // Against a naive loop on random data.
        var generator = SeededGenerator(seed: 61)
        let sequenceLength = 128
        let hiddenSize = 384
        let random = generator.gaussianVector(sequenceLength * hiddenSize)
        let mask: [Int32] = (0..<sequenceLength).map { $0 < 37 ? 1 : 0 }
        let fast = try EmbeddingPooling.meanPool(tokenEmbeddings: random, sequenceLength: sequenceLength, hiddenSize: hiddenSize, attentionMask: mask)
        for dimension in stride(from: 0, to: hiddenSize, by: 17) {
            var sum: Double = 0
            for position in 0..<37 { sum += Double(random[position * hiddenSize + dimension]) }
            XCTAssertEqual(Double(fast[dimension]), sum / 37, accuracy: 1e-4)
        }
    }

    func testPoolingRefusesInputsThatDoNotFit() {
        func assertUnexpected(_ body: @autoclosure () throws -> [Float], line: UInt = #line) {
            XCTAssertThrowsError(try body(), line: line) { error in
                guard case SemanticError.unexpectedModelOutput = error else { return XCTFail("unexpected \(error)", line: line) }
            }
        }
        assertUnexpected(try EmbeddingPooling.meanPool(tokenEmbeddings: [1, 2, 3], sequenceLength: 2, hiddenSize: 2, attentionMask: [1, 1] as [Int32]))
        assertUnexpected(try EmbeddingPooling.meanPool(tokenEmbeddings: [1, 2, 3, 4], sequenceLength: 2, hiddenSize: 2, attentionMask: [1] as [Int32]))
        assertUnexpected(try EmbeddingPooling.meanPool(tokenEmbeddings: [1, 2, 3, 4], sequenceLength: 2, hiddenSize: 2, attentionMask: [0, 0] as [Int32]))
        assertUnexpected(try EmbeddingPooling.meanPool(tokenEmbeddings: [], sequenceLength: 0, hiddenSize: 2, attentionMask: [] as [Int32]))
        assertUnexpected(try EmbeddingPooling.normalized([0, 0, 0]))
        assertUnexpected(try EmbeddingPooling.normalized([1, .nan]))
    }

    func testNormalizationGivesUnitLength() throws {
        XCTAssertEqual(try EmbeddingPooling.normalized([3, 0, 4]), [0.6, 0, 0.8])
        var generator = SeededGenerator(seed: 62)
        let unit = try EmbeddingPooling.normalized(generator.gaussianVector(384).map { $0 * 12 })
        XCTAssertEqual(VectorKernels.norm(unit), 1, accuracy: 1e-5)
    }

    func testASentenceVectorIsPooledAccordingToTheShapeOfTheOutput() throws {
        let mask: [Int32] = [1, 1, 0]
        let tokens: [Float] = [
            2, 0, 0, 0,
            0, 2, 0, 0,
            7, 7, 7, 7,
        ]
        let diagonal = Float(0.5).squareRoot()

        // One vector per token, with or without the batch dimension: mean-pooled under the mask.
        for shape in [[1, 3, 4], [3, 4]] {
            let pooled = try EmbeddingPooling.sentenceVector(
                from: ModelOutputRow(shape: shape, values: tokens), attentionMask: mask, strategy: .automatic, dimensions: 4
            )
            XCTAssertEqual(pooled[0], diagonal, accuracy: 1e-6)
            XCTAssertEqual(pooled[1], diagonal, accuracy: 1e-6)
            XCTAssertEqual(pooled[2], 0, accuracy: 1e-6)
            XCTAssertEqual(
                try EmbeddingPooling.sentenceVector(from: ModelOutputRow(shape: shape, values: tokens), attentionMask: mask, strategy: .mean, dimensions: 4),
                pooled
            )
        }
        // The first token's embedding.
        XCTAssertEqual(
            try EmbeddingPooling.sentenceVector(from: ModelOutputRow(shape: [1, 3, 4], values: tokens), attentionMask: mask, strategy: .firstToken, dimensions: 4),
            [1, 0, 0, 0]
        )
        // A vector the model pooled itself is only normalized, whatever the strategy.
        for strategy in [EmbeddingPoolingStrategy.automatic, .mean, .firstToken] {
            for shape in [[1, 4], [4]] {
                XCTAssertEqual(
                    try EmbeddingPooling.sentenceVector(from: ModelOutputRow(shape: shape, values: [0, 3, 0, 4]), attentionMask: mask, strategy: strategy, dimensions: 4),
                    [0, 0.6, 0, 0.8]
                )
            }
        }
    }

    func testASentenceVectorOfTheWrongWidthOrShapeIsRefused() {
        let mask: [Int32] = [1, 1, 0]
        XCTAssertThrowsError(try EmbeddingPooling.sentenceVector(
            from: ModelOutputRow(shape: [1, 4], values: [1, 0, 0, 0]), attentionMask: mask, strategy: .automatic, dimensions: 384
        )) { XCTAssertEqual($0 as? SemanticError, .dimensionMismatch(expected: 384, found: 4)) }
        XCTAssertThrowsError(try EmbeddingPooling.sentenceVector(
            from: ModelOutputRow(shape: [1, 3, 4], values: [Float](repeating: 1, count: 12)), attentionMask: mask, strategy: .automatic, dimensions: 8
        )) { XCTAssertEqual($0 as? SemanticError, .dimensionMismatch(expected: 8, found: 4)) }
        for output in [
            ModelOutputRow(shape: [2, 3, 4, 5], values: [Float](repeating: 1, count: 120)),   // too many dimensions
            ModelOutputRow(shape: [1, 3, 4], values: [1, 2, 3]),                              // values do not fill the shape
            ModelOutputRow(shape: [1, 4], values: [0, 0, 0, 0]),                              // no direction
            ModelOutputRow(shape: [1, 2, 4], values: [Float](repeating: 1, count: 8)),        // mask of another length
        ] {
            XCTAssertThrowsError(try EmbeddingPooling.sentenceVector(from: output, attentionMask: mask, strategy: .automatic, dimensions: 4)) { error in
                guard case SemanticError.unexpectedModelOutput = error else { return XCTFail("unexpected \(error)") }
            }
        }
    }

    // MARK: Scores

    func testARelevanceScoreIsTheLogitOrTheMarginOfTwo() throws {
        XCTAssertEqual(try RelevanceScoring.score(from: ModelOutputRow(shape: [1, 1], values: [2.5])), 2.5)
        XCTAssertEqual(try RelevanceScoring.score(from: ModelOutputRow(shape: [1], values: [-0.75])), -0.75)
        XCTAssertEqual(try RelevanceScoring.score(from: ModelOutputRow(shape: [], values: [0])), 0)
        // Two logits, irrelevant then relevant: the margin, so higher is still more relevant.
        XCTAssertEqual(try RelevanceScoring.score(from: ModelOutputRow(shape: [1, 2], values: [-1, 3])), 4)
        XCTAssertEqual(try RelevanceScoring.score(from: ModelOutputRow(shape: [2], values: [2, -1])), -3)
        for output in [
            ModelOutputRow(shape: [1, 3], values: [1, 2, 3]),
            ModelOutputRow(shape: [1, 0], values: []),
            ModelOutputRow(shape: [1, 1], values: [.nan]),
            ModelOutputRow(shape: [1, 1], values: [.infinity]),
        ] {
            XCTAssertThrowsError(try RelevanceScoring.score(from: output)) { error in
                guard case SemanticError.unexpectedModelOutput = error else { return XCTFail("unexpected \(error)") }
            }
        }
    }
}
