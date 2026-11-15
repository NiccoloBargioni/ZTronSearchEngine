import Foundation
import SQLite
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// Connections: file, in-memory, read-only and URI locations, closing, and serialization of
/// concurrent callers (specification section 16, "Adapter integration").
final class ConnectionTests: XCTestCase {
    private let createNotes: SearchSQL = "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)"

    // MARK: Locations

    func testFileDatabaseIsCreatedAndPersistsAcrossConnections() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("notes.sqlite")
        let database = SQLiteSearchDatabase()

        let first = try await database.connect(.file(url, readonly: false))
        try await first.execute([createNotes, SearchSQL(template: "INSERT INTO notes (body) VALUES (?)", bindings: [.text("kept")])])
        await first.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let second = try await database.connect(.file(url, readonly: false))
        let body = try await second.value("SELECT body FROM notes")
        XCTAssertEqual(body, .text("kept"))
        await second.close()
    }

    func testFilePathWithSpacesAndURICharactersIsTakenLiterally() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // `?` and `#` would start a query or a fragment if the path were read as a URI.
        let url = directory.file("my notes?mode=ro#1 100%.sqlite")
        let connection = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
        try await connection.execute([createNotes])
        await connection.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOpenThroughTheBoundaryProtocol() async throws {
        let database: any SearchDatabase = SQLiteSearchDatabase()
        let connection = try await database.open(.inMemory)
        let answer = try await connection.read { try $0.scalar("SELECT 40 + 2") }
        XCTAssertEqual(answer, .int(42))
        XCTAssertTrue(connection is SQLiteSearchConnection)
        await connection.close()
    }

    func testInMemoryDatabasesArePrivateToTheirConnection() async throws {
        let database = SQLiteSearchDatabase()
        let first = try await database.connect(.inMemory)
        let second = try await database.connect(.inMemory)
        try await first.execute([createNotes])

        let inFirst = try await first.value("SELECT COUNT(*) FROM sqlite_master WHERE name = 'notes'")
        let inSecond = try await second.value("SELECT COUNT(*) FROM sqlite_master WHERE name = 'notes'")
        XCTAssertEqual(inFirst, .int(1))
        XCTAssertEqual(inSecond, .int(0))
        await first.close()
        await second.close()
    }

    func testReadOnlyFileRefusesWriteAndStillReads() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("notes.sqlite")
        let database = SQLiteSearchDatabase()
        let writable = try await database.connect(.file(url, readonly: false))
        try await writable.execute([createNotes, "INSERT INTO notes (body) VALUES ('read me')"])
        await writable.close()

        let readOnly = try await database.connect(.file(url, readonly: true))
        let body = try await readOnly.value("SELECT body FROM notes")
        XCTAssertEqual(body, .text("read me"))

        do {
            try await readOnly.write { writer in
                XCTFail("the body of a refused write must not run")
                _ = try writer.run("INSERT INTO notes (body) VALUES ('nope')")
            }
            XCTFail("a read-only connection must refuse a write transaction")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .readOnlyConnection)
            XCTAssertTrue(String(describing: error).contains("read-only"), "the error must say why: \(error)")
        }

        // SQLite itself refuses the host's own writes.
        do {
            try await readOnly.withConnection { try $0.execute("INSERT INTO notes (body) VALUES ('nope')") }
            XCTFail("SQLite must refuse to write a read-only database")
        } catch {
            XCTAssertNotNil(error as? SQLite.Result, "expected SQLite's own error, got \(error)")
        }

        let count = try await readOnly.value("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(count, .int(1))
        await readOnly.close()
    }

    func testReadOnlyOpenOfAMissingFileThrows() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        do {
            _ = try await SQLiteSearchDatabase().connect(.file(directory.file("absent.sqlite"), readonly: true))
            XCTFail("a read-only open must not create the file")
        } catch {
            XCTAssertNotNil(error as? SQLite.Result, "expected SQLite's own error, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.file("absent.sqlite").path))
    }

    func testNonFileURLIsRefused() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/notes.sqlite"))
        do {
            _ = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
            XCTFail("only file URLs can be opened")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .unsupportedLocation(url.absoluteString))
        }
    }

    func testURIWithSharedMemoryDatabaseIsSeenByTwoConnections() async throws {
        let database = SQLiteSearchDatabase()
        let uri = "file:ztron-\(UUID().uuidString)?mode=memory&cache=shared"
        let first = try await database.connect(.uri(uri))
        let second = try await database.connect(.uri(uri))
        try await first.execute([createNotes, "INSERT INTO notes (body) VALUES ('shared')"])

        let body = try await second.value("SELECT body FROM notes")
        XCTAssertEqual(body, .text("shared"))
        await first.close()
        await second.close()
    }

    func testURIWithReadOnlyModeIsReadOnly() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("notes.sqlite")
        let database = SQLiteSearchDatabase()
        let writable = try await database.connect(.file(url, readonly: false))
        try await writable.execute([createNotes, "INSERT INTO notes (body) VALUES ('by uri')"])
        await writable.close()

        // The file is opened read-write as far as the location says; the URI makes it read-only.
        let connection = try await database.connect(.uri("file:\(url.path)?mode=ro"))
        let body = try await connection.value("SELECT body FROM notes")
        XCTAssertEqual(body, .text("by uri"))
        do {
            try await connection.write { _ in }
            XCTFail("a mode=ro URI must make the connection read-only")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .readOnlyConnection)
        }
        await connection.close()
    }

    // MARK: WAL

    func testWALIsEnabledOnRequestAndReportedByThePragma() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("wal.sqlite")

        let plain = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
        try await plain.execute([createNotes])
        let before = try await plain.value("PRAGMA journal_mode")
        XCTAssertEqual(before, .text("delete"), "SQLite's default is a rollback journal")
        await plain.close()

        let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))
        let connection = try await database.connect(.file(url, readonly: false))
        let mode = try await connection.value("PRAGMA journal_mode")
        XCTAssertEqual(mode, .text("wal"))
        try await connection.execute(["INSERT INTO notes (body) VALUES ('logged')"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"), "a write in WAL mode goes to the -wal file")
        await connection.close()

        // The mode is stored in the file: a later connection finds it without asking.
        let later = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
        let stored = try await later.value("PRAGMA journal_mode")
        XCTAssertEqual(stored, .text("wal"))
        await later.close()
    }

    func testWALRequestLeavesInMemoryAndReadOnlyDatabasesAlone() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("plain.sqlite")
        let plain = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
        try await plain.execute([createNotes])
        await plain.close()

        let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))
        let memory = try await database.connect(.inMemory)
        let memoryMode = try await memory.value("PRAGMA journal_mode")
        XCTAssertEqual(memoryMode, .text("memory"))
        await memory.close()

        let readOnly = try await database.connect(.file(url, readonly: true))
        let readOnlyMode = try await readOnly.value("PRAGMA journal_mode")
        XCTAssertEqual(readOnlyMode, .text("delete"))
        await readOnly.close()
    }

    // MARK: Closing

    func testCallsAfterCloseThrowAndCloseIsIdempotent() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        try await connection.execute([createNotes])
        await connection.close()
        await connection.close()

        do {
            _ = try await connection.read { try $0.scalar("SELECT 1") }
            XCTFail("read must throw once the connection is closed")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .connectionClosed)
        }
        do {
            try await connection.write { _ in }
            XCTFail("write must throw once the connection is closed")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .connectionClosed)
        }
        do {
            try await connection.withConnection { _ in }
            XCTFail("withConnection must throw once the connection is closed")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .connectionClosed)
        }
    }

    func testCloseEndsEveryChangeStream() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        let open = connection.changes(in: ["notes"])
        await connection.close()
        for await change in open {
            XCTFail("a closed connection must not yield \(change)")
        }
        // A stream asked for after the close is finished from the start.
        for await change in connection.changes(in: ["notes"]) {
            XCTFail("a closed connection must not yield \(change)")
        }
    }

    // MARK: Serialization

    func testConcurrentCallersAreSerialized() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        try await connection.execute(["CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)", "INSERT INTO counter VALUES (1, 0)"])

        // Read-modify-write in two statements: only whole transactions, one after the other,
        // can make every increment count.
        let writers = 200
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    try await connection.write { writer in
                        let current = try writer.scalar("SELECT value FROM counter WHERE id = 1")
                        guard case .int(let value)? = current else { throw TimedOut(description: "unexpected \(String(describing: current))") }
                        _ = try writer.run(SearchSQL(template: "UPDATE counter SET value = ? WHERE id = 1", bindings: [.int(value + 1)]))
                    }
                }
                group.addTask {
                    let value = try await connection.read { try $0.scalar("SELECT value FROM counter WHERE id = 1") }
                    guard case .int? = value else { throw TimedOut(description: "unexpected \(String(describing: value))") }
                }
            }
            try await group.waitForAll()
        }
        let total = try await connection.value("SELECT value FROM counter WHERE id = 1")
        XCTAssertEqual(total, .int(Int64(writers)))
        await connection.close()
    }

    /// Bodies are borrowed, not copied: Swift checks that nothing kept one when the call
    /// returns, and traps otherwise. Thousands of short calls from many tasks give that check
    /// every chance to catch a reference the queue would still hold.
    func testBorrowedBodiesAreReleasedBeforeTheCallerResumes() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        let total = try await withThrowingTaskGroup(of: Int64.self) { group in
            for index in 0..<5_000 {
                group.addTask {
                    let bound = Int64(index)
                    switch index % 3 {
                    case 0:
                        let value = try await connection.read { try $0.scalar(SearchSQL(template: "SELECT ?", bindings: [.int(bound)])) }
                        return value == .int(bound) ? 1 : 0
                    case 1:
                        return try await connection.write { _ in 1 }
                    default:
                        return try await connection.withConnection { db in (try db.scalar("SELECT 1") as? Int64) ?? 0 }
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        XCTAssertEqual(total, 5_000)
        await connection.close()
    }
}
