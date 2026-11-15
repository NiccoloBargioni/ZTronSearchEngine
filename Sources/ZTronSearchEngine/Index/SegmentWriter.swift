import Foundation

/// Assembles the bytes of one index segment.
///
/// Terms are committed in ascending UTF-8 order; documents in ordinal order.
struct SegmentWriter {
    /// Per-field posting payloads of the term being assembled. Callers fill these, then call
    /// ``commitTerm(_:documentFrequency:)``, which empties them again without freeing storage.
    var fieldPostings = [ByteWriter](repeating: ByteWriter(), count: SearchField.count)

    private var termOffsets: [UInt32] = [0]
    private var termBytes = ByteWriter()
    private var termDocumentFrequency: [UInt32] = []
    private var termSignatures: [UInt64] = []
    private var postingOffsets: [UInt32] = [0]
    private var postings = ByteWriter()

    /// One entry per (term, distinct padded trigram), in term order. Empty when the caller
    /// supplies a merged trigram index instead.
    private let collectsTrigrams: Bool
    private var trigramPairKeys: [UInt64] = []
    private var trigramPairTerms: [UInt32] = []
    private var scalarScratch: [UInt32] = []
    private var keyScratch: [UInt64] = []

    private var fieldLengths = [[UInt32]](repeating: [], count: SearchField.count)
    private var totalFieldLengths = [UInt64](repeating: 0, count: SearchField.count)
    private var idOffsets: [UInt32] = [0]
    private var idBytes = ByteWriter()
    private var storeOffsets: [UInt32] = [0]
    private var storeBytes = ByteWriter()
    private var documentKinds: [UInt16] = []
    private var filterOffsets: [UInt32] = [0]
    private var documentFilters: [UInt32] = []
    private var updatedAt: [Double] = []
    private var forwardOffsets: [UInt32] = [0]
    private var forwardBytes = ByteWriter()

    /// Sizes known up front, so the large buffers are allocated once instead of doubling.
    struct Reservation {
        var terms = 0
        var documents = 0
        var termBytes = 0
        var postingBytes = 0
        var idBytes = 0
        var storeBytes = 0
        var forwardBytes = 0
    }

    init(reserving reservation: Reservation = Reservation(), collectsTrigrams: Bool = true) {
        self.collectsTrigrams = collectsTrigrams
        termOffsets.reserveCapacity(reservation.terms + 1)
        termDocumentFrequency.reserveCapacity(reservation.terms)
        termSignatures.reserveCapacity(reservation.terms)
        postingOffsets.reserveCapacity(reservation.terms + 1)
        termBytes.bytes.reserveCapacity(reservation.termBytes)
        postings.bytes.reserveCapacity(reservation.postingBytes)
        for field in 0..<SearchField.count { fieldLengths[field].reserveCapacity(reservation.documents) }
        idOffsets.reserveCapacity(reservation.documents + 1)
        idBytes.bytes.reserveCapacity(reservation.idBytes)
        storeOffsets.reserveCapacity(reservation.documents + 1)
        storeBytes.bytes.reserveCapacity(reservation.storeBytes)
        documentKinds.reserveCapacity(reservation.documents)
        filterOffsets.reserveCapacity(reservation.documents + 1)
        updatedAt.reserveCapacity(reservation.documents)
        forwardOffsets.reserveCapacity(reservation.documents + 1)
        forwardBytes.bytes.reserveCapacity(reservation.forwardBytes)
    }

    var documentCount: Int { documentKinds.count }
    var termCount: Int { termDocumentFrequency.count }

    // MARK: Terms

    /// Appends one posting to a field payload: the gap to the previous document, then the
    /// frequency. `previous` is `-1` for the first posting of the list.
    @inline(__always)
    mutating func appendPosting(field: Int, document: Int, previous: Int, frequency: UInt32) {
        fieldPostings[field].append(varint: UInt64(document - previous))
        fieldPostings[field].append(varint: UInt64(frequency))
    }

    /// Empties ``fieldPostings`` without writing a term.
    mutating func discardStagedPostings() {
        for field in 0..<SearchField.count where fieldPostings[field].count > 0 {
            fieldPostings[field].bytes.removeAll(keepingCapacity: true)
        }
    }

    /// Writes the term whose payloads are in ``fieldPostings``.
    mutating func commitTerm(_ term: String, documentFrequency: UInt32) {
        var copy = term
        copy.withUTF8 { commitTerm(utf8: UnsafeRawBufferPointer($0), documentFrequency: documentFrequency) }
    }

    /// Writes the term whose normalized UTF-8 bytes are `term` and whose payloads are in
    /// ``fieldPostings``.
    mutating func commitTerm(utf8 term: UnsafeRawBufferPointer, documentFrequency: UInt32) {
        var mask: UInt8 = 0
        for field in 0..<SearchField.count where fieldPostings[field].count > 0 {
            mask |= 1 << UInt8(field)
        }
        postings.append(mask)
        for field in 0..<SearchField.count where fieldPostings[field].count > 0 {
            postings.append(varint: UInt64(fieldPostings[field].count))
        }
        for field in 0..<SearchField.count where fieldPostings[field].count > 0 {
            postings.append(contentsOf: fieldPostings[field].bytes)
            fieldPostings[field].bytes.removeAll(keepingCapacity: true)
        }
        postingOffsets.append(UInt32(postings.count))

        let ordinal = UInt32(termDocumentFrequency.count)
        termBytes.append(buffer: term)
        termOffsets.append(UInt32(termBytes.count))
        termDocumentFrequency.append(documentFrequency)
        termSignatures.append(TermSignature.of(utf8: term))
        // Exact-only terms are never fuzzy candidates, and nothing shorter than two scalars can
        // sit within the allowed edits of a three-scalar token.
        if collectsTrigrams, !ScriptClass.isExactOnly(utf8: term) {
            keyScratch.removeAll(keepingCapacity: true)
            Trigram.appendKeys(ofUTF8: term, scalars: &scalarScratch, into: &keyScratch)
            for key in keyScratch {
                trigramPairKeys.append(key)
                trigramPairTerms.append(ordinal)
            }
        }
    }

    // MARK: Documents

    mutating func addDocument(
        id: UnsafeRawBufferPointer,
        store: UnsafeRawBufferPointer,
        kind: Int,
        filters: [UInt32],
        updatedAt date: Double,
        lengths: (Int) -> UInt32
    ) {
        idBytes.append(buffer: id)
        idOffsets.append(UInt32(idBytes.count))
        storeBytes.append(buffer: store)
        storeOffsets.append(UInt32(storeBytes.count))
        documentKinds.append(UInt16(kind))
        documentFilters.append(contentsOf: filters)
        filterOffsets.append(UInt32(documentFilters.count))
        updatedAt.append(date)
        for field in 0..<SearchField.count {
            let length = lengths(field)
            fieldLengths[field].append(length)
            totalFieldLengths[field] += UInt64(length)
        }
    }

    /// Records the terms of the document added last: ascending, distinct term ordinals. Deleting
    /// the document later adjusts the statistics of exactly these terms, without tokenizing
    /// anything again.
    mutating func addForward(_ terms: [UInt32]) {
        var previous: UInt32 = 0
        for term in terms {
            forwardBytes.append(varint: UInt64(term &- previous))
            previous = term
        }
        forwardOffsets.append(UInt32(forwardBytes.count))
    }

    mutating func addDocument(_ document: SearchDocument, kind: Int, filters: [UInt32], lengths: (Int) -> UInt32) {
        var store = ByteWriter(capacity: 128 + document.text.utf8.count)
        DocumentCodec.encode(document, into: &store)
        var id = document.id.rawValue
        id.withUTF8 { idBuffer in
            store.bytes.withUnsafeBytes { storeBuffer in
                addDocument(
                    id: UnsafeRawBufferPointer(idBuffer),
                    store: storeBuffer,
                    kind: kind,
                    filters: filters,
                    updatedAt: document.updatedAt?.timeIntervalSinceReferenceDate ?? .nan,
                    lengths: lengths
                )
            }
        }
    }

    // MARK: Assembly

    /// A trigram index in its stored form.
    struct TrigramIndex {
        var keys: [UInt64] = []
        var offsets: [UInt32] = [0]
        var postings: [UInt8] = []
    }

    /// Lays the segment out in one allocation: header, section table, then every section on an
    /// 8-byte boundary. `trigrams` replaces the index this writer would build from its terms.
    func finish(kinds: [String], filters: [FilterRecord], metadata: IndexMetadata?, trigrams merged: TrigramIndex? = nil) -> Data {
        precondition(forwardOffsets.count == documentCount + 1, "every document needs its term list")
        var kindTable = ByteWriter()
        for kind in kinds { kindTable.append(string: kind) }
        var filterTable = ByteWriter()
        for filter in filters {
            filterTable.append(string: filter.key)
            filterTable.append(string: filter.value)
        }
        let (hashSlots, hashTable) = buildIDHash()
        let trigrams = merged ?? buildTrigramIndex()
        let metadataBytes = metadata?.encoded() ?? []
        let updatedAtBits = updatedAt.map(\.bitPattern)

        // What each section is made of, in `SegmentFormat.Section` order.
        var parts = [[Part]](repeating: [], count: SegmentFormat.Section.allCases.count)
        func set(_ section: SegmentFormat.Section, _ part: Part) { parts[section.rawValue] = [part] }
        set(.metadata, .bytes(metadataBytes))
        set(.termOffsets, .words32(termOffsets))
        set(.termBytes, .bytes(termBytes.bytes))
        set(.termDocumentFrequency, .words32(termDocumentFrequency))
        set(.postingOffsets, .words32(postingOffsets))
        set(.postings, .bytes(postings.bytes))
        parts[SegmentFormat.Section.fieldLengths.rawValue] = fieldLengths.map { .words32($0) }
        set(.idOffsets, .words32(idOffsets))
        set(.idBytes, .bytes(idBytes.bytes))
        set(.storeOffsets, .words32(storeOffsets))
        set(.storeBytes, .bytes(storeBytes.bytes))
        set(.documentKinds, .words16(documentKinds))
        set(.documentFilterOffsets, .words32(filterOffsets))
        set(.documentFilters, .words32(documentFilters))
        set(.documentUpdatedAt, .words64(updatedAtBits))
        set(.kindTable, .bytes(kindTable.bytes))
        set(.filterTable, .bytes(filterTable.bytes))
        set(.idHash, .words32(hashTable))
        set(.trigramKeys, .words64(trigrams.keys))
        set(.trigramOffsets, .words32(trigrams.offsets))
        set(.trigramPostings, .bytes(trigrams.postings))
        set(.forwardOffsets, .words32(forwardOffsets))
        set(.forwardBytes, .bytes(forwardBytes.bytes))
        set(.termSignatures, .words64(termSignatures))

        var header = ByteWriter(capacity: SegmentFormat.headerSize + parts.count * SegmentFormat.sectionEntrySize)
        header.append(contentsOf: SegmentFormat.magic)
        header.append(fixed: SegmentFormat.version)
        header.append(fixed: UInt32(SearchDocument.projectionVersion))
        header.append(fixed: UInt32(SearchNormalizer.version))
        header.append(fixed: UInt32(documentCount))
        header.append(fixed: UInt32(termCount))
        header.append(fixed: UInt32(kinds.count))
        header.append(fixed: UInt32(filters.count))
        header.append(fixed: UInt32(trigrams.keys.count))
        header.append(fixed: UInt32(hashSlots))
        for total in totalFieldLengths { header.append(fixed: total) }
        header.append(fixed: UInt32(parts.count))
        header.append(fixed: UInt32(0))
        precondition(header.count == SegmentFormat.headerSize)

        let sizes = parts.map { $0.reduce(0) { $0 + $1.byteCount } }
        let layout = SegmentFormat.layout(sectionSizes: sizes)
        for (index, size) in sizes.enumerated() {
            header.append(fixed: UInt64(layout.placements[index]))
            header.append(fixed: UInt64(size))
        }

        var data = Data(count: layout.total)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            header.bytes.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            for (index, section) in parts.enumerated() {
                var cursor = base + layout.placements[index]
                for part in section {
                    part.write(to: cursor)
                    cursor += part.byteCount
                }
            }
        }
        return data
    }

    /// A run of bytes inside a section, written in place from the array that holds it.
    private enum Part {
        case bytes([UInt8])
        case words16([UInt16])
        case words32([UInt32])
        case words64([UInt64])

        var byteCount: Int {
            switch self {
            case .bytes(let values): return values.count
            case .words16(let values): return values.count * 2
            case .words32(let values): return values.count * 4
            case .words64(let values): return values.count * 8
            }
        }

        func write(to destination: UnsafeMutableRawPointer) {
            switch self {
            case .bytes(let values): Self.copy(values, to: destination)
            case .words16(let values): Self.copy(values, to: destination)
            case .words32(let values): Self.copy(values, to: destination)
            case .words64(let values): Self.copy(values, to: destination)
            }
        }

        /// Every integer of the format is little-endian.
        private static func copy<T: FixedWidthInteger>(_ values: [T], to destination: UnsafeMutableRawPointer) {
            guard !values.isEmpty else { return }
            #if _endian(little)
            values.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            #else
            var cursor = destination
            for value in values {
                Swift.withUnsafeBytes(of: value.littleEndian) { cursor.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                cursor += MemoryLayout<T>.size
            }
            #endif
        }
    }

    /// Open-addressing table from id hash to ordinal + 1, at most half full.
    private func buildIDHash() -> (slots: Int, table: [UInt32]) {
        let count = documentCount
        guard count > 0 else { return (0, []) }
        var slots = 16
        while slots < count * 2 { slots <<= 1 }
        var table = [UInt32](repeating: 0, count: slots)
        let mask = slots - 1
        idBytes.bytes.withUnsafeBytes { raw in
            for document in 0..<count {
                let start = Int(idOffsets[document])
                let end = Int(idOffsets[document + 1])
                var slot = Int(truncatingIfNeeded: fnv1a(UnsafeRawBufferPointer(rebasing: raw[start..<end]))) & mask
                while table[slot] != 0 { slot = (slot + 1) & mask }
                table[slot] = UInt32(document + 1)
            }
        }
        return (slots, table)
    }

    /// Padded trigram to term ordinals. The pairs were collected in term order, so a stable sort
    /// by trigram leaves the ordinals of each trigram ascending.
    private func buildTrigramIndex() -> TrigramIndex {
        guard !trigramPairKeys.isEmpty else { return TrigramIndex() }
        var keys = trigramPairKeys
        var terms = trigramPairTerms
        RadixSort.sort(keys: &keys, values: &terms)

        var index = TrigramIndex()
        var postings = ByteWriter(capacity: terms.count * 2)
        var position = 0
        while position < keys.count {
            let key = keys[position]
            index.keys.append(key)
            var previous: UInt32 = 0
            while position < keys.count && keys[position] == key {
                postings.append(varint: UInt64(terms[position] &- previous))
                previous = terms[position]
                position += 1
            }
            index.offsets.append(UInt32(postings.count))
        }
        index.postings = postings.bytes
        return index
    }
}

/// Stable least-significant-digit radix sorts for the index builder.
enum RadixSort {
    /// Sorts `keys` ascending and permutes `values` along with them. Equal keys keep their
    /// order. Digits every key shares cost one counting pass and no move.
    static func sort(keys: inout [UInt64], values: inout [UInt32]) {
        let count = keys.count
        precondition(values.count == count)
        guard count > 1 else { return }
        if count <= 32 {
            for index in 1..<count {
                let key = keys[index]
                let value = values[index]
                var slot = index
                while slot > 0 && keys[slot - 1] > key {
                    keys[slot] = keys[slot - 1]
                    values[slot] = values[slot - 1]
                    slot -= 1
                }
                keys[slot] = key
                values[slot] = value
            }
            return
        }
        var otherKeys = [UInt64](repeating: 0, count: count)
        var otherValues = [UInt32](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 256)
        for shift in stride(from: UInt64(0), to: 64, by: 8) {
            for bucket in 0..<256 { histogram[bucket] = 0 }
            keys.withUnsafeBufferPointer { source in
                for index in 0..<count { histogram[Int((source[index] >> shift) & 0xFF)] += 1 }
            }
            if histogram[Int((keys[0] >> shift) & 0xFF)] == count { continue }
            var total = 0
            for bucket in 0..<256 {
                let size = histogram[bucket]
                histogram[bucket] = total
                total += size
            }
            keys.withUnsafeBufferPointer { sourceKeys in
                values.withUnsafeBufferPointer { sourceValues in
                    otherKeys.withUnsafeMutableBufferPointer { targetKeys in
                        otherValues.withUnsafeMutableBufferPointer { targetValues in
                            for index in 0..<count {
                                let bucket = Int((sourceKeys[index] >> shift) & 0xFF)
                                let slot = histogram[bucket]
                                histogram[bucket] = slot + 1
                                targetKeys[slot] = sourceKeys[index]
                                targetValues[slot] = sourceValues[index]
                            }
                        }
                    }
                }
            }
            swap(&keys, &otherKeys)
            swap(&values, &otherValues)
        }
    }

    /// Sorts ascending and removes repeats.
    static func sortUnique(_ values: inout [UInt32]) {
        let count = values.count
        guard count > 1 else { return }
        if count <= 64 {
            values.sort()
        } else {
            var other = [UInt32](repeating: 0, count: count)
            var histogram = [Int](repeating: 0, count: 256)
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                for bucket in 0..<256 { histogram[bucket] = 0 }
                values.withUnsafeBufferPointer { source in
                    for index in 0..<count { histogram[Int((source[index] >> shift) & 0xFF)] += 1 }
                }
                if histogram[Int((values[0] >> shift) & 0xFF)] == count { continue }
                var total = 0
                for bucket in 0..<256 {
                    let size = histogram[bucket]
                    histogram[bucket] = total
                    total += size
                }
                values.withUnsafeBufferPointer { source in
                    other.withUnsafeMutableBufferPointer { target in
                        for index in 0..<count {
                            let bucket = Int((source[index] >> shift) & 0xFF)
                            target[histogram[bucket]] = source[index]
                            histogram[bucket] += 1
                        }
                    }
                }
                swap(&values, &other)
            }
        }
        var kept = 1
        for index in 1..<count where values[index] != values[kept - 1] {
            values[kept] = values[index]
            kept += 1
        }
        values.removeSubrange(kept..<count)
    }
}

/// Builds a segment from tokenized documents (specification section 7.1: varint-compressed
/// postings per field with per-field document lengths).
enum SegmentBuilder {
    static func build(_ batches: [TokenizedBatch], metadata: IndexMetadata? = nil) -> Data {
        // 1. One vocabulary across the batches.
        var terms: [String]
        var documentFrequency: [UInt32]
        var localToGlobal: [[UInt32]] = []
        if batches.count == 1 {
            terms = batches[0].terms
            documentFrequency = batches[0].documentFrequency
            localToGlobal = [Array(0..<UInt32(terms.count))]
        } else {
            terms = []
            documentFrequency = []
            var ids: [String: UInt32] = [:]
            ids.reserveCapacity(batches.reduce(0) { max($0, $1.terms.count) } * 2)
            for batch in batches {
                var mapping = [UInt32](repeating: 0, count: batch.terms.count)
                for (local, term) in batch.terms.enumerated() {
                    if let existing = ids[term] {
                        mapping[local] = existing
                        documentFrequency[Int(existing)] += batch.documentFrequency[local]
                    } else {
                        let id = UInt32(terms.count)
                        ids[term] = id
                        terms.append(term)
                        documentFrequency.append(batch.documentFrequency[local])
                        mapping[local] = id
                    }
                }
                localToGlobal.append(mapping)
            }
        }

        // 2. Ascending UTF-8 order: what the reader's binary search and prefix ranges rely on.
        let order = sortedByUTF8(terms)
        var rank = [UInt32](repeating: 0, count: terms.count)
        for (position, term) in order.enumerated() { rank[term] = UInt32(position) }

        // 3. Counting sort of the postings by (term, field). Documents are visited in ordinal
        //    order, so each list comes out sorted by document without comparing anything.
        let fields = SearchField.count
        var starts = [Int](repeating: 0, count: terms.count * fields + 1)
        for (index, batch) in batches.enumerated() {
            let mapping = localToGlobal[index]
            for entry in batch.entries {
                let slot = Int(rank[Int(mapping[Int(TokenizedBatch.term(of: entry))])]) * fields + TokenizedBatch.field(of: entry)
                starts[slot + 1] += 1
            }
        }
        for slot in 0..<(terms.count * fields) { starts[slot + 1] += starts[slot] }
        let total = starts[terms.count * fields]
        var cursor = Array(starts.dropLast())
        var documents = [UInt32](repeating: 0, count: total)
        var frequencies = [UInt32](repeating: 0, count: total)
        var documentBase = 0
        for (index, batch) in batches.enumerated() {
            let mapping = localToGlobal[index]
            var entry = 0
            for document in 0..<batch.documents.count {
                let end = Int(batch.documentEnds[document])
                while entry < end {
                    let packed = batch.entries[entry]
                    let slot = Int(rank[Int(mapping[Int(TokenizedBatch.term(of: packed))])]) * fields + TokenizedBatch.field(of: packed)
                    let position = cursor[slot]
                    documents[position] = UInt32(documentBase + document)
                    frequencies[position] = TokenizedBatch.frequency(of: packed)
                    cursor[slot] = position + 1
                    entry += 1
                }
            }
            documentBase += batch.documents.count
        }

        // 4. Encode.
        var reservation = SegmentWriter.Reservation(terms: terms.count, documents: documentBase)
        reservation.postingBytes = total * 2 + terms.count * 2
        reservation.forwardBytes = total * 2
        for term in terms { reservation.termBytes += term.utf8.count }
        for batch in batches {
            for document in batch.documents {
                reservation.idBytes += document.id.rawValue.utf8.count
                reservation.storeBytes += document.encodedSizeEstimate
            }
        }
        var writer = SegmentWriter(reserving: reservation)
        for position in 0..<terms.count {
            for field in 0..<fields {
                var previous = -1
                for index in starts[position * fields + field]..<starts[position * fields + field + 1] {
                    let document = Int(documents[index])
                    writer.appendPosting(field: field, document: document, previous: previous, frequency: frequencies[index])
                    previous = document
                }
            }
            writer.commitTerm(terms[order[position]], documentFrequency: documentFrequency[order[position]])
        }

        // 5. Documents.
        var kinds: [String] = []
        var kindOrdinals: [String: Int] = [:]
        var filters: [FilterRecord] = []
        var filterOrdinals: [FilterRecord: UInt32] = [:]
        var forward: [UInt32] = []
        for (batchIndex, batch) in batches.enumerated() {
            let mapping = localToGlobal[batchIndex]
            var entry = 0
            for (index, document) in batch.documents.enumerated() {
                let kind: Int
                if let existing = kindOrdinals[document.kind] {
                    kind = existing
                } else {
                    kind = kinds.count
                    kindOrdinals[document.kind] = kind
                    kinds.append(document.kind)
                }
                var ordinals: [UInt32] = []
                for record in document.filters {
                    if let existing = filterOrdinals[record] {
                        ordinals.append(existing)
                    } else {
                        let ordinal = UInt32(filters.count)
                        filterOrdinals[record] = ordinal
                        filters.append(record)
                        ordinals.append(ordinal)
                    }
                }
                writer.addDocument(document, kind: kind, filters: ordinals) { field in
                    batch.fieldLengths[index * fields + field]
                }
                // The document's distinct terms, as ordinals of the finished vocabulary.
                forward.removeAll(keepingCapacity: true)
                let end = Int(batch.documentEnds[index])
                while entry < end {
                    forward.append(rank[Int(mapping[Int(TokenizedBatch.term(of: batch.entries[entry]))])])
                    entry += 1
                }
                forward.sort()
                var kept = 0
                for position in forward.indices where kept == 0 || forward[position] != forward[kept - 1] {
                    forward[kept] = forward[position]
                    kept += 1
                }
                forward.removeSubrange(kept..<forward.count)
                writer.addForward(forward)
            }
        }
        return writer.finish(kinds: kinds, filters: filters, metadata: metadata)
    }

    /// Indices of `terms` in ascending UTF-8 byte order. The first eight bytes of each term
    /// are sorted as one integer; only terms that share all eight are compared in full.
    static func sortedByUTF8(_ terms: [String]) -> [Int] {
        var prefixes = [UInt64](repeating: 0, count: terms.count)
        var order = [UInt32](repeating: 0, count: terms.count)
        for (index, term) in terms.enumerated() {
            var key: UInt64 = 0
            var shift: UInt64 = 56
            for byte in term.utf8.prefix(8) {
                key |= UInt64(byte) << shift
                shift = shift &- 8
            }
            prefixes[index] = key
            order[index] = UInt32(index)
        }
        RadixSort.sort(keys: &prefixes, values: &order)
        var result = order.map(Int.init)
        var start = 0
        while start < result.count {
            var end = start + 1
            while end < result.count && prefixes[end] == prefixes[start] { end += 1 }
            if end - start > 1 {
                result[start..<end].sort { terms[$0].utf8.lexicographicallyPrecedes(terms[$1].utf8) }
            }
            start = end
        }
        return result
    }
}
