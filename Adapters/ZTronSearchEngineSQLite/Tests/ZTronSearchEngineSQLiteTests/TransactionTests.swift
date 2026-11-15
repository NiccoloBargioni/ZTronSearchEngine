import Foundation
import SQLite
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// Transactions: `write` commits on return and rolls back on throw; `read` is one consistent
/// snapshot (specification section 9.2, rule 2).
final class TransactionTests: XCTestCase {
    private struct Refused: Error, Equatable {}

    private func makeConnection() async throws -> SQLiteSearchConnection {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        try await connection.execute(["CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL UNIQUE)"])
        return connection
    }

    func testWriteCommitsWhenTheBodyReturnsAndHandsItsValueBack() async throws {
        let connection = try await makeConnection()
        let changed = try await connection.write { writer in
            try writer.run("INSERT INTO notes (body) VALUES ('one')") + writer.run("INSERT INTO notes (body) VALUES ('two')")
        }
        XCTAssertEqual(changed, 2)
        let count = try await connection.value("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(count, .int(2))
        await connection.close()
    }

    func testWriteRollsBackWhenTheBodyThrowsAndRethrowsItsError() async throws {
        let connection = try await makeConnection()
        try await connection.execute(["INSERT INTO notes (body) VALUES ('before')"])

        do {
            try await connection.write { writer in
                _ = try writer.run("INSERT INTO notes (body) VALUES ('lost')")
                _ = try writer.run("DELETE FROM notes WHERE body = 'before'")
                throw Refused()
            }
            XCTFail("the error of the body must reach the caller")
        } catch {
            XCTAssertEqual(error as? Refused, Refused())
        }

        let bodies = try await connection.allRows("SELECT body FROM notes ORDER BY id")
        XCTAssertEqual(bodies, [[.text("before")]], "a rolled-back transaction leaves the database as it was")
        await connection.close()
    }

    func testWriteRollsBackWhenAStatementFails() async throws {
        let connection = try await makeConnection()
        do {
            try await connection.write { writer in
                _ = try writer.run("INSERT INTO notes (body) VALUES ('twice')")
                _ = try writer.run("INSERT INTO notes (body) VALUES ('twice')")
            }
            XCTFail("the UNIQUE constraint must fail the second insert")
        } catch {
            XCTAssertNotNil(error as? SQLite.Result, "SQLite's own error passes through: \(error)")
        }
        let count = try await connection.value("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(count, .int(0))

        // The connection is left out of any transaction: the next one starts normally.
        try await connection.execute(["INSERT INTO notes (body) VALUES ('after')"])
        let after = try await connection.value("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(after, .int(1))
        await connection.close()
    }

    func testReadThatThrowsLeavesTheConnectionUsable() async throws {
        let connection = try await makeConnection()
        do {
            _ = try await connection.read { reader in try reader.scalar("SELECT * FROM no_such_table") }
            XCTFail("a statement on a missing table must throw")
        } catch {
            XCTAssertNotNil(error as? SQLite.Result, "SQLite's own error passes through: \(error)")
        }
        let one = try await connection.value("SELECT 1")
        XCTAssertEqual(one, .int(1))
        await connection.close()
    }

    func testReadSeesOneSnapshotWhileAnotherConnectionCommits() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("snapshot.sqlite")
        let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))

        let reader = try await database.connect(.file(url, readonly: false))
        let writer = try await database.connect(.file(url, readonly: false))
        try await writer.execute([
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)",
            "INSERT INTO notes (body) VALUES ('one'), ('two'), ('three')",
        ])

        // The read transaction is held open across the other connection's commit: its first
        // statement fixes the snapshot, then it signals, then it waits for the commit. The wait
        // blocks the reader's own queue thread, which is the point of the test.
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let committed = DispatchSemaphore(value: 0)
        async let counts: [SearchBindingValue?] = reader.read { transaction in
            let before = try transaction.scalar("SELECT COUNT(*) FROM notes")
            startedContinuation.yield()
            guard committed.wait(timeout: .now() + 10) == .success else { throw TimedOut(description: "the writer never committed") }
            let after = try transaction.scalar("SELECT COUNT(*) FROM notes")
            let rows = try transaction.rows("SELECT body FROM notes ORDER BY id").map { $0.values[0] }
            return [before, after, .int(Int64(rows.count))]
        }

        for await _ in started { break }
        try await writer.execute(["INSERT INTO notes (body) VALUES ('four')", "DELETE FROM notes WHERE body = 'one'", "INSERT INTO notes (body) VALUES ('five')"])
        let seenByWriter = try await writer.value("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(seenByWriter, .int(4), "the writer committed while the read was open")
        committed.signal()

        let snapshot = try await counts
        XCTAssertEqual(snapshot, [.int(3), .int(3), .int(3)], "every statement of one read sees the same snapshot")

        // The next read starts a new snapshot.
        let afterwards = try await reader.value("SELECT COUNT(*) FROM notes")
        XCTAssertEqual(afterwards, .int(4))
        await reader.close()
        await writer.close()
    }

    func testReaderAndWriterRefuseToWorkAfterTheirTransaction() throws {
        let connection = try Connection(.inMemory)
        let session = SQLiteSearchSession(connection)
        XCTAssertEqual(try session.scalar("SELECT 7"), .int(7))
        session.end()

        XCTAssertThrowsError(try session.scalar("SELECT 7")) { XCTAssertEqual($0 as? SQLiteSearchError, .transactionEnded) }
        XCTAssertThrowsError(try session.rows("SELECT 7")) { XCTAssertEqual($0 as? SQLiteSearchError, .transactionEnded) }
        XCTAssertThrowsError(try session.run("SELECT 7")) { XCTAssertEqual($0 as? SQLiteSearchError, .transactionEnded) }
    }

    func testRowsAreReadBeforeTheTransactionEnds() async throws {
        let connection = try await makeConnection()
        try await connection.execute(["INSERT INTO notes (body) VALUES ('a'), ('b'), ('c')"])

        // The rows leave the body as plain values: the sequence does not need the transaction.
        let rows = try await connection.read { reader in Array(try reader.rows("SELECT id, body FROM notes ORDER BY id")) }
        XCTAssertEqual(rows.map(\.values), [[.int(1), .text("a")], [.int(2), .text("b")], [.int(3), .text("c")]])

        let none = try await connection.read { reader in Array(try reader.rows("SELECT id FROM notes WHERE id > 99")) }
        XCTAssertTrue(none.isEmpty)
        await connection.close()
    }
}
