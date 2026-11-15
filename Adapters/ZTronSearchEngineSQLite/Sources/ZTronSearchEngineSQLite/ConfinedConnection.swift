import Dispatch
import Foundation
import SQLite
import ZTronSearchEngine

/// Everything ``SQLiteSearchConnection`` confines to its serial queue: the SQLite.swift
/// `Connection`, the transactions run on it and the change tracker its hooks feed.
///
/// Nothing in this type is thread-safe and nothing has to be. Each entry point checks that it
/// runs on the queue, so a call from anywhere else traps instead of racing.
final class ConfinedConnection {
    private let queue: DispatchQueue
    private var connection: Connection?
    private let isReadOnly: Bool
    private let changes = ChangeTracker()

    /// Opens the database. Runs on `queue`, like everything else here.
    init(location: SearchDatabaseLocation, options: SQLiteSearchDatabase.Options, queue: DispatchQueue) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        self.queue = queue

        let connection: Connection
        let canJournal: Bool
        switch location {
        case .file(let url, let readonly):
            guard url.isFileURL else { throw SQLiteSearchError.unsupportedLocation(url.absoluteString) }
            // A path that does not start with `file:` is taken as it is, whatever it contains.
            connection = try Connection(.uri(url.path), readonly: readonly)
            canJournal = true
        case .inMemory:
            connection = try Connection(.inMemory)
            canJournal = false
        case .uri(let uri):
            connection = try Connection(.uri(uri))
            canJournal = !uri.isEmpty && uri != ":memory:"
        }

        // SQLite decides: a `mode=ro` URI or a file without write permission is read-only too.
        isReadOnly = connection.readonly
        // SQLite counts the timeout in milliseconds, in 32 bits.
        connection.busyTimeout = min(max(0, options.busyTimeout), 1_000_000)
        if options.enablesWAL, canJournal, !isReadOnly {
            // SQLite answers with the mode in force. A database that cannot use a write-ahead
            // log (an in-memory database behind a URI, some network volumes) keeps its own.
            _ = try connection.scalar("PRAGMA journal_mode = WAL")
        }

        // SQLite calls the hooks on the thread that runs the statement, which is this queue.
        // The rollback hook is the one exception, and so the one hook that does not check: it
        // also fires when a connection is released with a transaction still open, wherever
        // that happens, at a time when nothing else can touch the tracker.
        connection.updateHook { [changes, queue] _, _, table, rowID in
            dispatchPrecondition(condition: .onQueue(queue))
            changes.rowChanged(in: table, rowID: rowID)
        }
        connection.commitHook { [changes, queue] in
            dispatchPrecondition(condition: .onQueue(queue))
            changes.transactionWillCommit()
        }
        connection.rollbackHook { [changes] in
            changes.transactionDidRollBack()
        }
        self.connection = connection
    }

    // MARK: Transactions

    /// Runs `body` inside a deferred transaction: every statement of the body reads the same
    /// snapshot.
    func read<T>(_ body: (any SearchDatabaseReader) throws -> T) throws -> T {
        try transaction(.deferred) { try body($0) }
    }

    /// Runs `body` inside a transaction that takes the write lock up front. Commits when the
    /// body returns, rolls back when it throws.
    func write<T>(_ body: (any SearchDatabaseWriter) throws -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connection != nil else { throw SQLiteSearchError.connectionClosed }
        guard !isReadOnly else { throw SQLiteSearchError.readOnlyConnection }
        do {
            return try transaction(.immediate) { try body($0) }
        } catch {
            // Nothing was committed, so nothing this transaction touched may be announced.
            changes.discardUnpublished()
            throw error
        }
    }

    /// Runs the host's own statements on the connection.
    func withConnection<T>(_ body: (Connection) throws -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection else { throw SQLiteSearchError.connectionClosed }
        return try body(connection)
    }

    /// Spelled out instead of `Connection.transaction(_:block:)` for two reasons: the body's
    /// value comes back without a detour, and a `ROLLBACK` that fails because SQLite already
    /// rolled back on its own never replaces the error that caused it.
    private func transaction<T>(_ mode: Connection.TransactionMode, _ body: (SQLiteSearchSession) throws -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection else { throw SQLiteSearchError.connectionClosed }
        try connection.execute("BEGIN \(mode.rawValue) TRANSACTION")
        let session = SQLiteSearchSession(connection)
        defer { session.end() }
        do {
            let value = try body(session)
            try connection.execute("COMMIT TRANSACTION")
            return value
        } catch {
            try? connection.execute("ROLLBACK TRANSACTION")
            throw error
        }
    }

    // MARK: Changes

    func subscribe(_ id: UUID, to tables: Set<String>, _ continuation: AsyncStream<SearchDatabaseChange>.Continuation) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connection != nil else {
            continuation.finish()
            return
        }
        changes.subscribe(id, to: tables, continuation)
    }

    func unsubscribe(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        changes.unsubscribe(id)
    }

    var subscriberCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return changes.subscriberCount
    }

    func publishUnknownChanges(in tables: Set<String>) {
        dispatchPrecondition(condition: .onQueue(queue))
        changes.publishUnknownChanges(in: tables)
    }

    /// Publishes the commits of the block that just ran. Called at the end of every block, when
    /// the statements that committed have returned.
    func publishCommittedChanges() {
        dispatchPrecondition(condition: .onQueue(queue))
        changes.publishCommitted()
    }

    // MARK: Closing

    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        changes.finish()
        guard let connection else { return }
        connection.updateHook(nil)
        connection.commitHook(nil)
        connection.rollbackHook(nil)
        // A SQLite.swift `Connection` closes its database when it is released, and this was the
        // last reference to it: every reader and writer gave theirs up when its body returned.
        self.connection = nil
    }
}

/// The reader and writer handed to the body of a transaction.
///
/// It lives exactly as long as its transaction: once the body returned it refuses every call,
/// so a session that leaked out of its body cannot reach the connection.
final class SQLiteSearchSession: SearchDatabaseWriter {
    private var connection: Connection?

    init(_ connection: Connection) {
        self.connection = connection
    }

    func end() {
        connection = nil
    }

    /// Every row of the statement, read before this method returns, so the sequence holds
    /// plain values and outlives the transaction safely.
    func rows(_ statement: SearchSQL) throws -> AnySequence<SearchRow> {
        let prepared = try prepare(statement)
        let columns = prepared.columnCount
        var rows: [SearchRow] = []
        while try prepared.step() {
            // The cursor is only asked for once there is a row: SQLite.swift builds it from
            // the compiled statement, and a text without a statement in it has none.
            let cursor = prepared.row
            var values: [SearchBindingValue?] = []
            values.reserveCapacity(columns)
            for column in 0..<columns {
                let value: (any Binding)? = cursor[column]
                values.append(SearchBindingValue(value))
            }
            rows.append(SearchRow(values: values))
        }
        return AnySequence(rows)
    }

    /// The first value of the first row: `nil` when the statement returns no row, `.null` when
    /// the value is SQL `NULL`.
    func scalar(_ statement: SearchSQL) throws -> SearchBindingValue? {
        let prepared = try prepare(statement)
        guard try prepared.step(), prepared.columnCount > 0 else { return nil }
        let value: (any Binding)? = prepared.row[0]
        return SearchBindingValue(value)
    }

    /// Runs the statement to its end and returns the rows it changed itself: `sqlite3_changes`,
    /// and zero for a statement that changes none (SQLite leaves the previous count in place
    /// after a `CREATE TABLE`, for one).
    func run(_ statement: SearchSQL) throws -> Int {
        let connection = try live()
        let before = connection.totalChanges
        let prepared = try prepare(statement)
        while try prepared.step() {}
        return connection.totalChanges == before ? 0 : connection.changes
    }

    private func live() throws -> Connection {
        guard let connection else { throw SQLiteSearchError.transactionEnded }
        return connection
    }

    /// Compiles the template and binds the values, untouched and in order.
    private func prepare(_ statement: SearchSQL) throws -> Statement {
        let prepared = try live().prepare(statement.template)
        let expected = SQLParameterCounter.parameterCount(in: statement.template)
        guard expected == statement.bindings.count else {
            throw SQLiteSearchError.bindingCountMismatch(
                expected: expected, provided: statement.bindings.count, statement: statement.template
            )
        }
        guard !statement.bindings.isEmpty else { return prepared }
        return prepared.bind(statement.bindings.map(\.sqliteBinding))
    }
}
