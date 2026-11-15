import Foundation
import ZTronSearchEngine

/// The reference `SearchDatabase` of ZTronSearchEngine: SQLite, through SQLite.swift
/// (specification section 9.2, rule 8).
///
/// `open(_:)` maps the three locations of the boundary to a SQLite.swift `Connection`:
/// - `.file(url, readonly:)` opens the file at `url`, creating it unless `readonly` is set;
/// - `.inMemory` opens a private in-memory database;
/// - `.uri(string)` hands the string to SQLite as a filename or a `file:` URI, so its query
///   parameters (`mode=ro`, `cache=shared`, `immutable=1`) apply.
///
/// Core never imports SQLite.swift. A host creates this value, opens its database with it and
/// injects the connection into a `SearchContext`:
///
///     let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))
///     let connection = try await database.connect(.file(url, readonly: false))
///     let context = SearchContext<Schema>(id: "catalog", sources: [.database(connection, [tools])])
public struct SQLiteSearchDatabase: SearchDatabase {
    /// How connections are configured when they are opened.
    public struct Options: Sendable, Hashable {
        /// Switches a file database to write-ahead logging (`PRAGMA journal_mode = WAL`) when
        /// it is opened.
        ///
        /// The specification recommends it when the host writes while the engine reads: with a
        /// write-ahead log a reader never blocks a writer on another connection, and a writer
        /// never blocks a reader. The mode is stored in the database file, so it stays in
        /// force for every later connection, whoever opens it.
        ///
        /// In-memory and read-only databases are left alone, and so is `synchronous`, which
        /// decides how durable a commit is and is the host's call.
        public var enablesWAL: Bool

        /// How long, in seconds, a statement waits for a lock another connection holds before
        /// it fails with `SQLITE_BUSY`. Zero fails at once.
        ///
        /// The wait happens on the connection's own queue, never on a thread of the caller.
        public var busyTimeout: TimeInterval

        /// The defaults leave the journal mode of the database as it is and wait up to five
        /// seconds for a lock.
        public init(enablesWAL: Bool = false, busyTimeout: TimeInterval = 5) {
            self.enablesWAL = enablesWAL
            self.busyTimeout = busyTimeout
        }
    }

    /// How the connections this value opens are configured.
    public var options: Options

    /// A database whose connections are opened with `options`.
    public init(options: Options = Options()) {
        self.options = options
    }

    /// Opens `location`. The boundary's spelling: the connection comes back as the protocol.
    public func open(_ location: SearchDatabaseLocation) async throws -> any SearchDatabaseConnection {
        try await connect(location)
    }

    /// Opens `location` and returns the connection under its own type, which adds
    /// ``SQLiteSearchConnection/withConnection(_:)`` for the host's own statements.
    public func connect(_ location: SearchDatabaseLocation) async throws -> SQLiteSearchConnection {
        try await SQLiteSearchConnection.open(location, options: options)
    }
}
