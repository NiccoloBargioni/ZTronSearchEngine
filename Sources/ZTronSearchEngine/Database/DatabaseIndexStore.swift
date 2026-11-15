import Foundation

/// Index persistence inside the host database (specification section 9.2, rule 6).
///
/// The engine writes its own `<prefix>_meta`, `<prefix>_docs`, `<prefix>_terms` and
/// `<prefix>_postings` tables through the boundary's write transaction. A save inserts the
/// sections of a new generation, moves the generation pointer and deletes the previous
/// generation, all in one transaction, so generations swap atomically and the index commits
/// with the data at sync time.
///
/// The tables hold the sections of an index segment as chunked blobs, not one row per term or
/// document: a 10k-document index is a few dozen rows, which is what keeps a round trip inside
/// its budget through a boundary that prepares one statement per call.
struct DatabaseIndexStore: Sendable {
    let prefix: String
    static let chunkSize = 256 * 1024

    enum Table: CaseIterable {
        case docs
        case terms
        case postings
    }

    init(prefix: String) {
        self.prefix = prefix
    }

    func name(_ table: Table) -> String {
        switch table {
        case .docs: return SearchSQL.quote(prefix + "_docs")
        case .terms: return SearchSQL.quote(prefix + "_terms")
        case .postings: return SearchSQL.quote(prefix + "_postings")
        }
    }

    var metaName: String { SearchSQL.quote(prefix + "_meta") }

    /// Which table holds a section.
    static func table(for section: SegmentFormat.Section) -> Table {
        switch section {
        case .termOffsets, .termBytes, .termDocumentFrequency, .trigramKeys, .trigramOffsets, .trigramPostings,
             .termSignatures:
            return .terms
        case .postingOffsets, .postings:
            return .postings
        case .metadata, .fieldLengths, .idOffsets, .idBytes, .storeOffsets, .storeBytes, .documentKinds,
             .documentFilterOffsets, .documentFilters, .documentUpdatedAt, .kindTable, .filterTable, .idHash,
             .forwardOffsets, .forwardBytes:
            return .docs
        }
    }

    var schemaStatements: [SearchSQL] {
        var statements = [SearchSQL(template: "CREATE TABLE IF NOT EXISTS \(metaName) (\"key\" TEXT PRIMARY KEY NOT NULL, \"value\" BLOB)")]
        for table in Table.allCases {
            statements.append(SearchSQL(template: """
                CREATE TABLE IF NOT EXISTS \(name(table)) ("generation" INTEGER NOT NULL, "section" INTEGER NOT NULL, \
                "chunk" INTEGER NOT NULL, "data" BLOB NOT NULL, PRIMARY KEY ("generation", "section", "chunk"))
                """))
        }
        return statements
    }

    /// Writes `segment` as the next generation and retires the previous one, atomically.
    func save(_ segment: IndexSegment, on connection: any SearchDatabaseConnection) async throws {
        let store = self
        let header = segment.headerBytes
        let sections = SegmentFormat.Section.allCases.map { segment.sectionBytes($0) }
        try await connection.write { writer in
            for statement in store.schemaStatements {
                _ = try writer.run(statement)
            }
            let current = try writer.scalar(SearchSQL(
                template: "SELECT \"value\" FROM \(store.metaName) WHERE \"key\" = ?", bindings: [.text("generation")]
            ))?.integerValue ?? 0
            let next = current + 1

            for section in SegmentFormat.Section.allCases {
                let bytes = sections[section.rawValue]
                let table = store.name(Self.table(for: section))
                var chunk = 0
                var offset = 0
                repeat {
                    let end = min(bytes.count, offset + Self.chunkSize)
                    _ = try writer.run(SearchSQL(
                        template: "INSERT INTO \(table) (\"generation\", \"section\", \"chunk\", \"data\") VALUES (?, ?, ?, ?)",
                        bindings: [.int(next), .int(Int64(section.rawValue)), .int(Int64(chunk)), .blob(bytes.subdata(in: offset..<end))]
                    ))
                    chunk += 1
                    offset = end
                } while offset < bytes.count
            }

            let meta: [(String, SearchBindingValue)] = [
                ("generation", .int(next)),
                ("formatVersion", .int(Int64(SegmentFormat.version))),
                ("projectionVersion", .int(Int64(SearchDocument.projectionVersion))),
                ("normalizerVersion", .int(Int64(SearchNormalizer.version))),
                ("header", .blob(header)),
            ]
            for (key, value) in meta {
                _ = try writer.run(SearchSQL(
                    template: "INSERT OR REPLACE INTO \(store.metaName) (\"key\", \"value\") VALUES (?, ?)",
                    bindings: [.text(key), value]
                ))
            }
            for table in Table.allCases {
                _ = try writer.run(SearchSQL(
                    template: "DELETE FROM \(store.name(table)) WHERE \"generation\" <> ?", bindings: [.int(next)]
                ))
            }
        }
    }

    /// Reads the current generation back into one segment's bytes.
    ///
    /// `nil` when nothing was ever written or when the stored index was written by another
    /// format, projection or normalizer version: the caller rebuilds.
    func load(on connection: any SearchDatabaseConnection) async throws -> Data? {
        let store = self
        return try await connection.read { reader -> Data? in
            func meta(_ key: String) -> SearchBindingValue? {
                // A missing table means nothing was ever written.
                (try? reader.scalar(SearchSQL(
                    template: "SELECT \"value\" FROM \(store.metaName) WHERE \"key\" = ?", bindings: [.text(key)]
                ))) ?? nil
            }
            guard let generation = meta("generation")?.integerValue,
                  meta("formatVersion")?.integerValue == Int64(SegmentFormat.version),
                  meta("projectionVersion")?.integerValue == Int64(SearchDocument.projectionVersion),
                  meta("normalizerVersion")?.integerValue == Int64(SearchNormalizer.version),
                  case .blob(let header)? = meta("header") else { return nil }

            var sections = [Data](repeating: Data(), count: SegmentFormat.Section.allCases.count)
            for table in Table.allCases {
                let rows = try reader.rows(SearchSQL(
                    template: "SELECT \"section\", \"data\" FROM \(store.name(table)) WHERE \"generation\" = ? ORDER BY \"section\", \"chunk\"",
                    bindings: [.int(generation)]
                ))
                for row in rows {
                    guard row.values.count >= 2, let section = row.values[0]?.integerValue,
                          section >= 0, section < Int64(sections.count), case .blob(let data)? = row.values[1] else {
                        throw SearchError.corruptIndex("unexpected row in the index tables")
                    }
                    sections[Int(section)].append(data)
                }
            }
            return SegmentFormat.assemble(header: header, sections: sections)
        }
    }
}

extension SegmentFormat {
    /// Lays a header and its sections out as one segment: the section table after the header,
    /// then every section on an 8-byte boundary.
    static func assemble(header: Data, sections: [Data]) -> Data {
        let layout = layout(sectionSizes: sections.map(\.count))
        var table = ByteWriter(capacity: sections.count * sectionEntrySize)
        for (index, section) in sections.enumerated() {
            table.append(fixed: UInt64(layout.placements[index]))
            table.append(fixed: UInt64(section.count))
        }
        var data = Data(count: layout.total)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let fixed = header.prefix(headerSize)
            if !fixed.isEmpty {
                fixed.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
            if !table.bytes.isEmpty {
                table.bytes.withUnsafeBytes { (base + headerSize).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
            for (index, section) in sections.enumerated() where !section.isEmpty {
                section.withUnsafeBytes { (base + layout.placements[index]).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
        }
        return data
    }
}

extension IndexSegment {
    /// The fixed header, without the section table.
    var headerBytes: Data {
        data.prefix(SegmentFormat.headerSize)
    }

    /// The bytes of one section.
    func sectionBytes(_ section: SegmentFormat.Section) -> Data {
        let range = sectionRange(section)
        return data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }
}
