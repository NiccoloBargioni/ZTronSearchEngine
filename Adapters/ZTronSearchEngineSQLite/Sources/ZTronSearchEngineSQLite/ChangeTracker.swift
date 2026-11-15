import Foundation
import ZTronSearchEngine

/// Turns SQLite's update, commit and rollback hooks into the boundary's change stream
/// (specification section 9.2, rules 5 and 8).
///
/// The update hook reports one row at a time; the tracker collects the rowids of the running
/// transaction per table. The commit hook seals them into one batch, the rollback hook throws
/// them away, and the connection publishes the sealed batches once the statement that committed
/// has returned. Every subscriber then receives, per commit, one `SearchDatabaseChange` for
/// each of its tables the commit touched.
///
/// The rowids of a batch may include rows whose change was undone inside the transaction (a
/// statement that failed half way, `ROLLBACK TO` a savepoint). That is harmless: a subscriber
/// re-reads the rows it is told about.
///
/// The tracker is not thread-safe, on purpose. It is part of the state
/// ``SQLiteSearchConnection`` confines to its queue, which is also where SQLite calls the hooks.
final class ChangeTracker {
    private struct Subscriber {
        /// Folded table name to the spellings the subscriber asked for.
        let tables: [String: [String]]
        let continuation: AsyncStream<SearchDatabaseChange>.Continuation
    }

    private var subscribers: [UUID: Subscriber] = [:]
    /// The folded names of every table some subscriber listens to.
    private var watched: Set<String> = []
    /// A table name as SQLite reports it, to its folded name when the table is watched and to
    /// `nil` when it is not. Filled as tables are seen, emptied when the subscriptions change.
    private var routes: [String: String?] = [:]
    /// The rows the running transaction touched, per watched table.
    private var pending: [String: Set<Int64>] = [:]
    /// One entry per commit that has not been published yet.
    private var committed: [[String: Set<Int64>]] = []

    deinit {
        // A consumer must never wait forever on a stream nobody can feed any more.
        for subscriber in subscribers.values { subscriber.continuation.finish() }
    }

    // MARK: Subscriptions

    var subscriberCount: Int { subscribers.count }

    func subscribe(_ id: UUID, to tables: Set<String>, _ continuation: AsyncStream<SearchDatabaseChange>.Continuation) {
        var folded: [String: [String]] = [:]
        for table in tables.sorted() {
            folded[Self.fold(table), default: []].append(table)
        }
        subscribers[id] = Subscriber(tables: folded, continuation: continuation)
        subscriptionsChanged()
    }

    func unsubscribe(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        subscriptionsChanged()
    }

    /// Ends every stream. Used when the connection closes.
    func finish() {
        for subscriber in subscribers.values { subscriber.continuation.finish() }
        subscribers.removeAll()
        pending.removeAll()
        committed.removeAll()
        subscriptionsChanged()
    }

    private func subscriptionsChanged() {
        watched = Set(subscribers.values.flatMap { $0.tables.keys })
        routes.removeAll(keepingCapacity: true)
    }

    // MARK: Hooks

    /// The update hook: a row of `table` was inserted, updated or deleted.
    func rowChanged(in table: String, rowID: Int64) {
        guard !watched.isEmpty else { return }
        let route: String?
        if let known = routes[table] {
            route = known
        } else {
            let folded = Self.fold(table)
            route = watched.contains(folded) ? folded : nil
            routes.updateValue(route, forKey: table)
        }
        guard let route else { return }
        pending[route, default: []].insert(rowID)
    }

    /// The commit hook: the running transaction is about to commit.
    func transactionWillCommit() {
        guard !pending.isEmpty else { return }
        committed.append(pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// The rollback hook: the running transaction was rolled back.
    func transactionDidRollBack() {
        pending.removeAll(keepingCapacity: true)
    }

    // MARK: Publishing

    /// Sends the sealed batches to the subscribers, one commit after the other.
    func publishCommitted() {
        guard !committed.isEmpty else { return }
        let batches = committed
        committed.removeAll()
        guard !subscribers.isEmpty else { return }
        for batch in batches {
            let changes = batch.sorted { $0.key < $1.key }
            for subscriber in subscribers.values {
                for (table, rowIDs) in changes {
                    for spelling in subscriber.tables[table] ?? [] {
                        subscriber.continuation.yield(SearchDatabaseChange(table: spelling, rowIDs: rowIDs))
                    }
                }
            }
        }
    }

    /// Forgets what has not been published: the commit it was collected for did not happen.
    func discardUnpublished() {
        pending.removeAll(keepingCapacity: true)
        committed.removeAll()
    }

    /// Tells the subscribers of `tables` that they changed in a way SQLite did not report row
    /// by row.
    func publishUnknownChanges(in tables: Set<String>) {
        let folded = Set(tables.map(Self.fold)).sorted()
        for subscriber in subscribers.values {
            for table in folded {
                for spelling in subscriber.tables[table] ?? [] {
                    subscriber.continuation.yield(SearchDatabaseChange(table: spelling, rowIDs: nil))
                }
            }
        }
    }

    // MARK: Names

    /// SQLite compares table names without regard to ASCII case, and the update hook reports a
    /// name as the schema spells it; a subscriber may have spelled it differently.
    static func fold(_ name: String) -> String {
        guard name.utf8.contains(where: { (0x41 ... 0x5A).contains($0) }) else { return name }
        return String(decoding: name.utf8.map { (0x41 ... 0x5A).contains($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    }
}
