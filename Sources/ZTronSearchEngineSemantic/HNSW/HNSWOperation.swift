import Accelerate
import Foundation

/// Read access to the memory of a graph, valid for the duration of one operation.
///
/// Layout. Every node owns one block on the bottom layer and one block per layer above, up to
/// its own level. A block is a count followed by that many neighbours:
///
///     layer 0:   node * (2M + 1)                                   2M neighbours at most
///     layer l:   upperOffsets[node] + (l - 1) * (M + 1)            M neighbours at most
struct HNSWGraphView {
    let nodeCount: Int
    /// Neighbours a block holds on the bottom layer (2M) and on the layers above (M).
    let width0: Int
    let width: Int
    let levels: UnsafePointer<UInt8>
    let upperOffsets: UnsafePointer<UInt32>
    let deleted: UnsafePointer<UInt64>
    let layer0: UnsafePointer<UInt32>
    /// `nil` when no node rises above the bottom layer.
    let upper: UnsafePointer<UInt32>?

    @inline(__always)
    func block(of node: Int, level: Int) -> UnsafePointer<UInt32> {
        if level == 0 {
            return layer0 + node &* (width0 &+ 1)
        }
        return upper.unsafelyUnwrapped + (Int(upperOffsets[node]) &+ (level &- 1) &* (width &+ 1))
    }

    @inline(__always)
    func capacity(level: Int) -> Int {
        level == 0 ? width0 : width
    }

    @inline(__always)
    func isDeleted(_ node: Int) -> Bool {
        deleted[node >> 6] & (1 << UInt64(node & 63)) != 0
    }
}

/// The HNSW algorithms (Malkov and Yashunin) over raw memory: one value per operation.
///
/// Distances are negated similarities. The pivot of an operation, a query or the row being
/// inserted, is prepared once into `scratch.weights` and a bias; its similarity with a stored
/// row is then one widening and one dot product over the INT8 codes
/// (``VectorQuantization/prepare(_:into:)``). During construction the pivot is always a decoded
/// stored row, so distances between rows are symmetric and a graph can be rebuilt from its
/// vector file alone.
struct HNSWOperation {
    let graph: HNSWGraphView
    let rows: QuantizedVectorStore.Rows
    let scratch: HNSWScratch
    /// Searches honour task cancellation; insertions run to completion so a cancelled task
    /// never leaves a half-linked node behind.
    let checksCancellation: Bool

    private var visits = 0
    private var candidateCount = 0
    private var resultCount = 0

    init(graph: HNSWGraphView, rows: QuantizedVectorStore.Rows, scratch: HNSWScratch, checksCancellation: Bool) {
        self.graph = graph
        self.rows = rows
        self.scratch = scratch
        self.checksCancellation = checksCancellation
    }

    // MARK: Pivots and distances

    /// Prepares a query vector as the pivot. Returns its bias.
    private func prepare(query: UnsafePointer<Float>) -> Float {
        let length = vDSP_Length(scratch.dimensions)
        var bias: Float = 0
        vDSP_dotpr(query, 1, scratch.offsets, 1, &bias, length)
        vDSP_vmul(query, 1, scratch.scales, 1, scratch.weights, 1, length)
        return bias
    }

    /// Prepares the row already widened into `scratch.widened` as a pivot into `weights`.
    /// Returns its bias.
    @inline(__always)
    private func prepareWidenedRow(into weights: UnsafeMutablePointer<Float>) -> Float {
        let length = vDSP_Length(scratch.dimensions)
        var bias: Float = 0
        vDSP_vma(scratch.widened, 1, scratch.scales, 1, scratch.offsets, 1, scratch.decoded, 1, length)
        vDSP_dotpr(scratch.decoded, 1, scratch.offsets, 1, &bias, length)
        vDSP_vmul(scratch.decoded, 1, scratch.scales, 1, weights, 1, length)
        return bias
    }

    /// Prepares a stored row as a pivot into `weights`. Returns its bias.
    @inline(__always)
    private func prepare(row node: Int, into weights: UnsafeMutablePointer<Float>) -> Float {
        VectorKernels.widen(rows.row(node), into: scratch.widened, count: scratch.dimensions)
        return prepareWidenedRow(into: weights)
    }

    /// Distance from the pivot in `weights` to a stored row.
    @inline(__always)
    private func distance(_ weights: UnsafePointer<Float>, _ bias: Float, to node: Int) -> Float {
        -(bias + VectorKernels.dot(weights, rows.row(node), count: scratch.dimensions, scratch: scratch.widened))
    }

    @inline(__always)
    private mutating func noteVisit() throws {
        visits &+= 1
        // Every 64 node visits; the specification asks for at least every 100.
        if checksCancellation, visits & 63 == 0 {
            try Task.checkCancellation()
        }
    }

    private static func damaged() -> SemanticError {
        .corruptFile("the graph file links to a node that does not exist on that layer")
    }

    // MARK: Traversal

    /// Greedy walk on one layer: moves to a neighbour while one is nearer.
    private mutating func descend(from start: HNSWEntry, bias: Float, level: Int) throws -> HNSWEntry {
        var current = start
        var improved = true
        while improved {
            improved = false
            let block = graph.block(of: Int(current.node), level: level)
            let count = min(Int(block[0]), graph.capacity(level: level))
            var index = 1
            while index <= count {
                let neighbour = Int(block[index])
                index &+= 1
                guard neighbour < graph.nodeCount, Int(graph.levels[neighbour]) >= level else { throw Self.damaged() }
                try noteVisit()
                let candidate = distance(scratch.weights, bias, to: neighbour)
                if candidate < current.distance {
                    current = HNSWEntry(distance: candidate, node: UInt32(neighbour))
                    improved = true
                }
            }
        }
        return current
    }

    private mutating func beginLayer() {
        memset(scratch.visited, 0, scratch.visitedWordCount * MemoryLayout<UInt64>.stride)
        candidateCount = 0
        resultCount = 0
    }

    /// Adds an entry point to the layer search. Entry points arrive nearest first; once `ef`
    /// of them are among the results, the rest are only candidates to expand.
    private mutating func seed(_ entry: HNSWEntry, ef: Int, excludingDeleted: Bool) {
        let node = Int(entry.node)
        scratch.visited[node >> 6] |= 1 << UInt64(node & 63)
        HNSWHeap.pushMin(scratch.candidates, &candidateCount, entry)
        if resultCount < ef, !(excludingDeleted && graph.isDeleted(node)) {
            HNSWHeap.pushMax(scratch.results, &resultCount, entry)
        }
    }

    /// Best-first search of one layer from the seeded entry points, keeping the `ef` nearest.
    ///
    /// Tombstoned nodes are walked through like any other, so the graph stays navigable, but
    /// with `excludingDeleted` they never enter the results.
    private mutating func searchLayer(bias: Float, level: Int, ef: Int, excludingDeleted: Bool) throws {
        let capacity = graph.capacity(level: level)
        while candidateCount > 0 {
            let current = HNSWHeap.popMin(scratch.candidates, &candidateCount)
            if resultCount >= ef, current.distance > scratch.results[0].distance { break }
            let block = graph.block(of: Int(current.node), level: level)
            let count = min(Int(block[0]), capacity)
            var index = 1
            while index <= count {
                let neighbour = Int(block[index])
                index &+= 1
                guard neighbour < graph.nodeCount, Int(graph.levels[neighbour]) >= level else { throw Self.damaged() }
                let word = neighbour >> 6
                let bit: UInt64 = 1 << UInt64(neighbour & 63)
                if scratch.visited[word] & bit != 0 { continue }
                scratch.visited[word] |= bit
                try noteVisit()

                let candidate = distance(scratch.weights, bias, to: neighbour)
                if resultCount < ef || candidate < scratch.results[0].distance {
                    let entry = HNSWEntry(distance: candidate, node: UInt32(neighbour))
                    HNSWHeap.pushMin(scratch.candidates, &candidateCount, entry)
                    if excludingDeleted, graph.isDeleted(neighbour) { continue }
                    if resultCount < ef {
                        HNSWHeap.pushMax(scratch.results, &resultCount, entry)
                    } else {
                        HNSWHeap.replaceMax(scratch.results, resultCount, entry)
                    }
                }
            }
        }
    }

    /// Moves the results of a layer search into `scratch.found`, nearest first.
    private mutating func drainResults() -> Int {
        let count = resultCount
        var index = count
        while resultCount > 0 {
            index &-= 1
            scratch.found[index] = HNSWHeap.popMax(scratch.results, &resultCount)
        }
        return count
    }

    // MARK: Search

    /// Finds the nearest live nodes to `query`.
    ///
    /// The classic algorithm walks greedily down the upper layers and enters the bottom layer
    /// at a single node. That is all a query needs when its neighbours lie together, but a
    /// query between two topics has neighbours in both, and a search that enters in one of them
    /// seldom crosses over. With `efEntry` above 1 every upper layer is searched best-first
    /// with that breadth, and everything found seeds the layer below, so the bottom layer is
    /// entered in every region that is near the query.
    ///
    /// - Parameters:
    ///   - efEntry: Candidates kept on each layer above the bottom one; 1 is the greedy walk.
    ///   - ef: Candidates kept on the bottom layer.
    /// - Returns: How many were found, at most `ef`; they are in `scratch.found`, nearest first.
    mutating func search(query: UnsafePointer<Float>, entry: Int, top: Int, efEntry: Int, ef: Int) throws -> Int {
        let bias = prepare(query: query)
        try noteVisit()
        scratch.found[0] = HNSWEntry(distance: distance(scratch.weights, bias, to: entry), node: UInt32(entry))
        var seedCount = 1
        var level = top
        while level > 0 {
            if efEntry <= 1 {
                scratch.found[0] = try descend(from: scratch.found[0], bias: bias, level: level)
            } else {
                beginLayer()
                for index in 0..<seedCount {
                    seed(scratch.found[index], ef: efEntry, excludingDeleted: false)
                }
                try searchLayer(bias: bias, level: level, ef: efEntry, excludingDeleted: false)
                seedCount = drainResults()
            }
            level &-= 1
        }
        beginLayer()
        for index in 0..<seedCount {
            seed(scratch.found[index], ef: ef, excludingDeleted: true)
        }
        try searchLayer(bias: bias, level: 0, ef: ef, excludingDeleted: true)
        return drainResults()
    }

    // MARK: Insertion

    /// Links `node`, whose blocks are allocated and empty, into the graph.
    ///
    /// - Parameters:
    ///   - level: The top layer of `node`.
    ///   - entry: The entry point of the graph before this insertion, and `top` its level.
    ///   - layer0: Writable storage of the bottom layer; `upper` of the layers above.
    mutating func link(
        node: Int,
        level: Int,
        entry: Int,
        top: Int,
        layer0: UnsafeMutablePointer<UInt32>,
        upper: UnsafeMutablePointer<UInt32>?,
        configuration: HNSWConfiguration
    ) throws {
        let bias = prepare(row: node, into: scratch.weights)
        var current = HNSWEntry(distance: distance(scratch.weights, bias, to: entry), node: UInt32(entry))

        // Above the node's own level: a greedy walk towards it.
        var layer = top
        while layer > level {
            current = try descend(from: current, bias: bias, level: layer)
            layer &-= 1
        }

        // From its level down: find the neighbourhood, choose links, link back.
        var seedCount = 1
        scratch.found[0] = current
        while layer >= 0 {
            beginLayer()
            for index in 0..<seedCount {
                seed(scratch.found[index], ef: configuration.efConstruction, excludingDeleted: false)
            }
            try searchLayer(bias: bias, level: layer, ef: configuration.efConstruction, excludingDeleted: false)
            let foundCount = drainResults()

            let chosenCount = select(
                from: scratch.found, count: foundCount, limit: configuration.m,
                keepsPruned: configuration.keepsPrunedConnections
            )
            let own = mutableBlock(of: node, level: layer, layer0: layer0, upper: upper)
            own[0] = UInt32(chosenCount)
            for index in 0..<chosenCount {
                own[index &+ 1] = scratch.chosen[index]
            }
            // `scratch.chosen` is reused while linking back, so walk the node's own block.
            for index in 0..<chosenCount {
                let neighbour = Int(own[index &+ 1])
                connect(
                    neighbour, to: node, level: layer,
                    block: mutableBlock(of: neighbour, level: layer, layer0: layer0, upper: upper),
                    keepsPruned: configuration.keepsPrunedConnections
                )
            }
            // Everything found on this layer seeds the search of the layer below.
            seedCount = foundCount
            layer &-= 1
        }
    }

    @inline(__always)
    private func mutableBlock(
        of node: Int,
        level: Int,
        layer0: UnsafeMutablePointer<UInt32>,
        upper: UnsafeMutablePointer<UInt32>?
    ) -> UnsafeMutablePointer<UInt32> {
        if level == 0 {
            return layer0 + node &* (graph.width0 &+ 1)
        }
        return upper.unsafelyUnwrapped + (Int(graph.upperOffsets[node]) &+ (level &- 1) &* (graph.width &+ 1))
    }

    /// The neighbour-selection heuristic (algorithm 4 of the paper).
    ///
    /// Walks the candidates nearest first and keeps one only when it is nearer to the pivot
    /// than to every candidate already kept. That spreads the links over directions instead of
    /// spending them all inside one cluster, which is what keeps clustered data navigable.
    ///
    /// - Parameters:
    ///   - list: Candidates with their distance to the pivot, nearest first.
    ///   - limit: Links to choose at most; never more than a bottom-layer block holds.
    /// - Returns: How many were chosen; they are in `scratch.chosen`, nearest first.
    private func select(from list: UnsafePointer<HNSWEntry>, count: Int, limit: Int, keepsPruned: Bool) -> Int {
        let dimensions = scratch.dimensions
        var chosenCount = 0
        var discardedCount = 0
        var index = 0
        while index < count, chosenCount < limit {
            let candidate = list[index]
            index &+= 1
            VectorKernels.widen(rows.row(Int(candidate.node)), into: scratch.widened, count: dimensions)
            var isDiverse = true
            var other = 0
            while other < chosenCount {
                let similarity = scratch.chosenBiases[other]
                    + VectorKernels.dot(scratch.chosenWeights + other &* dimensions, scratch.widened, count: dimensions)
                if -similarity < candidate.distance {
                    isDiverse = false
                    break
                }
                other &+= 1
            }
            if isDiverse {
                scratch.chosenBiases[chosenCount] = prepareWidenedRow(into: scratch.chosenWeights + chosenCount &* dimensions)
                scratch.chosen[chosenCount] = candidate.node
                chosenCount &+= 1
            } else if keepsPruned {
                scratch.discarded[discardedCount] = candidate.node
                discardedCount &+= 1
            }
        }
        if keepsPruned {
            var refill = 0
            while chosenCount < limit, refill < discardedCount {
                scratch.chosen[chosenCount] = scratch.discarded[refill]
                chosenCount &+= 1
                refill &+= 1
            }
        }
        return chosenCount
    }

    /// Adds `node` to the links of `neighbour`, pruning the list with the selection heuristic
    /// when it is full.
    private func connect(
        _ neighbour: Int,
        to node: Int,
        level: Int,
        block: UnsafeMutablePointer<UInt32>,
        keepsPruned: Bool
    ) {
        let capacity = graph.capacity(level: level)
        let count = min(Int(block[0]), capacity)
        if count < capacity {
            block[count &+ 1] = UInt32(node)
            block[0] = UInt32(count &+ 1)
            return
        }

        // Full: the candidates are the current links and the new node, by distance from the
        // neighbour, which becomes the pivot.
        let bias = prepare(row: neighbour, into: scratch.pivotWeights)
        var listCount = 0
        var index = 0
        while index <= count {
            let candidate = index < count ? Int(block[index &+ 1]) : node
            index &+= 1
            let entry = HNSWEntry(distance: distance(scratch.pivotWeights, bias, to: candidate), node: UInt32(candidate))
            // Insertion sort, nearest first; equal distances keep their order.
            var slot = listCount
            while slot > 0, scratch.pruning[slot &- 1].distance > entry.distance {
                scratch.pruning[slot] = scratch.pruning[slot &- 1]
                slot &-= 1
            }
            scratch.pruning[slot] = entry
            listCount &+= 1
        }

        let chosenCount = select(from: scratch.pruning, count: listCount, limit: capacity, keepsPruned: keepsPruned)
        block[0] = UInt32(chosenCount)
        for slot in 0..<chosenCount {
            block[slot &+ 1] = scratch.chosen[slot]
        }
    }
}
