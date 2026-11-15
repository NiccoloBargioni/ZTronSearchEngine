import Accelerate
import Foundation
import ZTronSearchEngine

/// The item vectors of one embedding space, INT8 scalar-quantized.
///
/// 100,000 items of 384 dimensions take about 38 MB, which is why the vectors are never read
/// into memory: ``open(_:expecting:)`` memory-maps the file and pages load on demand
/// (specification section 10). The file records the model id, the dimensions and the
/// quantization parameters; opening it for another model or another dimension count throws.
///
/// A store is a value. Rows are addressed by ordinal, in insertion order, and an ordinal never
/// moves: the HNSW graph refers to rows by ordinal. Vectors that arrive at runtime are appended
/// in memory on top of the mapped file; replacing or removing a vector tombstones its row
/// instead of rewriting the file. ``compacted()`` drops the tombstones and renumbers.
///
/// ## File layout, version 1
///
/// Little-endian, sections padded to 8 bytes, the vectors to 64:
///
///     header (56 bytes)   magic "ZTVS", version, byte-order mark, dimensions, row count,
///                         live count, model id length, rows digest, id blob length
///     model id            UTF-8
///     offsets, scales     2 x dimensions x Float32      quantization parameters
///     tombstones          ceil(rows / 64) x UInt64      one bit per row
///     id offsets          (rows + 1) x UInt32           into the id blob
///     id blob             UTF-8, concatenated
///     sorted ordinals     live x UInt32                 live rows ordered by id, for lookup
///     vectors             rows x dimensions x Int8
///
/// Nothing but the small leading sections is touched when a file is opened: ids are sliced out
/// of the blob on demand and found by binary search over the sorted ordinals.
public struct QuantizedVectorStore: Sendable {
    /// What a caller requires of a vector file before it will use it.
    public struct Expectation: Sendable, Hashable {
        /// The model id the file must have been written for.
        public var modelID: String
        /// The dimensions the file must hold.
        public var dimensions: Int

        /// Creates an expectation.
        public init(modelID: String, dimensions: Int) {
            self.modelID = modelID
            self.dimensions = dimensions
        }
    }

    /// What ``upsert(_:vector:)`` did.
    public struct UpsertOutcome: Sendable, Hashable {
        /// Ordinal of the row that holds the vector now.
        public let ordinal: Int
        /// Ordinal of the row the upsert retired, when the id held a different vector before.
        public let replaced: Int?
        /// `true` when the id already held exactly these codes and nothing changed.
        public let isUnchanged: Bool
    }

    /// The extension vector files are written with.
    public static let fileExtension = "ztvec"
    /// The format version this build reads and writes.
    public static let formatVersion: UInt32 = 1
    private static let magic = "ZTVS"

    /// Identity of the embedding space the vectors belong to.
    public let modelID: String
    /// Components per vector.
    public let dimensions: Int
    /// How the stored codes map to values.
    public let quantization: VectorQuantization

    // The file this store was opened from, or the bytes it was built into. Immutable.
    private let base: Data
    private let baseCount: Int
    private let idOffsetsStart: Int
    private let idBlobStart: Int
    private let idBlobLength: Int
    private let sortedStart: Int
    private let sortedCount: Int
    private let vectorsStart: Int

    // Rows added since. Ordinals continue after the base rows.
    private var appendedCodes: [Int8] = []
    private var appendedIDs: [SearchableID] = []
    /// Ids whose live row is an appended one.
    private var overlay: [SearchableID: Int] = [:]
    private var tombstones: Bitset
    /// XOR of the hashes of every live row; kept current so the fingerprint costs nothing.
    private var rowsDigest: UInt64
    private let headerDigest: UInt64
    /// `true` until the first change after the store was built or opened.
    private var isPristine = true

    /// Rows that hold a current vector.
    public private(set) var liveCount: Int

    /// Rows ever stored, tombstoned ones included. Ordinals run from 0 to `count - 1`.
    public var count: Int { baseCount + appendedIDs.count }
    /// Rows retired by a replacement or a removal.
    public var tombstoneCount: Int { count - liveCount }
    /// `true` when no row holds a current vector.
    public var isEmpty: Bool { liveCount == 0 }

    /// Identifies the exact content of the store: model, dimensions, quantization, every live
    /// row and its ordinal. A graph file records the fingerprint of the store it was built over.
    public var fingerprint: UInt64 {
        Fingerprint.mix(headerDigest ^ rowsDigest ^ Fingerprint.mix(UInt64(count)))
    }

    // MARK: Creation

    /// An empty store for vectors that arrive at runtime.
    public init(modelID: String, dimensions: Int, quantization: VectorQuantization) throws {
        guard (1...SemanticLimits.maximumDimensions).contains(dimensions) else {
            throw SemanticError.unsupportedDimensions(dimensions)
        }
        guard quantization.dimensions == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: quantization.dimensions)
        }
        self.modelID = modelID
        self.dimensions = dimensions
        self.quantization = quantization
        self.base = Data()
        self.baseCount = 0
        self.idOffsetsStart = 0
        self.idBlobStart = 0
        self.idBlobLength = 0
        self.sortedStart = 0
        self.sortedCount = 0
        self.vectorsStart = 0
        self.tombstones = Bitset()
        self.rowsDigest = 0
        self.headerDigest = Self.headerDigest(modelID: modelID, dimensions: dimensions, quantization: quantization)
        self.liveCount = 0
    }

    /// Quantizes a set of vectors into a store.
    ///
    /// - Parameters:
    ///   - vectors: Id and vector pairs. When an id appears more than once its last vector wins.
    ///   - modelID: Identity of the embedding space.
    ///   - dimensions: Components per vector; 1...384.
    ///   - quantization: Parameters to quantize with. `nil` fits them to `vectors`
    ///     (``VectorQuantization/fitted(to:dimensions:headroom:minimumSampleCount:)``).
    /// - Throws: ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/invalidVector(_:)`` for a vector that does not fit the space.
    public static func build(
        from vectors: [(SearchableID, [Float])],
        modelID: String,
        dimensions: Int,
        quantization: VectorQuantization? = nil
    ) throws -> QuantizedVectorStore {
        guard (1...SemanticLimits.maximumDimensions).contains(dimensions) else {
            throw SemanticError.unsupportedDimensions(dimensions)
        }
        // Last occurrence wins, at the position of the first.
        var rowOfID: [SearchableID: Int] = [:]
        rowOfID.reserveCapacity(vectors.count)
        var ids: [SearchableID] = []
        var sources: [Int] = []
        for (index, entry) in vectors.enumerated() {
            guard entry.1.count == dimensions else {
                throw SemanticError.dimensionMismatch(expected: dimensions, found: entry.1.count)
            }
            if let row = rowOfID[entry.0] {
                sources[row] = index
            } else {
                rowOfID[entry.0] = ids.count
                ids.append(entry.0)
                sources.append(index)
            }
        }
        let parameters = try quantization ?? VectorQuantization.fitted(to: sources.map { vectors[$0].1 }, dimensions: dimensions)

        var codes = [Int8](repeating: 0, count: ids.count * dimensions)
        var digest: UInt64 = 0
        var scratch = [Float](repeating: 0, count: dimensions)
        try codes.withUnsafeMutableBufferPointer { codeBuffer in
            try scratch.withUnsafeMutableBufferPointer { work in
                guard let codeBase = codeBuffer.baseAddress, let workBase = work.baseAddress else { return }
                for (row, source) in sources.enumerated() {
                    try vectors[source].1.withUnsafeBufferPointer { values in
                        guard let valueBase = values.baseAddress else { return }
                        guard VectorKernels.squaredNorm(valueBase, count: dimensions).isFinite else {
                            throw SemanticError.invalidVector("the vector of '\(vectors[source].0)' holds a value that is not finite")
                        }
                        let target = codeBase + row * dimensions
                        parameters.encode(valueBase, into: target, scratch: workBase)
                        digest ^= Self.rowHash(ordinal: row, codes: target, dimensions: dimensions)
                    }
                }
            }
        }

        var staging = try QuantizedVectorStore(modelID: modelID, dimensions: dimensions, quantization: parameters)
        staging.appendedCodes = codes
        staging.appendedIDs = ids
        staging.rowsDigest = digest
        staging.liveCount = ids.count
        return try QuantizedVectorStore(data: staging.encoded())
    }

    /// Opens a vector file memory-mapped.
    ///
    /// This is the one synchronous file call of the store; it reads the header and the small
    /// leading sections and maps the rest.
    ///
    /// - Parameters:
    ///   - url: The file to open.
    ///   - expectation: The model and dimensions the caller will search with.
    /// - Throws: ``SemanticError/modelMismatch(expected:found:)`` or
    ///   ``SemanticError/dimensionMismatch(expected:found:)`` when the file was written for
    ///   another space; ``SemanticError/corruptFile(_:)``,
    ///   ``SemanticError/unsupportedFormatVersion(found:supported:)`` or ``SemanticError/io(_:)``
    ///   when it cannot be read.
    public static func open(_ url: URL, expecting expectation: Expectation? = nil) throws -> QuantizedVectorStore {
        let store = try QuantizedVectorStore(data: FileAccess.map(url))
        if let expectation {
            guard store.modelID == expectation.modelID else {
                throw SemanticError.modelMismatch(expected: expectation.modelID, found: store.modelID)
            }
            guard store.dimensions == expectation.dimensions else {
                throw SemanticError.dimensionMismatch(expected: expectation.dimensions, found: store.dimensions)
            }
        }
        return store
    }

    /// Parses the bytes of a vector file. Only the leading sections are read.
    init(data: Data) throws {
        var modelID = ""
        var dimensions = 0
        var rowCount = 0
        var liveCount = 0
        var rowsDigest: UInt64 = 0
        var offsets: [Float] = []
        var scales: [Float] = []
        var tombstoneWords: [UInt64] = []
        var idOffsetsStart = 0
        var idBlobStart = 0
        var idBlobLength = 0
        var sortedStart = 0
        var vectorsStart = 0

        try data.withUnsafeBytes { raw in
            var reader = BinaryReader(raw, label: "the vector file")
            try reader.readMagic(Self.magic)
            let version = try reader.readUInt32()
            guard version == Self.formatVersion else {
                throw SemanticError.unsupportedFormatVersion(found: version, supported: Self.formatVersion)
            }
            guard try reader.readUInt32() == binaryByteOrderMark else {
                throw SemanticError.corruptFile("the vector file was written in another byte order")
            }
            dimensions = Int(try reader.readUInt32())
            guard (1...SemanticLimits.maximumDimensions).contains(dimensions) else {
                throw SemanticError.unsupportedDimensions(dimensions)
            }
            rowCount = try reader.readCount(atMost: Int(Int32.max))
            liveCount = try reader.readCount(atMost: rowCount)
            let modelIDLength = try reader.readCount(atMost: 4_096)
            _ = try reader.readUInt32()
            rowsDigest = try reader.readUInt64()
            let blobLength = try reader.readUInt64()
            guard blobLength <= UInt64(UInt32.max) else {
                throw SemanticError.corruptFile("the vector file declares an impossible id table")
            }
            idBlobLength = Int(blobLength)
            _ = try reader.readUInt64()

            modelID = try reader.readString(byteCount: modelIDLength)
            try reader.align(to: 8)
            offsets = try reader.readArray(of: Float.self, count: dimensions)
            scales = try reader.readArray(of: Float.self, count: dimensions)
            try reader.align(to: 8)
            tombstoneWords = try reader.readArray(of: UInt64.self, count: (rowCount + 63) / 64)
            idOffsetsStart = try reader.skipSection(byteCount: (rowCount + 1) * 4)
            try reader.align(to: 8)
            idBlobStart = try reader.skipSection(byteCount: idBlobLength)
            try reader.align(to: 8)
            sortedStart = try reader.skipSection(byteCount: liveCount * 4)
            try reader.align(to: 64)
            vectorsStart = try reader.skipSection(byteCount: rowCount * dimensions)
            guard reader.offset == raw.count else {
                throw SemanticError.corruptFile("the vector file has \(raw.count - reader.offset) unexpected trailing bytes")
            }
            let lastOffset = raw.loadUnaligned(fromByteOffset: idOffsetsStart + rowCount * 4, as: UInt32.self)
            guard Int(UInt32(littleEndian: lastOffset)) == idBlobLength else {
                throw SemanticError.corruptFile("the id table of the vector file is inconsistent")
            }
        }

        let tombstones = Bitset(words: tombstoneWords)
        guard rowCount - tombstones.population == liveCount else {
            throw SemanticError.corruptFile("the tombstones of the vector file do not match its live count")
        }
        let quantization: VectorQuantization
        do {
            quantization = try VectorQuantization(offsets: offsets, scales: scales)
        } catch {
            throw SemanticError.corruptFile("the vector file holds unusable quantization parameters")
        }

        self.modelID = modelID
        self.dimensions = dimensions
        self.quantization = quantization
        self.base = data
        self.baseCount = rowCount
        self.idOffsetsStart = idOffsetsStart
        self.idBlobStart = idBlobStart
        self.idBlobLength = idBlobLength
        self.sortedStart = sortedStart
        self.sortedCount = liveCount
        self.vectorsStart = vectorsStart
        self.tombstones = tombstones
        self.rowsDigest = rowsDigest
        self.headerDigest = Self.headerDigest(modelID: modelID, dimensions: dimensions, quantization: quantization)
        self.liveCount = liveCount
    }

    // MARK: Persistence

    /// Writes the store to `url`, atomically.
    ///
    /// Tombstoned rows are written too, so that ordinals, and with them the graph file written
    /// alongside, stay valid; ``compacted()`` removes them. The write runs off the cooperative
    /// thread pool.
    public func write(to url: URL) async throws {
        try await FileAccess.write(encoded(), to: url)
    }

    /// The bytes of the vector file for the current content.
    func encoded() -> Data {
        if isPristine, !base.isEmpty { return base }

        // Ids: the base table verbatim, then the appended ids.
        var idOffsets: [UInt32] = []
        idOffsets.reserveCapacity(count + 1)
        var idBlob: [UInt8] = []
        base.withUnsafeBytes { raw in
            guard baseCount > 0 else { return }
            idBlob.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[idBlobStart..<(idBlobStart + idBlobLength)]))
            for row in 0..<baseCount {
                idOffsets.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: idOffsetsStart + row * 4, as: UInt32.self)))
            }
        }
        for id in appendedIDs {
            idOffsets.append(UInt32(idBlob.count))
            idBlob.append(contentsOf: id.rawValue.utf8)
        }
        idOffsets.append(UInt32(idBlob.count))

        // Live rows ordered by id bytes, for binary search.
        var sorted: [UInt32] = []
        sorted.reserveCapacity(liveCount)
        for row in 0..<count where !tombstones.contains(row) {
            sorted.append(UInt32(row))
        }
        idBlob.withUnsafeBytes { blob in
            idOffsets.withUnsafeBufferPointer { table in
                sorted.sort { lhs, rhs in
                    let left = UnsafeRawBufferPointer(rebasing: blob[Int(table[Int(lhs)])..<Int(table[Int(lhs) + 1])])
                    let right = UnsafeRawBufferPointer(rebasing: blob[Int(table[Int(rhs)])..<Int(table[Int(rhs) + 1])])
                    return Self.compare(left, right) < 0
                }
            }
        }

        var writer = BinaryWriter(capacity: 4_096 + idBlob.count + count * (dimensions + 8))
        writer.append(magic: Self.magic)
        writer.append(Self.formatVersion)
        writer.append(binaryByteOrderMark)
        writer.append(UInt32(dimensions))
        writer.append(UInt32(count))
        writer.append(UInt32(liveCount))
        writer.append(UInt32(modelID.utf8.count))
        writer.append(UInt32(0))
        writer.append(rowsDigest)
        writer.append(UInt64(idBlob.count))
        writer.append(UInt64(0))
        writer.append(utf8: modelID)
        writer.align(to: 8)
        writer.append(elements: quantization.offsets)
        writer.append(elements: quantization.scales)
        writer.align(to: 8)
        writer.append(elements: tombstones.words(covering: count))
        writer.append(elements: idOffsets)
        writer.align(to: 8)
        writer.append(elements: idBlob)
        writer.align(to: 8)
        writer.append(elements: sorted)
        writer.align(to: 64)
        base.withUnsafeBytes { raw in
            guard baseCount > 0 else { return }
            writer.append(bytes: UnsafeRawBufferPointer(rebasing: raw[vectorsStart..<(vectorsStart + baseCount * dimensions)]))
        }
        writer.append(elements: appendedCodes)
        return writer.data
    }

    /// A store with the same live vectors and no tombstones.
    ///
    /// Ordinals are renumbered in their current order, so a graph built over this store does
    /// not fit the result: rebuild it.
    public func compacted() throws -> QuantizedVectorStore {
        var codes: [Int8] = []
        codes.reserveCapacity(liveCount * dimensions)
        var ids: [SearchableID] = []
        ids.reserveCapacity(liveCount)
        var digest: UInt64 = 0
        withRows { rows in
            for ordinal in 0..<count {
                guard let id = id(at: ordinal) else { continue }
                let row = rows.row(ordinal)
                digest ^= Self.rowHash(ordinal: ids.count, codes: row, dimensions: dimensions)
                codes.append(contentsOf: UnsafeBufferPointer(start: row, count: dimensions))
                ids.append(id)
            }
        }
        var staging = try QuantizedVectorStore(modelID: modelID, dimensions: dimensions, quantization: quantization)
        staging.appendedCodes = codes
        staging.appendedIDs = ids
        staging.rowsDigest = digest
        staging.liveCount = ids.count
        return try QuantizedVectorStore(data: staging.encoded())
    }

    // MARK: Lookup

    /// The ordinal of the row that holds the current vector of `id`.
    public func ordinal(of id: SearchableID) -> Int? {
        if let ordinal = overlay[id] { return ordinal }
        guard let ordinal = baseOrdinal(of: id), !tombstones.contains(ordinal) else { return nil }
        return ordinal
    }

    /// `true` when `id` holds a vector.
    public func contains(_ id: SearchableID) -> Bool {
        ordinal(of: id) != nil
    }

    /// The id stored at `ordinal`, or `nil` when the row is tombstoned or does not exist.
    public func id(at ordinal: Int) -> SearchableID? {
        guard ordinal >= 0, ordinal < count, !tombstones.contains(ordinal) else { return nil }
        if ordinal >= baseCount { return appendedIDs[ordinal - baseCount] }
        return base.withUnsafeBytes { raw in
            idBytes(raw, row: ordinal).map { SearchableID(String(decoding: $0, as: UTF8.self)) }
        }
    }

    /// `true` when the row at `ordinal` was retired by a replacement or a removal.
    public func isTombstoned(_ ordinal: Int) -> Bool {
        tombstones.contains(ordinal)
    }

    /// The ids that hold a vector, in ordinal order.
    public var ids: [SearchableID] {
        var result: [SearchableID] = []
        result.reserveCapacity(liveCount)
        for ordinal in 0..<count {
            if let id = id(at: ordinal) { result.append(id) }
        }
        return result
    }

    /// The stored codes of the row at `ordinal`.
    public func codes(at ordinal: Int) -> [Int8]? {
        guard ordinal >= 0, ordinal < count, !tombstones.contains(ordinal) else { return nil }
        return withRows { rows in
            Array(UnsafeBufferPointer(start: rows.row(ordinal), count: dimensions))
        }
    }

    /// The vector the row at `ordinal` stands for: its codes, decoded.
    public func vector(at ordinal: Int) -> [Float]? {
        guard ordinal >= 0, ordinal < count, !tombstones.contains(ordinal) else { return nil }
        return withRows { rows in
            [Float](unsafeUninitializedCapacity: dimensions) { values, initialized in
                if let target = values.baseAddress {
                    quantization.decode(rows.row(ordinal), into: target)
                }
                initialized = dimensions
            }
        }
    }

    /// The vector stored for `id`, decoded.
    public func vector(for id: SearchableID) -> [Float]? {
        ordinal(of: id).flatMap(vector(at:))
    }

    /// Vectors added, by id, since the store was built or opened, decoded.
    public func runtimeVectors() -> [(SearchableID, [Float])] {
        var result: [(SearchableID, [Float])] = []
        for ordinal in baseCount..<count {
            if let id = id(at: ordinal), let vector = vector(at: ordinal) {
                result.append((id, vector))
            }
        }
        return result
    }

    // MARK: Changes in memory

    /// Stores the vector of `id`, replacing the one it had.
    ///
    /// The vector is appended in memory; a row that held another vector for the id is
    /// tombstoned. Upserting codes the id already holds changes nothing, so repeating an upsert
    /// is free.
    ///
    /// - Throws: ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/invalidVector(_:)``.
    @discardableResult
    public mutating func upsert(_ id: SearchableID, vector: [Float]) throws -> UpsertOutcome {
        let codes = try quantization.encode(vector)
        let existing = ordinal(of: id)
        if let existing {
            let same = withRows { rows in
                codes.withUnsafeBufferPointer { memcmp($0.baseAddress, rows.row(existing), dimensions) == 0 }
            }
            if same { return UpsertOutcome(ordinal: existing, replaced: nil, isUnchanged: true) }
            retire(existing)
        }
        let ordinal = count
        rowsDigest ^= codes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { Self.rowHash(ordinal: ordinal, codes: $0, dimensions: dimensions) } ?? 0
        }
        appendedCodes.append(contentsOf: codes)
        appendedIDs.append(id)
        overlay[id] = ordinal
        liveCount += 1
        isPristine = false
        return UpsertOutcome(ordinal: ordinal, replaced: existing, isUnchanged: false)
    }

    /// Removes the vector of `id`.
    ///
    /// - Returns: The ordinal of the tombstoned row, or `nil` when the id held no vector.
    @discardableResult
    public mutating func remove(_ id: SearchableID) -> Int? {
        guard let ordinal = ordinal(of: id) else { return nil }
        retire(ordinal)
        overlay[id] = nil
        isPristine = false
        return ordinal
    }

    private mutating func retire(_ ordinal: Int) {
        let hash = withRows { rows in
            Self.rowHash(ordinal: ordinal, codes: rows.row(ordinal), dimensions: dimensions)
        }
        rowsDigest ^= hash
        tombstones.insert(ordinal)
        liveCount -= 1
    }

    // MARK: Exact search

    /// The `limit` rows most similar to `query`, best first, by exhaustive comparison.
    ///
    /// The similarity is the dot product of the query with the decoded row, which is the cosine
    /// similarity when both are unit length. This is the reference the HNSW index is measured
    /// against, and it costs a pass over every row: use ``HNSWIndex`` to search.
    ///
    /// - Throws: ``SemanticError/dimensionMismatch(expected:found:)`` or
    ///   ``SemanticError/invalidVector(_:)``.
    public func nearest(to query: [Float], limit: Int) throws -> [SemanticMatch] {
        try nearestOrdinals(to: query, limit: limit).compactMap { entry in
            id(at: entry.ordinal).map { SemanticMatch(id: $0, similarity: min(1, max(-1, entry.similarity))) }
        }
    }

    /// Exhaustive search by ordinal.
    func nearestOrdinals(to query: [Float], limit: Int) throws -> [(ordinal: Int, similarity: Float)] {
        guard query.count == dimensions else {
            throw SemanticError.dimensionMismatch(expected: dimensions, found: query.count)
        }
        guard limit > 0, liveCount > 0 else { return [] }
        var weights = [Float](repeating: 0, count: dimensions)
        var bias: Float = 0
        try query.withUnsafeBufferPointer { values in
            guard let base = values.baseAddress, VectorKernels.squaredNorm(base, count: dimensions).isFinite else {
                throw SemanticError.invalidVector("the query holds a value that is not finite")
            }
            weights.withUnsafeMutableBufferPointer { buffer in
                if let target = buffer.baseAddress { bias = quantization.prepare(base, into: target) }
            }
        }

        let blockRows = 256
        var widened = [Float](repeating: 0, count: blockRows * dimensions)
        var scores = [Float](repeating: 0, count: blockRows)
        var best = TopMatches(limit: min(limit, liveCount))
        let dimensions = self.dimensions
        let total = count
        withRows { rows in
            weights.withUnsafeBufferPointer { weightBuffer in
                widened.withUnsafeMutableBufferPointer { widenedBuffer in
                    scores.withUnsafeMutableBufferPointer { scoreBuffer in
                        guard let weightBase = weightBuffer.baseAddress, let widenedBase = widenedBuffer.baseAddress,
                              let scoreBase = scoreBuffer.baseAddress else { return }
                        var start = 0
                        while start < total {
                            // A block never straddles the mapped rows and the appended ones.
                            let regionEnd = start < rows.baseCount ? rows.baseCount : total
                            let rowCount = min(blockRows, regionEnd - start)
                            vDSP_vflt8(rows.row(start), 1, widenedBase, 1, vDSP_Length(rowCount * dimensions))
                            VectorKernels.products(rows: widenedBase, rowCount: rowCount, vector: weightBase, count: dimensions, into: scoreBase)
                            for offset in 0..<rowCount {
                                let similarity = scoreBase[offset] + bias
                                if best.accepts(similarity), !tombstones.contains(start + offset) {
                                    best.insert(ordinal: start + offset, similarity: similarity)
                                }
                            }
                            start += rowCount
                        }
                    }
                }
            }
        }
        return best.sorted()
    }

    // MARK: Row access

    /// Unchecked access to the stored codes, valid only inside ``withRows(_:)``.
    struct Rows {
        let base: UnsafePointer<Int8>?
        let baseCount: Int
        let appended: UnsafePointer<Int8>?
        let dimensions: Int

        /// The codes of the row at `ordinal`; the caller guarantees `ordinal` is in range.
        @inline(__always)
        func row(_ ordinal: Int) -> UnsafePointer<Int8> {
            if ordinal < baseCount {
                return base.unsafelyUnwrapped + ordinal &* dimensions
            }
            return appended.unsafelyUnwrapped + (ordinal &- baseCount) &* dimensions
        }
    }

    /// Runs `body` with pointers into the mapped file and the appended rows.
    func withRows<Value>(_ body: (Rows) throws -> Value) rethrows -> Value {
        try base.withUnsafeBytes { raw in
            try appendedCodes.withUnsafeBufferPointer { appended in
                let mapped = baseCount > 0
                    ? raw.baseAddress.map { ($0 + vectorsStart).assumingMemoryBound(to: Int8.self) }
                    : nil
                return try body(Rows(base: mapped, baseCount: baseCount, appended: appended.baseAddress, dimensions: dimensions))
            }
        }
    }

    // MARK: Internals

    private static func headerDigest(modelID: String, dimensions: Int, quantization: VectorQuantization) -> UInt64 {
        Fingerprint.hash(modelID, seed: 0x6D6F_6465_6C) ^ Fingerprint.mix(UInt64(dimensions)) ^ quantization.digest
    }

    private static func rowHash(ordinal: Int, codes: UnsafePointer<Int8>, dimensions: Int) -> UInt64 {
        Fingerprint.hash(UnsafeRawBufferPointer(start: codes, count: dimensions), seed: UInt64(ordinal) &+ 1)
    }

    /// Orders two byte strings lexicographically: negative, zero or positive.
    private static func compare(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Int {
        let shared = min(lhs.count, rhs.count)
        if shared > 0, let left = lhs.baseAddress, let right = rhs.baseAddress {
            let order = memcmp(left, right, shared)
            if order != 0 { return Int(order) }
        }
        return lhs.count - rhs.count
    }

    /// The UTF-8 bytes of the id of a base row, or `nil` when the id table is damaged.
    private func idBytes(_ raw: UnsafeRawBufferPointer, row: Int) -> UnsafeRawBufferPointer? {
        let start = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: idOffsetsStart + row * 4, as: UInt32.self)))
        let end = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: idOffsetsStart + (row + 1) * 4, as: UInt32.self)))
        guard start <= end, end <= idBlobLength else { return nil }
        return UnsafeRawBufferPointer(rebasing: raw[(idBlobStart + start)..<(idBlobStart + end)])
    }

    /// Binary search over the sorted ordinals of the mapped file. Tombstones are not consulted.
    private func baseOrdinal(of id: SearchableID) -> Int? {
        guard sortedCount > 0 else { return nil }
        var key = id.rawValue
        return key.withUTF8 { keyBytes in
            base.withUnsafeBytes { raw -> Int? in
                var low = 0
                var high = sortedCount - 1
                while low <= high {
                    let middle = (low + high) / 2
                    let ordinal = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: sortedStart + middle * 4, as: UInt32.self)))
                    guard ordinal < baseCount, let candidate = idBytes(raw, row: ordinal) else { return nil }
                    let order = Self.compare(candidate, UnsafeRawBufferPointer(keyBytes))
                    if order == 0 { return ordinal }
                    if order < 0 { low = middle + 1 } else { high = middle - 1 }
                }
                return nil
            }
        }
    }
}

/// The best `limit` rows seen so far: a binary heap with the worst kept row on top.
struct TopMatches {
    private var entries: [(ordinal: Int, similarity: Float)] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
        entries.reserveCapacity(self.limit)
    }

    /// `true` when a row of this similarity may enter the set. Rows that tie with the worst
    /// kept row are let through, and ``insert(ordinal:similarity:)`` settles the tie.
    @inline(__always)
    func accepts(_ similarity: Float) -> Bool {
        entries.count < limit || similarity >= entries[0].similarity
    }

    /// `true` when `lhs` ranks below `rhs`: less similar, or equally similar with a higher ordinal.
    @inline(__always)
    private static func isWorse(_ lhs: (ordinal: Int, similarity: Float), _ rhs: (ordinal: Int, similarity: Float)) -> Bool {
        lhs.similarity < rhs.similarity || (lhs.similarity == rhs.similarity && lhs.ordinal > rhs.ordinal)
    }

    mutating func insert(ordinal: Int, similarity: Float) {
        guard limit > 0, !similarity.isNaN else { return }
        let entry = (ordinal: ordinal, similarity: similarity)
        if entries.count < limit {
            entries.append(entry)
            var child = entries.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.isWorse(entries[child], entries[parent]) else { break }
                entries.swapAt(child, parent)
                child = parent
            }
            return
        }
        guard Self.isWorse(entries[0], entry) else { return }
        entries[0] = entry
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var worst = parent
            if left < entries.count, Self.isWorse(entries[left], entries[worst]) { worst = left }
            if right < entries.count, Self.isWorse(entries[right], entries[worst]) { worst = right }
            if worst == parent { break }
            entries.swapAt(parent, worst)
            parent = worst
        }
    }

    /// The kept rows, best first; ties broken by ordinal.
    func sorted() -> [(ordinal: Int, similarity: Float)] {
        entries.sorted { Self.isWorse($1, $0) }
    }
}
