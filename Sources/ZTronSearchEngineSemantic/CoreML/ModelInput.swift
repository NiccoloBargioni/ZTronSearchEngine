import Accelerate
import Foundation

/// The token windows of one model call: `rowCount` rows of `sequenceLength` ids, row-major.
///
/// The embedding model is called with one row, the query. The cross-encoder is called with one
/// row per (query, passage) pair, all in a single batched call (specification section 7.4).
public struct ModelInputBatch: Sendable, Hashable {
    /// Rows of the batch: texts, or (query, passage) pairs.
    public let rowCount: Int
    /// Tokens per row.
    public let sequenceLength: Int
    /// `rowCount * sequenceLength` token ids.
    public let inputIDs: [Int32]
    /// 1 for a token, 0 for padding.
    public let attentionMask: [Int32]
    /// The segment of each token.
    public let tokenTypeIDs: [Int32]

    /// Stacks windows that were tokenized to `sequenceLength`.
    ///
    /// - Precondition: Every window holds exactly `sequenceLength` ids, mask values and
    ///   segment ids, as ``TextTokenizing/encode(_:maxLength:)`` produces them.
    public init(sequences: [TokenizedSequence], sequenceLength: Int) {
        let window = max(0, sequenceLength)
        var ids: [Int32] = []
        var mask: [Int32] = []
        var types: [Int32] = []
        ids.reserveCapacity(sequences.count * window)
        mask.reserveCapacity(sequences.count * window)
        types.reserveCapacity(sequences.count * window)
        for sequence in sequences {
            precondition(
                sequence.inputIDs.count == window && sequence.attentionMask.count == window && sequence.tokenTypeIDs.count == window,
                "every window of a batch must hold exactly \(window) tokens"
            )
            ids.append(contentsOf: sequence.inputIDs)
            mask.append(contentsOf: sequence.attentionMask)
            types.append(contentsOf: sequence.tokenTypeIDs)
        }
        self.rowCount = sequences.count
        self.sequenceLength = window
        self.inputIDs = ids
        self.attentionMask = mask
        self.tokenTypeIDs = types
    }

    /// One row per text.
    public static func texts(
        _ texts: [String],
        tokenizer: any TextTokenizing,
        sequenceLength: Int = SemanticLimits.tokenWindow
    ) -> ModelInputBatch {
        ModelInputBatch(sequences: texts.map { tokenizer.encode($0, maxLength: sequenceLength) }, sequenceLength: sequenceLength)
    }

    /// One row per (query, passage) pair, each truncated to the window. The query is tokenized
    /// once.
    public static func pairs(
        query: String,
        passages: [String],
        tokenizer: any TextTokenizing,
        sequenceLength: Int = SemanticLimits.tokenWindow
    ) -> ModelInputBatch {
        let queryTokens = tokenizer.tokenize(query)
        return ModelInputBatch(
            sequences: passages.map { tokenizer.window(pair: queryTokens, tokenizer.tokenize($0), maxLength: sequenceLength) },
            sequenceLength: sequenceLength
        )
    }

    /// The elements of one row of a row-major buffer.
    private func row(_ index: Int, of buffer: [Int32]) -> ArraySlice<Int32> {
        buffer[(index * sequenceLength)..<((index + 1) * sequenceLength)]
    }

    /// The token ids of one row.
    public func inputIDs(row index: Int) -> ArraySlice<Int32> { row(index, of: inputIDs) }
    /// The attention mask of one row.
    public func attentionMask(row index: Int) -> ArraySlice<Int32> { row(index, of: attentionMask) }
    /// The segment ids of one row.
    public func tokenTypeIDs(row index: Int) -> ArraySlice<Int32> { row(index, of: tokenTypeIDs) }
}

/// What a model returned for one row of a batch: a tensor, flattened in row-major order.
public struct ModelOutputRow: Sendable, Hashable {
    /// The shape of the tensor, batch dimension included or not.
    public var shape: [Int]
    /// The elements, in row-major order.
    public var values: [Float]

    /// Creates an output row from a shape and its elements.
    public init(shape: [Int], values: [Float]) {
        self.shape = shape
        self.values = values
    }

    /// The shape without leading dimensions of size one: `[1, 128, 384]` and `[128, 384]` are
    /// the same tensor to the adapters.
    var significantShape: [Int] {
        Array(shape.drop(while: { $0 == 1 }))
    }
}

/// How a sentence vector is made from what the embedding model returns.
public enum EmbeddingPoolingStrategy: Sendable, Hashable {
    /// Mean-pool when the model returns token embeddings; take the output as it is when the
    /// model pools by itself.
    case automatic
    /// The mean of the token embeddings, weighted by the attention mask.
    case mean
    /// The embedding of the first token.
    case firstToken
}

/// The arithmetic between a model's raw output and a unit-length sentence vector.
public enum EmbeddingPooling: Sendable {
    /// The mean of the token embeddings over the tokens the attention mask keeps.
    ///
    /// - Parameters:
    ///   - tokenEmbeddings: `sequenceLength * hiddenSize` values, one row per token.
    ///   - attentionMask: `sequenceLength` values; padding is 0 and does not count.
    public static func meanPool<Mask: Collection>(
        tokenEmbeddings: [Float],
        sequenceLength: Int,
        hiddenSize: Int,
        attentionMask: Mask
    ) throws -> [Float] where Mask.Element == Int32 {
        guard sequenceLength > 0, hiddenSize > 0, tokenEmbeddings.count == sequenceLength * hiddenSize else {
            throw SemanticError.unexpectedModelOutput(
                "\(tokenEmbeddings.count) values do not make \(sequenceLength) token embeddings of \(hiddenSize) dimensions"
            )
        }
        guard attentionMask.count == sequenceLength else {
            throw SemanticError.unexpectedModelOutput("the attention mask covers \(attentionMask.count) tokens, the output \(sequenceLength)")
        }
        let weights = attentionMask.map { $0 == 0 ? Float(0) : Float(1) }
        var tokenCount: Float = 0
        vDSP_sve(weights, 1, &tokenCount, vDSP_Length(sequenceLength))
        guard tokenCount > 0 else {
            throw SemanticError.unexpectedModelOutput("the attention mask keeps no token")
        }
        // pooled = weights (1 x sequence) * embeddings (sequence x hidden), then the mean.
        var pooled = [Float](repeating: 0, count: hiddenSize)
        pooled.withUnsafeMutableBufferPointer { buffer in
            guard let target = buffer.baseAddress else { return }
            vDSP_mmul(weights, 1, tokenEmbeddings, 1, target, 1, 1, vDSP_Length(hiddenSize), vDSP_Length(sequenceLength))
            vDSP_vsdiv(target, 1, &tokenCount, target, 1, vDSP_Length(hiddenSize))
        }
        return pooled
    }

    /// Scales a pooled vector to unit length.
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        guard let unit = VectorKernels.normalized(vector) else {
            throw SemanticError.unexpectedModelOutput("the model returned a vector without direction")
        }
        return unit
    }

    /// The unit-length sentence vector for one row of the embedding model's output.
    ///
    /// A rank-1 output is a vector the model pooled itself. A rank-2 output is one embedding
    /// per token, pooled here according to `strategy`.
    ///
    /// - Throws: ``SemanticError/dimensionMismatch(expected:found:)`` when the model's width is
    ///   not `dimensions`; ``SemanticError/unexpectedModelOutput(_:)`` for any other surprise.
    public static func sentenceVector<Mask: Collection>(
        from output: ModelOutputRow,
        attentionMask: Mask,
        strategy: EmbeddingPoolingStrategy,
        dimensions: Int
    ) throws -> [Float] where Mask.Element == Int32 {
        let shape = output.significantShape
        guard output.values.count == shape.reduce(1, *) || (shape.isEmpty && output.values.count == 1) else {
            throw SemanticError.unexpectedModelOutput("\(output.values.count) values for a tensor of shape \(output.shape)")
        }
        let pooled: [Float]
        switch shape.count {
        case 0, 1:
            pooled = output.values
        case 2:
            let sequenceLength = shape[0]
            let hiddenSize = shape[1]
            switch strategy {
            case .automatic, .mean:
                pooled = try meanPool(
                    tokenEmbeddings: output.values, sequenceLength: sequenceLength, hiddenSize: hiddenSize, attentionMask: attentionMask
                )
            case .firstToken:
                pooled = Array(output.values.prefix(hiddenSize))
            }
        default:
            throw SemanticError.unexpectedModelOutput("an embedding output of shape \(output.shape) is neither a vector nor one vector per token")
        }
        guard pooled.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: pooled.count)
        }
        return try normalized(pooled)
    }
}

/// The arithmetic between a cross-encoder's raw output and a relevance score.
public enum RelevanceScoring: Sendable {
    /// The relevance score of one (query, passage) pair; higher is more relevant.
    ///
    /// A single logit is the score. Two logits are a binary classifier, irrelevant and
    /// relevant: the score is their margin.
    public static func score(from output: ModelOutputRow) throws -> Float {
        let score: Float
        switch output.values.count {
        case 1:
            score = output.values[0]
        case 2:
            score = output.values[1] - output.values[0]
        default:
            throw SemanticError.unexpectedModelOutput("a relevance output of shape \(output.shape) is neither one logit nor two")
        }
        guard score.isFinite else {
            throw SemanticError.unexpectedModelOutput("the model returned a score that is not finite")
        }
        return score
    }
}
