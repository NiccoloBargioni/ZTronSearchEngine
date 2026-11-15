import Foundation

/// The production ``EmbeddingProvider``: a multilingual sentence-embedding model converted to
/// Core ML (`Scripts/convert_embedding_model.py`).
///
/// Encoding a query tokenizes it with the tokenizer found next to the model, pads or truncates
/// it to the 128-token window, runs the model, mean-pools the token embeddings under the
/// attention mask (or takes the pooled output when the model has one) and scales the result to
/// unit length.
///
/// The model and its tokenizer load lazily, on the first call to ``encode(_:locale:)``, and
/// ``unload()`` releases them. A model whose files exceed the size budget (80 MB,
/// specification section 15.5) is refused before anything is loaded.
///
/// The actor runs on its own serial queue: loading a model and running a prediction are
/// synchronous Core ML calls that must not block the cooperative thread pool (specification
/// section 11, rule 7). `MLModel` offers an asynchronous prediction only from iOS 17 on; the
/// synchronous call on a private queue behaves the same on every system the package supports.
public actor CoreMLEmbeddingProvider: EmbeddingProvider {
    /// Settings of a ``CoreMLEmbeddingProvider``.
    public struct Configuration: Sendable, Hashable {
        /// The compiled model, a `.mlmodelc` directory.
        public var modelURL: URL
        /// Identity of the embedding space; recorded in vector files and graph files.
        public var modelID: String
        /// Width of the model's sentence vectors; at most 384.
        public var dimensions: Int
        /// Processors Core ML may use. The reference device only has the CPU.
        public var computeUnits: ModelComputeUnits
        /// The input window, in tokens.
        public var sequenceLength: Int
        /// The names of the model's inputs and output.
        public var features: ModelFeatureNames
        /// How a sentence vector is made from the model's output.
        public var pooling: EmbeddingPoolingStrategy
        /// Text put in front of every query. Some models are trained with one, e.g.
        /// `"query: "` for the multilingual-e5 family.
        public var queryPrefix: String
        /// Where the tokenizer files are. `nil` looks next to the model
        /// (``TokenizerLoader/tokenizerDirectory(forModelAt:)``).
        public var tokenizerDirectory: URL?
        /// The most the model may take on disk, in bytes.
        public var sizeBudget: Int64
        /// Release the tokenizer together with the model. A 250,000-piece vocabulary takes a
        /// few megabytes and a moment to parse; keeping it shortens the reload.
        public var releasesTokenizerOnUnload: Bool

        /// Creates a configuration; the window is at least one token.
        public init(
            modelURL: URL,
            modelID: String,
            dimensions: Int,
            computeUnits: ModelComputeUnits = .all,
            sequenceLength: Int = SemanticLimits.tokenWindow,
            features: ModelFeatureNames = ModelFeatureNames(),
            pooling: EmbeddingPoolingStrategy = .automatic,
            queryPrefix: String = "",
            tokenizerDirectory: URL? = nil,
            sizeBudget: Int64 = SemanticLimits.embeddingModelBudget,
            releasesTokenizerOnUnload: Bool = true
        ) {
            self.modelURL = modelURL
            self.modelID = modelID
            self.dimensions = dimensions
            self.computeUnits = computeUnits
            self.sequenceLength = max(1, sequenceLength)
            self.features = features
            self.pooling = pooling
            self.queryPrefix = queryPrefix
            self.tokenizerDirectory = tokenizerDirectory
            self.sizeBudget = sizeBudget
            self.releasesTokenizerOnUnload = releasesTokenizerOnUnload
        }
    }

    /// Identity of the embedding space.
    public nonisolated let modelID: String
    /// Width of the vectors the provider returns.
    public nonisolated let dimensions: Int
    /// The settings the provider was created with.
    public nonisolated let configuration: Configuration

    private let loader: SequenceModelLoader
    private let executor: SerialQueueExecutor
    private var tokenizer: (any TextTokenizing)?
    private var model: (any SequenceModelRunning)?

    /// The provider's private serial queue: Core ML's synchronous calls run there, not on the
    /// cooperative thread pool.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Creates a provider for the compiled model named by `configuration`. Nothing is loaded yet.
    public init(configuration: Configuration) {
        self.init(configuration: configuration, loader: .coreML)
    }

    /// The designated initializer; tests substitute the loader.
    init(configuration: Configuration, loader: SequenceModelLoader) {
        self.configuration = configuration
        self.modelID = configuration.modelID
        self.dimensions = configuration.dimensions
        self.loader = loader
        self.executor = SerialQueueExecutor(label: "com.ztron.searchengine.semantic.embedding-model")
    }

    /// `true` while the model is in memory.
    public var isLoaded: Bool { model != nil }
    /// How many times the model was brought into memory since the adapter was created.
    public private(set) var loadCount = 0
    /// How many calls the model has served. A rerank is one call, whatever the number of pairs.
    public private(set) var predictionCount = 0

    /// Encodes `text` into a unit-length vector, loading the model first when needed.
    ///
    /// - Throws: ``SemanticError/modelOverBudget(bytes:budget:)`` when the model exceeds its
    ///   budget, ``SemanticError/tokenizerUnavailable(_:)`` or
    ///   ``SemanticError/modelUnavailable(_:)`` when it cannot be loaded or run,
    ///   ``SemanticError/dimensionMismatch(expected:found:)`` when its width is not
    ///   ``dimensions``, `CancellationError` when the task is cancelled before the model runs.
    public func encode(_ text: String, locale: Locale?) async throws -> [Float] {
        try Task.checkCancellation()
        let (tokenizer, model) = try load()
        let batch = ModelInputBatch.texts(
            [configuration.queryPrefix + text], tokenizer: tokenizer, sequenceLength: configuration.sequenceLength
        )
        predictionCount += 1
        let outputs = try model.predict(batch)
        guard outputs.count == 1 else {
            throw SemanticError.unexpectedModelOutput("\(outputs.count) outputs for one text")
        }
        return try EmbeddingPooling.sentenceVector(
            from: outputs[0], attentionMask: batch.attentionMask(row: 0),
            strategy: configuration.pooling, dimensions: dimensions
        )
    }

    /// Releases the model. It loads again on the next ``encode(_:locale:)``.
    public func unload() async {
        model = nil
        if configuration.releasesTokenizerOnUnload {
            tokenizer = nil
        }
    }

    private func load() throws -> (any TextTokenizing, any SequenceModelRunning) {
        if let tokenizer, let model { return (tokenizer, model) }
        // The budget first: a model that does not fit is refused before anything is loaded.
        let bytes = try loader.footprint(configuration.modelURL)
        guard bytes <= configuration.sizeBudget else {
            throw SemanticError.modelOverBudget(bytes: bytes, budget: configuration.sizeBudget)
        }
        let tokenizer = try self.tokenizer ?? loader.tokenizer(configuration.modelURL, configuration.tokenizerDirectory)
        let model = try loader.model(
            configuration.modelURL, configuration.computeUnits, configuration.features, configuration.sequenceLength, .embedding
        )
        self.tokenizer = tokenizer
        self.model = model
        loadCount += 1
        return (tokenizer, model)
    }
}
