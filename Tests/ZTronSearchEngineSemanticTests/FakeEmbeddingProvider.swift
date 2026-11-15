import Foundation
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

/// The deterministic fake the specification asks for (section 7.3): a bag of concepts.
///
/// Every word maps to a concept, a few translations and synonyms share one, and every concept
/// has a fixed pseudo-random direction derived from its name. A text is the normalized sum of
/// the directions of its words, so texts that share concepts are close, whatever the language.
/// The provider counts model loads the way a real one would incur them: lazily, on the first
/// encoding after creation or after an unload.
actor FakeEmbeddingProvider: EmbeddingProvider {
    nonisolated let modelID: String
    nonisolated let dimensions: Int

    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var encodedTexts: [String] = []
    private var isLoaded = false

    /// When set, every encoding fails with it.
    private var failure: (any Error)?
    /// When set, every encoding returns it instead of the embedding.
    private var override: [Float]?
    /// When set, encoding this text cancels the task that asked for it, the way a host
    /// cancelling a sync would, at a point the test controls.
    private var cancellingText: String?

    private static let concepts: [String: String] = [
        "gatto": "cat", "chat": "cat", "katze": "cat", "cats": "cat",
        "cane": "dog", "chien": "dog", "hund": "dog", "dogs": "dog",
        "mappa": "map", "carte": "map", "karte": "map", "maps": "map",
        "consiglio": "tip", "astuce": "tip", "tipp": "tip", "tips": "tip", "hint": "tip",
        "strumento": "tool", "outil": "tool", "werkzeug": "tool", "tools": "tool",
        "gioco": "game", "jeu": "game", "spiel": "game", "games": "game",
    ]

    init(modelID: String = "fake-embedding-v1", dimensions: Int = 64) {
        self.modelID = modelID
        self.dimensions = dimensions
    }

    func encode(_ text: String, locale: Locale?) async throws -> [Float] {
        if !isLoaded {
            isLoaded = true
            loadCount += 1
        }
        encodedTexts.append(text)
        if text == cancellingText {
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        }
        if let failure { throw failure }
        if let override { return override }
        return Self.embed(text, dimensions: dimensions)
    }

    func unload() async {
        if isLoaded {
            isLoaded = false
            unloadCount += 1
        }
    }

    var isModelLoaded: Bool { isLoaded }

    func fail(with error: (any Error)?) { failure = error }
    func respond(with vector: [Float]?) { override = vector }
    func cancelTask(whenEncoding text: String?) { cancellingText = text }

    /// The embedding of a text: pure, so tests can compute expected vectors without a provider.
    static func embed(_ text: String, dimensions: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: dimensions)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for word in words {
            let concept = concepts[String(word)] ?? String(word)
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in concept.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
            }
            var generator = SeededGenerator(seed: hash)
            let direction = generator.unitVector(dimensions)
            for index in 0..<dimensions { sum[index] += direction[index] }
        }
        if !VectorKernels.normalize(&sum) {
            // A text without words still needs a direction.
            sum[0] = 1
        }
        return sum
    }
}
