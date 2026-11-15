import Foundation
import SQLite
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// The change stream: update, commit and rollback hooks turned into one change per commit and
/// table (specification section 9.2, rules 5 and 8).
final class ChangeStreamTests: XCTestCase {
    private struct Refused: Error {}

    private let tools = Table("tools")
    private let id = SQLite.Expression<Int64>("id")
    private let title = SQLite.Expression<String>("title")

    private func makeConnection() async throws -> SQLiteSearchConnection {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        try await connection.execute([
            "CREATE TABLE tools (id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE)",
            "CREATE TABLE tips (id INTEGER PRIMARY KEY, body TEXT NOT NULL)",
        ])
        return connection
    }

    private func change(_ table: String, _ rowIDs: Set<Int64>) -> SearchDatabaseChange {
        SearchDatabaseChange(table: table, rowIDs: rowIDs)
    }

    // MARK: Commits

    func testEachCommitYieldsOneChangeWithTheRowsItInsertedUpdatedAndDeleted() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools", changeMarker])

        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass'), ('sextant'), ('barometer')"])
        sendMarker(on: connection)
        var received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [1, 2, 3])], "three inserted rows, one commit")

        try await connection.execute([
            "UPDATE tools SET title = 'brass sextant' WHERE id = 2",
            "DELETE FROM tools WHERE id = 3",
            "INSERT INTO tools (id, title) VALUES (10, 'astrolabe')",
        ])
        sendMarker(on: connection)
        received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [2, 3, 10])], "an update, a delete and an insert, one commit")

        // Two commits are two changes, in the order they were made.
        try await connection.execute(["INSERT INTO tools (id, title) VALUES (11, 'quadrant')"])
        try await connection.execute(["DELETE FROM tools WHERE id IN (1, 11)"])
        sendMarker(on: connection)
        received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [11]), change("tools", [1, 11])])
        await connection.close()
    }

    func testACommitIsPublishedWithoutAnyFurtherStatement() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools"])
        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass')"])

        // Nothing else runs on the connection: the commit alone must deliver its change.
        let first = try await nextChange(in: stream)
        XCTAssertEqual(first, change("tools", [1]))
        await connection.close()
    }

    func testOneCommitThatTouchesTwoTablesYieldsOneChangePerTable() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools", "tips", changeMarker])

        try await connection.execute([
            "INSERT INTO tools (title) VALUES ('compass'), ('sextant')",
            "INSERT INTO tips (body) VALUES ('hold it level')",
            "UPDATE tools SET title = 'pocket compass' WHERE id = 1",
        ])
        sendMarker(on: connection)
        let received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tips", [1]), change("tools", [1, 2])])
        await connection.close()
    }

    func testOnlySubscribedTablesAreReported() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools", changeMarker])

        try await connection.execute(["INSERT INTO tips (body) VALUES ('nobody listens to tips')"])
        sendMarker(on: connection)
        var received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [], "a commit that touches no subscribed table yields nothing")

        try await connection.execute([
            "INSERT INTO tips (body) VALUES ('still nobody')",
            "INSERT INTO tools (title) VALUES ('compass')",
            "CREATE TABLE zt_docs (generation INTEGER, data BLOB)",
            "INSERT INTO zt_docs VALUES (1, x'00')",
        ])
        sendMarker(on: connection)
        received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [1])])
        await connection.close()
    }

    func testSubscriptionStartsWithTheStatementsThatFollowIt() async throws {
        let connection = try await makeConnection()
        try await connection.execute(["INSERT INTO tools (title) VALUES ('before')"])
        let stream = connection.changes(in: ["tools", changeMarker])
        try await connection.execute(["INSERT INTO tools (title) VALUES ('after')"])
        sendMarker(on: connection)
        let received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [2])])
        await connection.close()
    }

    // MARK: Rollbacks

    func testRolledBackTransactionsYieldNothing() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools", changeMarker])

        // The body throws after it changed rows.
        do {
            try await connection.write { writer in
                _ = try writer.run("INSERT INTO tools (title) VALUES ('ghost')")
                throw Refused()
            }
            XCTFail("the body's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        // A statement fails after another changed rows.
        do {
            try await connection.execute([
                "INSERT INTO tools (title) VALUES ('twice')",
                "INSERT INTO tools (title) VALUES ('twice')",
            ])
            XCTFail("the UNIQUE constraint must fail the second insert")
        } catch {
            XCTAssertNotNil(error as? SQLite.Result)
        }
        // The host rolls its own transaction back.
        try await connection.withConnection { db in
            try db.execute("BEGIN; INSERT INTO tools (title) VALUES ('phantom'); DELETE FROM tools; ROLLBACK")
        }
        do {
            try await connection.withConnection { db in
                try db.transaction {
                    try db.run("INSERT INTO tools (title) VALUES ('spectre')")
                    throw Refused()
                }
            }
            XCTFail("the transaction's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Refused)
        }

        sendMarker(on: connection)
        var received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [], "a rolled-back transaction yields nothing")
        let count = try await connection.value("SELECT COUNT(*) FROM tools")
        XCTAssertEqual(count, .int(0))

        // The rows a rollback discarded do not leak into the next commit.
        try await connection.execute(["INSERT INTO tools (title) VALUES ('real')"])
        sendMarker(on: connection)
        received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [1])])
        await connection.close()
    }

    // MARK: Subscribers

    func testEverySubscriberGetsItsOwnStream() async throws {
        let connection = try await makeConnection()
        let first = connection.changes(in: ["tools", changeMarker])
        let second = connection.changes(in: ["tools", "tips", changeMarker])
        let third = connection.changes(in: ["tips", changeMarker])
        let subscribers = await connection.subscriberCount()
        XCTAssertEqual(subscribers, 3)

        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass')"])
        try await connection.execute(["INSERT INTO tips (body) VALUES ('hold it level')"])
        sendMarker(on: connection)

        let toFirst = try await changesBeforeMarker(in: first)
        let toSecond = try await changesBeforeMarker(in: second)
        let toThird = try await changesBeforeMarker(in: third)
        XCTAssertEqual(toFirst, [change("tools", [1])])
        XCTAssertEqual(toSecond, [change("tools", [1]), change("tips", [1])])
        XCTAssertEqual(toThird, [change("tips", [1])])
        await connection.close()
    }

    func testDroppingAStreamRemovesItsSubscription() async throws {
        let connection = try await makeConnection()
        do {
            let stream = connection.changes(in: ["tools"])
            let subscribed = await connection.subscriberCount()
            XCTAssertEqual(subscribed, 1)
            _ = stream
        }
        let removed = await eventually { await connection.subscriberCount() == 0 }
        XCTAssertTrue(removed, "a stream nobody references any more gives up its subscription")

        // The connection keeps working, and writing, without subscribers.
        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass')"])
        await connection.close()
    }

    func testCancellingTheConsumerRemovesItsSubscription() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools"])
        let kept = connection.changes(in: ["tools", changeMarker])
        let consumer = Task {
            var seen = 0
            for await _ in stream { seen += 1 }
            return seen
        }
        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass')"])
        let subscribedBoth = await connection.subscriberCount()
        XCTAssertEqual(subscribedBoth, 2)

        consumer.cancel()
        _ = await consumer.value
        let removed = await eventually { await connection.subscriberCount() == 1 }
        XCTAssertTrue(removed, "a cancelled stream gives up its subscription")

        // The other subscriber is untouched.
        try await connection.execute(["INSERT INTO tools (title) VALUES ('sextant')"])
        sendMarker(on: connection)
        let received = try await changesBeforeMarker(in: kept)
        XCTAssertEqual(received, [change("tools", [1]), change("tools", [2])])
        await connection.close()
    }

    // MARK: The host's own statements

    func testHostStatementsThroughWithConnectionAreObserved() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools", changeMarker])
        let (tools, id, title) = (self.tools, self.id, self.title)

        // Outside a transaction every statement commits on its own.
        let rowID = try await connection.withConnection { db in
            try db.run(tools.insert(title <- "compass"))
        }
        XCTAssertEqual(rowID, 1)
        try await connection.withConnection { db in
            try db.run(tools.insert(title <- "sextant"))
            try db.run(tools.filter(id == 1).update(title <- "pocket compass"))
        }
        sendMarker(on: connection)
        var received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [1]), change("tools", [2]), change("tools", [1])])

        // Inside the host's transaction they commit together.
        try await connection.withConnection { db in
            try db.transaction {
                try db.run(tools.insert(title <- "barometer"))
                try db.run(tools.filter(id == 2).delete())
            }
        }
        sendMarker(on: connection)
        received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [2, 3])])

        // A commit made before the body throws still happened.
        do {
            try await connection.withConnection { db in
                try db.run(tools.insert(title <- "astrolabe"))
                throw Refused()
            }
            XCTFail("the body's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        sendMarker(on: connection)
        received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [4])])
        await connection.close()
    }

    // MARK: Names

    func testTableNamesMatchLikeSQLiteMatchesThem() async throws {
        let connection = try await makeConnection()
        // The schema says `tools`; the subscribers spell it their own way.
        let upper = connection.changes(in: ["TOOLS", changeMarker])
        let mixed = connection.changes(in: ["Tools", "tools", changeMarker])

        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass')"])
        sendMarker(on: connection)
        let toUpper = try await changesBeforeMarker(in: upper)
        let toMixed = try await changesBeforeMarker(in: mixed)
        XCTAssertEqual(toUpper, [change("TOOLS", [1])], "a change is reported in the subscriber's spelling")
        XCTAssertEqual(toMixed, [change("Tools", [1]), change("tools", [1])])
        await connection.close()
    }

    // MARK: What SQLite does not report

    func testUnknownChangesReachTheSubscribersOfTheTable() async throws {
        let connection = try await makeConnection()
        let toolsStream = connection.changes(in: ["tools", changeMarker])
        let tipsStream = connection.changes(in: ["tips", changeMarker])
        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass'), ('sextant')"])

        // `DELETE` without `WHERE`: SQLite may empty the table without visiting its rows, in
        // which case the update hook is not called. The host says so itself.
        try await connection.withConnection { db in try db.execute("DELETE FROM tools") }
        connection.reportUnknownChanges(in: ["TOOLS"])
        sendMarker(on: connection)

        let toTools = try await changesBeforeMarker(in: toolsStream)
        let toTips = try await changesBeforeMarker(in: tipsStream)
        XCTAssertEqual(toTools.first, change("tools", [1, 2]))
        XCTAssertEqual(toTools.last, SearchDatabaseChange(table: "tools", rowIDs: nil), "a change without rowids refreshes the table")
        XCTAssertEqual(toTips, [])
        await connection.close()
    }

    func testDeleteWithAWhereClauseReportsEveryRow() async throws {
        let connection = try await makeConnection()
        let stream = connection.changes(in: ["tools", changeMarker])
        try await connection.execute(["INSERT INTO tools (title) VALUES ('compass'), ('sextant'), ('barometer')"])
        try await connection.execute(["DELETE FROM tools WHERE 1"])
        sendMarker(on: connection)
        let received = try await changesBeforeMarker(in: stream)
        XCTAssertEqual(received, [change("tools", [1, 2, 3]), change("tools", [1, 2, 3])])
        await connection.close()
    }
}
