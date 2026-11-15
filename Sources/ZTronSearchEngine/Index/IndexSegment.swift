import Foundation

/// What an index was built for. Recorded in persisted files: any mismatch with the running
/// engine discards the file and rebuilds (specification section 6).
struct IndexMetadata: Sendable, Hashable {
    var localeTag: String = ""
    var secondaryLanguages: [String] = []
    var includesAllLanguages = false
    var embeddingModelID: String = ""
    /// Identifies the content the index was built from, when the builder knows it.
    var contentFingerprint: String = ""

    func encoded() -> [UInt8] {
        var writer = ByteWriter()
        writer.append(string: localeTag)
        writer.append(varint: UInt64(secondaryLanguages.count))
        for language in secondaryLanguages { writer.append(string: language) }
        writer.append(includesAllLanguages ? 1 : 0)
        writer.append(string: embeddingModelID)
        writer.append(string: contentFingerprint)
        return writer.bytes
    }

    static func decode(_ buffer: UnsafeRawBufferPointer) throws -> IndexMetadata {
        var reader = ByteReader(buffer)
        var metadata = IndexMetadata()
        metadata.localeTag = try reader.string()
        for _ in 0..<Int(try reader.varint()) { metadata.secondaryLanguages.append(try reader.string()) }
        metadata.includesAllLanguages = try reader.byte() != 0
        metadata.embeddingModelID = try reader.string()
        metadata.contentFingerprint = try reader.string()
        return metadata
    }
}

/// Layout of one index segment. The same bytes serve in memory, in a memory-mapped file and,
/// cut into chunks, inside the host database.
///
/// Every integer is little-endian. Fixed-width sections start on 8-byte boundaries.
enum SegmentFormat {
    static let magic: [UInt8] = Array("ZTSI".utf8)
    /// 2: per-document term lists (`forwardOffsets`, `forwardBytes`) and term signatures.
    static let version: UInt32 = 2
    static let headerSize = 96
    static let sectionEntrySize = 16

    /// Where each section starts and how long the whole segment is: the section table follows
    /// the header, then every section sits on an 8-byte boundary.
    static func layout(sectionSizes: [Int]) -> (placements: [Int], total: Int) {
        var offset = headerSize + sectionSizes.count * sectionEntrySize
        offset += (8 - offset % 8) % 8
        var placements: [Int] = []
        placements.reserveCapacity(sectionSizes.count)
        for size in sectionSizes {
            placements.append(offset)
            offset += size
            offset += (8 - offset % 8) % 8
        }
        return (placements, offset)
    }

    enum Section: Int, CaseIterable {
        case metadata
        case termOffsets          // UInt32 x (terms + 1), into termBytes
        case termBytes            // UTF-8, ascending byte order
        case termDocumentFrequency // UInt32 x terms
        case postingOffsets       // UInt32 x (terms + 1), into postings
        case postings             // per term: field mask, byte length per present field, payloads
        case fieldLengths         // UInt32 x fields x documents, field-major
        case idOffsets            // UInt32 x (documents + 1), into idBytes
        case idBytes
        case storeOffsets         // UInt32 x (documents + 1), into storeBytes
        case storeBytes           // DocumentCodec records
        case documentKinds        // UInt16 x documents
        case documentFilterOffsets // UInt32 x (documents + 1), into documentFilters
        case documentFilters      // UInt32 filter ordinals
        case documentUpdatedAt    // Float64 x documents, NaN = none
        case kindTable            // strings
        case filterTable          // (key, value) strings
        case idHash               // UInt32 x slots, ordinal + 1, 0 = empty; FNV-1a, linear probing
        case trigramKeys          // UInt64 x trigrams, ascending
        case trigramOffsets       // UInt32 x (trigrams + 1), into trigramPostings
        case trigramPostings      // varint deltas of term ordinals
        case forwardOffsets       // UInt32 x (documents + 1), into forwardBytes
        case forwardBytes         // per document: varint deltas of its distinct term ordinals
        case termSignatures       // UInt64 x terms: which scalars the term contains (`TermSignature`)
    }
}

/// An immutable index segment: sorted vocabulary, per-field postings, document table, document
/// store and trigram index, all read in place from `data`.
struct IndexSegment: Sendable {
    let data: Data
    let documentCount: Int
    let termCount: Int
    let trigramCount: Int
    let idHashSlots: Int
    let projectionVersion: Int
    let normalizerVersion: Int
    let totalFieldLengths: [UInt64]
    let kinds: [String]
    let filters: [FilterRecord]
    let metadata: IndexMetadata?
    private let offsets: [Int]
    private let lengths: [Int]

    init(data: Data) throws {
        self.data = data
        guard data.count >= SegmentFormat.headerSize else {
            throw SearchError.corruptIndex("file is shorter than a segment header")
        }
        let parsed: Parsed = try data.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            for expected in SegmentFormat.magic where try reader.byte() != expected {
                throw SearchError.corruptIndex("not an index segment")
            }
            let version: UInt32 = try reader.fixed()
            guard version == SegmentFormat.version else {
                throw SearchError.versionMismatch("segment format \(version), expected \(SegmentFormat.version)")
            }
            var parsed = Parsed()
            parsed.projectionVersion = Int(try reader.fixed(UInt32.self))
            parsed.normalizerVersion = Int(try reader.fixed(UInt32.self))
            parsed.documentCount = Int(try reader.fixed(UInt32.self))
            parsed.termCount = Int(try reader.fixed(UInt32.self))
            let kindCount = Int(try reader.fixed(UInt32.self))
            let filterCount = Int(try reader.fixed(UInt32.self))
            parsed.trigramCount = Int(try reader.fixed(UInt32.self))
            parsed.idHashSlots = Int(try reader.fixed(UInt32.self))
            for _ in 0..<SearchField.count { parsed.totalFieldLengths.append(try reader.fixed(UInt64.self)) }
            let sectionCount = Int(try reader.fixed(UInt32.self))
            _ = try reader.fixed(UInt32.self)
            guard sectionCount == SegmentFormat.Section.allCases.count else {
                throw SearchError.corruptIndex("unexpected section count \(sectionCount)")
            }
            for _ in 0..<sectionCount {
                let offset = Int(try reader.fixed(UInt64.self))
                let length = Int(try reader.fixed(UInt64.self))
                guard offset >= 0, length >= 0, offset + length <= raw.count else {
                    throw SearchError.corruptIndex("a section overruns the file")
                }
                parsed.offsets.append(offset)
                parsed.lengths.append(length)
            }
            func expect(_ section: SegmentFormat.Section, bytes: Int) throws {
                guard parsed.lengths[section.rawValue] == bytes else {
                    throw SearchError.corruptIndex("section \(section) has \(parsed.lengths[section.rawValue]) bytes, expected \(bytes)")
                }
            }
            try expect(.termOffsets, bytes: 4 * (parsed.termCount + 1))
            try expect(.termDocumentFrequency, bytes: 4 * parsed.termCount)
            try expect(.postingOffsets, bytes: 4 * (parsed.termCount + 1))
            try expect(.fieldLengths, bytes: 4 * SearchField.count * parsed.documentCount)
            try expect(.idOffsets, bytes: 4 * (parsed.documentCount + 1))
            try expect(.storeOffsets, bytes: 4 * (parsed.documentCount + 1))
            try expect(.documentKinds, bytes: 2 * parsed.documentCount)
            try expect(.documentFilterOffsets, bytes: 4 * (parsed.documentCount + 1))
            try expect(.documentUpdatedAt, bytes: 8 * parsed.documentCount)
            try expect(.idHash, bytes: 4 * parsed.idHashSlots)
            try expect(.trigramKeys, bytes: 8 * parsed.trigramCount)
            try expect(.trigramOffsets, bytes: 4 * (parsed.trigramCount + 1))
            try expect(.forwardOffsets, bytes: 4 * (parsed.documentCount + 1))
            try expect(.termSignatures, bytes: 8 * parsed.termCount)
            guard parsed.idHashSlots == 0 || parsed.idHashSlots & (parsed.idHashSlots - 1) == 0 else {
                throw SearchError.corruptIndex("id table size is not a power of two")
            }

            func section(_ section: SegmentFormat.Section) -> UnsafeRawBufferPointer {
                let start = parsed.offsets[section.rawValue]
                return UnsafeRawBufferPointer(rebasing: raw[start..<(start + parsed.lengths[section.rawValue])])
            }
            var kindReader = ByteReader(section(.kindTable))
            for _ in 0..<kindCount { parsed.kinds.append(try kindReader.string()) }
            var filterReader = ByteReader(section(.filterTable))
            for _ in 0..<filterCount {
                let key = try filterReader.string()
                parsed.filters.append(FilterRecord(key: key, value: try filterReader.string()))
            }
            if parsed.lengths[SegmentFormat.Section.metadata.rawValue] > 0 {
                parsed.metadata = try IndexMetadata.decode(section(.metadata))
            }
            return parsed
        }
        documentCount = parsed.documentCount
        termCount = parsed.termCount
        trigramCount = parsed.trigramCount
        idHashSlots = parsed.idHashSlots
        projectionVersion = parsed.projectionVersion
        normalizerVersion = parsed.normalizerVersion
        totalFieldLengths = parsed.totalFieldLengths
        kinds = parsed.kinds
        filters = parsed.filters
        metadata = parsed.metadata
        offsets = parsed.offsets
        lengths = parsed.lengths
    }

    private struct Parsed {
        var documentCount = 0
        var termCount = 0
        var trigramCount = 0
        var idHashSlots = 0
        var projectionVersion = 0
        var normalizerVersion = 0
        var totalFieldLengths: [UInt64] = []
        var kinds: [String] = []
        var filters: [FilterRecord] = []
        var metadata: IndexMetadata?
        var offsets: [Int] = []
        var lengths: [Int] = []
    }

    /// Where a section sits, relative to the start of the segment.
    func sectionRange(_ section: SegmentFormat.Section) -> Range<Int> {
        offsets[section.rawValue]..<(offsets[section.rawValue] + lengths[section.rawValue])
    }

    /// Runs `body` with direct access to the segment's bytes.
    @inline(__always)
    func withView<Result>(_ body: (SegmentView) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes { raw in
            try body(SegmentView(base: raw.baseAddress!, segment: self, offsets: offsets, lengths: lengths))
        }
    }

    /// The document stored at an ordinal.
    func document(at ordinal: Int) throws -> SearchDocument {
        try withView { try $0.document(at: ordinal) }
    }

    func id(at ordinal: Int) -> SearchableID {
        withView { SearchableID($0.idString(ordinal)) }
    }

    func ordinal(of id: SearchableID) -> Int? {
        withView { $0.ordinal(ofID: id.rawValue) }
    }
}

/// Pointer-level accessors over a segment's bytes. Valid only inside ``IndexSegment/withView(_:)``.
struct SegmentView {
    let base: UnsafeRawPointer
    let segment: IndexSegment
    private let termOffsets: UnsafeRawPointer
    private let termBytes: UnsafeRawPointer
    private let termDF: UnsafeRawPointer
    private let postingOffsets: UnsafeRawPointer
    let postings: UnsafePointer<UInt8>
    private let fieldLengths: UnsafeRawPointer
    private let idOffsets: UnsafeRawPointer
    private let idBytes: UnsafeRawPointer
    private let storeOffsets: UnsafeRawPointer
    private let storeBytes: UnsafeRawPointer
    private let documentKinds: UnsafeRawPointer
    private let filterOffsets: UnsafeRawPointer
    private let documentFilters: UnsafeRawPointer
    private let updatedAt: UnsafeRawPointer
    private let idHash: UnsafeRawPointer
    private let trigramKeys: UnsafeRawPointer
    private let trigramOffsets: UnsafeRawPointer
    let trigramPostings: UnsafePointer<UInt8>
    private let forwardOffsets: UnsafeRawPointer
    let forward: UnsafePointer<UInt8>
    private let termSignatures: UnsafeRawPointer

    init(base: UnsafeRawPointer, segment: IndexSegment, offsets: [Int], lengths: [Int]) {
        self.base = base
        self.segment = segment
        func pointer(_ section: SegmentFormat.Section) -> UnsafeRawPointer { base + offsets[section.rawValue] }
        termOffsets = pointer(.termOffsets)
        termBytes = pointer(.termBytes)
        termDF = pointer(.termDocumentFrequency)
        postingOffsets = pointer(.postingOffsets)
        postings = pointer(.postings).assumingMemoryBound(to: UInt8.self)
        fieldLengths = pointer(.fieldLengths)
        idOffsets = pointer(.idOffsets)
        idBytes = pointer(.idBytes)
        storeOffsets = pointer(.storeOffsets)
        storeBytes = pointer(.storeBytes)
        documentKinds = pointer(.documentKinds)
        filterOffsets = pointer(.documentFilterOffsets)
        documentFilters = pointer(.documentFilters)
        updatedAt = pointer(.documentUpdatedAt)
        idHash = pointer(.idHash)
        trigramKeys = pointer(.trigramKeys)
        trigramOffsets = pointer(.trigramOffsets)
        trigramPostings = pointer(.trigramPostings).assumingMemoryBound(to: UInt8.self)
        forwardOffsets = pointer(.forwardOffsets)
        forward = pointer(.forwardBytes).assumingMemoryBound(to: UInt8.self)
        termSignatures = pointer(.termSignatures)
    }

    @inline(__always) private func u32(_ pointer: UnsafeRawPointer, _ index: Int) -> Int {
        Int(UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: index &* 4, as: UInt32.self)))
    }

    // MARK: Vocabulary

    @inline(__always) func termBuffer(_ term: Int) -> UnsafeRawBufferPointer {
        let start = u32(termOffsets, term)
        return UnsafeRawBufferPointer(start: termBytes + start, count: u32(termOffsets, term + 1) - start)
    }

    func termString(_ term: Int) -> String {
        String(decoding: termBuffer(term), as: UTF8.self)
    }

    @inline(__always) func documentFrequency(_ term: Int) -> Int {
        u32(termDF, term)
    }

    /// Which scalars the term contains, as a `TermSignature`.
    @inline(__always) func signature(_ term: Int) -> UInt64 {
        UInt64(littleEndian: termSignatures.loadUnaligned(fromByteOffset: term &* 8, as: UInt64.self))
    }

    /// Byte-wise comparison of a stored term with `key`: negative, zero or positive.
    @inline(__always) private func compare(_ term: Int, _ key: UnsafeRawBufferPointer) -> Int {
        let stored = termBuffer(term)
        let common = min(stored.count, key.count)
        if common > 0 {
            let order = memcmp(stored.baseAddress!, key.baseAddress!, common)
            if order != 0 { return Int(order) }
        }
        return stored.count - key.count
    }

    /// The first term that is not less than `key`.
    func lowerBound(_ key: UnsafeRawBufferPointer) -> Int {
        var low = 0
        var high = segment.termCount
        while low < high {
            let middle = (low + high) / 2
            if compare(middle, key) < 0 { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func find(_ term: String) -> Int? {
        var copy = term
        return copy.withUTF8 { find(utf8: UnsafeRawBufferPointer($0)) }
    }

    func find(utf8 key: UnsafeRawBufferPointer) -> Int? {
        let index = lowerBound(key)
        return index < segment.termCount && compare(index, key) == 0 ? index : nil
    }

    /// The contiguous run of terms that start with `prefix`.
    func prefixRange(_ prefix: String) -> Range<Int> {
        var copy = prefix
        return copy.withUTF8 { prefixRange(utf8: UnsafeRawBufferPointer($0)) }
    }

    func prefixRange(utf8 key: UnsafeRawBufferPointer) -> Range<Int> {
        let lower = lowerBound(key)
        var low = lower
        var high = segment.termCount
        while low < high {
            let middle = (low + high) / 2
            let stored = termBuffer(middle)
            let hasPrefix = stored.count >= key.count
                && (key.count == 0 || memcmp(stored.baseAddress!, key.baseAddress!, key.count) == 0)
            if hasPrefix { low = middle + 1 } else { high = middle }
        }
        return lower..<low
    }

    // MARK: Postings

    /// Where the postings of `term` in `field` start inside ``postings``, and how many bytes they span.
    @inline(__always) func postingRange(term: Int, field: Int) -> (start: Int, length: Int)? {
        var offset = u32(postingOffsets, term)
        let mask = postings[offset]
        offset += 1
        guard mask & (1 << UInt8(field)) != 0 else { return nil }
        var skipped = 0
        var length = 0
        for present in 0..<SearchField.count where mask & (1 << UInt8(present)) != 0 {
            let byteLength = Int(readVarint(postings, &offset))
            if present < field { skipped += byteLength }
            if present == field { length = byteLength }
        }
        return (offset + skipped, length)
    }

    // MARK: Documents

    @inline(__always) func fieldLength(field: Int, document: Int) -> UInt32 {
        UInt32(littleEndian: fieldLengths.loadUnaligned(fromByteOffset: (field &* segment.documentCount &+ document) &* 4, as: UInt32.self))
    }

    @inline(__always) func idBuffer(_ document: Int) -> UnsafeRawBufferPointer {
        let start = u32(idOffsets, document)
        return UnsafeRawBufferPointer(start: idBytes + start, count: u32(idOffsets, document + 1) - start)
    }

    func idString(_ document: Int) -> String {
        String(decoding: idBuffer(document), as: UTF8.self)
    }

    @inline(__always) func kindOrdinal(_ document: Int) -> Int {
        Int(UInt16(littleEndian: documentKinds.loadUnaligned(fromByteOffset: document &* 2, as: UInt16.self)))
    }

    @inline(__always) func filterCount(_ document: Int) -> Int {
        u32(filterOffsets, document + 1) - u32(filterOffsets, document)
    }

    @inline(__always) func filterOrdinal(_ document: Int, _ index: Int) -> Int {
        u32(documentFilters, u32(filterOffsets, document) + index)
    }

    func updatedAt(_ document: Int) -> Date? {
        let value = Double(bitPattern: UInt64(littleEndian: updatedAt.loadUnaligned(fromByteOffset: document &* 8, as: UInt64.self)))
        return value.isNaN ? nil : Date(timeIntervalSinceReferenceDate: value)
    }

    func storeBuffer(_ document: Int) -> UnsafeRawBufferPointer {
        let start = u32(storeOffsets, document)
        return UnsafeRawBufferPointer(start: storeBytes + start, count: u32(storeOffsets, document + 1) - start)
    }

    func document(at ordinal: Int) throws -> SearchDocument {
        try DocumentCodec.decode(storeBuffer(ordinal))
    }

    func ordinal(ofID id: String) -> Int? {
        guard segment.idHashSlots > 0 else { return nil }
        var copy = id
        return copy.withUTF8 { utf8 -> Int? in
            let key = UnsafeRawBufferPointer(utf8)
            let mask = segment.idHashSlots - 1
            var slot = Int(truncatingIfNeeded: fnv1a(key)) & mask
            while true {
                let stored = u32(idHash, slot)
                if stored == 0 { return nil }
                let candidate = idBuffer(stored - 1)
                if candidate.count == key.count && (key.count == 0 || memcmp(candidate.baseAddress!, key.baseAddress!, key.count) == 0) {
                    return stored - 1
                }
                slot = (slot + 1) & mask
            }
        }
    }

    /// Calls `body` with the ordinal of every distinct term of a document, ascending.
    @inline(__always) func forEachTerm(of document: Int, _ body: (Int) -> Void) {
        var offset = u32(forwardOffsets, document)
        let end = u32(forwardOffsets, document + 1)
        var term = 0
        while offset < end {
            term += Int(readVarint(forward, &offset))
            body(term)
        }
    }

    // MARK: Trigrams

    @inline(__always) func trigramKey(_ index: Int) -> UInt64 {
        UInt64(littleEndian: trigramKeys.loadUnaligned(fromByteOffset: index &* 8, as: UInt64.self))
    }

    /// The varint-delta run of the trigram at `index`.
    @inline(__always) func trigramRun(_ index: Int) -> (start: Int, length: Int) {
        let start = u32(trigramOffsets, index)
        return (start, u32(trigramOffsets, index + 1) - start)
    }

    /// The term ordinals that contain a padded trigram, as a varint-delta run.
    func trigramRange(_ key: UInt64) -> (start: Int, length: Int)? {
        var low = 0
        var high = segment.trigramCount
        while low < high {
            let middle = (low + high) / 2
            let stored = UInt64(littleEndian: trigramKeys.loadUnaligned(fromByteOffset: middle &* 8, as: UInt64.self))
            if stored < key { low = middle + 1 } else { high = middle }
        }
        guard low < segment.trigramCount,
              UInt64(littleEndian: trigramKeys.loadUnaligned(fromByteOffset: low &* 8, as: UInt64.self)) == key else { return nil }
        let start = u32(trigramOffsets, low)
        return (start, u32(trigramOffsets, low + 1) - start)
    }
}
