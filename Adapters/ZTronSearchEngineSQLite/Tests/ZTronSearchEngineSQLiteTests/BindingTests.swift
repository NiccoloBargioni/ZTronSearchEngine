import Foundation
import SQLite
import SQLite3
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// Bindings: every `SearchBindingValue` case goes into SQLite and comes back unchanged; `run`
/// reports the rows it changed; a statement with the wrong number of bindings throws.
final class BindingTests: XCTestCase {
    // MARK: Round trips

    private let samples: [SearchBindingValue] = [
        .null,
        .int(0), .int(-1), .int(42), .int(.max), .int(.min),
        .real(0), .real(-0.5), .real(.pi), .real(1e300), .real(-Double.greatestFiniteMagnitude), .real(.leastNonzeroMagnitude),
        .real(.infinity), .real(3),
        .text(""), .text("plain"), .text("it's \"quoted\" ? :name"), .text("città, 東京, 🧭 and e\u{301}"),
        .text(String(repeating: "long ", count: 20_000)),
        .blob(Data()), .blob(Data([0])), .blob(Data([0, 255, 0, 1, 2, 0])), .blob(Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
    ]

    func testEveryValueRoundTripsThroughAStatement() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        for sample in samples {
            let statement = SearchSQL(template: "SELECT ?", bindings: [sample])
            let scalar = try await connection.value(statement)
            XCTAssertEqual(scalar, sample, "scalar of \(describe(sample))")
            let rows = try await connection.allRows(statement)
            XCTAssertEqual(rows, [[sample]], "row of \(describe(sample))")
        }

        // All of them in one row, in order.
        let placeholders = samples.map { _ in "?" }.joined(separator: ", ")
        let row = try await connection.allRows(SearchSQL(template: "SELECT \(placeholders)", bindings: samples))
        XCTAssertEqual(row, [samples.map(Optional.some)])
        await connection.close()
    }

    func testEveryValueRoundTripsThroughATable() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        // A column without a declared type keeps the storage class of what is stored in it.
        try await connection.execute(["CREATE TABLE samples (position INTEGER PRIMARY KEY, value)"])
        let samples = self.samples
        try await connection.write { writer in
            for (position, sample) in samples.enumerated() {
                let changed = try writer.run(SearchSQL(
                    template: "INSERT INTO samples (position, value) VALUES (?, ?)", bindings: [.int(Int64(position)), sample]
                ))
                XCTAssertEqual(changed, 1)
            }
        }
        let stored = try await connection.allRows("SELECT value FROM samples ORDER BY position")
        XCTAssertEqual(stored, samples.map { [$0] })

        let types = try await connection.allRows("SELECT DISTINCT typeof(value) FROM samples ORDER BY 1")
        XCTAssertEqual(types, [[.text("blob")], [.text("integer")], [.text("null")], [.text("real")], [.text("text")]])
        await connection.close()
    }

    func testNullIsNeverConfusedWithAMissingRow() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        let null = try await connection.value("SELECT NULL")
        XCTAssertEqual(null, .some(.null), "a NULL value is `.null`")
        let nothing = try await connection.value("SELECT 1 WHERE 0")
        XCTAssertNil(nothing, "a statement without rows has no scalar")
        let rows = try await connection.allRows("SELECT NULL, 1, NULL")
        XCTAssertEqual(rows, [[.null, .int(1), .null]])
        await connection.close()
    }

    func testConversionsWithSQLiteSwiftBindings() {
        XCTAssertEqual(SearchBindingValue(nil), .null)
        XCTAssertEqual(SearchBindingValue(Int64(-7)), .int(-7))
        XCTAssertEqual(SearchBindingValue(2.5), .real(2.5))
        XCTAssertEqual(SearchBindingValue("text"), .text("text"))
        XCTAssertEqual(SearchBindingValue(Blob(bytes: [1, 2, 3])), .blob(Data([1, 2, 3])))
        // SQLite.swift stores `Int` and `Bool` as integers.
        XCTAssertEqual(SearchBindingValue(7), .int(7))
        XCTAssertEqual(SearchBindingValue(true), .int(1))
        XCTAssertEqual(SearchBindingValue(false), .int(0))

        XCTAssertNil(SearchBindingValue.null.sqliteBinding)
        XCTAssertEqual(SearchBindingValue.int(9).sqliteBinding as? Int64, 9)
        XCTAssertEqual(SearchBindingValue.real(0.25).sqliteBinding as? Double, 0.25)
        XCTAssertEqual(SearchBindingValue.text("t").sqliteBinding as? String, "t")
        XCTAssertEqual(SearchBindingValue.blob(Data([9, 8])).sqliteBinding as? Blob, Blob(bytes: [9, 8]))

        for sample in samples {
            XCTAssertEqual(SearchBindingValue(sample.sqliteBinding), sample, describe(sample))
        }
    }

    // MARK: Rows changed

    func testRunReturnsTheRowsTheStatementChanged() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        let counts: [Int] = try await connection.write { writer in
            var counts: [Int] = []
            counts.append(try writer.run("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"))
            counts.append(try writer.run("INSERT INTO notes (body) VALUES ('a'), ('b'), ('c')"))
            counts.append(try writer.run(SearchSQL(template: "UPDATE notes SET body = ? WHERE id >= ?", bindings: [.text("z"), .int(2)])))
            // A statement that changes nothing reports nothing, whatever ran before it.
            counts.append(try writer.run("UPDATE notes SET body = 'never' WHERE id > 99"))
            counts.append(try writer.run("CREATE TABLE other (id INTEGER PRIMARY KEY)"))
            counts.append(try writer.run("SELECT * FROM notes"))
            counts.append(try writer.run("DELETE FROM notes WHERE id = 1"))
            counts.append(try writer.run("INSERT OR REPLACE INTO notes (id, body) VALUES (2, 'replaced')"))
            counts.append(try writer.run("DELETE FROM notes"))
            return counts
        }
        XCTAssertEqual(counts, [0, 3, 2, 0, 0, 0, 1, 1, 2])
        await connection.close()
    }

    // MARK: Binding counts

    func testWrongNumberOfBindingsThrowsInsteadOfTrapping() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        try await connection.execute(["CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"])

        let cases: [(SearchSQL, expected: Int)] = [
            (SearchSQL(template: "SELECT ?, ?", bindings: [.int(1)]), 2),
            (SearchSQL(template: "SELECT ?", bindings: [.int(1), .int(2)]), 1),
            (SearchSQL(template: "SELECT ?"), 1),
            (SearchSQL(template: "SELECT 1", bindings: [.text("stray")]), 0),
            (SearchSQL(template: "SELECT '?' || ?", bindings: []), 1),
            (SearchSQL(template: "SELECT :a, :a, :b", bindings: [.int(1)]), 2),
        ]
        for (statement, expected) in cases {
            let outcomes: [Swift.Result<Bool, any Error>] = [
                await capture { try await connection.read { _ = try $0.rows(statement); return true } },
                await capture { try await connection.read { _ = try $0.scalar(statement); return true } },
                await capture { try await connection.write { _ = try $0.run(statement); return true } },
            ]
            for outcome in outcomes {
                guard case .failure(let error) = outcome else {
                    XCTFail("\(statement.template) with \(statement.bindings.count) binding(s) must throw")
                    continue
                }
                XCTAssertEqual(
                    error as? SQLiteSearchError,
                    .bindingCountMismatch(expected: expected, provided: statement.bindings.count, statement: statement.template)
                )
            }
        }

        // Named and numbered parameters bind by position, as SQLite numbers them.
        let named = try await connection.allRows(SearchSQL(template: "SELECT :a, :b, :a", bindings: [.text("a"), .text("b")]))
        XCTAssertEqual(named, [[.text("a"), .text("b"), .text("a")]])
        let numbered = try await connection.allRows(SearchSQL(template: "SELECT ?2, ?1", bindings: [.int(1), .int(2)]))
        XCTAssertEqual(numbered, [[.int(2), .int(1)]])
        await connection.close()
    }

    func testTextWithoutAStatementThrowsInsteadOfTrapping() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        for text in ["", "   ", "-- only a comment", "/* nothing */ ;"] {
            let statement = SearchSQL(template: text)
            let outcomes: [Swift.Result<Bool, any Error>] = [
                await capture { try await connection.read { _ = try $0.rows(statement); return true } },
                await capture { try await connection.read { _ = try $0.scalar(statement); return true } },
                await capture { try await connection.write { _ = try $0.run(statement); return true } },
            ]
            for outcome in outcomes {
                guard case .failure(let error) = outcome else {
                    XCTFail("'\(text)' holds no statement and must throw")
                    continue
                }
                XCTAssertNotNil(error as? SQLite.Result, "SQLite's own error passes through: \(error)")
            }
        }
        // The connection is none the worse for it.
        let one = try await connection.value("SELECT 1")
        XCTAssertEqual(one, .int(1))
        await connection.close()
    }

    private func capture(_ work: @Sendable () async throws -> Bool) async -> Swift.Result<Bool, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// The adapter counts the parameters of a statement itself (SQLite.swift does not expose
    /// the number). This holds the count against SQLite's own, statement by statement.
    func testParameterCountAgreesWithSQLite() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE tools (id INTEGER PRIMARY KEY, title TEXT, "we""ird ?" TEXT, [bra?cket] TEXT, `tick?` TEXT, a$b TEXT, "naïve" TEXT);
            CREATE TABLE "zt_meta" ("key" TEXT PRIMARY KEY NOT NULL, "value" BLOB);
            """, nil, nil, nil), SQLITE_OK)

        let statements = [
            "SELECT 1",
            "SELECT ?",
            "SELECT ?, ?, ?",
            "SELECT ?1, ?1, ?2",
            "SELECT ?3",
            "SELECT ?3, ?",
            "SELECT ?, ?1",
            "SELECT ?2, ?, ?1",
            "SELECT ?010, ?10",
            "SELECT :a, :b, :a",
            "SELECT @a, :a, $a, @a",
            "SELECT $1, $2, $1",
            "SELECT :1, ?1, :1",
            "SELECT ?5, :a, ?",
            "SELECT :a, ?5",
            "SELECT $ns::name, $ns::name, $array(index), $array(other)",
            "SELECT $a$b, $a",
            "SELECT '?', '?''?', ?",
            "SELECT \"we\"\"ird ?\", [bra?cket], `tick?`, ? FROM tools",
            "SELECT a$b, :a$b, \"naïve\", ? FROM tools",
            "SELECT x'3F3F', X'3f', ?",
            "SELECT 1 -- ? :a\n, ?",
            "SELECT 1 /* ? :a */, ? /* unterminated ?",
            "SELECT 1 - -?, 1--?\n, ?",
            "SELECT 7 / ?, 7 /? , 7/ ?",
            "SELECT title -> ?, title ->> '$.a' FROM tools",
            "SELECT ?; SELECT ?, ?",
            ";;  ; SELECT ?, ?; SELECT ?",
            "  \t\n SELECT ?",
            "SELECT 'città ?', ?, 'é' || ? || '東京'",
            "SELECT * FROM tools WHERE id IN (?, ?, ?) AND title LIKE ? ESCAPE '\\' LIMIT ? OFFSET ?",
            "SELECT 1e5, 0x1F, 1.5e-3, .5, ?",
            "INSERT INTO tools (id, title) VALUES (:id, :title) ON CONFLICT (id) DO UPDATE SET title = :title",
            "UPDATE tools SET title = ?2 WHERE id = ?1",
            "DELETE FROM tools WHERE id = ? OR title = ? -- trailing",
            "SELECT \"value\" FROM \"zt_meta\" WHERE \"key\" = ?",
            "INSERT OR REPLACE INTO \"zt_meta\" (\"key\", \"value\") VALUES (?, ?)",
            "SELECT \"id\", \"title\" FROM (SELECT * FROM \"tools\" WHERE (\"title\" = ?)) AS \"tools\" WHERE (\"id\" > ?) AND (\"id\" IN (?, ?)) LIMIT 500 OFFSET 0",
            "SELECT \"id\", rowid, \"title\" FROM \"tools\" WHERE (\"id\" > ?) AND (rowid IN (?, ?)) LIMIT 500 OFFSET 0",
            "WITH RECURSIVE c(n) AS (SELECT ? UNION ALL SELECT n + 1 FROM c WHERE n < ?) SELECT n FROM c",
            "SELECT CASE WHEN ? THEN :yes ELSE :no END, CAST (? AS TEXT)",
        ]
        for sql in statements {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK, "SQLite refused: \(sql): \(String(cString: sqlite3_errmsg(handle)))")
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(
                SQLParameterCounter.parameterCount(in: sql), Int(sqlite3_bind_parameter_count(statement)),
                "parameters of: \(sql)"
            )
        }
    }

    func testParameterCountOfTextSQLiteWouldRefuseDoesNotTrap() {
        // The counter only ever sees text SQLite compiled, but it must be safe on anything.
        for sql in ["", "?", "'unterminated ?", "\"unterminated ?", "[unterminated ?", "/* unterminated ?", ":", "$", "@(", "$a(", "?99999999999999999999999999", "--", "/", "-"] {
            XCTAssertGreaterThanOrEqual(SQLParameterCounter.parameterCount(in: sql), 0, sql)
        }
        XCTAssertEqual(SQLParameterCounter.parameterCount(in: "'unterminated ?"), 0)
        XCTAssertEqual(SQLParameterCounter.parameterCount(in: "?"), 1)
    }

    private func describe(_ value: SearchBindingValue) -> String {
        switch value {
        case .text(let text) where text.count > 40: return "text of \(text.count) characters"
        case .blob(let data) where data.count > 40: return "blob of \(data.count) bytes"
        default: return String(describing: value)
        }
    }
}
