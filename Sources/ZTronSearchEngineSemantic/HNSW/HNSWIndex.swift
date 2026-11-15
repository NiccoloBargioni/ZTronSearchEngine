import Foundation
import ZTronSearchEngine

/// An approximate nearest-neighbour index: a Hierarchical Navigable Small World graph, in pure
/// Swift, over a ``QuantizedVectorStore``.
///
/// The actor owns the store and the graph, so the two can never disagree: node `n` of the graph
/// is always row `n` of the store. Searching measures the query, kept in `Float`, against the
/// stored INT8 codes with the Accelerate kernels of ``VectorKernels``.
///
/// - Inserting a vector appends a row and links a node. Replacing or removing a vector
///   tombstones the old node, which stays in the graph as a waypoint and is never returned
///   again. ``compacted(configuration:)`` rebuilds without tombstones.
/// - A search descends the upper layers with a breadth of its own
///   (``HNSWConfiguration/efEntry``) instead of the classic greedy walk, so it enters the
///   bottom layer in every region that is near the query, not in one.
/// - Levels come from a seeded, counter-based generator: the same vectors inserted in the same
///   order with the same seed give the same graph and the same results.
/// - A search checks for task cancellation every 64 node visits (specification section 11,
///   rule 4, asks for at least every 100). An insertion is never interrupted half-way; bulk
///   insertions check between vectors.
/// - The graph is written to a compact file and attached again without rebuilding; its link
///   sections are used in place from the memory-mapped file until the first change.
///
/// There is no `@unchecked Sendable` here: all mutable state is isolated to the actor, and the
/// unsafe pointers the hot loops use never outlive the call that created them.
public actor HNSWIndex {
    /// The parameters the graph was built with.
    public nonisolated let configuration: HNSWConfiguration
    /// Identity of the embedding space of the stored vectors.
    public nonisolated let modelID: String
    /// Components per vector.
    public nonisolated let dimensions: Int
    /// How the stored codes map to values.
    public nonisolated let quantization: VectorQuantization

    private var store: QuantizedVectorStore
    private var graph: HNSWGraph
    private var workspace: HNSWWorkspace

    // MARK: Creation

    /// An empty index for vectors that arrive at runtime.
    public init(
        modelID: String,
        dimensions: Int,
        quantization: VectorQuantization,
        configuration: HNSWConfiguration = .default
    ) throws {
        let store = try QuantizedVectorStore(modelID: modelID, dimensions: dimensions, quantization: quantization)
        self.init(store: store, graph: HNSWGraph(configuration: configuration))
    }

    /// Attaches the graph file that was written for `store`. Nothing is rebuilt: the file is
    /// memory-mapped and its links are used in place.
    ///
    /// This is a synchronous memory-map open, like ``QuantizedVectorStore/open(_:expecting:)``.
    ///
    /// - Parameters:
    ///   - store: The vector store the graph was built over.
    ///   - url: The graph file.
    ///   - efSearch: Overrides the search breadth recorded in the file.
    ///   - efEntry: Overrides the breadth of the descent recorded in the file.
    /// - Throws: ``SemanticError/modelMismatch(expected:found:)``,
    ///   ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/graphStoreMismatch(_:)`` when the file belongs to another store;
    ///   ``SemanticError/corruptFile(_:)``,
    ///   ``SemanticError/unsupportedFormatVersion(found:supported:)`` or ``SemanticError/io(_:)``
    ///   when it cannot be read.
    public init(store: QuantizedVectorStore, graphAt url: URL, efSearch: Int? = nil, efEntry: Int? = nil) throws {
        let decoded = try HNSWGraph.decode(FileAccess.map(url))
        guard decoded.origin.modelID == store.modelID else {
            throw SemanticError.modelMismatch(expected: store.modelID, found: decoded.origin.modelID)
        }
        guard decoded.origin.dimensions == store.dimensions else {
            throw SemanticError.dimensionMismatch(expected: store.dimensions, found: decoded.origin.dimensions)
        }
        guard decoded.graph.nodeCount == store.count else {
            throw SemanticError.graphStoreMismatch("the graph has \(decoded.graph.nodeCount) nodes, the store \(store.count) rows")
        }
        guard decoded.origin.storeFingerprint == store.fingerprint else {
            throw SemanticError.graphStoreMismatch("the graph was built over other vectors")
        }
        for node in 0..<store.count where store.isTombstoned(node) != decoded.graph.isDeleted(node) {
            throw SemanticError.graphStoreMismatch("the tombstones of the graph and the store differ at row \(node)")
        }
        var graph = decoded.graph
        graph.setSearchBreadth(efSearch: efSearch, efEntry: efEntry)
        self.init(store: store, graph: graph)
    }

    /// Builds the graph over every row of `store`.
    ///
    /// Building costs roughly a millisecond per vector on the reference device, so it belongs
    /// at build or sync time. The work yields regularly and stops when the task is cancelled.
    public static func build(
        over store: QuantizedVectorStore,
        configuration: HNSWConfiguration = .default
    ) async throws -> HNSWIndex {
        let index = HNSWIndex(store: store, graph: HNSWGraph(configuration: configuration))
        try await index.linkPendingRows()
        return index
    }

    private init(store: QuantizedVectorStore, graph: HNSWGraph) {
        self.configuration = graph.configuration
        self.modelID = store.modelID
        self.dimensions = store.dimensions
        self.quantization = store.quantization
        self.store = store
        self.graph = graph
        self.workspace = HNSWWorkspace(dimensions: store.dimensions, width0: graph.width0)
    }

    // MARK: State

    /// Vectors the index can return.
    public var count: Int { store.liveCount }
    /// Nodes of the graph, tombstoned ones included.
    public var nodeCount: Int { graph.nodeCount }
    /// Nodes retired by a replacement or a removal. They cost memory and search time until
    /// ``compacted(configuration:)`` drops them.
    public var tombstoneCount: Int { graph.deletedCount }
    /// The fingerprint of the vector store in its current state.
    public var storeFingerprint: UInt64 { store.fingerprint }
    /// `true` while the links are still used in place from the memory-mapped graph file.
    public var isGraphMapped: Bool { graph.isMapped }

    /// `true` when `id` holds a vector.
    public func contains(_ id: SearchableID) -> Bool {
        store.contains(id)
    }

    /// The ids that hold a vector, in insertion order.
    public var ids: [SearchableID] { store.ids }

    /// The vector stored for `id`, decoded from its INT8 codes.
    public func vector(for id: SearchableID) -> [Float]? {
        store.vector(for: id)
    }

    /// The stored vectors of `ids`, decoded; ids without a vector are skipped.
    public func vectors(for ids: [SearchableID]) -> [(SearchableID, [Float])] {
        ids.compactMap { id in store.vector(for: id).map { (id, $0) } }
    }

    /// A copy of the vector store in its current state.
    public func snapshotStore() -> QuantizedVectorStore {
        store
    }

    // MARK: Changes

    /// Inserts the vector of `id`, replacing the one it had.
    ///
    /// - Returns: `false` when the id already held this vector and nothing changed.
    /// - Throws: ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/invalidVector(_:)``; the index is unchanged then.
    @discardableResult
    public func insert(_ id: SearchableID, vector: [Float]) throws -> Bool {
        let outcome = try store.upsert(id, vector: vector)
        guard !outcome.isUnchanged else { return false }
        if let replaced = outcome.replaced {
            graph.markDeleted(replaced)
        }
        try linkRows()
        return true
    }

    /// Inserts many vectors.
    ///
    /// Every vector is validated before the first one is inserted, so a vector that does not
    /// fit the space leaves the index unchanged. The work yields every 128 insertions and stops
    /// between two insertions when the task is cancelled; what was inserted until then stays.
    ///
    /// - Returns: How many vectors were added or replaced; repeats of a stored vector do not count.
    @discardableResult
    public func insert(contentsOf vectors: [(SearchableID, [Float])]) async throws -> Int {
        for entry in vectors {
            try validate(entry.1)
        }
        var changed = 0
        for (position, entry) in vectors.enumerated() {
            if position > 0, position % 128 == 0 {
                await Task.yield()
                try Task.checkCancellation()
            }
            if try insert(entry.0, vector: entry.1) {
                changed += 1
            }
        }
        return changed
    }

    /// Removes the vector of `id`. Its node is tombstoned.
    ///
    /// - Returns: `false` when the id held no vector.
    @discardableResult
    public func remove(_ id: SearchableID) -> Bool {
        guard let ordinal = store.remove(id) else { return false }
        graph.markDeleted(ordinal)
        return true
    }

    /// Removes the vectors of `ids`.
    ///
    /// - Returns: The ids that held a vector.
    @discardableResult
    public func remove(contentsOf ids: [SearchableID]) -> [SearchableID] {
        ids.filter { remove($0) }
    }

    // MARK: Search

    /// The `limit` vectors nearest to `query`, best first.
    ///
    /// The similarity is the dot product of the query with the stored vector: the cosine
    /// similarity when the query is unit length, as stored vectors are.
    ///
    /// - Parameters:
    ///   - query: A vector of ``dimensions`` finite values.
    ///   - limit: Results wanted; 50 by default (specification section 10).
    ///   - efSearch: Candidates to examine; `nil` uses the configured breadth. Never fewer than `limit`.
    /// - Throws: `CancellationError` when the task is cancelled,
    ///   ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/invalidVector(_:)`` for a query that does not fit the space.
    public func search(
        _ query: [Float],
        limit: Int = HNSWConfiguration.defaultNeighbourCount,
        efSearch: Int? = nil
    ) throws -> [SemanticMatch] {
        try Task.checkCancellation()
        try validate(query)
        let breadth = min(max(1, efSearch ?? graph.configuration.efSearch), 4_096)
        let hits = try store.withRows { rows in
            try query.withUnsafeBufferPointer { values in
                try graph.search(
                    query: values.baseAddress.unsafelyUnwrapped, limit: limit, ef: breadth,
                    rows: rows, quantization: quantization, workspace: &workspace
                )
            }
        }
        return hits.compactMap { hit in
            store.id(at: hit.node).map { SemanticMatch(id: $0, similarity: min(1, max(-1, hit.similarity))) }
        }
    }

    /// The `limit` vectors nearest to `query` by comparing it with every stored vector.
    ///
    /// The exact answer the graph approximates: the reference for recall measurements, at the
    /// cost of a pass over the whole store.
    public func exhaustiveSearch(
        _ query: [Float],
        limit: Int = HNSWConfiguration.defaultNeighbourCount
    ) throws -> [SemanticMatch] {
        try store.nearest(to: query, limit: limit)
    }

    // MARK: Persistence

    /// Writes the graph to `url`, atomically and off the cooperative thread pool.
    ///
    /// The file records the fingerprint of the vector store as it is now, so it only attaches
    /// to a vector file written from the same state: use
    /// ``write(vectorsTo:graphTo:)`` after the index has changed.
    public func write(graphTo url: URL) async throws {
        let data = graph.encoded(origin: origin)
        try await FileAccess.write(data, to: url)
    }

    /// Writes the vector file and the graph file of the current state.
    ///
    /// Both are serialized before the first byte is written, so the pair is consistent even if
    /// the index changes while the files are being written.
    public func write(vectorsTo vectorsURL: URL, graphTo graphURL: URL) async throws {
        let vectors = store.encoded()
        let links = graph.encoded(origin: origin)
        try await FileAccess.write(vectors, to: vectorsURL)
        try await FileAccess.write(links, to: graphURL)
    }

    /// A new index over the same vectors without tombstones: the store is compacted and the
    /// graph rebuilt. Worth it once ``tombstoneCount`` is a sizeable share of ``nodeCount``.
    public func compacted(configuration: HNSWConfiguration? = nil) async throws -> HNSWIndex {
        try await HNSWIndex.build(over: store.compacted(), configuration: configuration ?? graph.configuration)
    }

    // MARK: Internals

    private var origin: HNSWGraph.Origin {
        HNSWGraph.Origin(modelID: modelID, dimensions: dimensions, storeFingerprint: store.fingerprint)
    }

    private func validate(_ vector: [Float]) throws {
        guard vector.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
        }
        let isFinite = vector.withUnsafeBufferPointer { values in
            values.baseAddress.map { VectorKernels.squaredNorm($0, count: values.count).isFinite } ?? false
        }
        guard isFinite else {
            throw SemanticError.invalidVector("the vector holds a value that is not finite")
        }
    }

    /// Links the next row of the store the graph does not know yet. Node numbers and row
    /// ordinals are the same thing, so rows are linked strictly in order, and a row that is
    /// already tombstoned is linked too, as a tombstoned node.
    private func linkNextRow() throws {
        let node = graph.nodeCount
        try store.withRows { rows in
            try graph.insert(rows: rows, quantization: quantization, workspace: &workspace)
        }
        if store.isTombstoned(node) {
            graph.markDeleted(node)
        }
    }

    /// Links every row the graph does not know yet.
    private func linkRows() throws {
        while graph.nodeCount < store.count {
            try linkNextRow()
        }
    }

    /// Links the rows of a store the index was just created over, yielding regularly.
    private func linkPendingRows() async throws {
        graph.reserveCapacity(nodes: store.count)
        while graph.nodeCount < store.count {
            if graph.nodeCount > 0, graph.nodeCount % 128 == 0 {
                await Task.yield()
                try Task.checkCancellation()
            }
            try linkNextRow()
        }
    }

    /// Structural check of the graph, for tests.
    func validateGraph() throws {
        try graph.validate()
        guard graph.nodeCount == store.count, graph.liveCount == store.liveCount else {
            throw SemanticError.graphStoreMismatch("the graph and the store disagree on their size")
        }
    }

    /// The neighbours of a row on a layer, for tests.
    func neighbours(ofRow node: Int, level: Int) -> [Int] {
        graph.neighbours(of: node, level: level)
    }

    /// The top layer of a row, for tests.
    func level(ofRow node: Int) -> Int {
        graph.level(of: node)
    }
}
