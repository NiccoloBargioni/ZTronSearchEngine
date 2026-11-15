import Foundation

/// Failures reported by the semantic channel and the rerank stage.
///
/// Every case names a condition a host can act on: a file written for another model is
/// discarded and rebuilt, a model over its budget is not shipped, and so on.
public enum SemanticError: Error, Sendable, Equatable {
    /// A vector file or graph file was written for another embedding model.
    case modelMismatch(expected: String, found: String)
    /// A vector, or a file, does not have the number of dimensions the caller expects.
    case dimensionMismatch(expected: Int, found: Int)
    /// The embedding space has no dimensions, or more than ``SemanticLimits/maximumDimensions``.
    case unsupportedDimensions(Int)
    /// A vector holds a value that is not finite, or has no direction (zero length).
    case invalidVector(String)
    /// A vector file or graph file is truncated or internally inconsistent.
    case corruptFile(String)
    /// A file was written by a format version this build does not read.
    case unsupportedFormatVersion(found: UInt32, supported: UInt32)
    /// A graph file does not belong to the vector store it is being attached to.
    case graphStoreMismatch(String)
    /// Reading or writing a file failed.
    case io(String)
    /// The model on disk is larger than its budget (80 MB embedding, 60 MB reranker); it is not loaded.
    case modelOverBudget(bytes: Int64, budget: Int64)
    /// The model cannot be loaded or does not expose the features the adapter needs.
    case modelUnavailable(String)
    /// No usable tokenizer files sit next to the model, or they cannot be read.
    case tokenizerUnavailable(String)
    /// The model answered with an output of an unexpected type or shape.
    case unexpectedModelOutput(String)
    /// An HNSW parameter is outside its supported range.
    case invalidConfiguration(String)
}

extension SemanticError: CustomStringConvertible, LocalizedError {
    /// A one-line description of the failure, for logs.
    public var description: String {
        switch self {
        case .modelMismatch(let expected, let found):
            return "written for embedding model '\(found)', expected '\(expected)'"
        case .dimensionMismatch(let expected, let found):
            return "\(found) dimensions, expected \(expected)"
        case .unsupportedDimensions(let dimensions):
            return "\(dimensions) dimensions; the supported range is 1...\(SemanticLimits.maximumDimensions)"
        case .invalidVector(let reason):
            return "invalid vector: \(reason)"
        case .corruptFile(let reason):
            return "corrupt file: \(reason)"
        case .unsupportedFormatVersion(let found, let supported):
            return "format version \(found); this build reads version \(supported)"
        case .graphStoreMismatch(let reason):
            return "the graph does not belong to this vector store: \(reason)"
        case .io(let reason):
            return "file access failed: \(reason)"
        case .modelOverBudget(let bytes, let budget):
            return "the model takes \(bytes) bytes on disk, over its budget of \(budget) bytes; it was not loaded"
        case .modelUnavailable(let reason):
            return "the model is unavailable: \(reason)"
        case .tokenizerUnavailable(let reason):
            return "the tokenizer is unavailable: \(reason)"
        case .unexpectedModelOutput(let reason):
            return "unexpected model output: \(reason)"
        case .invalidConfiguration(let reason):
            return "invalid configuration: \(reason)"
        }
    }

    /// The description, for `LocalizedError`.
    public var errorDescription: String? { description }
}

/// Fixed limits of the semantic channel (specification sections 7.3 and 10).
public enum SemanticLimits: Sendable {
    /// Item and query vectors have at most this many dimensions.
    public static let maximumDimensions = 384
    /// The input window of both models, in tokens.
    public static let tokenWindow = 128
    /// On-disk budget of the embedding model (specification section 15.5).
    public static let embeddingModelBudget: Int64 = 80 * 1024 * 1024
    /// On-disk budget of the cross-encoder (specification section 15.5).
    public static let rerankerModelBudget: Int64 = 60 * 1024 * 1024
}
