import Foundation

// Boundaries of specification section 9.2. Core never imports SQLite.swift; the host conforms
// its facade to these and injects it, connection opening and transactions included.

/// A value bound into, or read out of, a statement.
public enum SearchBindingValue: Sendable, Hashable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A SQL fragment the host rendered from its own expression type.
///
/// For SQLite.swift this is an `Expression`'s `template` and `bindings`, or a `Table`'s
/// rendering. Core concatenates fragments and passes bindings through untouched.
public struct SearchSQL: Sendable, Hashable {
    public var template: String
    public var bindings: [SearchBindingValue]

    public init(template: String, bindings: [SearchBindingValue] = []) {
        self.template = template
        self.bindings = bindings
    }
}

extension SearchSQL: ExpressibleByStringLiteral {
    /// A fragment with no bindings, taken verbatim.
    public init(stringLiteral value: String) {
        self.init(template: value)
    }

    /// A quoted identifier: `"name"`, with embedded quotes doubled.
    public static func identifier(_ name: String) -> SearchSQL {
        SearchSQL(template: quote(name))
    }

    /// A quoted, optionally qualified column: `"table"."column"`.
    public static func column(_ name: String, in table: String? = nil) -> SearchSQL {
        if let table {
            return SearchSQL(template: quote(table) + "." + quote(name))
        }
        return SearchSQL(template: quote(name))
    }

    /// Quotes an identifier the SQL way.
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Where a database lives.
public enum SearchDatabaseLocation: Sendable, Hashable {
    case file(URL, readonly: Bool)
    case inMemory
    case uri(String)
}

/// The host's SQLite.swift facade conforms to this.
public protocol SearchDatabase: Sendable {
    func open(_ location: SearchDatabaseLocation) async throws -> any SearchDatabaseConnection
}

/// One open connection. `Sendable`: it serializes concurrent calls itself.
public protocol SearchDatabaseConnection: Sendable {
    /// Deferred read transaction: one consistent snapshot.
    func read<T: Sendable>(_ body: @Sendable (any SearchDatabaseReader) throws -> T) async throws -> T
    /// Commit on return, rollback on throw.
    func write<T: Sendable>(_ body: @Sendable (any SearchDatabaseWriter) throws -> T) async throws -> T
    /// The host wires update and commit hooks; the stream may stay silent.
    func changes(in tables: Set<String>) -> AsyncStream<SearchDatabaseChange>
    func close() async
}

public protocol SearchDatabaseReader {
    func rows(_ statement: SearchSQL) throws -> AnySequence<SearchRow>
    func scalar(_ statement: SearchSQL) throws -> SearchBindingValue?
}

public protocol SearchDatabaseWriter: SearchDatabaseReader {
    /// Rows changed. Used only for the engine's own index tables.
    func run(_ statement: SearchSQL) throws -> Int
}

public struct SearchRow: Sendable, Hashable {
    public let values: [SearchBindingValue?]

    public init(values: [SearchBindingValue?]) {
        self.values = values
    }
}

/// The rows of one table touched by one commit.
public struct SearchDatabaseChange: Sendable, Hashable {
    public let table: String
    /// `nil` = unknown; the whole table is refreshed.
    public let rowIDs: Set<Int64>?

    public init(table: String, rowIDs: Set<Int64>?) {
        self.table = table
        self.rowIDs = rowIDs
    }
}

// MARK: - What to search

/// Names a bundle for the host's resolver without core ever touching `Bundle`.
public struct SearchBundleID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let main = SearchBundleID("main")
}

/// How the value of a string field is to be read.
public enum SearchStringEncoding: Sendable, Hashable {
    /// The value is the text, with an optional BCP 47 tag.
    case literal(language: String?)
    /// The value is a key in a strings catalog, resolved per language.
    case localizedKey(table: String?, bundle: SearchBundleID)
    /// A boolean expression decides per row whether the value is a key.
    case perRow(isKey: SearchSQL, table: String?, bundle: SearchBundleID)
}

public struct SearchStringField: Sendable, Hashable {
    /// `.title`, `.text`, `.keywords`, `.caption`, `.ocrText`.
    public var role: SearchField
    /// From `Expression<String>` or `Expression<String?>`.
    public var expression: SearchSQL
    public var encoding: SearchStringEncoding
    /// Splits the value of a `.keywords` field into keywords; `nil` = one keyword per value.
    public var separator: String?

    public init(role: SearchField, expression: SearchSQL, encoding: SearchStringEncoding = .literal(language: nil), separator: String? = nil) {
        self.role = role
        self.expression = expression
        self.encoding = encoding
        self.separator = separator
    }
}

/// A column whose value becomes a typed filter through `Schema.Filter.init?(key:value:)`.
public struct SearchFilterColumn: Sendable, Hashable {
    public var key: String
    public var expression: SearchSQL
    /// Splits a multi-valued column (`"ios,mac"`) into several records; `nil` = one record.
    public var separator: String?

    public init(key: String, expression: SearchSQL, separator: String? = nil) {
        self.key = key
        self.expression = expression
        self.separator = separator
    }
}

/// How a row's id becomes a ``SearchableID``.
public enum SearchRowIdentity: Sendable, Hashable {
    /// `"<table>#<id>"`, the default.
    case tablePrefixed
    /// The id column's value as is. Uniqueness across sources is then the host's responsibility.
    case verbatim
    /// `"<prefix><id>"`.
    case prefixed(String)
}

/// One table (or sub-select) of searchable rows.
public struct SearchTableSource<Schema: SearchSchema>: Sendable {
    /// A table name or a sub-select.
    public var table: SearchSQL
    /// Unique within the table; `SearchableID` is `"<table>#<id>"` unless the host maps it.
    public var id: SearchSQL
    /// Every row of this source.
    public var kind: Schema.Kind
    /// Literal and localized fields mixed freely.
    public var fields: [SearchStringField]
    /// Key plus expression; rebuilt through `Schema.Filter.init?(key:value:)`.
    public var filters: [SearchFilterColumn]
    /// Optional WHERE.
    public var predicate: SearchSQL?
    /// Optional; gives rows `TemporalSearchable` semantics.
    public var updatedAt: SearchSQL?

    /// The `<table>` of the default identity, and the table whose changes refresh this source.
    public var name: String
    public var identity: SearchRowIdentity
    /// The rowid expression used to re-read changed rows. `nil` (sub-selects, `WITHOUT ROWID`
    /// tables) = every change refreshes the whole table.
    public var rowID: SearchSQL?

    public init(
        table: SearchSQL,
        name: String? = nil,
        id: SearchSQL,
        kind: Schema.Kind,
        fields: [SearchStringField],
        filters: [SearchFilterColumn] = [],
        predicate: SearchSQL? = nil,
        updatedAt: SearchSQL? = nil,
        identity: SearchRowIdentity = .tablePrefixed,
        rowID: SearchSQL? = SearchSQL(template: "rowid")
    ) {
        self.table = table
        self.name = name ?? SearchTableSource.derivedName(from: table)
        self.id = id
        self.kind = kind
        self.fields = fields
        self.filters = filters
        self.predicate = predicate
        self.updatedAt = updatedAt
        self.identity = identity
        self.rowID = rowID
    }

    /// The bare table name when `table` is a single identifier, quoted or not; otherwise the
    /// template itself.
    static func derivedName(from table: SearchSQL) -> String {
        var name = table.template.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, let first = name.first, let last = name.last,
           (first == "\"" && last == "\"") || (first == "`" && last == "`") || (first == "[" && last == "]") {
            name = String(name.dropFirst().dropLast())
            if first == "\"" { name = name.replacingOccurrences(of: "\"\"", with: "\"") }
        }
        return name
    }
}

/// Resolves localization keys. Implemented by the host:
/// `Bundle.localizedString(forKey:value:table:)` on the language bundle, cached.
///
/// This is the only place a bundle is consulted, so core stays bundle-free and tests stay
/// deterministic.
public protocol LocalizedStringResolving: Sendable {
    func string(forKey key: String, table: String?, bundle: SearchBundleID, language: String) -> String?
    func languages(bundle: SearchBundleID, table: String?) -> [String]
}
