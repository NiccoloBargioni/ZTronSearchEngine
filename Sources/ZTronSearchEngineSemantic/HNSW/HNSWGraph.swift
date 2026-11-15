import Foundation

/// The topology of an HNSW index: levels, links, tombstones and the entry point.
///
/// A value type with no knowledge of vectors: node `n` is row `n` of the vector store the graph
/// was built over, and every operation is handed the rows it should measure against. All
/// mutable state lives in the actor that owns the graph (``HNSWIndex``).
///
/// ## File layout, version 1
///
/// Little-endian, sections padded to 8 bytes:
///
///     header (80 bytes)   magic "ZTHG", version, byte-order mark, M, efConstruction, efSearch,
///                         flags, dimensions, seed, store fingerprint, node count, tombstone
///                         count, entry point, top level, upper slot count, model id length,
///                         efEntry
///     model id            UTF-8
///     levels              nodes x UInt8
///     tombstones          ceil(nodes / 64) x UInt64
///     layer 0             nodes x (2M + 1) x UInt32       count, then neighbours
///     upper layers        upper slots x UInt32            (M + 1) per node and layer above 0
///
/// With M = 16 that is 132 bytes per node on the bottom layer and about 5 above it: 13.7 MB
/// for 100,000 nodes. The two link sections are used in place from the memory-mapped file;
/// they are copied into memory only when the graph is first changed.
struct HNSWGraph: Sendable {
    /// Levels are stored in a byte and drawn from a geometric distribution; with M >= 2 a node
    /// above this level does not occur in practice.
    static let maximumLevel = 15
    static let formatVersion: UInt32 = 1
    private static let magic = "ZTHG"

    /// What a graph file says about the store it was built over.
    struct Origin: Sendable, Equatable {
        var modelID: String
        var dimensions: Int
        var storeFingerprint: UInt64
    }

    private struct MappedLinks: Sendable {
        var data: Data
        var layer0Start: Int
        var upperStart: Int
    }

    private(set) var configuration: HNSWConfiguration
    private(set) var nodeCount = 0
    private(set) var deletedCount = 0
    /// The node searches start from: one of the nodes on the top level. -1 while empty.
    private(set) var entryPoint = -1
    private(set) var maxLevel = -1

    private var levels: [UInt8] = []
    /// Per node, the first slot of its blocks above the bottom layer.
    private var upperOffsets: [UInt32] = []
    private var deleted = Bitset()
    private var layer0: [UInt32] = []
    private var upper: [UInt32] = []
    /// Set while the links are still served from the memory-mapped file.
    private var mapped: MappedLinks?
    private var upperSlotCount = 0

    var width: Int { configuration.m }
    var width0: Int { configuration.m * 2 }
    var liveCount: Int { nodeCount - deletedCount }
    /// `true` while the links are used in place from a memory-mapped file.
    var isMapped: Bool { mapped != nil }

    init(configuration: HNSWConfiguration) {
        self.configuration = configuration
    }

    /// Changes how many candidates a search examines on the bottom layer and on the layers
    /// above it; `nil` keeps a value. The topology is unaffected.
    mutating func setSearchBreadth(efSearch: Int?, efEntry: Int?) {
        configuration = HNSWConfiguration(
            m: configuration.m, efConstruction: configuration.efConstruction,
            efSearch: efSearch ?? configuration.efSearch, efEntry: efEntry ?? configuration.efEntry,
            seed: configuration.seed, keepsPrunedConnections: configuration.keepsPrunedConnections
        )
    }

    // MARK: Levels

    /// The top layer of a node: a geometric draw from a counter-based generator.
    ///
    /// The draw depends only on the seed and the node number, so the level of a node does not
    /// depend on what was inserted or removed before it, and there is no generator state to
    /// persist.
    static func level(forNode node: Int, configuration: HNSWConfiguration) -> Int {
        let bits = Fingerprint.mix(configuration.seed ^ Fingerprint.mix(UInt64(node)))
        // 53 random bits mapped into the open interval (0, 1).
        let unit = (Double(bits >> 11) + 0.5) / 9_007_199_254_740_992
        let level = Int(-log(unit) / log(Double(configuration.m)))
        return min(level, maximumLevel)
    }

    func level(of node: Int) -> Int {
        Int(levels[node])
    }

    func isDeleted(_ node: Int) -> Bool {
        deleted.contains(node)
    }

    // MARK: Changes

    /// Makes room for `nodes` nodes in all, so that a build over a store of known size
    /// allocates its link storage once instead of growing it by doubling. For a graph that is
    /// about to be built: it copies the links of a memory-mapped graph into memory.
    mutating func reserveCapacity(nodes: Int) {
        materialize()
        levels.reserveCapacity(nodes)
        upperOffsets.reserveCapacity(nodes)
        layer0.reserveCapacity(nodes * (width0 + 1))
        deleted.reserve(nodes)
    }

    /// Appends node `nodeCount`, the row of the same ordinal, and links it into the graph.
    mutating func insert(
        rows: QuantizedVectorStore.Rows,
        quantization: VectorQuantization,
        workspace: inout HNSWWorkspace
    ) throws {
        materialize()
        let node = nodeCount
        let level = Self.level(forNode: node, configuration: configuration)
        levels.append(UInt8(level))
        upperOffsets.append(UInt32(upper.count))
        layer0.append(contentsOf: repeatElement(0, count: width0 + 1))
        if level > 0 {
            upper.append(contentsOf: repeatElement(0, count: level * (width + 1)))
            upperSlotCount = upper.count
        }
        nodeCount += 1
        deleted.reserve(nodeCount)

        guard entryPoint >= 0 else {
            entryPoint = node
            maxLevel = level
            return
        }

        let entry = entryPoint
        let top = maxLevel
        let configuration = self.configuration
        // Linking only fails on a graph file that turned out to be damaged. The node is part of
        // the graph either way, so the entry point is settled before the failure is reported.
        let linking = Result {
            try workspace.withScratch(quantization: quantization, nodeCount: nodeCount, ef: configuration.efConstruction) { scratch in
                try withMutableLinks { view, bottom, above in
                    var operation = HNSWOperation(graph: view, rows: rows, scratch: scratch, checksCancellation: false)
                    try operation.link(node: node, level: level, entry: entry, top: top, layer0: bottom, upper: above, configuration: configuration)
                }
            }
        }
        if level > maxLevel {
            entryPoint = node
            maxLevel = level
        }
        try linking.get()
    }

    /// Tombstones a node: it stays in the graph as a waypoint and is never returned again.
    ///
    /// - Returns: `false` when the node was already tombstoned or does not exist.
    @discardableResult
    mutating func markDeleted(_ node: Int) -> Bool {
        guard node >= 0, node < nodeCount, deleted.insert(node) else { return false }
        deletedCount += 1
        return true
    }

    // MARK: Search

    /// The nearest live nodes to a query, nearest first; ties are ordered by node number.
    ///
    /// - Parameter query: `dimensions` finite values.
    /// - Throws: `CancellationError` when the task is cancelled, or
    ///   ``SemanticError/corruptFile(_:)`` when a mapped graph file turns out to be damaged.
    func search(
        query: UnsafePointer<Float>,
        limit: Int,
        ef: Int,
        rows: QuantizedVectorStore.Rows,
        quantization: VectorQuantization,
        workspace: inout HNSWWorkspace
    ) throws -> [(node: Int, similarity: Float)] {
        guard entryPoint >= 0, liveCount > 0, limit > 0 else { return [] }
        let entry = entryPoint
        let top = maxLevel
        let breadth = max(ef, limit)
        let efEntry = configuration.efEntry
        var hits = try workspace.withScratch(quantization: quantization, nodeCount: nodeCount, ef: max(breadth, efEntry)) { scratch in
            try withView { view in
                var operation = HNSWOperation(graph: view, rows: rows, scratch: scratch, checksCancellation: true)
                let count = try operation.search(query: query, entry: entry, top: top, efEntry: efEntry, ef: breadth)
                return (0..<count).map { (node: Int(scratch.found[$0].node), similarity: -scratch.found[$0].distance) }
            }
        }
        hits.sort { $0.similarity > $1.similarity || ($0.similarity == $1.similarity && $0.node < $1.node) }
        if hits.count > limit { hits.removeSubrange(limit...) }
        return hits
    }

    // MARK: Memory access

    private func withView<Value>(_ body: (HNSWGraphView) throws -> Value) rethrows -> Value {
        let nodeCount = self.nodeCount
        let width0 = self.width0
        let width = self.width
        return try levels.withUnsafeBufferPointer { levelBuffer in
            try upperOffsets.withUnsafeBufferPointer { offsetBuffer in
                try deleted.words.withUnsafeBufferPointer { deletedBuffer in
                    // A graph with a node has non-empty levels, offsets and tombstone words.
                    let levelBase = levelBuffer.baseAddress.unsafelyUnwrapped
                    let offsetBase = offsetBuffer.baseAddress.unsafelyUnwrapped
                    let deletedBase = deletedBuffer.baseAddress.unsafelyUnwrapped
                    if let mapped {
                        return try mapped.data.withUnsafeBytes { raw in
                            let base = raw.baseAddress.unsafelyUnwrapped
                            return try body(HNSWGraphView(
                                nodeCount: nodeCount, width0: width0, width: width,
                                levels: levelBase, upperOffsets: offsetBase, deleted: deletedBase,
                                layer0: (base + mapped.layer0Start).assumingMemoryBound(to: UInt32.self),
                                upper: upperSlotCount > 0 ? (base + mapped.upperStart).assumingMemoryBound(to: UInt32.self) : nil
                            ))
                        }
                    }
                    return try layer0.withUnsafeBufferPointer { bottom in
                        try upper.withUnsafeBufferPointer { above in
                            try body(HNSWGraphView(
                                nodeCount: nodeCount, width0: width0, width: width,
                                levels: levelBase, upperOffsets: offsetBase, deleted: deletedBase,
                                layer0: bottom.baseAddress.unsafelyUnwrapped, upper: above.baseAddress
                            ))
                        }
                    }
                }
            }
        }
    }

    private mutating func withMutableLinks<Value>(
        _ body: (HNSWGraphView, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>?) throws -> Value
    ) rethrows -> Value {
        let nodeCount = self.nodeCount
        let width0 = self.width0
        let width = self.width
        return try levels.withUnsafeBufferPointer { levelBuffer in
            try upperOffsets.withUnsafeBufferPointer { offsetBuffer in
                try deleted.words.withUnsafeBufferPointer { deletedBuffer in
                    try layer0.withUnsafeMutableBufferPointer { bottom in
                        try upper.withUnsafeMutableBufferPointer { above in
                            let bottomBase = bottom.baseAddress.unsafelyUnwrapped
                            return try body(
                                HNSWGraphView(
                                    nodeCount: nodeCount, width0: width0, width: width,
                                    levels: levelBuffer.baseAddress.unsafelyUnwrapped,
                                    upperOffsets: offsetBuffer.baseAddress.unsafelyUnwrapped,
                                    deleted: deletedBuffer.baseAddress.unsafelyUnwrapped,
                                    layer0: UnsafePointer(bottomBase),
                                    upper: above.baseAddress.map { UnsafePointer($0) }
                                ),
                                bottomBase,
                                above.baseAddress
                            )
                        }
                    }
                }
            }
        }
    }

    /// Copies the links out of the mapped file, once, before the first change.
    private mutating func materialize() {
        guard let mapped else { return }
        let bottomCount = nodeCount * (width0 + 1)
        let aboveCount = upperSlotCount
        mapped.data.withUnsafeBytes { raw in
            layer0 = [UInt32](unsafeUninitializedCapacity: bottomCount) { buffer, initialized in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(
                    from: UnsafeRawBufferPointer(rebasing: raw[mapped.layer0Start..<(mapped.layer0Start + bottomCount * 4)])
                )
                initialized = bottomCount
            }
            upper = [UInt32](unsafeUninitializedCapacity: aboveCount) { buffer, initialized in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(
                    from: UnsafeRawBufferPointer(rebasing: raw[mapped.upperStart..<(mapped.upperStart + aboveCount * 4)])
                )
                initialized = aboveCount
            }
        }
        self.mapped = nil
    }

    // MARK: Persistence

    /// The bytes of the graph file.
    func encoded(origin: Origin) -> Data {
        var writer = BinaryWriter(capacity: 256 + nodeCount * (4 * (width0 + 1) + 2) + upperSlotCount * 4)
        writer.append(magic: Self.magic)
        writer.append(Self.formatVersion)
        writer.append(binaryByteOrderMark)
        writer.append(UInt32(configuration.m))
        writer.append(UInt32(configuration.efConstruction))
        writer.append(UInt32(configuration.efSearch))
        writer.append(UInt32(configuration.keepsPrunedConnections ? 1 : 0))
        writer.append(UInt32(origin.dimensions))
        writer.append(configuration.seed)
        writer.append(origin.storeFingerprint)
        writer.append(UInt32(nodeCount))
        writer.append(UInt32(deletedCount))
        writer.append(Int32(entryPoint))
        writer.append(Int32(maxLevel))
        writer.append(UInt64(upperSlotCount))
        writer.append(UInt32(origin.modelID.utf8.count))
        writer.append(UInt32(configuration.efEntry))
        writer.append(utf8: origin.modelID)
        writer.align(to: 8)
        writer.append(elements: levels)
        writer.align(to: 8)
        writer.append(elements: deleted.words(covering: nodeCount))
        if let mapped {
            mapped.data.withUnsafeBytes { raw in
                let bottomBytes = nodeCount * (width0 + 1) * 4
                writer.append(bytes: UnsafeRawBufferPointer(rebasing: raw[mapped.layer0Start..<(mapped.layer0Start + bottomBytes)]))
                writer.align(to: 8)
                writer.append(bytes: UnsafeRawBufferPointer(rebasing: raw[mapped.upperStart..<(mapped.upperStart + upperSlotCount * 4)]))
            }
        } else {
            writer.append(elements: layer0)
            writer.align(to: 8)
            writer.append(elements: upper)
        }
        writer.align(to: 8)
        return writer.data
    }

    /// Parses a graph file. The link sections stay in `data`, which is normally memory-mapped;
    /// only the small leading sections are read.
    ///
    /// - Returns: The graph and what the file says about the store it was built over.
    static func decode(_ data: Data) throws -> (graph: HNSWGraph, origin: Origin) {
        var configuration = HNSWConfiguration()
        var origin = Origin(modelID: "", dimensions: 0, storeFingerprint: 0)
        var nodeCount = 0
        var deletedCount = 0
        var entryPoint = -1
        var maxLevel = -1
        var upperSlotCount = 0
        var levels: [UInt8] = []
        var deletedWords: [UInt64] = []
        var layer0Start = 0
        var upperStart = 0

        try data.withUnsafeBytes { raw in
            var reader = BinaryReader(raw, label: "the graph file")
            try reader.readMagic(magic)
            let version = try reader.readUInt32()
            guard version == formatVersion else {
                throw SemanticError.unsupportedFormatVersion(found: version, supported: formatVersion)
            }
            guard try reader.readUInt32() == binaryByteOrderMark else {
                throw SemanticError.corruptFile("the graph file was written in another byte order")
            }
            let m = Int(try reader.readUInt32())
            let efConstruction = Int(try reader.readUInt32())
            let efSearch = Int(try reader.readUInt32())
            let flags = try reader.readUInt32()
            guard (2...64).contains(m), (m...4_096).contains(efConstruction), (1...4_096).contains(efSearch) else {
                throw SemanticError.corruptFile("the graph file declares parameters outside their range")
            }
            origin.dimensions = Int(try reader.readUInt32())
            let seed = try reader.readUInt64()
            origin.storeFingerprint = try reader.readUInt64()
            nodeCount = try reader.readCount(atMost: Int(Int32.max))
            deletedCount = try reader.readCount(atMost: nodeCount)
            entryPoint = Int(try reader.readInt32())
            maxLevel = Int(try reader.readInt32())
            let slots = try reader.readUInt64()
            guard slots <= UInt64(UInt32.max) else {
                throw SemanticError.corruptFile("the graph file declares an impossible number of links")
            }
            upperSlotCount = Int(slots)
            let modelIDLength = try reader.readCount(atMost: 4_096)
            let efEntry = Int(try reader.readUInt32())
            guard (1...4_096).contains(efEntry) else {
                throw SemanticError.corruptFile("the graph file declares parameters outside their range")
            }
            configuration = HNSWConfiguration(
                m: m, efConstruction: efConstruction, efSearch: efSearch, efEntry: efEntry, seed: seed,
                keepsPrunedConnections: flags & 1 != 0
            )
            origin.modelID = try reader.readString(byteCount: modelIDLength)
            try reader.align(to: 8)
            levels = try reader.readArray(of: UInt8.self, count: nodeCount)
            try reader.align(to: 8)
            deletedWords = try reader.readArray(of: UInt64.self, count: (nodeCount + 63) / 64)
            layer0Start = try reader.skipSection(byteCount: nodeCount * (2 * m + 1) * 4)
            try reader.align(to: 8)
            upperStart = try reader.skipSection(byteCount: upperSlotCount * 4)
            try reader.align(to: 8)
            guard reader.offset == raw.count else {
                throw SemanticError.corruptFile("the graph file has \(raw.count - reader.offset) unexpected trailing bytes")
            }
        }

        // The upper blocks are laid out in node order, so their offsets are a prefix sum of the
        // levels; a file whose levels do not add up to its link section is damaged.
        var upperOffsets = [UInt32](repeating: 0, count: nodeCount)
        var slot = 0
        var highest = -1
        for node in 0..<nodeCount {
            let level = Int(levels[node])
            guard level <= maximumLevel else {
                throw SemanticError.corruptFile("the graph file holds a node above the highest level")
            }
            upperOffsets[node] = UInt32(truncatingIfNeeded: slot)
            slot += level * (configuration.m + 1)
            highest = max(highest, level)
        }
        let deleted = Bitset(words: deletedWords)
        guard slot == upperSlotCount, highest == maxLevel, deleted.population == deletedCount else {
            throw SemanticError.corruptFile("the sections of the graph file disagree with its header")
        }
        if nodeCount == 0 {
            guard entryPoint == -1 else {
                throw SemanticError.corruptFile("the graph file is empty but names an entry point")
            }
        } else {
            guard entryPoint >= 0, entryPoint < nodeCount, Int(levels[entryPoint]) == maxLevel else {
                throw SemanticError.corruptFile("the graph file names an entry point that is not on its top level")
            }
        }

        var graph = HNSWGraph(configuration: configuration)
        graph.nodeCount = nodeCount
        graph.deletedCount = deletedCount
        graph.entryPoint = entryPoint
        graph.maxLevel = maxLevel
        graph.levels = levels
        graph.upperOffsets = upperOffsets
        graph.deleted = deleted
        graph.upperSlotCount = upperSlotCount
        graph.mapped = nodeCount > 0 ? MappedLinks(data: data, layer0Start: layer0Start, upperStart: upperStart) : nil
        return (graph, origin)
    }

    // MARK: Inspection

    /// The neighbours of a node on a layer.
    func neighbours(of node: Int, level: Int) -> [Int] {
        guard node >= 0, node < nodeCount, level >= 0, level <= Int(levels[node]) else { return [] }
        return withView { view in
            let block = view.block(of: node, level: level)
            let count = min(Int(block[0]), view.capacity(level: level))
            return (0..<count).map { Int(block[$0 + 1]) }
        }
    }

    /// Checks every structural invariant of the graph.
    ///
    /// - Throws: ``SemanticError/corruptFile(_:)`` naming the first violation.
    func validate() throws {
        guard nodeCount > 0 else {
            guard entryPoint == -1, maxLevel == -1 else {
                throw SemanticError.corruptFile("an empty graph has an entry point")
            }
            return
        }
        guard entryPoint >= 0, entryPoint < nodeCount, Int(levels[entryPoint]) == maxLevel,
              Int(levels.max() ?? 0) == maxLevel else {
            throw SemanticError.corruptFile("the entry point is not on the top level")
        }
        try withView { view in
            for node in 0..<nodeCount {
                for level in 0...Int(view.levels[node]) {
                    let block = view.block(of: node, level: level)
                    let count = Int(block[0])
                    guard count <= view.capacity(level: level) else {
                        throw SemanticError.corruptFile("node \(node) holds \(count) links on layer \(level)")
                    }
                    var seen: Set<UInt32> = []
                    for index in 0..<count {
                        let neighbour = block[index + 1]
                        guard Int(neighbour) < nodeCount, Int(neighbour) != node,
                              Int(view.levels[Int(neighbour)]) >= level, seen.insert(neighbour).inserted else {
                            throw SemanticError.corruptFile("node \(node) holds an invalid link on layer \(level)")
                        }
                    }
                }
            }
        }
    }
}
