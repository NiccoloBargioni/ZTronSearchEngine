import Accelerate
import Foundation
import ZTronSearchEngine

/// What the fakes throw.
public enum FakeSemanticError: Error, Sendable, Hashable {
    /// The test asked the fake to fail.
    case scripted
    /// A vector does not have the dimensions of the space.
    case dimensionMismatch(expected: Int, found: Int)
}

/// A deterministic `SemanticSearching` for tests: the fake embedding space with a brute-force
/// cosine search over the vectors it was given.
///
/// Test hooks: an artificial delay before a query is encoded, a switch that makes encoding and
/// neighbour search throw, and counters of the calls it received. All state lives in the actor.
public actor FakeSemanticSearcher: SemanticSearching {
    /// Identity of the embedding space: the provider's.
    public nonisolated let modelID: String
    /// Dimensions of every vector: the provider's.
    public nonisolated let dimensions: Int
    /// The space queries are encoded in. Use it to embed the items to ``upsert(_:)``.
    public nonisolated let provider: FakeEmbeddingProvider

    private var ids: [SearchableID] = []
    private var rows: [SearchableID: Int] = [:]
    /// Unit vectors, row-major, in the order of `ids`.
    private var matrix: [Float] = []

    private var encodeDelay: UInt64 = 0
    private var shouldThrow = false

    /// Calls to ``encodeQuery(_:locale:)``, counted when the call starts.
    public private(set) var encodeCallCount = 0
    /// Calls to ``nearest(to:limit:)``.
    public private(set) var nearestCallCount = 0
    /// Calls to ``unload()``.
    public private(set) var unloadCallCount = 0
    /// Calls to ``upsert(_:)``.
    public private(set) var upsertCallCount = 0
    /// Calls to ``remove(_:)``.
    public private(set) var removeCallCount = 0
    /// Every text passed to ``encodeQuery(_:locale:)``, in order.
    public private(set) var encodedQueries: [String] = []
    /// Every tag passed to ``setLocale(_:)``, in order.
    public private(set) var localeTags: [String] = []

    /// Creates an empty searcher over an embedding space.
    public init(provider: FakeEmbeddingProvider = FakeEmbeddingProvider()) {
        self.provider = provider
        self.modelID = provider.modelID
        self.dimensions = provider.dimensions
    }

    // MARK: Test hooks

    /// Makes every later ``encodeQuery(_:locale:)`` wait this long before it answers. The wait
    /// is cancellable: a cancelled call throws `CancellationError`.
    public func setEncodeDelay(nanoseconds: UInt64) {
        encodeDelay = nanoseconds
    }

    /// Makes ``encodeQuery(_:locale:)`` and ``nearest(to:limit:)`` throw
    /// ``FakeSemanticError/scripted`` until switched off again.
    public func setShouldThrow(_ flag: Bool) {
        shouldThrow = flag
    }

    /// Sets every counter back to zero and forgets the recorded queries and locales.
    public func resetCounters() {
        encodeCallCount = 0
        nearestCallCount = 0
        unloadCallCount = 0
        upsertCallCount = 0
        removeCallCount = 0
        encodedQueries = []
        localeTags = []
    }

    /// Vectors currently stored.
    public var count: Int { ids.count }

    /// `true` when a vector is stored for `id`.
    public func contains(_ id: SearchableID) -> Bool {
        rows[id] != nil
    }

    /// Embeds items with ``provider`` and stores their vectors. Not counted as an upsert call.
    public func index<Item: Searchable>(_ items: [Item]) {
        store(provider.itemVectors(for: items))
    }

    // MARK: SemanticSearching

    /// Encodes a query with ``provider``. Waits for the delay first, and throws when asked to.
    /// The locale is not needed: every language shares the space.
    public func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] {
        encodeCallCount += 1
        encodedQueries.append(text)
        if encodeDelay > 0 {
            try await Task.sleep(nanoseconds: encodeDelay)
        }
        if shouldThrow { throw FakeSemanticError.scripted }
        return provider.queryVector(for: text)
    }

    /// The `limit` stored vectors closest to `vector` by cosine, best first, found by comparing
    /// with every one of them. Equal similarities are ordered by id.
    public func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] {
        nearestCallCount += 1
        if shouldThrow { throw FakeSemanticError.scripted }
        guard vector.count == dimensions else {
            throw FakeSemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
        }
        guard limit > 0, !ids.isEmpty else { return [] }

        let query = unit(vector)
        let dimensions = self.dimensions
        let count = ids.count
        let wanted = min(limit, count)
        // The best `wanted` rows so far, best first: similarity, then id.
        var best: [(similarity: Float, row: Int)] = []
        best.reserveCapacity(wanted + 1)

        // Every similarity in one matrix-vector product: quick even in a debug build, so the
        // relevance tests can afford a real corpus.
        var similarities = [Float](repeating: 0, count: count)
        vDSP_mmul(matrix, 1, query, 1, &similarities, 1, vDSP_Length(count), 1, vDSP_Length(dimensions))
        for row in 0..<count {
            let dot = similarities[row]
            if best.count == wanted, let last = best.last, !precedes(dot, row, last.similarity, last.row) {
                continue
            }
            var low = 0
            var high = best.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(dot, row, best[middle].similarity, best[middle].row) { high = middle } else { low = middle + 1 }
            }
            best.insert((dot, row), at: low)
            if best.count > wanted { best.removeLast() }
        }
        return best.map { SemanticMatch(id: ids[$0.row], similarity: min(max($0.similarity, -1), 1)) }
    }

    /// Stores vectors, replacing those already stored under the same id. Vectors are scaled to
    /// unit length. When any vector has the wrong dimension the call throws and stores nothing.
    public func upsert(_ vectors: [SearchableID: [Float]]) async throws {
        upsertCallCount += 1
        for (_, vector) in vectors where vector.count != dimensions {
            throw FakeSemanticError.dimensionMismatch(expected: dimensions, found: vector.count)
        }
        store(vectors)
    }

    /// Forgets the vectors of these ids. Unknown ids are ignored.
    public func remove(_ ids: [SearchableID]) async {
        removeCallCount += 1
        for id in ids {
            guard let row = rows.removeValue(forKey: id) else { continue }
            let last = self.ids.count - 1
            if row != last {
                // Move the last row into the hole.
                let moved = self.ids[last]
                self.ids[row] = moved
                rows[moved] = row
                for position in 0..<dimensions {
                    matrix[row * dimensions + position] = matrix[last * dimensions + position]
                }
            }
            self.ids.removeLast()
            matrix.removeLast(dimensions)
        }
    }

    /// Records the tag. The fake has one vector set, shared by every locale.
    public func setLocale(_ languageTag: String) async {
        localeTags.append(languageTag)
    }

    /// Counts the call. There is no model to release; stored vectors stay.
    public func unload() async {
        unloadCallCount += 1
    }

    // MARK: Storage

    private func store(_ vectors: [SearchableID: [Float]]) {
        // Sorted, so the stored order never depends on dictionary iteration order.
        for id in vectors.keys.sorted() {
            guard let vector = vectors[id], vector.count == dimensions else { continue }
            let unit = unit(vector)
            if let row = rows[id] {
                for position in 0..<dimensions {
                    matrix[row * dimensions + position] = unit[position]
                }
            } else {
                rows[id] = ids.count
                ids.append(id)
                matrix.append(contentsOf: unit)
            }
        }
    }

    /// Best first: higher similarity, then the smaller id, so ties never depend on storage order.
    private func precedes(_ lhsSimilarity: Float, _ lhsRow: Int, _ rhsSimilarity: Float, _ rhsRow: Int) -> Bool {
        if lhsSimilarity != rhsSimilarity { return lhsSimilarity > rhsSimilarity }
        return ids[lhsRow] < ids[rhsRow]
    }

    /// The vector scaled to unit length; a zero vector stays zero and is similar to nothing.
    private func unit(_ vector: [Float]) -> [Float] {
        var squares: Float = 0
        for value in vector { squares += value * value }
        guard squares > 0 else { return vector }
        let scale = 1 / squares.squareRoot()
        return vector.map { $0 * scale }
    }
}
