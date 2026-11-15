import Foundation

/// One entry of a search heap or a candidate list: a node and its distance to the pivot of the
/// operation. Distances are negated similarities, so smaller is nearer.
struct HNSWEntry: Sendable {
    var distance: Float
    var node: UInt32
}

/// Binary heaps over caller-owned memory. The caller guarantees capacity.
///
/// The hot loops of the index push and pop tens of thousands of entries per insertion, so the
/// heaps are plain functions over raw storage: no allocation, no bounds checks, no generics.
enum HNSWHeap {
    /// Pushes onto a heap whose top is the nearest entry.
    @inline(__always)
    static func pushMin(_ heap: UnsafeMutablePointer<HNSWEntry>, _ count: inout Int, _ entry: HNSWEntry) {
        var child = count
        count &+= 1
        while child > 0 {
            let parent = (child &- 1) >> 1
            if heap[parent].distance <= entry.distance { break }
            heap[child] = heap[parent]
            child = parent
        }
        heap[child] = entry
    }

    /// Removes and returns the nearest entry. The heap must not be empty.
    @inline(__always)
    static func popMin(_ heap: UnsafeMutablePointer<HNSWEntry>, _ count: inout Int) -> HNSWEntry {
        let top = heap[0]
        count &-= 1
        if count > 0 {
            let last = heap[count]
            var parent = 0
            while true {
                var child = 2 &* parent &+ 1
                if child >= count { break }
                if child &+ 1 < count, heap[child &+ 1].distance < heap[child].distance { child &+= 1 }
                if last.distance <= heap[child].distance { break }
                heap[parent] = heap[child]
                parent = child
            }
            heap[parent] = last
        }
        return top
    }

    /// Pushes onto a heap whose top is the farthest entry.
    @inline(__always)
    static func pushMax(_ heap: UnsafeMutablePointer<HNSWEntry>, _ count: inout Int, _ entry: HNSWEntry) {
        var child = count
        count &+= 1
        while child > 0 {
            let parent = (child &- 1) >> 1
            if heap[parent].distance >= entry.distance { break }
            heap[child] = heap[parent]
            child = parent
        }
        heap[child] = entry
    }

    /// Removes and returns the farthest entry. The heap must not be empty.
    @inline(__always)
    static func popMax(_ heap: UnsafeMutablePointer<HNSWEntry>, _ count: inout Int) -> HNSWEntry {
        let top = heap[0]
        count &-= 1
        if count > 0 {
            siftDownMax(heap, count, heap[count])
        }
        return top
    }

    /// Replaces the farthest entry of a non-empty heap.
    @inline(__always)
    static func replaceMax(_ heap: UnsafeMutablePointer<HNSWEntry>, _ count: Int, _ entry: HNSWEntry) {
        siftDownMax(heap, count, entry)
    }

    @inline(__always)
    private static func siftDownMax(_ heap: UnsafeMutablePointer<HNSWEntry>, _ count: Int, _ entry: HNSWEntry) {
        var parent = 0
        while true {
            var child = 2 &* parent &+ 1
            if child >= count { break }
            if child &+ 1 < count, heap[child &+ 1].distance > heap[child].distance { child &+= 1 }
            if entry.distance >= heap[child].distance { break }
            heap[parent] = heap[child]
            parent = child
        }
        heap[parent] = entry
    }
}

/// Pointers into a workspace, valid for the duration of one operation.
struct HNSWScratch {
    let dimensions: Int
    /// The quantization parameters of the store, one float per dimension each.
    let offsets: UnsafePointer<Float>
    let scales: UnsafePointer<Float>

    /// One bit per node: seen during the current layer search.
    let visited: UnsafeMutablePointer<UInt64>
    let visitedWordCount: Int

    /// Heap of nodes still to expand, nearest on top. Room for every node.
    let candidates: UnsafeMutablePointer<HNSWEntry>
    /// Heap of the best nodes found, farthest on top. Room for `ef + 1`.
    let results: UnsafeMutablePointer<HNSWEntry>
    /// The outcome of a layer search, nearest first. Room for `ef + 1`.
    let found: UnsafeMutablePointer<HNSWEntry>
    /// The candidate links of a neighbour being pruned. Room for a full bottom-layer list plus one.
    let pruning: UnsafeMutablePointer<HNSWEntry>

    /// Nodes chosen by the selection heuristic.
    let chosen: UnsafeMutablePointer<UInt32>
    /// Nodes the heuristic passed over, nearest first.
    let discarded: UnsafeMutablePointer<UInt32>

    /// The prepared pivot of the operation: the query, or the row being inserted.
    let weights: UnsafeMutablePointer<Float>
    /// The stored row most recently widened to floats.
    let widened: UnsafeMutablePointer<Float>
    /// A stored row, decoded.
    let decoded: UnsafeMutablePointer<Float>
    /// The prepared pivot of a neighbour whose list is being pruned.
    let pivotWeights: UnsafeMutablePointer<Float>
    /// One prepared row per chosen node.
    let chosenWeights: UnsafeMutablePointer<Float>
    let chosenBiases: UnsafeMutablePointer<Float>
}

/// Reusable working memory of one index.
///
/// Sized once for the dimension count and the link width; the parts that depend on the number
/// of nodes or on `ef` grow geometrically. Nothing is allocated per search.
struct HNSWWorkspace: Sendable {
    private let dimensions: Int
    private let width0: Int
    private var floats: [Float]
    private var entries: [HNSWEntry]
    private var visited: [UInt64] = []
    private var nodes: [UInt32]
    private var listCapacity = 0
    private var nodeCapacity = 0

    init(dimensions: Int, width0: Int) {
        self.dimensions = dimensions
        self.width0 = width0
        // weights, widened, decoded, pivot weights, then one row and one bias per chosen node.
        floats = [Float](repeating: 0, count: 4 * dimensions + (width0 + 1) * (dimensions + 1))
        entries = []
        nodes = []
    }

    /// Runs `body` with scratch memory large enough for `nodeCount` nodes and searches of `ef`.
    mutating func withScratch<Value>(
        quantization: VectorQuantization,
        nodeCount: Int,
        ef: Int,
        _ body: (HNSWScratch) throws -> Value
    ) rethrows -> Value {
        reserve(nodeCount: nodeCount, ef: ef)
        let dimensions = self.dimensions
        let width0 = self.width0
        let listCapacity = self.listCapacity
        let visitedWordCount = (nodeCount + 63) / 64
        return try quantization.offsets.withUnsafeBufferPointer { offsets in
            try quantization.scales.withUnsafeBufferPointer { scales in
                try floats.withUnsafeMutableBufferPointer { floatBuffer in
                    try entries.withUnsafeMutableBufferPointer { entryBuffer in
                        try visited.withUnsafeMutableBufferPointer { visitedBuffer in
                            try nodes.withUnsafeMutableBufferPointer { nodeBuffer in
                                // Every buffer is non-empty: the sizes above are at least one.
                                let floatBase = floatBuffer.baseAddress.unsafelyUnwrapped
                                let entryBase = entryBuffer.baseAddress.unsafelyUnwrapped
                                let nodeBase = nodeBuffer.baseAddress.unsafelyUnwrapped
                                return try body(HNSWScratch(
                                    dimensions: dimensions,
                                    offsets: offsets.baseAddress.unsafelyUnwrapped,
                                    scales: scales.baseAddress.unsafelyUnwrapped,
                                    visited: visitedBuffer.baseAddress.unsafelyUnwrapped,
                                    visitedWordCount: visitedWordCount,
                                    candidates: entryBase + 2 * listCapacity + (width0 + 2),
                                    results: entryBase,
                                    found: entryBase + listCapacity,
                                    pruning: entryBase + 2 * listCapacity,
                                    chosen: nodeBase,
                                    discarded: nodeBase + (width0 + 1),
                                    weights: floatBase,
                                    widened: floatBase + dimensions,
                                    decoded: floatBase + 2 * dimensions,
                                    pivotWeights: floatBase + 3 * dimensions,
                                    chosenWeights: floatBase + 4 * dimensions + (width0 + 1),
                                    chosenBiases: floatBase + 4 * dimensions
                                ))
                            }
                        }
                    }
                }
            }
        }
    }

    private mutating func reserve(nodeCount: Int, ef: Int) {
        let neededList = ef + 2
        let neededNodes = max(1, nodeCount)
        if neededList > listCapacity || neededNodes > nodeCapacity {
            listCapacity = max(listCapacity, neededList)
            if neededNodes > nodeCapacity {
                nodeCapacity = max(neededNodes, nodeCapacity * 2, 1_024)
            }
            let zero = HNSWEntry(distance: 0, node: 0)
            entries = [HNSWEntry](repeating: zero, count: 2 * listCapacity + (width0 + 2) + nodeCapacity)
            nodes = [UInt32](repeating: 0, count: (width0 + 1) + max(listCapacity, width0 + 2))
            visited = [UInt64](repeating: 0, count: (nodeCapacity + 63) / 64)
        }
    }
}
