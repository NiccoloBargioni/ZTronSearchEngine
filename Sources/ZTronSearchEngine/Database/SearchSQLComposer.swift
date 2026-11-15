import Foundation

/// Where each value of a composed SELECT sits in a row.
struct SearchRowLayout: Sendable, Hashable {
    var id = 0
    var rowID: Int?
    /// Per declared field: the column of its value and, for `.perRow`, of its key flag.
    var fields: [(value: Int, isKey: Int?)] = []
    var filters: [Int] = []
    var updatedAt: Int?
    var columnCount = 0

    static func == (lhs: SearchRowLayout, rhs: SearchRowLayout) -> Bool {
        lhs.id == rhs.id && lhs.rowID == rhs.rowID && lhs.filters == rhs.filters && lhs.updatedAt == rhs.updatedAt
            && lhs.columnCount == rhs.columnCount && lhs.fields.map(\.value) == rhs.fields.map(\.value)
            && lhs.fields.map(\.isKey) == rhs.fields.map(\.isKey)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(rowID)
        hasher.combine(fields.map(\.value))
        hasher.combine(filters)
        hasher.combine(updatedAt)
        hasher.combine(columnCount)
    }
}

/// Composes the one shape of SQL core ever runs against host tables (specification section 9.2,
/// rule 1):
///
///     SELECT <id>, <fields> FROM <table> WHERE <predicate> LIMIT 500 OFFSET n
///
/// Every fragment is one the host rendered; core only concatenates them, in statement order, and
/// passes their bindings through untouched. `LIMIT` and `OFFSET` are integer literals, so the
/// bindings of a statement are exactly the host's. Core never writes DDL or DML against host
/// tables.
enum SearchSQLComposer {
    static func select<Schema: SearchSchema>(
        from source: SearchTableSource<Schema>,
        limit: Int,
        offset: Int,
        rowIDs: [Int64]? = nil
    ) -> (statement: SearchSQL, layout: SearchRowLayout) {
        var layout = SearchRowLayout()
        var columns: [SearchSQL] = [source.id]
        layout.id = 0
        if let rowID = source.rowID {
            layout.rowID = columns.count
            columns.append(rowID)
        }
        for field in source.fields {
            let value = columns.count
            columns.append(field.expression)
            var isKey: Int?
            if case .perRow(let flag, _, _) = field.encoding {
                isKey = columns.count
                columns.append(flag)
            }
            layout.fields.append((value, isKey))
        }
        for filter in source.filters {
            layout.filters.append(columns.count)
            columns.append(filter.expression)
        }
        if let updatedAt = source.updatedAt {
            layout.updatedAt = columns.count
            columns.append(updatedAt)
        }
        layout.columnCount = columns.count

        var template = "SELECT " + columns.map(\.template).joined(separator: ", ") + " FROM " + source.table.template
        var bindings = columns.flatMap(\.bindings) + source.table.bindings

        var conditions: [SearchSQL] = []
        if let predicate = source.predicate { conditions.append(predicate) }
        if let rowIDs, let rowID = source.rowID {
            let placeholders = [String](repeating: "?", count: rowIDs.count).joined(separator: ", ")
            conditions.append(SearchSQL(
                template: rowID.template + " IN (" + placeholders + ")",
                bindings: rowID.bindings + rowIDs.map(SearchBindingValue.int)
            ))
        }
        if conditions.count == 1 {
            template += " WHERE " + conditions[0].template
        } else if conditions.count > 1 {
            template += " WHERE " + conditions.map { "(" + $0.template + ")" }.joined(separator: " AND ")
        }
        bindings += conditions.flatMap(\.bindings)
        template += " LIMIT \(max(0, limit)) OFFSET \(max(0, offset))"
        return (SearchSQL(template: template, bindings: bindings), layout)
    }
}

/// Reads a table source page by page (section 9.2, rule 2).
///
/// Each page is read inside one deferred read transaction, so a page is a consistent snapshot.
/// Cancellation is checked between pages.
enum SearchRowReader {
    /// Changed rowids are re-read at most this many per statement, well inside SQLite's limit
    /// on bound parameters.
    static let rowIDChunk = 400

    static func forEachPage<Schema: SearchSchema>(
        of source: SearchTableSource<Schema>,
        on connection: any SearchDatabaseConnection,
        pageSize: Int,
        rowIDs: [Int64]? = nil,
        _ body: ([SearchRow], SearchRowLayout) async throws -> Void
    ) async throws {
        if let rowIDs {
            guard source.rowID != nil else { return }
            var start = 0
            while start < rowIDs.count {
                let chunk = Array(rowIDs[start..<min(rowIDs.count, start + rowIDChunk)])
                try await pages(of: source, on: connection, pageSize: pageSize, rowIDs: chunk, body)
                start += rowIDChunk
            }
        } else {
            try await pages(of: source, on: connection, pageSize: pageSize, rowIDs: nil, body)
        }
    }

    private static func pages<Schema: SearchSchema>(
        of source: SearchTableSource<Schema>,
        on connection: any SearchDatabaseConnection,
        pageSize: Int,
        rowIDs: [Int64]?,
        _ body: ([SearchRow], SearchRowLayout) async throws -> Void
    ) async throws {
        var offset = 0
        while true {
            try Task.checkCancellation()
            let (statement, layout) = SearchSQLComposer.select(from: source, limit: pageSize, offset: offset, rowIDs: rowIDs)
            let rows: [SearchRow] = try await connection.read { reader in
                Array(try reader.rows(statement))
            }
            if !rows.isEmpty {
                try await body(rows, layout)
            }
            if rows.count < pageSize { return }
            offset += pageSize
        }
    }
}

extension SearchBindingValue {
    /// The value as text: what an id, a string field or a filter value is read as.
    var stringValue: String? {
        switch self {
        case .null: return nil
        case .int(let value): return String(value)
        case .real(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .text(let value): return value
        case .blob(let data): return String(data: data, encoding: .utf8)
        }
    }

    var integerValue: Int64? {
        switch self {
        case .int(let value): return value
        case .real(let value): return Int64(exactly: value.rounded())
        case .text(let value): return Int64(value)
        case .null, .blob: return nil
        }
    }

    /// A boolean the SQLite way: non-zero numbers, and the usual spellings of true.
    var isTruthy: Bool {
        switch self {
        case .int(let value): return value != 0
        case .real(let value): return value != 0
        case .text(let value): return ["1", "true", "yes", "y", "t"].contains(value.lowercased())
        case .null, .blob: return false
        }
    }

    /// A date: seconds since 1970 for numbers; ISO 8601, with or without fractional seconds or a
    /// zone, for text.
    var dateValue: Date? {
        switch self {
        case .int(let value): return Date(timeIntervalSince1970: TimeInterval(value))
        case .real(let value): return Date(timeIntervalSince1970: value)
        case .text(let value): return SearchDateParser.date(from: value)
        case .null, .blob: return nil
        }
    }
}

enum SearchDateParser {
    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Double(trimmed) { return Date(timeIntervalSince1970: seconds) }
        let hasZone = trimmed.hasSuffix("Z") || trimmed.dropFirst(10).contains(where: { $0 == "+" || $0 == "-" })
        let candidate = (hasZone ? trimmed : trimmed + "Z").replacingOccurrences(of: " ", with: "T")
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: options == [.withFullDate] ? String(trimmed.prefix(10)) : candidate) {
                return date
            }
        }
        return nil
    }
}
