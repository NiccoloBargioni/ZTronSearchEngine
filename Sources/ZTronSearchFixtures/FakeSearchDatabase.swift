import Foundation
import ZTronSearchEngine

/// A dictionary-backed fake of the database boundary, with transactions and a change stream,
/// for core tests (specification section 18.1, package 7). No SQLite is involved.
///
/// It interprets exactly the SQL core composes: the one SELECT shape over host tables
/// (`SELECT <columns> FROM <table> [WHERE ...] LIMIT n OFFSET m`) and the DDL and DML of the
/// engine's own index tables. Anything else throws, which is itself a test: core must never
/// compose another shape against host tables.
public actor FakeSearchDatabaseConnection: SearchDatabaseConnection {
    public struct Statement: Sendable, Hashable {
        public let sql: SearchSQL
        /// Ordinal of the transaction the statement ran in.
        public let transaction: Int
        public let isWrite: Bool
    }

    private var tables: [String: FakeTable] = [:]
    private var subscribers: [UUID: (tables: Set<String>, continuation: AsyncStream<SearchDatabaseChange>.Continuation)] = [:]
    private var transactionCount = 0
    private var log: [Statement] = []
    private var isClosed = false
    private var isSilent = false
    private var readDelay: UInt64 = 0
    private var scriptedReadDelays: [UInt64] = []
    private var failure: String?
    private var writeStatementBudget: Int?

    public init() {}

    // MARK: Boundary

    public func read<T: Sendable>(_ body: @Sendable (any SearchDatabaseReader) throws -> T) async throws -> T {
        if let failure { throw SearchError.database(failure) }
        guard !isClosed else { throw SearchError.database("connection is closed") }
        transactionCount += 1
        // A read sees one consistent snapshot: the tables as they are when it begins, however
        // long the read then takes.
        let session = FakeSession(tables: tables, transaction: transactionCount, isWrite: false)
        let delay = scriptedReadDelays.isEmpty ? readDelay : scriptedReadDelays.removeFirst()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        defer { log.append(contentsOf: session.statements) }
        return try body(session)
    }

    public func write<T: Sendable>(_ body: @Sendable (any SearchDatabaseWriter) throws -> T) async throws -> T {
        if let failure { throw SearchError.database(failure) }
        guard !isClosed else { throw SearchError.database("connection is closed") }
        transactionCount += 1
        let session = FakeSession(tables: tables, transaction: transactionCount, isWrite: true)
        session.statementBudget = writeStatementBudget
        defer { log.append(contentsOf: session.statements) }
        // Commit on return, rollback on throw: the working copy is adopted only on success.
        let result = try body(session)
        tables = session.tables
        publish(session.changes)
        return result
    }

    public nonisolated func changes(in tables: Set<String>) -> AsyncStream<SearchDatabaseChange> {
        let (stream, continuation) = AsyncStream<SearchDatabaseChange>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        Task { await self.subscribe(id, tables: tables, continuation: continuation) }
        return stream
    }

    public func close() async {
        isClosed = true
        for subscriber in subscribers.values { subscriber.continuation.finish() }
        subscribers = [:]
    }

    // MARK: Scripting

    /// Creates a host table. `columns` are the column names; `rowid` is implicit.
    public func createTable(_ name: String, columns: [String]) {
        tables[name] = FakeTable(columns: columns, primaryKey: [])
    }

    /// Inserts a row in its own transaction and returns its rowid.
    @discardableResult
    public func insert(into table: String, _ values: [String: SearchBindingValue]) -> Int64 {
        transactionCount += 1
        guard var target = tables[table] else { return -1 }
        let rowID = target.insert(values)
        tables[table] = target
        publish([table: [rowID]])
        return rowID
    }

    /// Inserts many rows in ONE transaction: one commit, one change per table.
    @discardableResult
    public func insert(into table: String, rows: [[String: SearchBindingValue]]) -> [Int64] {
        transactionCount += 1
        guard var target = tables[table] else { return [] }
        let rowIDs = rows.map { target.insert($0) }
        tables[table] = target
        publish([table: Set(rowIDs)])
        return rowIDs
    }

    public func update(_ table: String, rowID: Int64, _ values: [String: SearchBindingValue]) {
        transactionCount += 1
        guard var target = tables[table], var row = target.rows[rowID] else { return }
        for (column, value) in values { row[column] = value }
        target.rows[rowID] = row
        tables[table] = target
        publish([table: [rowID]])
    }

    public func delete(from table: String, rowIDs: Set<Int64>) {
        transactionCount += 1
        guard var target = tables[table] else { return }
        for rowID in rowIDs { target.rows[rowID] = nil }
        tables[table] = target
        publish([table: rowIDs])
    }

    /// Several mutations in one transaction: one commit, one change per touched table.
    public func transaction(_ mutations: [(table: String, rowID: Int64?, values: [String: SearchBindingValue]?)]) {
        transactionCount += 1
        var touched: [String: Set<Int64>] = [:]
        for mutation in mutations {
            guard var target = tables[mutation.table] else { continue }
            if let rowID = mutation.rowID {
                if let values = mutation.values {
                    var row = target.rows[rowID] ?? [:]
                    for (column, value) in values { row[column] = value }
                    target.rows[rowID] = row
                } else {
                    target.rows[rowID] = nil
                }
                touched[mutation.table, default: []].insert(rowID)
            } else if let values = mutation.values {
                touched[mutation.table, default: []].insert(target.insert(values))
            }
            tables[mutation.table] = target
        }
        publish(touched)
    }

    /// Emits a change exactly as given: use `rowIDs: nil` for "unknown, refresh the table".
    public func emit(_ change: SearchDatabaseChange) {
        for subscriber in subscribers.values where subscriber.tables.contains(change.table) {
            subscriber.continuation.yield(change)
        }
    }

    /// Mutations stop producing changes: the stream "may stay silent".
    public func setSilent(_ silent: Bool) { isSilent = silent }

    /// Every read takes this long, so tests can interleave with paging.
    public func setReadDelay(nanoseconds: UInt64) { readDelay = nanoseconds }

    /// The next reads take these long, one each, before the default delay applies again.
    public func scriptReadDelays(nanoseconds: [UInt64]) { scriptedReadDelays = nanoseconds }

    /// A write transaction throws once it has run this many statements, and is rolled back.
    /// `nil` lifts the limit.
    public func failWrites(afterStatements budget: Int?) { writeStatementBudget = budget }

    /// Every transaction throws until the failure is cleared.
    public func setFailure(_ message: String?) { failure = message }

    /// Rows of a table, in rowid order. For assertions on the engine's own tables.
    public func rows(of table: String) -> [[String: SearchBindingValue]] {
        guard let target = tables[table] else { return [] }
        return target.rows.keys.sorted().compactMap { target.rows[$0] }
    }

    public func tableNames() -> [String] { tables.keys.sorted() }

    /// Every statement run so far, with the transaction it ran in.
    public func statements() -> [Statement] { log }

    public func transactions() -> Int { transactionCount }

    public func subscriberCount() -> Int { subscribers.count }

    public func resetLog() { log = [] }

    // MARK: Internals

    private func subscribe(_ id: UUID, tables: Set<String>, continuation: AsyncStream<SearchDatabaseChange>.Continuation) {
        guard !isClosed else {
            continuation.finish()
            return
        }
        subscribers[id] = (tables, continuation)
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    /// One change per touched table per commit.
    private func publish(_ touched: [String: Set<Int64>]) {
        guard !isSilent else { return }
        for (table, rowIDs) in touched.sorted(by: { $0.key < $1.key }) where !rowIDs.isEmpty {
            emit(SearchDatabaseChange(table: table, rowIDs: rowIDs))
        }
    }
}

/// The fake as a `SearchDatabase`: every location opens the same in-memory connection.
public struct FakeSearchDatabase: SearchDatabase {
    public let connection: FakeSearchDatabaseConnection

    public init(connection: FakeSearchDatabaseConnection = FakeSearchDatabaseConnection()) {
        self.connection = connection
    }

    public func open(_ location: SearchDatabaseLocation) async throws -> any SearchDatabaseConnection {
        connection
    }
}

struct FakeTable: Sendable {
    var columns: [String]
    var primaryKey: [String]
    var rows: [Int64: [String: SearchBindingValue]] = [:]
    var nextRowID: Int64 = 1

    mutating func insert(_ values: [String: SearchBindingValue]) -> Int64 {
        let rowID = nextRowID
        nextRowID += 1
        rows[rowID] = values
        return rowID
    }
}

/// One transaction over a working copy of the tables. Confined to the connection actor.
final class FakeSession: SearchDatabaseWriter {
    var tables: [String: FakeTable]
    var statements: [FakeSearchDatabaseConnection.Statement] = []
    var changes: [String: Set<Int64>] = [:]
    let transaction: Int
    let isWrite: Bool
    var statementBudget: Int?

    init(tables: [String: FakeTable], transaction: Int, isWrite: Bool) {
        self.tables = tables
        self.transaction = transaction
        self.isWrite = isWrite
    }

    func rows(_ statement: SearchSQL) throws -> AnySequence<SearchRow> {
        statements.append(.init(sql: statement, transaction: transaction, isWrite: isWrite))
        return AnySequence(try FakeSQL.select(statement, tables: tables))
    }

    func scalar(_ statement: SearchSQL) throws -> SearchBindingValue? {
        statements.append(.init(sql: statement, transaction: transaction, isWrite: isWrite))
        return try FakeSQL.select(statement, tables: tables).first?.values.first ?? nil
    }

    func run(_ statement: SearchSQL) throws -> Int {
        guard isWrite else { throw SearchError.database("write statement inside a read transaction") }
        if let budget = statementBudget {
            guard budget > 0 else { throw SearchError.database("injected write failure") }
            statementBudget = budget - 1
        }
        statements.append(.init(sql: statement, transaction: transaction, isWrite: true))
        return try FakeSQL.run(statement, tables: &tables, changes: &changes)
    }
}

/// The subset of SQL the fake understands.
enum FakeSQL {
    // MARK: Lexing

    enum Token: Equatable {
        case word(String)       // keyword or bare identifier, uppercased for keywords by the parser
        case identifier(String) // "quoted"
        case placeholder        // ?
        case number(Int)
        case string(String)     // 'literal'
        case symbol(Character)
    }

    static func tokens(_ sql: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = sql.startIndex
        while index < sql.endIndex {
            let character = sql[index]
            if character.isWhitespace {
                index = sql.index(after: index)
            } else if character == "\"" {
                var name = ""
                var cursor = sql.index(after: index)
                while cursor < sql.endIndex {
                    if sql[cursor] == "\"" {
                        let next = sql.index(after: cursor)
                        if next < sql.endIndex, sql[next] == "\"" {
                            name.append("\"")
                            cursor = sql.index(after: next)
                            continue
                        }
                        break
                    }
                    name.append(sql[cursor])
                    cursor = sql.index(after: cursor)
                }
                guard cursor < sql.endIndex else { throw SearchError.database("unterminated identifier in: \(sql)") }
                tokens.append(.identifier(name))
                index = sql.index(after: cursor)
            } else if character == "'" {
                var value = ""
                var cursor = sql.index(after: index)
                while cursor < sql.endIndex, sql[cursor] != "'" {
                    value.append(sql[cursor])
                    cursor = sql.index(after: cursor)
                }
                guard cursor < sql.endIndex else { throw SearchError.database("unterminated string in: \(sql)") }
                tokens.append(.string(value))
                index = sql.index(after: cursor)
            } else if character == "?" {
                tokens.append(.placeholder)
                index = sql.index(after: index)
            } else if character.isNumber {
                var cursor = index
                while cursor < sql.endIndex, sql[cursor].isNumber { cursor = sql.index(after: cursor) }
                tokens.append(.number(Int(sql[index..<cursor]) ?? 0))
                index = cursor
            } else if character.isLetter || character == "_" {
                var cursor = index
                while cursor < sql.endIndex, sql[cursor].isLetter || sql[cursor].isNumber || sql[cursor] == "_" {
                    cursor = sql.index(after: cursor)
                }
                tokens.append(.word(String(sql[index..<cursor])))
                index = cursor
            } else if character == "<", sql.index(after: index) < sql.endIndex, sql[sql.index(after: index)] == ">" {
                tokens.append(.word("<>"))
                index = sql.index(index, offsetBy: 2)
            } else {
                tokens.append(.symbol(character))
                index = sql.index(after: index)
            }
        }
        return tokens
    }

    struct Cursor {
        let tokens: [Token]
        let sql: String
        var position = 0
        var bindings: ArraySlice<SearchBindingValue>

        var peek: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func next() throws -> Token {
            guard position < tokens.count else { throw SearchError.database("unexpected end of statement: \(sql)") }
            defer { position += 1 }
            return tokens[position]
        }

        func isKeyword(_ keyword: String) -> Bool {
            if case .word(let word)? = peek { return word.uppercased() == keyword }
            return false
        }

        mutating func accept(_ keyword: String) -> Bool {
            guard isKeyword(keyword) else { return false }
            position += 1
            return true
        }

        mutating func expect(_ keyword: String) throws {
            guard accept(keyword) else { throw SearchError.database("expected \(keyword) in: \(sql)") }
        }

        mutating func acceptSymbol(_ symbol: Character) -> Bool {
            guard case .symbol(symbol)? = peek else { return false }
            position += 1
            return true
        }

        mutating func expectSymbol(_ symbol: Character) throws {
            guard acceptSymbol(symbol) else { throw SearchError.database("expected '\(symbol)' in: \(sql)") }
        }

        mutating func identifier() throws -> String {
            switch try next() {
            case .identifier(let name), .word(let name): return name
            default: throw SearchError.database("expected an identifier in: \(sql)")
            }
        }

        mutating func binding() throws -> SearchBindingValue {
            guard let value = bindings.first else { throw SearchError.database("too few bindings for: \(sql)") }
            bindings = bindings.dropFirst()
            return value
        }
    }

    // MARK: Expressions

    enum Operand {
        case column(String)
        case rowID
        case value(SearchBindingValue)
    }

    static func operand(_ cursor: inout Cursor) throws -> Operand {
        switch try cursor.next() {
        case .identifier(let name): return .column(name)
        case .word(let name): return name.lowercased() == "rowid" ? .rowID : (name.uppercased() == "NULL" ? .value(.null) : .column(name))
        case .placeholder: return .value(try cursor.binding())
        case .number(let number): return .value(.int(Int64(number)))
        case .string(let string): return .value(.text(string))
        case .symbol(let symbol): throw SearchError.database("unexpected '\(symbol)' in: \(cursor.sql)")
        }
    }

    static func evaluate(_ operand: Operand, rowID: Int64, row: [String: SearchBindingValue]) -> SearchBindingValue {
        switch operand {
        case .column(let name): return row[name] ?? .null
        case .rowID: return .int(rowID)
        case .value(let value): return value
        }
    }

    indirect enum Condition {
        case comparison(Operand, String, Operand)
        case isNull(Operand, negated: Bool)
        case inList(Operand, [SearchBindingValue])
        case and([Condition])
    }

    static func condition(_ cursor: inout Cursor) throws -> Condition {
        var terms = [try term(&cursor)]
        while cursor.accept("AND") {
            terms.append(try term(&cursor))
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    static func term(_ cursor: inout Cursor) throws -> Condition {
        if cursor.acceptSymbol("(") {
            let inner = try condition(&cursor)
            try cursor.expectSymbol(")")
            return inner
        }
        let left = try operand(&cursor)
        if cursor.accept("IS") {
            let negated = cursor.accept("NOT")
            try cursor.expect("NULL")
            return .isNull(left, negated: negated)
        }
        if cursor.accept("IN") {
            try cursor.expectSymbol("(")
            var values: [SearchBindingValue] = []
            repeat {
                if case .value(let value) = try operand(&cursor) { values.append(value) }
            } while cursor.acceptSymbol(",")
            try cursor.expectSymbol(")")
            return .inList(left, values)
        }
        if cursor.acceptSymbol("=") {
            return .comparison(left, "=", try operand(&cursor))
        }
        if cursor.accept("<>") {
            return .comparison(left, "<>", try operand(&cursor))
        }
        throw SearchError.database("unsupported condition in: \(cursor.sql)")
    }

    static func holds(_ condition: Condition, rowID: Int64, row: [String: SearchBindingValue]) -> Bool {
        switch condition {
        case .comparison(let left, let comparison, let right):
            let lhs = evaluate(left, rowID: rowID, row: row)
            let rhs = evaluate(right, rowID: rowID, row: row)
            if lhs == .null || rhs == .null { return false }
            return comparison == "=" ? equal(lhs, rhs) : !equal(lhs, rhs)
        case .isNull(let operand, let negated):
            return (evaluate(operand, rowID: rowID, row: row) == .null) != negated
        case .inList(let operand, let values):
            let value = evaluate(operand, rowID: rowID, row: row)
            return values.contains { equal($0, value) }
        case .and(let conditions):
            return conditions.allSatisfy { holds($0, rowID: rowID, row: row) }
        }
    }

    /// The rowids a condition confines a statement to when it names them with integers:
    /// `rowid IN (...)` on its own or as one term of a conjunction. `nil` means scan.
    static func namedRowIDs(_ condition: Condition) -> Set<Int64>? {
        switch condition {
        case .inList(.rowID, let values):
            var ids = Set<Int64>()
            for value in values {
                guard case .int(let id) = value else { return nil }
                ids.insert(id)
            }
            return ids
        case .and(let conditions):
            for condition in conditions {
                if let ids = namedRowIDs(condition) { return ids }
            }
            return nil
        default:
            return nil
        }
    }

    static func equal(_ lhs: SearchBindingValue, _ rhs: SearchBindingValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let a), .real(let b)), (.real(let b), .int(let a)): return Double(a) == b
        default: return lhs == rhs
        }
    }

    static func order(_ lhs: SearchBindingValue, _ rhs: SearchBindingValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)): return a < b
        case (.real(let a), .real(let b)): return a < b
        case (.text(let a), .text(let b)): return a < b
        default: return false
        }
    }

    // MARK: Statements

    static func select(_ statement: SearchSQL, tables: [String: FakeTable]) throws -> [SearchRow] {
        var cursor = Cursor(tokens: try tokens(statement.template), sql: statement.template, bindings: statement.bindings[...])
        try cursor.expect("SELECT")
        var columns = [try operand(&cursor)]
        while cursor.acceptSymbol(",") {
            columns.append(try operand(&cursor))
        }
        try cursor.expect("FROM")
        let name = try cursor.identifier()
        guard let table = tables[name] else { throw SearchError.database("no such table: \(name)") }
        let filter = cursor.accept("WHERE") ? try condition(&cursor) : nil
        var ordering: [Operand] = []
        if cursor.accept("ORDER") {
            try cursor.expect("BY")
            repeat { ordering.append(try operand(&cursor)) } while cursor.acceptSymbol(",")
        }
        var limit: Int?
        var offset = 0
        if cursor.accept("LIMIT") {
            guard case .number(let value) = try cursor.next() else { throw SearchError.database("LIMIT needs a number") }
            limit = value
            if cursor.accept("OFFSET") {
                guard case .number(let value) = try cursor.next() else { throw SearchError.database("OFFSET needs a number") }
                offset = value
            }
        }
        guard cursor.peek == nil else { throw SearchError.database("unsupported SQL: \(statement.template)") }
        guard cursor.bindings.isEmpty else { throw SearchError.database("too many bindings for: \(statement.template)") }

        // `rowid IN (...)` is a lookup in SQLite, not a scan of the table: the fake starts from
        // the named rows too, so reading a handful of changed rows costs what it costs there.
        var rowIDs: [Int64]
        if let filter, let named = namedRowIDs(filter) {
            rowIDs = named.filter { table.rows[$0] != nil }.sorted()
        } else {
            rowIDs = table.rows.keys.sorted()
        }
        if let filter {
            rowIDs = rowIDs.filter { holds(filter, rowID: $0, row: table.rows[$0] ?? [:]) }
        }
        if !ordering.isEmpty {
            rowIDs.sort { lhs, rhs in
                for operand in ordering {
                    let left = evaluate(operand, rowID: lhs, row: table.rows[lhs] ?? [:])
                    let right = evaluate(operand, rowID: rhs, row: table.rows[rhs] ?? [:])
                    if order(left, right) { return true }
                    if order(right, left) { return false }
                }
                return lhs < rhs
            }
        }
        let page = rowIDs.dropFirst(offset).prefix(limit ?? Int.max)
        return page.map { rowID in
            let row = table.rows[rowID] ?? [:]
            return SearchRow(values: columns.map { column -> SearchBindingValue? in
                let value = evaluate(column, rowID: rowID, row: row)
                return value == .null ? nil : value
            })
        }
    }

    static func run(_ statement: SearchSQL, tables: inout [String: FakeTable], changes: inout [String: Set<Int64>]) throws -> Int {
        var cursor = Cursor(tokens: try tokens(statement.template), sql: statement.template, bindings: statement.bindings[...])
        if cursor.accept("CREATE") {
            try cursor.expect("TABLE")
            let ifNotExists = cursor.accept("IF")
            if ifNotExists {
                try cursor.expect("NOT")
                try cursor.expect("EXISTS")
            }
            let name = try cursor.identifier()
            try cursor.expectSymbol("(")
            var columns: [String] = []
            var primaryKey: [String] = []
            var depth = 1
            var expectingColumn = true
            while depth > 0 {
                let token = try cursor.next()
                switch token {
                case .symbol("("): depth += 1
                case .symbol(")"): depth -= 1
                case .symbol(",") where depth == 1: expectingColumn = true
                case .word(let word) where word.uppercased() == "PRIMARY" && depth == 1 && expectingColumn:
                    // Table constraint: PRIMARY KEY ("a", "b")
                    try cursor.expect("KEY")
                    try cursor.expectSymbol("(")
                    repeat { primaryKey.append(try cursor.identifier()) } while cursor.acceptSymbol(",")
                    try cursor.expectSymbol(")")
                    expectingColumn = false
                case .identifier(let column) where depth == 1 && expectingColumn:
                    columns.append(column)
                    expectingColumn = false
                case .word(let word) where word.uppercased() == "PRIMARY" && depth == 1:
                    // Column constraint: "key" TEXT PRIMARY KEY
                    if let last = columns.last { primaryKey.append(last) }
                default: break
                }
            }
            if tables[name] == nil {
                tables[name] = FakeTable(columns: columns, primaryKey: primaryKey)
            } else if !ifNotExists {
                throw SearchError.database("table \(name) already exists")
            }
            return 0
        }
        if cursor.accept("INSERT") {
            var replaces = false
            if cursor.accept("OR") {
                try cursor.expect("REPLACE")
                replaces = true
            }
            try cursor.expect("INTO")
            let name = try cursor.identifier()
            guard var table = tables[name] else { throw SearchError.database("no such table: \(name)") }
            try cursor.expectSymbol("(")
            var columns: [String] = []
            repeat { columns.append(try cursor.identifier()) } while cursor.acceptSymbol(",")
            try cursor.expectSymbol(")")
            try cursor.expect("VALUES")
            try cursor.expectSymbol("(")
            var values: [String: SearchBindingValue] = [:]
            for (index, column) in columns.enumerated() {
                if index > 0 { try cursor.expectSymbol(",") }
                if case .value(let value) = try operand(&cursor) { values[column] = value }
            }
            try cursor.expectSymbol(")")
            if !table.primaryKey.isEmpty {
                let existing = table.rows.first { _, row in table.primaryKey.allSatisfy { equal(row[$0] ?? .null, values[$0] ?? .null) } }
                if let existing {
                    guard replaces else { throw SearchError.database("UNIQUE constraint failed: \(name)") }
                    table.rows[existing.key] = nil
                }
            }
            let rowID = table.insert(values)
            tables[name] = table
            changes[name, default: []].insert(rowID)
            return 1
        }
        if cursor.accept("DELETE") {
            try cursor.expect("FROM")
            let name = try cursor.identifier()
            guard var table = tables[name] else { throw SearchError.database("no such table: \(name)") }
            let filter = cursor.accept("WHERE") ? try condition(&cursor) : nil
            let doomed = table.rows.keys.filter { rowID in
                filter.map { holds($0, rowID: rowID, row: table.rows[rowID] ?? [:]) } ?? true
            }
            for rowID in doomed { table.rows[rowID] = nil }
            tables[name] = table
            if !doomed.isEmpty { changes[name, default: []].formUnion(doomed) }
            return doomed.count
        }
        throw SearchError.database("unsupported SQL: \(statement.template)")
    }
}

/// A fake strings catalog: per-language string tables, with missing-key cases
/// (specification section 18.1, package 8).
public struct FakeLocalizedStringResolver: LocalizedStringResolving {
    /// Languages in catalog order; the first is the base language.
    public var languageOrder: [String]
    /// language -> key -> string.
    public var strings: [String: [String: String]]
    /// When set, only this table name resolves; any other table has no strings.
    public var table: String?

    public init(languageOrder: [String], strings: [String: [String: String]], table: String? = nil) {
        self.languageOrder = languageOrder
        self.strings = strings
        self.table = table
    }

    public func string(forKey key: String, table: String?, bundle: SearchBundleID, language: String) -> String? {
        if let expected = self.table, expected != table { return nil }
        return strings[language]?[key]
    }

    public func languages(bundle: SearchBundleID, table: String?) -> [String] {
        languageOrder
    }
}
