import Foundation
import ZTronSearchEngine

/// The production ``Reranking`` model: a multilingual cross-encoder converted to Core ML
/// (`Scripts/convert_cross_encoder.py`).
///
/// A cross-encoder reads the query and a candidate together, a full transformer pass per pair,
/// so its cost grows with the number of candidates and nothing can be precomputed
/// (specification section 7.4). ``scores(query:passages:)`` tokenizes every (query, passage)
/// pair into one 128-token window, the passage giving way when the pair is too long, and runs
/// all of them in one batched call.
///
/// The model loads lazily on the first rerank and ``unload()`` releases it. A model whose files
/// exceed the size budget (60 MB, specification section 15.5) is refused before anything is
/// loaded.
///
/// On its own the adapter is never enabled under core's `.auto` mode: whether a device can
/// afford the stage is measured, not assumed. Wrap it in a ``CalibratedReranker``
/// (``calibrated(store:environment:thresholds:)``) to let the calibration gate decide.
///
/// Like ``CoreMLEmbeddingProvider``, the actor runs on its own serial queue so that Core ML's
/// synchronous calls never block the cooperative thread pool.
public actor CoreMLCrossEncoder: Reranking {
    /// Settings of a ``CoreMLCrossEncoder``.
    public struct Configuration: Sendable, Hashable {
        /// The compiled model, a `.mlmodelc` directory.
        public var modelURL: URL
        /// Identity of the model; the calibration verdict is stored under it.
        public var modelID: String
        /// Processors Core ML may use. The stage is only affordable on the Neural Engine.
        public var computeUnits: ModelComputeUnits
        /// The window of one (query, passage) pair, in tokens.
        public var sequenceLength: Int
        /// The names of the model's inputs and output.
        public var features: ModelFeatureNames
        /// Where the tokenizer files are. `nil` looks next to the model.
        public var tokenizerDirectory: URL?
        /// The most the model may take on disk, in bytes.
        public var sizeBudget: Int64

        /// Creates a configuration; the window is at least one token.
        public init(
            modelURL: URL,
            modelID: String,
            computeUnits: ModelComputeUnits = .all,
            sequenceLength: Int = SemanticLimits.tokenWindow,
            features: ModelFeatureNames = ModelFeatureNames(),
            tokenizerDirectory: URL? = nil,
            sizeBudget: Int64 = SemanticLimits.rerankerModelBudget
        ) {
            self.modelURL = modelURL
            self.modelID = modelID
            self.computeUnits = computeUnits
            self.sequenceLength = max(1, sequenceLength)
            self.features = features
            self.tokenizerDirectory = tokenizerDirectory
            self.sizeBudget = sizeBudget
        }
    }

    /// The id of the model; the calibration verdict is stored under it.
    public nonisolated let modelID: String
    /// The settings the adapter was created with.
    public nonisolated let configuration: Configuration

    private let loader: SequenceModelLoader
    private let executor: SerialQueueExecutor
    private var tokenizer: (any TextTokenizing)?
    private var model: (any SequenceModelRunning)?

    /// The adapter's private serial queue: Core ML's synchronous calls run there, not on the
    /// cooperative thread pool.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Creates an adapter for the compiled model named by `configuration`. Nothing is loaded yet.
    public init(configuration: Configuration) {
        self.init(configuration: configuration, loader: .coreML)
    }

    /// The designated initializer; tests substitute the loader.
    init(configuration: Configuration, loader: SequenceModelLoader) {
        self.configuration = configuration
        self.modelID = configuration.modelID
        self.loader = loader
        self.executor = SerialQueueExecutor(label: "com.ztron.searchengine.semantic.cross-encoder")
    }

    /// `true` while the model is in memory.
    public var isLoaded: Bool { model != nil }
    /// How many times the model was brought into memory since the adapter was created.
    public private(set) var loadCount = 0
    /// How many calls the model has served. A rerank is one call, whatever the number of pairs.
    public private(set) var predictionCount = 0

    /// Always `false`: an uncalibrated model is never enabled under `.auto`.
    ///
    /// Core consults this only under ``RerankingMode/auto``. The answer there has to be the
    /// persisted verdict of a calibration pass, which is what ``CalibratedReranker`` returns.
    public func isEnabled() async -> Bool {
        false
    }

    /// Scores every (query, passage) pair in one batched call; higher is more relevant.
    ///
    /// - Returns: One score per passage, in order.
    /// - Throws: ``SemanticError/modelOverBudget(bytes:budget:)``,
    ///   ``SemanticError/tokenizerUnavailable(_:)``, ``SemanticError/modelUnavailable(_:)`` or
    ///   ``SemanticError/unexpectedModelOutput(_:)``; `CancellationError` when the task is
    ///   cancelled before the model runs.
    public func scores(query: String, passages: [String]) async throws -> [Float] {
        guard !passages.isEmpty else { return [] }
        try Task.checkCancellation()
        let (tokenizer, model) = try load()
        let batch = ModelInputBatch.pairs(
            query: query, passages: passages, tokenizer: tokenizer, sequenceLength: configuration.sequenceLength
        )
        predictionCount += 1
        let outputs = try model.predict(batch)
        guard outputs.count == passages.count else {
            throw SemanticError.unexpectedModelOutput("\(outputs.count) scores for \(passages.count) pairs")
        }
        return try outputs.map(RelevanceScoring.score(from:))
    }

    /// Releases the model and its tokenizer. They load again on the next rerank.
    public func unload() async {
        model = nil
        tokenizer = nil
    }

    private func load() throws -> (any TextTokenizing, any SequenceModelRunning) {
        if let tokenizer, let model { return (tokenizer, model) }
        // The budget first: a model that does not fit is refused before anything is loaded.
        let bytes = try loader.footprint(configuration.modelURL)
        guard bytes <= configuration.sizeBudget else {
            throw SemanticError.modelOverBudget(bytes: bytes, budget: configuration.sizeBudget)
        }
        let tokenizer = try loader.tokenizer(configuration.modelURL, configuration.tokenizerDirectory)
        let model = try loader.model(
            configuration.modelURL, configuration.computeUnits, configuration.features, configuration.sequenceLength, .relevance
        )
        self.tokenizer = tokenizer
        self.model = model
        loadCount += 1
        return (tokenizer, model)
    }
}
