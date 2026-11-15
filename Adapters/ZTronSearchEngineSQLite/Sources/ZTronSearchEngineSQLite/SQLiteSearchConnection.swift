import Dispatch
import Foundation
import SQLite
import ZTronSearchEngine

/// One SQLite.swift `Connection` behind the engine's database boundary
/// (specification section 9.2, rules 7 and 8).
///
/// The connection serializes its callers itself: `read`, `write`, `withConnection` and `close`
/// may be called from any task or thread, and run one after the other on a private queue. None
/// of them blocks the calling thread; the caller is suspended and resumed with the result.
///
/// ## Why this type is `@unchecked Sendable`
///
/// A SQLite.swift `Connection` is not `Sendable`, and neither is what is kept next to it in
/// ``ConfinedConnection``: the readers and writers handed to transaction bodies and the change
/// tracker the hooks feed. The compiler cannot check what makes sharing this object safe, so it
/// is stated here and enforced below. This is the one unchecked conformance of the adapter.
///
/// **Invariant.** `confined`, and through it the `Connection`, is only ever touched by a block
/// running on `queue`: a private, serial `DispatchQueue` that nothing else submits work to.
///
/// It holds because:
///
/// 1. `confined` is created on `queue` (`open(_:options:)`) and is read in exactly one place,
///    `enqueue(_:)`, inside a block submitted to `queue`. Every operation of this class goes
///    through that method.
/// 2. The `Connection` leaves `confined` only as the argument of a `withConnection` body, and
///    the readers and writers that wrap it only as the argument of a `read` or `write` body.
///    These bodies run synchronously inside such a block. They are `@Sendable` and return a
///    `Sendable` value, so the compiler refuses a body that tries to carry the connection, a
///    statement or a reader out. A reader or writer that escapes all the same refuses to work
///    once its transaction ended.
/// 3. SQLite calls the update, commit and rollback hooks on the thread that runs the statement,
///    so they run on `queue` too.
/// 4. The other stored property, `queue`, is immutable and `Sendable`.
///
/// `ConfinedConnection` asserts the queue with `dispatchPrecondition` in every entry point and
/// in the update and commit hooks: a violation traps instead of racing. The connection is
/// released with this object; a pending block holds the object, so none can be left by then.
public final class SQLiteSearchConnection: SearchDatabaseConnection, @unchecked Sendable {
    private let queue: DispatchQueue
    private let confined: ConfinedConnection

    private init(confined: ConfinedConnection, queue: DispatchQueue) {
        self.confined = confined
        self.queue = queue
    }

    /// Opens `location` on a queue of its own and returns once the database is open.
    static func open(_ location: SearchDatabaseLocation, options: SQLiteSearchDatabase.Options) async throws -> SQLiteSearchConnection {
        // No quality of service of its own: a block runs at the priority of the caller that
        // submitted it. Each block drains its own autorelease pool.
        let queue = DispatchQueue(label: "com.ztron.searchengine.sqlite.connection", autoreleaseFrequency: .workItem)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Swift.Result {
                    SQLiteSearchConnection(
                        confined: try ConfinedConnection(location: location, options: options, queue: queue),
                        queue: queue
                    )
                })
            }
        }
    }

    // MARK: The queue

    /// The single door to the confined state: a block on `queue`.
    ///
    /// Every block ends by publishing the changes of the commits it made, so a subscriber hears
    /// of a commit only after the statement that committed has returned.
    private func enqueue(_ job: @escaping @Sendable (ConfinedConnection) -> Void) {
        queue.async {
            job(self.confined)
            self.confined.publishCommittedChanges()
        }
    }

    /// Runs `work` on the queue and resumes the caller with its outcome.
    ///
    /// The caller is resumed from a second block, not from the one that ran `work`. A serial
    /// queue destroys a block before it starts the next, so by the time the caller continues,
    /// the queue holds no reference to `work` any more. `read`, `write` and `withConnection`
    /// rely on that: they lend their non-escaping body to `work`, and Swift checks, when such a
    /// loan ends, that nobody kept it.
    private func perform<T: Sendable>(_ work: @escaping @Sendable (ConfinedConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            enqueue { confined in
                let outcome = Swift.Result { try work(confined) }
                self.queue.async { continuation.resume(with: outcome) }
            }
        }
    }

    // MARK: SearchDatabaseConnection

    /// Runs `body` inside a deferred read transaction: every statement of the body sees the same
    /// snapshot of the database, whatever other connections commit meanwhile.
    ///
    /// The reader is only valid inside the body. `rows(_:)` reads every row before it returns,
    /// so the rows themselves are plain values and may be returned from the body.
    public func read<T: Sendable>(_ body: @Sendable (any SearchDatabaseReader) throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { body in
            try await self.perform { confined in try confined.read(body) }
        }
    }

    /// Runs `body` inside a write transaction: committed when the body returns, rolled back when
    /// it throws.
    ///
    /// The transaction takes the write lock when it begins (`BEGIN IMMEDIATE`), so it cannot
    /// fail half way because another connection wrote first. A connection whose database is
    /// read-only throws ``SQLiteSearchError/readOnlyConnection`` without running the body.
    public func write<T: Sendable>(_ body: @Sendable (any SearchDatabaseWriter) throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { body in
            try await self.perform { confined in try confined.write(body) }
        }
    }

    /// The changes committed through this connection to any of `tables`.
    ///
    /// Each commit yields one `SearchDatabaseChange` per table of `tables` it touched, carrying
    /// the rowids that were inserted, updated or deleted. A transaction that is rolled back
    /// yields nothing. Changes are seen whoever made them through this connection: the body of
    /// `write`, or the host's own statements in ``withConnection(_:)``.
    ///
    /// Every call returns a stream of its own. A stream ends when the connection closes; a
    /// stream that is cancelled, or no longer referenced, gives up its subscription.
    ///
    /// Table names are matched the way SQLite matches them, without regard to ASCII case, and
    /// reported in the spelling of `tables`. The schema a table lives in (`main`, an attached
    /// database) is not part of the match.
    ///
    /// SQLite reports row changes through its update hook, which stays silent for:
    /// - changes made through another connection, or by another process;
    /// - tables declared `WITHOUT ROWID`;
    /// - `DELETE FROM table` without a `WHERE` clause on a table that has no trigger, which
    ///   SQLite executes without visiting the rows (`DELETE FROM table WHERE 1` visits them);
    /// - rows removed to make room for another by `INSERT OR REPLACE` and its relatives.
    ///
    /// After such a change, call ``reportUnknownChanges(in:)``.
    public func changes(in tables: Set<String>) -> AsyncStream<SearchDatabaseChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SearchDatabaseChange>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.enqueue { $0.unsubscribe(id) }
        }
        enqueue { $0.subscribe(id, to: tables, continuation) }
        return stream
    }

    /// Ends every change stream and closes the database. Calls made afterwards throw
    /// ``SQLiteSearchError/connectionClosed``.
    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue { confined in
                confined.close()
                continuation.resume()
            }
        }
    }

    // MARK: The host's own access

    /// Runs the host's own statements on the connection, on its queue.
    ///
    /// This is how a host shares one `Connection` with the engine: its writes go through here,
    /// so they are serialized with the engine's reads and their changes reach
    /// ``changes(in:)``.
    ///
    ///     try await connection.withConnection { db in
    ///         try db.run(tools.filter(id == 7).update(title <- "Sextant"))
    ///     }
    ///
    /// Three rules keep the connection sound:
    /// - The `Connection` must not outlive the body, and neither may anything made from it (a
    ///   `Statement`, a row iterator). Return plain values.
    /// - A transaction begun in the body must end in it.
    /// - The update, commit and rollback hooks belong to the adapter. Replacing them silences
    ///   ``changes(in:)``; subscribe to it instead.
    @discardableResult
    public func withConnection<T: Sendable>(_ body: @Sendable (Connection) throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { body in
            try await self.perform { confined in try confined.withConnection(body) }
        }
    }

    /// Tells the subscribers of `tables` that they changed in a way SQLite did not report: they
    /// receive a change without rowids, which makes the engine read the table again.
    ///
    /// See ``changes(in:)`` for the changes SQLite does not report.
    public func reportUnknownChanges(in tables: Set<String>) {
        enqueue { $0.publishUnknownChanges(in: tables) }
    }

    /// The number of change streams that are subscribed right now. For the tests.
    func subscriberCount() async -> Int {
        (try? await perform { $0.subscriberCount }) ?? 0
    }
}
