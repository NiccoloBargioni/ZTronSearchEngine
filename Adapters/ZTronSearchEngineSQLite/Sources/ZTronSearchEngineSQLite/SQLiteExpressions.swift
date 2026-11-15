import Foundation
import SQLite
import ZTronSearchEngine

// Rendering of the host's own query layer to the fragments core composes
// (specification section 9.2, rules 1 and 8). Core concatenates the fragments into its one
// SELECT and passes their bindings through untouched; nothing here rewrites what SQLite.swift
// rendered.
//
// `SQLite.Expression` is spelled with its module throughout: Foundation has an `Expression` of
// its own on recent systems.

// MARK: - Expressions

extension SearchSQL {
    /// The fragment a typed SQLite.swift expression renders to: its template and its bindings,
    /// untouched.
    ///
    ///     let title = SQLite.Expression<String>("title")
    ///     SearchSQL(title)             // "title"
    ///     SearchSQL(tools[title])      // "tools"."title"
    ///     SearchSQL(price > 10)        // ("price" > ?), bound to 10
    public init<E: ExpressionType>(_ expression: E) {
        self.init(template: expression.template, bindings: expression.bindings.map { SearchBindingValue($0) })
    }

    /// The fragment any other `Expressible` renders to: the template and bindings of its
    /// `expression`, untouched.
    ///
    /// A plain value (`"en"`, `42`, a `Date`) renders as one bound parameter. A query renders
    /// as its whole SELECT statement; to name a table after `FROM` use ``init(table:)``.
    public init(expressible: any Expressible) {
        self.init(expressible.expression)
    }

    /// A table, a view or a virtual table, as it stands after `FROM`.
    ///
    /// A table that carries no clause renders as its quoted name, qualified by its database and
    /// followed by its alias when it has them:
    ///
    ///     SearchSQL(table: Table("tools"))                     // "tools"
    ///     SearchSQL(table: Table("tools", database: "catalog")) // "catalog"."tools"
    ///
    /// A table that carries clauses (a filter, a join, its own column list) renders as a
    /// sub-select named after the table, with the bindings of its clauses:
    ///
    ///     SearchSQL(table: Table("tools").filter(isPublished))
    ///     // (SELECT * FROM "tools" WHERE "is_published") AS "tools"
    public init<T: SchemaType>(table: T) {
        self = SQLiteTableRendering(table).from
    }
}

// MARK: - Tables

/// How a SQLite.swift table reads as the `FROM` of the engine's SELECT.
struct SQLiteTableRendering {
    /// What follows `FROM`.
    let from: SearchSQL
    /// The table's own name, unquoted: what SQLite reports in the update hook.
    let name: String
    /// `true` when the table carries clauses and was rendered as a sub-select.
    let isSubselect: Bool

    init<T: SchemaType>(_ table: T) {
        // SQLite.swift keeps a table's clauses to itself. What it does publish is the SELECT
        // the table stands for, and the name it qualifies columns with: `table[*]` is that
        // name, or the alias, followed by `.*`.
        let select = table.expression
        let reference = Self.quotedPath(Substring(table[*].template.dropLast(2)))?.names ?? []

        let selectAll = "SELECT * FROM "
        if select.template.hasPrefix(selectAll), let path = Self.quotedPath(select.template.dropFirst(selectAll.count)) {
            var rest = path.rest
            if rest.hasPrefix(" AS "), let alias = Self.quotedIdentifier(rest.dropFirst(4)) {
                rest = alias.rest
            }
            name = path.names.last ?? ""
            if rest.isEmpty, select.bindings.isEmpty {
                // Nothing but the table: its name is all the SELECT needs.
                from = SearchSQL(template: String(select.template.dropFirst(selectAll.count)))
                isSubselect = false
                return
            }
        } else {
            name = reference.last ?? ""
        }
        from = SearchSQL(
            template: "(" + select.template + ") AS " + SearchSQL.quote(reference.last ?? name),
            bindings: select.bindings.map { SearchBindingValue($0) }
        )
        isSubselect = true
    }

    /// Reads `"a"` or `"a"."b"` off the front of `text`.
    private static func quotedPath(_ text: Substring) -> (names: [String], rest: Substring)? {
        guard let first = quotedIdentifier(text) else { return nil }
        var names = [first.name]
        var rest = first.rest
        while rest.first == ".", let next = quotedIdentifier(rest.dropFirst()) {
            names.append(next.name)
            rest = next.rest
        }
        return (names, rest)
    }

    /// Reads one double-quoted identifier off the front of `text`; a doubled quote inside it is
    /// a quote.
    private static func quotedIdentifier(_ text: Substring) -> (name: String, rest: Substring)? {
        guard text.first == "\"" else { return nil }
        var name = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\"" {
                guard next < text.endIndex, text[next] == "\"" else { return (name, text[next...]) }
                name.append("\"")
                index = text.index(after: next)
            } else {
                name.append(text[index])
                index = next
            }
        }
        return nil
    }
}

// MARK: - Declaring a source from typed columns

/// Where the engine finds the rowid of a source's rows.
///
/// The rowid is what lets a change be applied row by row: SQLite reports the rowids a commit
/// touched, and the engine reads exactly those rows again. A source without one is read again
/// as a whole whenever its table changes.
public enum SQLiteRowID: Sendable, Hashable {
    /// `rowid` for a table rendered by its name; none for a view or a sub-select, which have
    /// no rowid.
    case automatic
    /// None. For a table declared `WITHOUT ROWID`.
    case unavailable
    /// An expression of the host's, for a sub-select that selects its table's rowid under a
    /// name.
    case expression(SearchSQL)
}

extension SearchStringField {
    /// A field read from a typed string column or expression.
    public init(
        role: SearchField,
        expression: SQLite.Expression<String>,
        encoding: SearchStringEncoding = .literal(language: nil),
        separator: String? = nil
    ) {
        self.init(role: role, expression: SearchSQL(expression), encoding: encoding, separator: separator)
    }

    /// A field read from a typed, nullable string column or expression. A row whose value is
    /// `NULL` indexes nothing for the field.
    public init(
        role: SearchField,
        expression: SQLite.Expression<String?>,
        encoding: SearchStringEncoding = .literal(language: nil),
        separator: String? = nil
    ) {
        self.init(role: role, expression: SearchSQL(expression), encoding: encoding, separator: separator)
    }
}

extension SearchStringEncoding {
    /// A value that is a localization key in some rows and the text itself in the others; a
    /// typed boolean column or expression tells which.
    public static func perRow(isKey: SQLite.Expression<Bool>, table: String?, bundle: SearchBundleID) -> SearchStringEncoding {
        .perRow(isKey: SearchSQL(isKey), table: table, bundle: bundle)
    }

    /// The same, for a nullable flag; `NULL` reads as "not a key".
    public static func perRow(isKey: SQLite.Expression<Bool?>, table: String?, bundle: SearchBundleID) -> SearchStringEncoding {
        .perRow(isKey: SearchSQL(isKey), table: table, bundle: bundle)
    }
}

extension SearchFilterColumn {
    /// A filter read from a typed column or expression of any type. The value reaches
    /// `Schema.Filter.init?(key:value:)` as text.
    public init<E: ExpressionType>(key: String, expression: E, separator: String? = nil) {
        self.init(key: key, expression: SearchSQL(expression), separator: separator)
    }
}

extension SearchTableSource {
    /// A source declared from the host's own SQLite.swift table and typed columns.
    ///
    ///     let tools = Table("tools")
    ///     let id = SQLite.Expression<Int64>("id")
    ///     let title = SQLite.Expression<String>("title")
    ///
    ///     SearchTableSource<Schema>(
    ///         table: tools, id: id, kind: .tool,
    ///         fields: [.init(role: .title, expression: title, encoding: .literal(language: "en"))],
    ///         predicate: isPublished
    ///     )
    ///
    /// - Parameters:
    ///   - table: The table, view or virtual table. Pass it without clauses and give the filter
    ///     as `predicate`: a table that carries clauses of its own becomes a sub-select, which
    ///     has no rowid, so every change to it reads the whole source again.
    ///   - name: The name of the table whose changes refresh the source, and the `<table>` of
    ///     the default identity. `nil` takes it from `table`.
    ///   - id: The column or expression that identifies a row; unique within the source.
    ///   - kind: The kind of every row of the source.
    ///   - fields: The string fields to index.
    ///   - filters: The columns that become typed filters.
    ///   - predicate: An optional condition a row must meet.
    ///   - updatedAt: An optional date, as seconds since 1970 or ISO 8601 text, which is how
    ///     SQLite.swift stores a `Date`.
    ///   - identity: How a row's id becomes a `SearchableID`.
    ///   - rowID: Where the rowid of a row is found.
    public init<T: SchemaType, ID: ExpressionType>(
        table: T,
        name: String? = nil,
        id: ID,
        kind: Schema.Kind,
        fields: [SearchStringField],
        filters: [SearchFilterColumn] = [],
        predicate: SQLite.Expression<Bool>? = nil,
        updatedAt: (any ExpressionType)? = nil,
        identity: SearchRowIdentity = .tablePrefixed,
        rowID: SQLiteRowID = .automatic
    ) {
        self.init(
            rendering: SQLiteTableRendering(table), isView: table is View, name: name, id: SearchSQL(id), kind: kind,
            fields: fields, filters: filters, predicate: predicate.map { SearchSQL($0) }, updatedAt: updatedAt,
            identity: identity, rowID: rowID
        )
    }

    /// The same, with a condition that may be `NULL`; a row for which it is `NULL` is left out.
    public init<T: SchemaType, ID: ExpressionType>(
        table: T,
        name: String? = nil,
        id: ID,
        kind: Schema.Kind,
        fields: [SearchStringField],
        filters: [SearchFilterColumn] = [],
        predicate: SQLite.Expression<Bool?>,
        updatedAt: (any ExpressionType)? = nil,
        identity: SearchRowIdentity = .tablePrefixed,
        rowID: SQLiteRowID = .automatic
    ) {
        self.init(
            rendering: SQLiteTableRendering(table), isView: table is View, name: name, id: SearchSQL(id), kind: kind,
            fields: fields, filters: filters, predicate: SearchSQL(predicate), updatedAt: updatedAt,
            identity: identity, rowID: rowID
        )
    }

    private init(
        rendering: SQLiteTableRendering,
        isView: Bool,
        name: String?,
        id: SearchSQL,
        kind: Schema.Kind,
        fields: [SearchStringField],
        filters: [SearchFilterColumn],
        predicate: SearchSQL?,
        updatedAt: (any ExpressionType)?,
        identity: SearchRowIdentity,
        rowID: SQLiteRowID
    ) {
        let rowIDColumn: SearchSQL?
        switch rowID {
        case .automatic: rowIDColumn = rendering.isSubselect || isView ? nil : SearchSQL(template: "rowid")
        case .unavailable: rowIDColumn = nil
        case .expression(let expression): rowIDColumn = expression
        }
        self.init(
            table: rendering.from,
            name: name ?? rendering.name,
            id: id,
            kind: kind,
            fields: fields,
            filters: filters,
            predicate: predicate,
            updatedAt: updatedAt.map { SearchSQL(template: $0.template, bindings: $0.bindings.map { SearchBindingValue($0) }) },
            identity: identity,
            rowID: rowIDColumn
        )
    }
}
