import Foundation

/// Append-only little-endian sink used to assemble vector files and graph files.
///
/// Every multi-byte section is padded to an 8-byte boundary, so a reader that memory-maps the
/// file can bind sections to `UInt32`, `UInt64` or `Float` without unaligned loads.
struct BinaryWriter {
    private(set) var data: Data

    init(capacity: Int = 0) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func append(magic: String) {
        data.append(contentsOf: Array(magic.utf8))
    }

    mutating func append(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int32) {
        append(UInt32(bitPattern: value))
    }

    mutating func append(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Appends raw bytes: an array's storage, a mapped region, a string's UTF-8.
    mutating func append(bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        data.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
    }

    mutating func append(utf8 string: String) {
        var copy = string
        copy.withUTF8 { append(bytes: UnsafeRawBufferPointer($0)) }
    }

    /// Appends the elements of a trivially copyable array in host byte order. Files carry a
    /// byte-order mark, and every supported platform is little-endian.
    mutating func append<Element: BitwiseCopyable>(elements: [Element]) {
        elements.withUnsafeBytes { append(bytes: $0) }
    }

    mutating func append(zeros count: Int) {
        guard count > 0 else { return }
        data.append(Data(count: count))
    }

    /// Pads with zero bytes up to the next multiple of `alignment`.
    mutating func align(to alignment: Int) {
        let remainder = data.count % alignment
        if remainder != 0 { append(zeros: alignment - remainder) }
    }

}

/// Bounds-checked little-endian reader over a file's bytes.
///
/// It never traps on a truncated or malformed file: every read that would leave the buffer
/// throws ``SemanticError/corruptFile(_:)``.
struct BinaryReader {
    private let bytes: UnsafeRawBufferPointer
    private(set) var offset = 0
    private let label: String

    init(_ bytes: UnsafeRawBufferPointer, label: String) {
        self.bytes = bytes
        self.label = label
    }

    private func require(_ length: Int) throws {
        guard length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw SemanticError.corruptFile("\(label) is truncated at byte \(offset)")
        }
    }

    mutating func readMagic(_ expected: String) throws {
        let wanted = Array(expected.utf8)
        try require(wanted.count)
        for (index, byte) in wanted.enumerated() where bytes[offset + index] != byte {
            throw SemanticError.corruptFile("\(label) does not start with '\(expected)'")
        }
        offset += wanted.count
    }

    mutating func readUInt32() throws -> UInt32 {
        try require(4)
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt64() throws -> UInt64 {
        try require(8)
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8
        return UInt64(littleEndian: value)
    }

    /// A count or length field, checked to fit an `Int` and a plausible bound.
    mutating func readCount(atMost limit: Int) throws -> Int {
        let raw = try readUInt32()
        guard Int(raw) <= limit else {
            throw SemanticError.corruptFile("\(label) declares a count of \(raw), over the limit of \(limit)")
        }
        return Int(raw)
    }

    mutating func readString(byteCount: Int) throws -> String {
        try require(byteCount)
        let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + byteCount)])
        offset += byteCount
        return String(decoding: slice, as: UTF8.self)
    }

    /// Copies `count` trivially copyable elements out of the buffer.
    mutating func readArray<Element: BitwiseCopyable>(of type: Element.Type, count: Int) throws -> [Element] {
        let byteCount = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        guard !byteCount.overflow else {
            throw SemanticError.corruptFile("\(label) declares an impossible section size")
        }
        try require(byteCount.partialValue)
        guard count > 0 else { return [] }
        let start = offset
        offset += byteCount.partialValue
        return [Element](unsafeUninitializedCapacity: count) { buffer, initialized in
            UnsafeMutableRawBufferPointer(buffer).copyMemory(
                from: UnsafeRawBufferPointer(rebasing: bytes[start..<(start + byteCount.partialValue)])
            )
            initialized = count
        }
    }

    /// Reserves a section of `byteCount` bytes and returns where it starts, without copying it.
    mutating func skipSection(byteCount: Int) throws -> Int {
        try require(byteCount)
        let start = offset
        offset += byteCount
        return start
    }

    mutating func align(to alignment: Int) throws {
        let remainder = offset % alignment
        if remainder != 0 { try require(alignment - remainder); offset += alignment - remainder }
    }
}

/// The value both file formats store to detect a file written on a machine of another byte order.
let binaryByteOrderMark: UInt32 = 0x0102_0304

/// 64-bit mixing used for content fingerprints. Not cryptographic: it only has to tell a graph
/// file that belongs to a vector store from one that does not.
enum Fingerprint {
    /// SplitMix64 finalizer: a bijective scrambling of one word.
    @inline(__always)
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Hashes a byte range, eight bytes at a time.
    static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64) -> UInt64 {
        var state = mix(seed ^ UInt64(bytes.count))
        guard let base = bytes.baseAddress else { return state }
        var offset = 0
        var word: UInt64 = 0
        while offset + 8 <= bytes.count {
            memcpy(&word, base + offset, 8)
            state = mix(state ^ word)
            offset += 8
        }
        if offset < bytes.count {
            word = 0
            memcpy(&word, base + offset, bytes.count - offset)
            state = mix(state ^ word)
        }
        return state
    }

    static func hash(_ string: String, seed: UInt64) -> UInt64 {
        var copy = string
        return copy.withUTF8 { hash(UnsafeRawBufferPointer($0), seed: seed) }
    }

    static func hash<Element: BitwiseCopyable>(_ elements: [Element], seed: UInt64) -> UInt64 {
        elements.withUnsafeBytes { hash($0, seed: seed) }
    }
}

/// A growable set of small non-negative integers, one bit each.
struct Bitset: Sendable, Equatable {
    private(set) var words: [UInt64]

    init(capacity: Int = 0) {
        words = [UInt64](repeating: 0, count: (capacity + 63) / 64)
    }

    init(words: [UInt64]) {
        self.words = words
    }

    func contains(_ index: Int) -> Bool {
        let word = index >> 6
        guard word < words.count else { return false }
        return words[word] & (1 << UInt64(index & 63)) != 0
    }

    /// Returns `true` when the bit was not set before.
    @discardableResult
    mutating func insert(_ index: Int) -> Bool {
        let word = index >> 6
        if word >= words.count {
            words.append(contentsOf: repeatElement(0, count: word + 1 - words.count))
        }
        let mask: UInt64 = 1 << UInt64(index & 63)
        let inserted = words[word] & mask == 0
        words[word] |= mask
        return inserted
    }

    /// Makes room for `count` bits, so that the words can be read through a pointer.
    mutating func reserve(_ count: Int) {
        let needed = (count + 63) / 64
        if words.count < needed {
            words.append(contentsOf: repeatElement(0, count: needed - words.count))
        }
    }

    /// The words that cover `count` bits, zero-extended, for serialization.
    func words(covering count: Int) -> [UInt64] {
        let needed = (count + 63) / 64
        if words.count == needed { return words }
        if words.count > needed { return Array(words[..<needed]) }
        return words + [UInt64](repeating: 0, count: needed - words.count)
    }

    var population: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}
