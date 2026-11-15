import Foundation

/// One neighbour returned by the semantic channel.
public struct SemanticMatch: Sendable, Hashable {
    public let id: SearchableID
    /// Cosine similarity between the query and the item, in -1...1.
    public let similarity: Float

    public init(id: SearchableID, similarity: Float) {
        self.id = id
        self.similarity = similarity
    }
}

/// The boundary through which the semantic channel is injected into core.
///
/// Core never imports `ZTronSearchEngineSemantic`; it only streams through this protocol, so the
/// model is swappable and tests use a deterministic fake (specification section 7.3).
///
/// Encoding and neighbour search are separate calls on purpose. Indexed contexts ask for the
/// nearest neighbours of the encoded query; scan contexts only ask for the encoding and compare
/// it with the vectors their items carry by brute-force dot product, never through HNSW
/// (section 9.1, rule 4).
public protocol SemanticSearching: Sendable {
    /// Identity of the embedding space. Recorded in persisted indexes; a mismatch discards them.
    var modelID: String { get }
    /// Dimensions of every vector in the space; at most 384.
    var dimensions: Int { get }

    /// Encodes a query into a unit-length vector. Only queries are ever encoded at runtime.
    func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float]
    /// The `limit` nearest items to a query vector, best first.
    func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch]

    /// Adds or replaces precomputed item vectors.
    func upsert(_ vectors: [SearchableID: [Float]]) async throws
    func remove(_ ids: [SearchableID]) async

    /// Switches to the vector set shipped for a locale, with base fallback, when the pipeline
    /// ships per-locale sets. Items are never re-embedded on device.
    func setLocale(_ languageTag: String) async
    /// Releases the embedding model. It reloads lazily on the next query.
    func unload() async
}

extension SemanticSearching {
    public func setLocale(_ languageTag: String) async {}
}

/// The boundary through which the cross-encoder stage is injected into core (section 7.4).
public protocol Reranking: Sendable {
    var modelID: String { get }

    /// The capability gate under ``RerankingMode/auto``: the persisted calibration verdict,
    /// measured on first use. Never consulted under `.on` or `.off`.
    func isEnabled() async -> Bool
    /// Scores each (query, passage) pair in one batched call; higher is more relevant.
    func scores(query: String, passages: [String]) async throws -> [Float]
    /// Called after three consecutive cap breaches: the verdict must be measured again at the
    /// next launch.
    func invalidateCalibration() async
    /// Releases the model. It reloads lazily on the next rerank.
    func unload() async
}

extension Reranking {
    public func invalidateCalibration() async {}
}
