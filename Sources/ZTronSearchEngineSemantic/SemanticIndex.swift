import Foundation
import os
import ZTronSearchEngine

/// The semantic channel: the implementation of core's ``SemanticSearching`` boundary.
///
/// It owns an ``EmbeddingProvider``, which encodes queries, and an ``HNSWIndex`` over a
/// ``QuantizedVectorStore``, which holds the item vectors. Item vectors are precomputed at
/// build or sync time and only the query is encoded at runtime (specification sections 7.3
/// and 10):
///
/// - Vectors that ship with the app are loaded from a vector file and a graph file, both
///   memory-mapped, with no rebuild.
/// - Vectors that items carry arrive through ``upsert(_:)``.
/// - Text is embedded on device only when the host asks for it, through
///   ``embedMissing(_:locale:)`` at sync time. Nothing calls it automatically.
///
/// The embedding model loads lazily, on the first ``encodeQuery(_:locale:)``, and
/// ``unload()`` releases it; core calls `unload()` after 60 s without a semantic query and on
/// memory warnings.
///
/// Changes are serialized among themselves; searches never wait for them and run against the
/// state they find.
public actor SemanticIndex: SemanticSearching {
    /// Settings of a ``SemanticIndex``.
    public struct Configuration: Sendable, Hashable {
        /// Parameters of the HNSW graph when it is built on device. A graph that ships with the
        /// app keeps the parameters it was built with, except the two that only matter at
        /// search time, `efSearch` and `efEntry`, which are taken from here.
        public var hnsw: HNSWConfiguration
        /// A set created from vectors that arrive at runtime starts with a quantization range
        /// that fits any unit vector. Once it holds this many vectors the ranges are fitted to
        /// them, once, which is several times more precise.
        public var quantizationSampleCount: Int

        /// Creates settings; the sample count is at least 2.
        public init(
            hnsw: HNSWConfiguration = .default,
            quantizationSampleCount: Int = VectorQuantization.defaultMinimumSampleCount
        ) {
            self.hnsw = hnsw
            self.quantizationSampleCount = max(2, quantizationSampleCount)
        }

        /// The specification's defaults: M = 16, efSearch = 64, ranges fitted from 256 vectors on.
        public static let `default` = Configuration()
    }

    /// Identity of the embedding space: the provider's model id. Recorded in persisted indexes.
    public nonisolated let modelID: String
    /// Dimensions of every vector in the space; at most 384.
    public nonisolated let dimensions: Int
    /// The settings the index was created with.
    public nonisolated let configuration: Configuration

    private let provider: any EmbeddingProvider
    private let catalog: VectorSetCatalog?
    /// `nil` until the first vector arrives.
    private var index: HNSWIndex?
    /// Key of the per-locale set in use; `nil` for the base set or a set created at runtime.
    private var activeSet: String?
    /// `true` while a set created at runtime still uses the unfitted quantization range.
    private var isQuantizationProvisional = false
    /// The exact vectors of a set that is still provisional, so that the refit quantizes the
    /// originals and not their coarse codes. Never more than `quantizationSampleCount` vectors.
    private var provisionalVectors: [SearchableID: [Float]] = [:]
    /// Ids changed at runtime, so that a locale switch can carry the changes to the next set.
    private var upsertedAtRuntime: Set<SearchableID> = []
    private var removedAtRuntime: Set<SearchableID> = []

    private var isChanging = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Creation

    /// An empty index. Item vectors arrive through ``upsert(_:)`` or ``embedMissing(_:locale:)``.
    ///
    /// - Throws: ``SemanticError/unsupportedDimensions(_:)`` when the provider's space has no
    ///   dimensions or more than 384.
    public init(provider: any EmbeddingProvider, configuration: Configuration = .default) throws {
        try Self.checkDimensions(of: provider)
        self.provider = provider
        self.modelID = provider.modelID
        self.dimensions = provider.dimensions
        self.configuration = configuration
        self.catalog = nil
    }

    /// An index over a vector file and the graph file that ship with the app.
    ///
    /// Both files are memory-mapped; nothing is rebuilt. Pass `graph: nil` to build the graph
    /// on device instead, which costs about a millisecond per vector.
    ///
    /// - Throws: ``SemanticError/modelMismatch(expected:found:)`` or
    ///   ``SemanticError/dimensionMismatch(expected:found:)`` when the files were written for
    ///   another model than `provider`; ``SemanticError/graphStoreMismatch(_:)`` when the graph
    ///   file does not belong to the vector file.
    public init(
        provider: any EmbeddingProvider,
        vectors: URL,
        graph: URL?,
        configuration: Configuration = .default
    ) async throws {
        try await self.init(
            provider: provider,
            catalog: VectorSetCatalog(base: .init(vectors: vectors, graph: graph)),
            languageTag: nil,
            configuration: configuration
        )
    }

    /// An index over the vector sets a pipeline ships, starting with the set of `languageTag`.
    ///
    /// The set of the active locale is loaded, with base fallback (specification section 5,
    /// rule 8); ``setLocale(_:)`` switches sets. Items are never re-embedded on device.
    public init(
        provider: any EmbeddingProvider,
        catalog: VectorSetCatalog,
        languageTag: String?,
        configuration: Configuration = .default
    ) async throws {
        try Self.checkDimensions(of: provider)
        let loaded = try await Self.load(
            catalog, languageTag: languageTag,
            expecting: .init(modelID: provider.modelID, dimensions: provider.dimensions),
            hnsw: configuration.hnsw
        )
        self.provider = provider
        self.modelID = provider.modelID
        self.dimensions = provider.dimensions
        self.configuration = configuration
        self.catalog = catalog
        self.index = loaded.index
        self.activeSet = loaded.languageTag
    }

    // MARK: SemanticSearching

    /// Encodes a query into a unit-length vector. The model loads on the first call.
    public func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] {
        var vector = try await provider.encode(text, locale: locale)
        guard vector.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
        }
        guard VectorKernels.normalize(&vector) else {
            throw SemanticError.invalidVector("the embedding provider returned a vector without direction")
        }
        return vector
    }

    /// The `limit` items nearest to a query vector, best first, with their cosine similarity.
    public func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] {
        guard vector.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
        }
        guard let query = Self.unitLength(vector) else {
            throw SemanticError.invalidVector("the query vector has no direction")
        }
        guard limit > 0, let index else { return [] }
        return try await index.search(query, limit: limit)
    }

    /// Adds or replaces precomputed item vectors.
    ///
    /// Every vector is checked before the first one is stored: a vector of the wrong length or
    /// without direction throws and changes nothing. Vectors are scaled to unit length, and an
    /// item whose vector is already stored costs nothing, so repeating an upsert is free.
    public func upsert(_ vectors: [SearchableID: [Float]]) async throws {
        guard !vectors.isEmpty else { return }
        var entries: [(SearchableID, [Float])] = []
        entries.reserveCapacity(vectors.count)
        // In id order: a dictionary iterates in an order that changes from run to run, and the
        // graph depends on the order of insertion.
        for (id, vector) in vectors.sorted(by: { $0.key < $1.key }) {
            guard vector.count == dimensions else {
                throw SemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
            }
            guard let unit = Self.unitLength(vector) else {
                throw SemanticError.invalidVector("the vector of '\(id)' has no direction")
            }
            entries.append((id, unit))
        }
        try await exclusively {
            try await store(entries)
        }
    }

    /// Removes the vectors of `ids`. They stop being returned from the next search on.
    public func remove(_ ids: [SearchableID]) async {
        guard !ids.isEmpty else { return }
        await exclusively {
            guard let index else { return }
            let removed = await index.remove(contentsOf: ids)
            for id in removed {
                provisionalVectors[id] = nil
            }
            if tracksRuntimeChanges {
                upsertedAtRuntime.subtract(removed)
                removedAtRuntime.formUnion(removed)
            }
        }
    }

    /// Switches to the vector set shipped for a locale, with base fallback.
    ///
    /// Vectors added or removed at runtime are carried over to the new set. When the set
    /// cannot be loaded the current one stays in use; the failure is logged.
    public func setLocale(_ languageTag: String) async {
        guard let catalog, !catalog.localized.isEmpty else { return }
        await exclusively {
            guard catalog.resolve(languageTag).languageTag != activeSet else { return }
            do {
                let loaded = try await Self.load(
                    catalog, languageTag: languageTag,
                    expecting: .init(modelID: modelID, dimensions: dimensions),
                    hnsw: configuration.hnsw
                )
                guard loaded.languageTag != activeSet else { return }
                if let index, !upsertedAtRuntime.isEmpty {
                    let carried = await index.vectors(for: upsertedAtRuntime.sorted())
                    try await loaded.index.insert(contentsOf: carried)
                }
                if !removedAtRuntime.isEmpty {
                    await loaded.index.remove(contentsOf: removedAtRuntime.sorted())
                }
                index = loaded.index
                activeSet = loaded.languageTag
            } catch {
                Logger.semantic.error(
                    "cannot switch to the vector set of '\(languageTag, privacy: .public)': \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Releases the embedding model. It loads again on the next ``encodeQuery(_:locale:)``.
    public func unload() async {
        await provider.unload()
    }

    // MARK: Sync-time embedding

    /// Embeds the items that have no vector yet and stores the result.
    ///
    /// This is the only place item text is encoded on device, and only the host calls it, at
    /// sync time: no query, upsert or locale change ever triggers it. Items that already hold
    /// a vector are skipped, so the call can be repeated. Cancelling the task stops between
    /// two items; what was embedded until then is kept.
    ///
    /// The embedding model is loaded by the first item and stays loaded: call ``unload()``
    /// afterwards, and ``save(vectorsTo:graphTo:)`` so the next launch finds the vectors.
    ///
    /// - Parameters:
    ///   - texts: Id and embedding text of the items, the deterministic composition of
    ///     specification section 7.3 (`EmbeddableSearchable.embeddingText`).
    ///   - locale: The language of the texts, when known.
    /// - Returns: The ids that were embedded.
    @discardableResult
    public func embedMissing(_ texts: [(SearchableID, String)], locale: Locale? = nil) async throws -> [SearchableID] {
        let known = await index?.snapshotStore()
        var seen: Set<SearchableID> = []
        var pending: [(SearchableID, [Float])] = []
        var embedded: [SearchableID] = []

        for (id, text) in texts {
            guard known?.contains(id) != true, seen.insert(id).inserted else { continue }
            do {
                try Task.checkCancellation()
                pending.append((id, try await encodeQuery(text, locale: locale)))
            } catch {
                // Keep what was embedded before the failure. The task may be cancelled, and
                // storing must not be: it runs in a task of its own.
                let batch = pending
                _ = try await Task { try await self.storeMissing(batch) }.value
                throw error
            }
            if pending.count >= 32 {
                embedded.append(contentsOf: try await storeMissing(pending))
                pending.removeAll(keepingCapacity: true)
            }
        }
        embedded.append(contentsOf: try await storeMissing(pending))
        return embedded
    }

    /// Stores the vectors of a batch of freshly embedded items. An item that received a vector
    /// in the meantime keeps it.
    private func storeMissing(_ batch: [(SearchableID, [Float])]) async throws -> [SearchableID] {
        guard !batch.isEmpty else { return [] }
        return try await exclusively {
            let current = await index?.snapshotStore()
            let missing = batch.filter { current?.contains($0.0) != true }
            try await store(missing)
            return missing.map(\.0)
        }
    }

    // MARK: Persistence and maintenance

    /// Writes the vector file and the graph file of the current state, for the next launch.
    ///
    /// Vectors that arrived at runtime are written with the ones that shipped. The files are
    /// written off the cooperative thread pool, each atomically, one after the other: should
    /// the process die between the two, the pair no longer matches, loading it throws
    /// ``SemanticError/graphStoreMismatch(_:)``, and loading the vector file with `graph: nil`
    /// rebuilds the graph.
    public func save(vectorsTo vectorsURL: URL, graphTo graphURL: URL) async throws {
        try await exclusively {
            if let index {
                try await index.write(vectorsTo: vectorsURL, graphTo: graphURL)
            } else {
                let empty = try HNSWIndex(
                    modelID: modelID, dimensions: dimensions,
                    quantization: .uniform(dimensions: dimensions), configuration: configuration.hnsw
                )
                try await empty.write(vectorsTo: vectorsURL, graphTo: graphURL)
            }
        }
    }

    /// Rebuilds the set without the tombstones that replacements and removals left behind.
    ///
    /// Tombstones cost memory and search time; a rebuild costs about a millisecond per vector.
    /// Worth calling at sync time once ``tombstoneCount`` is a sizeable share of the vectors.
    public func compact() async throws {
        try await exclusively {
            guard let index, await index.tombstoneCount > 0 else { return }
            self.index = try await index.compacted()
        }
    }

    // MARK: State

    /// Item vectors the index can return.
    public var count: Int {
        get async { await index?.count ?? 0 }
    }

    /// Rows retired by replacements and removals since the set was built or compacted.
    public var tombstoneCount: Int {
        get async { await index?.tombstoneCount ?? 0 }
    }

    /// `true` when the item holds a vector.
    public func contains(_ id: SearchableID) async -> Bool {
        await index?.contains(id) ?? false
    }

    /// The vector stored for an item, decoded from its INT8 codes.
    public func vector(for id: SearchableID) async -> [Float]? {
        await index?.vector(for: id)
    }

    /// The key of the per-locale vector set in use; `nil` for the base set.
    public var activeLanguageTag: String? { activeSet }

    // MARK: Internals

    private static func checkDimensions(of provider: any EmbeddingProvider) throws {
        guard (1...SemanticLimits.maximumDimensions).contains(provider.dimensions) else {
            throw SemanticError.unsupportedDimensions(provider.dimensions)
        }
    }

    /// `vector` at unit length, or `nil` when it has no direction or holds a value that is not
    /// finite. A vector that is already unit length is returned as it is, without a copy:
    /// embeddings normally are, and an upsert of 100,000 of them should not double its memory.
    private static func unitLength(_ vector: [Float]) -> [Float]? {
        let squared = vector.withUnsafeBufferPointer { values in
            values.baseAddress.map { VectorKernels.squaredNorm($0, count: values.count) } ?? 0
        }
        guard squared.isFinite, squared > 0 else { return nil }
        if abs(squared - 1) < 1e-5 { return vector }
        return VectorKernels.normalized(vector)
    }

    /// Loads the set for a locale: the per-locale set when it is usable, else the base set.
    private static func load(
        _ catalog: VectorSetCatalog,
        languageTag: String?,
        expecting expectation: QuantizedVectorStore.Expectation,
        hnsw: HNSWConfiguration
    ) async throws -> (index: HNSWIndex, languageTag: String?) {
        func open(_ files: VectorSetCatalog.Files) async throws -> HNSWIndex {
            let store = try QuantizedVectorStore.open(files.vectors, expecting: expectation)
            if let graph = files.graph {
                return try HNSWIndex(store: store, graphAt: graph, efSearch: hnsw.efSearch, efEntry: hnsw.efEntry)
            }
            return try await HNSWIndex.build(over: store, configuration: hnsw)
        }

        let resolution = catalog.resolve(languageTag)
        if let tag = resolution.languageTag {
            do {
                return (try await open(resolution.files), tag)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.semantic.error(
                    "vector set '\(tag, privacy: .public)' is unusable, falling back to the base set: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return (try await open(catalog.base), nil)
    }

    /// Runtime changes only need tracking when there is another set to carry them to.
    private var tracksRuntimeChanges: Bool {
        catalog.map { !$0.localized.isEmpty } ?? false
    }

    /// Stores validated, unit-length vectors. Runs inside ``exclusively(_:)``.
    private func store(_ entries: [(SearchableID, [Float])]) async throws {
        guard !entries.isEmpty else { return }
        if let index, isQuantizationProvisional {
            var all = provisionalVectors
            for entry in entries {
                all[entry.0] = entry.1
            }
            if all.count >= configuration.quantizationSampleCount {
                // Enough vectors to fit real ranges: rebuild the set once, from the exact
                // vectors seen so far.
                try await create(from: all.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            } else {
                try await index.insert(contentsOf: entries)
                provisionalVectors = all
            }
        } else if let index {
            try await index.insert(contentsOf: entries)
        } else {
            try await create(from: entries)
        }
        if tracksRuntimeChanges {
            for entry in entries {
                upsertedAtRuntime.insert(entry.0)
                removedAtRuntime.remove(entry.0)
            }
        }
    }

    /// Builds a set from vectors that arrived at runtime.
    private func create(from entries: [(SearchableID, [Float])]) async throws {
        let quantization = try VectorQuantization.fitted(
            to: entries.map(\.1), dimensions: dimensions,
            minimumSampleCount: configuration.quantizationSampleCount
        )
        let store = try QuantizedVectorStore.build(from: entries, modelID: modelID, dimensions: dimensions, quantization: quantization)
        index = try await HNSWIndex.build(over: store, configuration: configuration.hnsw)
        isQuantizationProvisional = store.count < configuration.quantizationSampleCount
        provisionalVectors = isQuantizationProvisional ? Dictionary(entries, uniquingKeysWith: { _, last in last }) : [:]
    }

    /// Runs `body` after every change that was requested before it has finished.
    ///
    /// Actors are reentrant: an `await` inside a change lets the next one start. Changes that
    /// span suspension points (a locale switch, a refit) must not interleave, so they queue
    /// here. The queue never blocks a thread: a waiter is suspended and handed the turn
    /// directly by the change that finishes before it.
    private func exclusively<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        if isChanging {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isChanging = true
        }
        defer {
            if waiters.isEmpty {
                isChanging = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await body()
    }
}
