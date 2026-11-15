import Foundation

/// One string of a document as the engine tokenizes it.
struct DocumentSurface {
    let field: SearchField
    let text: String
    let language: String?
    /// UTF-8 offset of `text` inside `SearchDocument.surface(for: field)`.
    let surfaceOffset: Int
}

extension SearchDocument {
    /// Visits every surface in scoring order. Multi-valued fields yield one surface per element,
    /// each with its own language, so a phrase never matches across two keywords.
    func forEachSurface(_ body: (DocumentSurface) throws -> Void) rethrows {
        if let title, !title.isEmpty {
            try body(DocumentSurface(field: .title, text: title, language: languages.title, surfaceOffset: 0))
        }
        var offset = 0
        for keyword in keywords {
            if !keyword.isEmpty {
                try body(DocumentSurface(field: .keywords, text: keyword, language: languages.keywords, surfaceOffset: offset))
            }
            offset += keyword.utf8.count + SearchDocument.surfaceSeparator.utf8.count
        }
        if let caption, !caption.isEmpty {
            try body(DocumentSurface(field: .caption, text: caption, language: languages.caption, surfaceOffset: 0))
        }
        if !text.isEmpty {
            try body(DocumentSurface(field: .text, text: text, language: languages.text, surfaceOffset: 0))
        }
        offset = 0
        for (index, alt) in localizedAlt.enumerated() {
            if !alt.isEmpty {
                let language = index < languages.localizedAlt.count ? languages.localizedAlt[index] : nil
                try body(DocumentSurface(field: .localizedAlt, text: alt, language: language, surfaceOffset: offset))
            }
            offset += alt.utf8.count + SearchDocument.surfaceSeparator.utf8.count
        }
        if let ocrText, !ocrText.isEmpty {
            try body(DocumentSurface(field: .ocrText, text: ocrText, language: languages.ocrText, surfaceOffset: 0))
        }
    }
}

/// Documents reduced to what an index needs: interned terms, term frequencies and field lengths.
///
/// A batch is produced by one tokenizer session, so batches can be built in parallel and merged
/// by the segment builder.
struct TokenizedBatch: Sendable {
    /// Batch-local vocabulary; `entries` refer to it by position.
    var terms: [String] = []
    /// Distinct documents of this batch that contain each local term.
    var documentFrequency: [UInt32] = []
    /// Packed postings in document order: term (32 bits) | field (3 bits) | frequency (29 bits).
    var entries: [UInt64] = []
    /// Index one past the last entry of each document.
    var documentEnds: [UInt32] = []
    /// `SearchField.count` primary-word counts per document.
    var fieldLengths: [UInt32] = []
    var documents: [SearchDocument] = []
    /// Where every token of every document sits, when the tokenizer was asked to keep it:
    /// `spanEnds[d]` is one past the last span of document `d`.
    var spans: [TokenSpan] = []
    var spanEnds: [UInt32] = []

    @inline(__always) static func pack(term: UInt32, field: Int, frequency: UInt32) -> UInt64 {
        (UInt64(term) << 32) | (UInt64(field) << 29) | UInt64(min(frequency, 0x1FFF_FFFF))
    }

    @inline(__always) static func term(of entry: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: entry >> 32) }
    @inline(__always) static func field(of entry: UInt64) -> Int { Int((entry >> 29) & 0x7) }
    @inline(__always) static func frequency(of entry: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: entry & 0x1FFF_FFFF) }
}

/// Where one token of a document sits. A scan context keeps these, so highlighting a hit reads
/// positions instead of tokenizing the hit again.
struct TokenSpan: Sendable {
    /// Batch-local term.
    let term: UInt32
    /// The surface the token belongs to, counted in `SearchDocument.forEachSurface` order.
    let piece: UInt16
    /// UTF-8 offset inside that surface's text, and length.
    let start: UInt32
    let length: UInt32
}

/// Turns documents into a ``TokenizedBatch``.
struct DocumentTokenizer {
    let session: TokenizerSession
    /// Keep the position of every token (``TokenizedBatch/spans``).
    let recordsSpans: Bool
    private var termIDs: [String: UInt32] = [:]
    private var batch = TokenizedBatch()
    private var tokens: [SearchToken] = []
    private var keys: [UInt64] = []

    init(session: TokenizerSession, recordsSpans: Bool = false) {
        self.session = session
        self.recordsSpans = recordsSpans
    }

    mutating func add(_ document: SearchDocument) {
        keys.removeAll(keepingCapacity: true)
        var lengths = [UInt32](repeating: 0, count: SearchField.count)
        var piece: UInt16 = 0
        document.forEachSurface { surface in
            defer { piece &+= 1 }
            tokens.removeAll(keepingCapacity: true)
            session.tokenize(surface.text, language: surface.language, into: &tokens)
            let field = surface.field.ordinal
            let bytes = surface.text.utf8
            for token in tokens {
                if token.kind == .word { lengths[field] += 1 }
                let id: UInt32
                if let existing = termIDs[token.term] {
                    id = existing
                } else {
                    id = UInt32(batch.terms.count)
                    termIDs[token.term] = id
                    batch.terms.append(token.term)
                    batch.documentFrequency.append(0)
                }
                keys.append((UInt64(id) << 3) | UInt64(field))
                if recordsSpans {
                    batch.spans.append(TokenSpan(
                        term: id, piece: piece,
                        start: UInt32(bytes.distance(from: bytes.startIndex, to: token.range.lowerBound)),
                        length: UInt32(bytes.distance(from: token.range.lowerBound, to: token.range.upperBound))
                    ))
                }
            }
        }
        if recordsSpans { batch.spanEnds.append(UInt32(batch.spans.count)) }
        // Sorting groups equal (term, field) pairs, and equal terms, next to each other.
        keys.sort()
        var index = 0
        var previousTerm: UInt32?
        while index < keys.count {
            let key = keys[index]
            var run = index + 1
            while run < keys.count && keys[run] == key { run += 1 }
            let term = UInt32(truncatingIfNeeded: key >> 3)
            batch.entries.append(TokenizedBatch.pack(term: term, field: Int(key & 0x7), frequency: UInt32(run - index)))
            if previousTerm != term {
                batch.documentFrequency[Int(term)] += 1
                previousTerm = term
            }
            index = run
        }
        batch.documentEnds.append(UInt32(batch.entries.count))
        batch.fieldLengths.append(contentsOf: lengths)
        batch.documents.append(document)
    }

    consuming func finish() -> TokenizedBatch {
        batch
    }

    /// Tokenizes a list of documents with one session.
    static func tokenize(_ documents: [SearchDocument], session: TokenizerSession = TokenizerSession(), recordingSpans: Bool = false) -> TokenizedBatch {
        var tokenizer = DocumentTokenizer(session: session, recordsSpans: recordingSpans)
        for document in documents {
            tokenizer.add(document)
        }
        return tokenizer.finish()
    }

    /// Tokenizes in parallel. Each child task owns its tokenizer session; the cooperative pool
    /// decides how many run at once.
    static func tokenizeConcurrently(_ documents: [SearchDocument], chunkSize: Int = 4_096) async -> [TokenizedBatch] {
        guard documents.count > chunkSize else {
            return documents.isEmpty ? [] : [tokenize(documents)]
        }
        let chunkCount = (documents.count + chunkSize - 1) / chunkSize
        return await withTaskGroup(of: (Int, TokenizedBatch).self, returning: [TokenizedBatch].self) { group in
            for chunk in 0..<chunkCount {
                let slice = Array(documents[(chunk * chunkSize)..<min(documents.count, (chunk + 1) * chunkSize)])
                group.addTask {
                    (chunk, tokenize(slice))
                }
            }
            var batches = [TokenizedBatch?](repeating: nil, count: chunkCount)
            for await (chunk, batch) in group {
                batches[chunk] = batch
            }
            return batches.compactMap { $0 }
        }
    }
}

extension SearchDocument {
    /// An upper bound, give or take a few bytes, on the size of the stored record.
    var encodedSizeEstimate: Int {
        var size = 48 + id.rawValue.utf8.count + kind.utf8.count + text.utf8.count
        size += (title?.utf8.count ?? 0) + (caption?.utf8.count ?? 0) + (ocrText?.utf8.count ?? 0)
        for keyword in keywords { size += keyword.utf8.count + 2 }
        for alt in localizedAlt { size += alt.utf8.count + 12 }
        for filter in filters { size += filter.key.utf8.count + filter.value.utf8.count + 4 }
        return size
    }
}

/// Binary encoding of a ``SearchDocument`` inside a segment's document store.
enum DocumentCodec {
    static func encode(_ document: SearchDocument, into writer: inout ByteWriter) {
        writer.append(string: document.id.rawValue)
        writer.append(string: document.kind)
        writer.append(optionalString: document.language)
        writer.append(optionalString: document.title)
        writer.append(string: document.text)
        writer.append(varint: UInt64(document.keywords.count))
        for keyword in document.keywords { writer.append(string: keyword) }
        writer.append(optionalString: document.caption)
        writer.append(optionalString: document.ocrText)
        writer.append(varint: UInt64(document.localizedAlt.count))
        for alt in document.localizedAlt { writer.append(string: alt) }
        writer.append(varint: UInt64(document.filters.count))
        for filter in document.filters {
            writer.append(string: filter.key)
            writer.append(string: filter.value)
        }
        if let updatedAt = document.updatedAt {
            writer.append(1)
            writer.append(double: updatedAt.timeIntervalSinceReferenceDate)
        } else {
            writer.append(0)
        }
        writer.append(optionalString: document.languages.title)
        writer.append(optionalString: document.languages.text)
        writer.append(optionalString: document.languages.keywords)
        writer.append(optionalString: document.languages.caption)
        writer.append(optionalString: document.languages.ocrText)
        for language in document.languages.localizedAlt { writer.append(optionalString: language) }
    }

    static func decode(_ buffer: UnsafeRawBufferPointer) throws -> SearchDocument {
        var reader = ByteReader(buffer)
        let id = SearchableID(try reader.string())
        let kind = try reader.string()
        let language = try reader.optionalString()
        let title = try reader.optionalString()
        let text = try reader.string()
        var keywords: [String] = []
        for _ in 0..<Int(try reader.varint()) { keywords.append(try reader.string()) }
        let caption = try reader.optionalString()
        let ocrText = try reader.optionalString()
        var alt: [String] = []
        for _ in 0..<Int(try reader.varint()) { alt.append(try reader.string()) }
        var filters: [FilterRecord] = []
        for _ in 0..<Int(try reader.varint()) {
            let key = try reader.string()
            filters.append(FilterRecord(key: key, value: try reader.string()))
        }
        let updatedAt: Date? = try reader.byte() == 0 ? nil : Date(timeIntervalSinceReferenceDate: try reader.double())
        var languages = SearchFieldLanguages()
        languages.title = try reader.optionalString()
        languages.text = try reader.optionalString()
        languages.keywords = try reader.optionalString()
        languages.caption = try reader.optionalString()
        languages.ocrText = try reader.optionalString()
        for _ in alt.indices { languages.localizedAlt.append(try reader.optionalString()) }
        return SearchDocument(
            id: id, kind: kind, language: language, title: title, text: text, keywords: keywords,
            caption: caption, ocrText: ocrText, localizedAlt: alt, filters: filters, updatedAt: updatedAt,
            languages: languages
        )
    }
}
