import Foundation

/// Turns text into vectors of one embedding space.
///
/// The model behind the semantic channel is swappable: the engine only ever talks to this
/// protocol, production injects ``CoreMLEmbeddingProvider`` and tests inject a deterministic
/// fake (specification section 7.3).
///
/// Conformers load their model lazily, on the first call to ``encode(_:locale:)``, and release
/// it in ``unload()``; the next call loads it again.
public protocol EmbeddingProvider: Sendable {
    /// Identity of the embedding space. Recorded in vector files and graph files; a file written
    /// for another model is refused.
    var modelID: String { get }
    /// Dimensions of every vector the provider returns; at most
    /// ``SemanticLimits/maximumDimensions``.
    var dimensions: Int { get }

    /// Encodes `text` into a unit-length vector of ``dimensions`` components.
    ///
    /// - Parameters:
    ///   - text: The text to embed.
    ///   - locale: The language of `text` when the caller knows it; multilingual models ignore it.
    func encode(_ text: String, locale: Locale?) async throws -> [Float]

    /// Releases the model. It loads again on the next call to ``encode(_:locale:)``.
    func unload() async
}
