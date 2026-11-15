import Foundation
import XCTest
@testable import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// Core's index tables, written and read back through the adapter (specification section 9.2,
/// rule 6): the DDL and DML of `DatabaseIndexStore` run in the adapter's write transaction, and
/// the blobs come back to the byte.
final class IndexStoreTests: XCTestCase {
    private func documents(_ count: Int, generation: Int = 1) -> [SearchDocument] {
        (0..<count).map { index in
            SearchDocument(
                id: SearchableID("doc\(index)"),
                kind: "tool",
                language: "en",
                title: "Instrument \(index) of generation \(generation)",
                text: (0..<40).map { "word\(index &* 31 &+ $0) measures angle \($0) under generation \(generation)" }.joined(separator: " "),
                keywords: ["k\(index % 17)", "shared"]
            )
        }
    }

    private func segment(of documents: [SearchDocument]) throws -> IndexSegment {
        try IndexSegment(data: SegmentBuilder.build([DocumentTokenizer.tokenize(documents)], metadata: IndexMetadata(localeTag: "en")))
    }

    func testIndexIsWrittenAndReadBackThroughTheConnection() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("index.sqlite")
        let connection = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
        let store = DatabaseIndexStore(prefix: "zt_search")

        // Nothing was ever written: the tables do not exist, which reads as "no index".
        let nothing = try await store.load(on: connection)
        XCTAssertNil(nothing)

        // Large enough for several sections to span more than one 256 KiB chunk.
        let written = try segment(of: documents(1_500))
        XCTAssertGreaterThan(written.data.count, 3 * DatabaseIndexStore.chunkSize)
        try await store.save(written, on: connection)

        let chunked = try await connection.value(SearchSQL(template: "SELECT MAX(\"chunk\") FROM \"zt_search_docs\""))
        guard case .int(let highestChunk)? = chunked else { return XCTFail("unexpected \(String(describing: chunked))") }
        XCTAssertGreaterThanOrEqual(highestChunk, 1, "at least one section was cut into chunks")
        let tables = try await connection.allRows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'zt!_search!_%' ESCAPE '!' ORDER BY name")
        XCTAssertEqual(tables, [[.text("zt_search_docs")], [.text("zt_search_meta")], [.text("zt_search_postings")], [.text("zt_search_terms")]])

        let stored = try await store.load(on: connection)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded, written.data, "the segment comes back to the byte")
        let read = try IndexSegment(data: loaded)
        XCTAssertEqual(read.documentCount, 1_500)
        XCTAssertEqual(read.termCount, written.termCount)

        // The same bytes through another connection, after this one is closed.
        await connection.close()
        let reopened = try await SQLiteSearchDatabase().connect(.file(url, readonly: true))
        let reloaded = try await store.load(on: reopened)
        XCTAssertEqual(reloaded, written.data)
        let index = LexicalIndex()
        try await index.adopt(try XCTUnwrap(reloaded), expecting: IndexMetadata(localeTag: "en"))
        let adopted = await index.count
        XCTAssertEqual(adopted, 1_500)
        await reopened.close()
    }

    func testANewGenerationReplacesThePreviousOneAtomically() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        let store = DatabaseIndexStore(prefix: "zt")
        let first = try segment(of: documents(120, generation: 1))
        let second = try segment(of: documents(80, generation: 2))

        try await store.save(first, on: connection)
        let firstGeneration = try await connection.value("SELECT \"value\" FROM \"zt_meta\" WHERE \"key\" = 'generation'")
        XCTAssertEqual(firstGeneration, .int(1))

        try await store.save(second, on: connection)
        let secondGeneration = try await connection.value("SELECT \"value\" FROM \"zt_meta\" WHERE \"key\" = 'generation'")
        XCTAssertEqual(secondGeneration, .int(2))
        for table in ["zt_docs", "zt_terms", "zt_postings"] {
            let generations = try await connection.allRows(SearchSQL(template: "SELECT DISTINCT \"generation\" FROM \"\(table)\""))
            XCTAssertEqual(generations, [[.int(2)]], "\(table) keeps the current generation only")
        }
        let loaded = try await store.load(on: connection)
        XCTAssertEqual(loaded, second.data)
        await connection.close()
    }

    func testAFailedSaveLeavesThePreviousGenerationInPlace() async throws {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        let store = DatabaseIndexStore(prefix: "zt")
        let first = try segment(of: documents(60, generation: 1))
        try await store.save(first, on: connection)

        // The save runs in one write transaction. Make its last step fail: the whole
        // generation must be rolled back with it.
        try await connection.execute([
            "CREATE TRIGGER refuse_retirement BEFORE DELETE ON \"zt_docs\" BEGIN SELECT RAISE(ABORT, 'refused'); END",
        ])
        do {
            try await store.save(try segment(of: documents(90, generation: 2)), on: connection)
            XCTFail("the trigger must fail the save")
        } catch {
            XCTAssertTrue(String(describing: error).contains("refused"), "\(error)")
        }

        let generation = try await connection.value("SELECT \"value\" FROM \"zt_meta\" WHERE \"key\" = 'generation'")
        XCTAssertEqual(generation, .int(1))
        let loaded = try await store.load(on: connection)
        XCTAssertEqual(loaded, first.data, "the previous generation is still the one that loads")
        await connection.close()
    }

    func testAReadOnlyConnectionRefusesToPersistTheIndex() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("readonly.sqlite")
        let writable = try await SQLiteSearchDatabase().connect(.file(url, readonly: false))
        try await writable.execute(["CREATE TABLE tools (id INTEGER PRIMARY KEY)"])
        await writable.close()

        let readOnly = try await SQLiteSearchDatabase().connect(.file(url, readonly: true))
        do {
            try await DatabaseIndexStore(prefix: "zt").save(try segment(of: documents(10)), on: readOnly)
            XCTFail("a read-only connection cannot hold the index")
        } catch {
            XCTAssertEqual(error as? SQLiteSearchError, .readOnlyConnection)
        }
        let nothing = try await DatabaseIndexStore(prefix: "zt").load(on: readOnly)
        XCTAssertNil(nothing)
        await readOnly.close()
    }
}
