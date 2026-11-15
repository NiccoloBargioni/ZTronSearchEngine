import Foundation

/// Append-only little-endian byte sink used to assemble index segments.
struct ByteWriter {
    var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    var count: Int { bytes.count }

    @inline(__always)
    mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    mutating func append<T: FixedWidthInteger>(fixed value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func append(double value: Double) {
        append(fixed: value.bitPattern)
    }

    /// LEB128: seven payload bits per byte, high bit set on every byte but the last.
    @inline(__always)
    mutating func append(varint value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(truncatingIfNeeded: remaining))
    }

    mutating func append(string: String) {
        var copy = string
        copy.withUTF8 { utf8 in
            append(varint: UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        }
    }

    mutating func append(optionalString: String?) {
        if let optionalString {
            append(1)
            append(string: optionalString)
        } else {
            append(0)
        }
    }

    mutating func append(contentsOf other: [UInt8]) {
        bytes.append(contentsOf: other)
    }

    mutating func append(buffer: UnsafeRawBufferPointer) {
        bytes.append(contentsOf: buffer)
    }

    /// Pads with zeros to a multiple of `alignment`.
    mutating func align(to alignment: Int) {
        let remainder = bytes.count % alignment
        if remainder != 0 {
            bytes.append(contentsOf: repeatElement(0, count: alignment - remainder))
        }
    }
}

/// Bounds-checked little-endian reader over a raw buffer.
struct ByteReader {
    let buffer: UnsafeRawBufferPointer
    var offset: Int

    init(_ buffer: UnsafeRawBufferPointer, offset: Int = 0) {
        self.buffer = buffer
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= buffer.count }

    mutating func byte() throws -> UInt8 {
        guard offset < buffer.count else { throw SearchError.corruptIndex("unexpected end of data") }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func fixed<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= buffer.count else { throw SearchError.corruptIndex("unexpected end of data") }
        defer { offset += size }
        return T(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    mutating func double() throws -> Double {
        Double(bitPattern: try fixed(UInt64.self))
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let next = try byte()
            result |= UInt64(next & 0x7F) << shift
            if next & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw SearchError.corruptIndex("varint overflow") }
        }
    }

    mutating func string() throws -> String {
        let length = Int(try varint())
        guard length >= 0, offset + length <= buffer.count else { throw SearchError.corruptIndex("string overruns its section") }
        defer { offset += length }
        return String(decoding: UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)]), as: UTF8.self)
    }

    mutating func optionalString() throws -> String? {
        try byte() == 0 ? nil : try string()
    }
}

/// Unchecked varint decoding for the scoring loops. The segment was validated when it was opened.
@inline(__always)
func readVarint(_ pointer: UnsafePointer<UInt8>, _ offset: inout Int) -> UInt32 {
    var byte = pointer[offset]
    offset += 1
    if byte < 0x80 { return UInt32(byte) }
    var result = UInt32(byte & 0x7F)
    var shift: UInt32 = 7
    while true {
        byte = pointer[offset]
        offset += 1
        result |= UInt32(byte & 0x7F) << shift
        if byte < 0x80 { return result }
        shift += 7
    }
}

/// A growable bitset over document ordinals.
struct Bitset: Sendable, Hashable {
    private(set) var words: [UInt64]
    private(set) var count: Int = 0

    init(capacity: Int = 0) {
        words = [UInt64](repeating: 0, count: (capacity + 63) / 64)
    }

    @inline(__always)
    func contains(_ index: Int) -> Bool {
        let word = index >> 6
        return word < words.count && (words[word] & (1 << UInt64(index & 63))) != 0
    }

    /// Returns `true` when the bit was newly set.
    @discardableResult
    mutating func insert(_ index: Int) -> Bool {
        let word = index >> 6
        if word >= words.count {
            words.append(contentsOf: repeatElement(0, count: word - words.count + 1))
        }
        let mask: UInt64 = 1 << UInt64(index & 63)
        if words[word] & mask != 0 { return false }
        words[word] |= mask
        count += 1
        return true
    }

    var isEmpty: Bool { count == 0 }
}

/// FNV-1a over the UTF-8 bytes of an id; the hash of the persisted id table.
@inline(__always)
func fnv1a(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}

func fnv1a(_ string: String) -> UInt64 {
    var copy = string
    return copy.withUTF8 { fnv1a(UnsafeRawBufferPointer($0)) }
}
