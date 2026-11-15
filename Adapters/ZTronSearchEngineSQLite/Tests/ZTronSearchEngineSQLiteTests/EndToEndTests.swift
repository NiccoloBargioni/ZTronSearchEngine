import Foundation
import SQLite
import XCTest
import ZTronSearchEngine
import ZTronSearchEngineSQLite

/// End to end through core's public API: a real SQLite table of 200 rows with literal,
/// localized-key and per-row fields is searched by a `SearchService`, and changes made through
/// the connection reach the results by way of the change stream.
///
/// Only public API of both packages is used here, the way a host would.
final class EndToEndTests: XCTestCase {
    // The host's own table, declared with SQLite.swift.
    private static let tools = Table("tools")
    private static let id = SQLite.Expression<Int64>("id")
    private static let titleKey = SQLite.Expression<String>("title_key")
    private static let summary = SQLite.Expression<String>("summary")
    private static let tags = SQLite.Expression<String?>("tags")
    private static let caption = SQLite.Expression<String?>("caption")
    private static let captionIsKey = SQLite.Expression<Bool>("caption_is_key")
    private static let platform = SQLite.Expression<String>("platform")
    private static let updatedAt = SQLite.Expression<Double?>("updated_at")

    private static let catalog: SearchBundleID = "catalog"
    private static let rowCount = 200

    /// Everything a test needs: the open database with its rows, the resolver over the fixture
    /// strings and the source declared from the typed columns.
    private struct Catalog: Sendable {
        let connection: SQLiteSearchConnection
        let resolver: BundleLocalizedStringResolver
        let source: SearchTableSource<CatalogSchema>
    }

    private func makeCatalog(in directory: TemporaryDirectory, at location: SearchDatabaseLocation = .inMemory, enablesWAL: Bool = false) async throws -> Catalog {
        // Strings: one title per row and one caption, in English (the base) and Italian.
        var english: [String: String] = ["ck0004": "Works offline with a theodolite"]
        var italian: [String: String] = ["ck0004": "Funziona con un teodolite"]
        for row in 1...Self.rowCount {
            english[String(format: "tk%04d", row)] = "Gadget \(row)"
            italian[String(format: "tk%04d", row)] = "Aggeggio \(row)"
        }
        english["tk0017"] = "Brass Sextant"
        italian["tk0017"] = "Sestante di ottone"
        let bundle = try makeStringsBundle(in: directory.url, name: "Catalog", developmentRegion: "en", tables: [
            "en": ["Catalog": english],
            "it": ["Catalog": italian],
        ])
        let resolver = BundleLocalizedStringResolver(bundles: [Self.catalog: bundle])

        let database = SQLiteSearchDatabase(options: .init(enablesWAL: enablesWAL))
        let connection = try await database.connect(location)
        try await connection.write { writer in
            _ = try writer.run("""
                CREATE TABLE tools (
                    id INTEGER PRIMARY KEY, title_key TEXT NOT NULL, summary TEXT NOT NULL, tags TEXT, caption TEXT,
                    caption_is_key INTEGER NOT NULL DEFAULT 0, platform TEXT NOT NULL, updated_at REAL
                )
                """)
            for row in 1...Self.rowCount {
                var summary = "General purpose item number \(row)"
                var tags: SearchBindingValue = row % 2 == 0 ? .text("alpha, beta") : .null
                var caption: SearchBindingValue = .null
                var captionIsKey = false
                var platform = row % 2 == 0 ? "ios" : "mac"
                switch row {
                case 3: caption = .text("Folding periscope included")
                case 4: caption = .text("ck0004"); captionIsKey = true
                case 5: summary = "Antique quadrant for star sightings"
                case 17: platform = "ios,mac"
                case 42: summary = "Calibrated barometer for mountain weather"
                case 99: tags = .text("gyroscope, stabilizer")
                default: break
                }
                _ = try writer.run(SearchSQL(
                    template: """
                    INSERT INTO tools (id, title_key, summary, tags, caption, caption_is_key, platform, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .int(Int64(row)), .text(String(format: "tk%04d", row)), .text(summary), tags, caption,
                        .int(captionIsKey ? 1 : 0), .text(platform), .real(1_700_000_000 + Double(row)),
                    ]
                ))
            }
        }

        let source = SearchTableSource<CatalogSchema>(
            table: Self.tools,
            id: Self.id,
            kind: .tool,
            fields: [
                .init(role: .title, expression: Self.titleKey, encoding: .localizedKey(table: "Catalog", bundle: Self.catalog)),
                .init(role: .text, expression: Self.summary, encoding: .literal(language: "en")),
                .init(role: .keywords, expression: Self.tags, encoding: .literal(language: "en"), separator: ","),
                .init(role: .caption, expression: Self.caption, encoding: .perRow(isKey: Self.captionIsKey, table: "Catalog", bundle: Self.catalog)),
            ],
            filters: [.init(key: "platform", expression: Self.platform, separator: ",")],
            updatedAt: Self.updatedAt
        )
        return Catalog(connection: connection, resolver: resolver, source: source)
    }

    /// The configuration of every service here, with a sink that keeps what the engine reports.
    private func makeConfiguration(locale: String = "en") -> (SearchEngineConfiguration, AsyncStream<SearchDiagnostic>, AsyncStream<SearchDiagnostic>.Continuation) {
        var configuration = SearchEngineConfiguration(
            locale: Locale(identifier: locale), secondaryLanguages: .none, lexicalDebounce: 0, semanticDebounce: 0
        )
        let (diagnostics, sink) = AsyncStream<SearchDiagnostic>.makeStream()
        configuration.diagnostics = { sink.yield($0) }
        return (configuration, diagnostics, sink)
    }

    /// What the engine reported, minus the notes about localization keys without a string.
    private func problems(in diagnostics: AsyncStream<SearchDiagnostic>, _ sink: AsyncStream<SearchDiagnostic>.Continuation) async -> [SearchDiagnostic] {
        sink.finish()
        var problems: [SearchDiagnostic] = []
        for await diagnostic in diagnostics {
            if case .unresolvedLocalizationKey = diagnostic { continue }
            problems.append(diagnostic)
        }
        return problems
    }

    // MARK: Searching rows

    func testServiceSearchesTheRowsOfARealTable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let (configuration, diagnostics, sink) = makeConfiguration()
        let service = SearchService<CatalogSchema>(
            context: SearchContext(
                id: "catalog",
                sources: [.database(catalog.connection, [catalog.source])],
                localizedStrings: catalog.resolver,
                indexStorage: .inMemory
            ),
            configuration: configuration
        )
        await service.waitUntilReady()

        let count = await service.count
        XCTAssertEqual(count, Self.rowCount)
        let scans = await service.usesScanStrategy
        XCTAssertTrue(scans, "200 rows are below the scan threshold")

        // A title that is a localization key in the row: found by its English string.
        let sextant = await finalSnapshot(of: service, for: SearchQuery(text: "sextant"))
        XCTAssertEqual(sextant?.isFinal, true)
        XCTAssertEqual(sextant?.contextID, "catalog")
        XCTAssertEqual(sextant?.hits.map(\.id), ["tools#17"])
        XCTAssertEqual(sextant?.hits.first?.kind, .tool)
        XCTAssertEqual(sextant?.hits.first?.matchedField, .title)

        // A literal text column, a keywords column split on its separator, and the two
        // encodings of the per-row caption.
        let barometer = await finalSnapshot(of: service, for: SearchQuery(text: "barometer"))
        XCTAssertEqual(barometer?.hits.map(\.id), ["tools#42"])
        XCTAssertEqual(barometer?.hits.first?.matchedField, .text)
        let gyroscope = await finalSnapshot(of: service, for: SearchQuery(text: "gyroscope"))
        XCTAssertEqual(gyroscope?.hits.map(\.id), ["tools#99"])
        XCTAssertEqual(gyroscope?.hits.first?.matchedField, .keywords)
        let periscope = await hitIDs(of: service, for: "periscope")
        XCTAssertEqual(periscope, ["tools#3"], "a caption that is the text itself")
        let theodolite = await hitIDs(of: service, for: "theodolite")
        XCTAssertEqual(theodolite, ["tools#4"], "a caption that is a key in this row")

        // The raw keys never enter the index, and neither does a language nobody asked for.
        let titleKey = await hitIDs(of: service, for: "tk0017")
        XCTAssertEqual(titleKey, [])
        let captionKey = await hitIDs(of: service, for: "ck0004")
        XCTAssertEqual(captionKey, [])
        let italian = await hitIDs(of: service, for: "ottone")
        XCTAssertEqual(italian, [], "Italian is not searched by an English context without secondary languages")

        // Typed filters rebuilt from the filter column, multi-valued where the row says so.
        let onIOS = await finalSnapshot(of: service, for: SearchQuery(text: "gadget", filters: [.platform("ios")]))
        let iosRows = try XCTUnwrap(onIOS).hits.compactMap { Int($0.id.rawValue.dropFirst("tools#".count)) }
        XCTAssertEqual(iosRows.count, 20, "a page of hits")
        XCTAssertTrue(iosRows.allSatisfy { $0 % 2 == 0 }, "only the even rows are on iOS: \(iosRows)")
        let sextantOnMac = await finalSnapshot(of: service, for: SearchQuery(text: "sextant", filters: [.platform("mac")]))
        XCTAssertEqual(sextantOnMac?.hits.map(\.id), ["tools#17"], "row 17 is on both platforms")
        let sextantOnTV = await finalSnapshot(of: service, for: SearchQuery(text: "sextant", filters: [.platform("tv")]))
        XCTAssertEqual(sextantOnTV?.hits.map(\.id), [])
        let tips = await finalSnapshot(of: service, for: SearchQuery(text: "sextant", kinds: [.tip]))
        XCTAssertEqual(tips?.hits.map(\.id), [])

        // The projection of a row: every declared column is where it belongs.
        let stored = await service.document(for: "tools#17")
        let document = try XCTUnwrap(stored)
        XCTAssertEqual(document.kind, "tool")
        XCTAssertEqual(document.title, "Brass Sextant")
        XCTAssertEqual(document.text, "General purpose item number 17")
        XCTAssertEqual(Set(document.filters), [FilterRecord(key: "platform", value: "ios"), FilterRecord(key: "platform", value: "mac")])
        XCTAssertEqual(document.updatedAt, Date(timeIntervalSince1970: 1_700_000_017))
        let tagged = await service.document(for: "tools#99")
        XCTAssertEqual(tagged?.keywords, ["gyroscope", "stabilizer"])

        await catalog.connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [], "the engine met no problem reading the database")
    }

    func testContextInAnotherLocaleSearchesTheStringsOfThatLanguage() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let (configuration, diagnostics, sink) = makeConfiguration(locale: "it")
        let service = SearchService<CatalogSchema>(
            context: SearchContext(
                id: "catalogo",
                sources: [.database(catalog.connection, [catalog.source])],
                localizedStrings: catalog.resolver,
                indexStorage: .inMemory
            ),
            configuration: configuration
        )
        await service.waitUntilReady()

        let ottone = await finalSnapshot(of: service, for: SearchQuery(text: "ottone"))
        XCTAssertEqual(ottone?.hits.map(\.id), ["tools#17"])
        XCTAssertEqual(ottone?.hits.first?.matchedField, .title)
        XCTAssertEqual(ottone?.hits.first?.matchedLanguage, "it")
        let document = await service.document(for: "tools#17")
        XCTAssertEqual(document?.title, "Sestante di ottone")
        let aggeggio = await finalSnapshot(of: service, for: SearchQuery(text: "aggeggio"))
        XCTAssertEqual(aggeggio?.hits.count, 20)

        await catalog.connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [])
    }

    // MARK: The change stream

    func testChangesMadeThroughTheConnectionReachTheResults() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let connection = catalog.connection
        let (configuration, diagnostics, sink) = makeConfiguration()
        let service = SearchService<CatalogSchema>(
            context: SearchContext(
                id: "catalog",
                sources: [.database(connection, [catalog.source])],
                localizedStrings: catalog.resolver,
                indexStorage: .inMemory
            ),
            configuration: configuration
        )
        await service.waitUntilReady()
        let quadrant = await hitIDs(of: service, for: "quadrant")
        XCTAssertEqual(quadrant, ["tools#5"])

        // 1. An update in the boundary's write transaction: the row is read again.
        try await connection.write { writer in
            _ = try writer.run("UPDATE tools SET summary = 'Portable astrolabe replica' WHERE id = 5")
        }
        var arrived = await eventually { await hitIDs(of: service, for: "astrolabe") == ["tools#5"] }
        XCTAssertTrue(arrived, "the updated text must become searchable")
        let stale = await hitIDs(of: service, for: "quadrant")
        XCTAssertEqual(stale, [], "the text the row no longer has must stop matching")

        // 2. The host inserts through its own typed statements.
        let (tools, id, titleKey, summary, platform) = (Self.tools, Self.id, Self.titleKey, Self.summary, Self.platform)
        try await connection.withConnection { db in
            try db.run(tools.insert(id <- 201, titleKey <- "tk0201", summary <- "Signal heliograph mirror", platform <- "mac"))
        }
        arrived = await eventually { await hitIDs(of: service, for: "heliograph") == ["tools#201"] }
        XCTAssertTrue(arrived, "the inserted row must become searchable")
        var count = await service.count
        XCTAssertEqual(count, 201)

        // 3. The host deletes.
        try await connection.withConnection { db in
            try db.run(tools.filter(id == 17).delete())
        }
        arrived = await eventually { await hitIDs(of: service, for: "sextant") == [] }
        XCTAssertTrue(arrived, "the deleted row must stop matching")
        count = await service.count
        XCTAssertEqual(count, 200)

        // 4. A rolled-back write changes nothing; the commit after it is applied on its own.
        struct Refused: Error {}
        do {
            try await connection.write { writer in
                _ = try writer.run("UPDATE tools SET summary = 'Unfinished phantasmagoria' WHERE id = 6")
                throw Refused()
            }
            XCTFail("the body's error must reach the caller")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        try await connection.write { writer in
            _ = try writer.run("UPDATE tools SET summary = 'Marine chronometer in gimbals' WHERE id = 7")
        }
        arrived = await eventually { await hitIDs(of: service, for: "chronometer") == ["tools#7"] }
        XCTAssertTrue(arrived)
        let phantom = await hitIDs(of: service, for: "phantasmagoria")
        XCTAssertEqual(phantom, [], "a rolled-back change never reaches the index")

        // 5. Many rows in one commit arrive as one change.
        try await connection.withConnection { db in
            try db.transaction {
                for row in 20...60 {
                    try db.run(tools.filter(id == Int64(row)).update(summary <- "Tethered zeppelin number \(row)"))
                }
            }
        }
        var zeppelins = SearchQuery<CatalogSchema>(text: "zeppelin")
        zeppelins.limit = 100
        let query = zeppelins
        arrived = await eventually { await finalSnapshot(of: service, for: query)?.hits.count == 41 }
        let zeppelinRows = await finalSnapshot(of: service, for: query)?.hits.map(\.id.rawValue).sorted() ?? []
        XCTAssertTrue(arrived, "all 41 rows of the commit must be read again, found \(zeppelinRows.count)")
        XCTAssertEqual(zeppelinRows, (20...60).map { "tools#\($0)" }.sorted())

        // 6. A change SQLite does not report row by row, announced by the host: the table is
        // read again as a whole.
        try await connection.withConnection { db in try db.execute("DELETE FROM tools WHERE id > 100") }
        try await connection.withConnection { db in try db.execute("DELETE FROM tools") }
        connection.reportUnknownChanges(in: ["tools"])
        arrived = await eventually { await service.count == 0 }
        XCTAssertTrue(arrived, "an unknown change must refresh the table")
        let gone = await hitIDs(of: service, for: "chronometer")
        XCTAssertEqual(gone, [])

        await connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [], "the engine met no problem applying the changes")
    }

    func testFilteredTableSourceIsReadAgainAsAWholeWhenItsTableChanges() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let connection = catalog.connection

        // The same source over a table that carries its own filter: a sub-select, which has no
        // rowid, so a change cannot be applied row by row.
        let macOnly = SearchTableSource<CatalogSchema>(
            table: Self.tools.filter(Self.platform == "mac"),
            id: Self.id,
            kind: .tool,
            fields: [
                .init(role: .text, expression: Self.summary, encoding: .literal(language: "en")),
                .init(role: .caption, expression: Self.caption),
            ]
        )
        XCTAssertNil(macOnly.rowID)
        XCTAssertEqual(macOnly.name, "tools")

        let (configuration, diagnostics, sink) = makeConfiguration()
        let service = SearchService<CatalogSchema>(
            context: SearchContext(id: "mac", sources: [.database(connection, [macOnly])], indexStorage: .inMemory),
            configuration: configuration
        )
        await service.waitUntilReady()
        // The odd rows, without row 17, which is on both platforms.
        var count = await service.count
        XCTAssertEqual(count, 99)
        let periscope = await hitIDs(of: service, for: "periscope")
        XCTAssertEqual(periscope, ["tools#3"])

        // A row enters the filter and another leaves it, in one commit.
        try await connection.write { writer in
            _ = try writer.run("UPDATE tools SET platform = 'mac', summary = 'Tethered zeppelin' WHERE id = 2")
            _ = try writer.run("UPDATE tools SET platform = 'ios' WHERE id = 3")
        }
        let entered = await eventually { await hitIDs(of: service, for: "zeppelin") == ["tools#2"] }
        XCTAssertTrue(entered, "a row that now passes the filter must become searchable")
        let left = await eventually { await hitIDs(of: service, for: "periscope") == [] }
        XCTAssertTrue(left, "a row that no longer passes the filter must stop matching")
        count = await service.count
        XCTAssertEqual(count, 99)

        await connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [])
    }

    // MARK: Findings about core
    //
    // Three tests that are expected to fail against the core this adapter was built with. Each
    // one makes a commit land between two page reads of the engine and shows a row of the
    // index going wrong. The adapter delivers every commit made after a subscription, in
    // order; what is missing is on core's side, and each test says where.
    //
    // The expectations are not strict. The outcome depends on the commit landing inside the
    // read, which it does here in all but a starved run, and the tests must turn into plain
    // passing tests the day core is fixed.

    /// Starts watching the statements run on `connection`: the stream yields each time the
    /// engine starts a SELECT on `tools`.
    private func watchPageReads(on connection: SQLiteSearchConnection) async throws -> AsyncStream<Void> {
        let (pages, signal) = AsyncStream<Void>.makeStream()
        try await connection.withConnection { db in
            db.trace { sql in
                if sql.hasPrefix("SELECT"), sql.contains("FROM \"tools\"") { signal.yield() }
            }
        }
        return pages
    }

    /// Returns once the engine has started to read `tools`: its first page is being read, the
    /// others are still to come.
    private func waitForFirstPage(in pages: AsyncStream<Void>, on connection: SQLiteSearchConnection) async throws {
        let started = await firstElement(of: pages) != nil
        try await connection.withConnection { db in db.trace(nil) }
        try XCTSkipUnless(started, "the engine did not read the table, so there is nothing to interleave a commit with")
    }

    private func makePagedService(over catalog: Catalog) -> (SearchService<CatalogSchema>, AsyncStream<SearchDiagnostic>, AsyncStream<SearchDiagnostic>.Continuation) {
        var (configuration, diagnostics, sink) = makeConfiguration()
        // Five reads for the 200 rows, so a commit has room to land between two of them.
        configuration.databasePageSize = 50
        let service = SearchService<CatalogSchema>(
            context: SearchContext(
                id: "catalog",
                sources: [.database(catalog.connection, [catalog.source])],
                localizedStrings: catalog.resolver,
                indexStorage: .inMemory
            ),
            configuration: configuration
        )
        return (service, diagnostics, sink)
    }

    /// A change committed while a context is still loading its rows reaches the index.
    ///
    /// The service subscribes to `changes(in:)` before its first read, so a commit that lands
    /// after a page was read is not lost: the table is read again once the load is in.
    func testAChangeCommittedWhileAContextLoadsReachesTheIndex() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let connection = catalog.connection
        let pages = try await watchPageReads(on: connection)
        let (service, diagnostics, sink) = makePagedService(over: catalog)

        // Row 1 is on the first page. Change it once that page was read: four reads follow.
        try await waitForFirstPage(in: pages, on: connection)
        try await connection.write { writer in
            _ = try writer.run("UPDATE tools SET summary = 'Tethered zeppelin' WHERE id = 1")
        }
        await service.waitUntilReady()

        let arrived = await eventually(timeout: 1) { await hitIDs(of: service, for: "zeppelin") == ["tools#1"] }
        XCTAssertTrue(arrived, "a commit made during the load must reach the index")

        // The row is there and readable: reading the sources again finds it.
        await service.refresh()
        let refreshed = await hitIDs(of: service, for: "zeppelin")
        XCTAssertEqual(refreshed, ["tools#1"])

        await connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [])
    }

    /// A change committed while a service reads its sources again (`refresh()`, a locale
    /// change) survives the rebuild.
    ///
    /// Changes are applied one at a time and never in the middle of a rebuild, and a table
    /// that changed while it was being read page by page is read again, so the rebuild cannot
    /// install the row as an earlier page saw it.
    func testAChangeCommittedDuringARefreshSurvivesIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let connection = catalog.connection
        let (service, diagnostics, sink) = makePagedService(over: catalog)
        await service.waitUntilReady()

        let pages = try await watchPageReads(on: connection)
        async let refresh: Void = service.refresh()
        try await waitForFirstPage(in: pages, on: connection)
        try await connection.write { writer in
            _ = try writer.run("UPDATE tools SET summary = 'Tethered zeppelin' WHERE id = 1")
        }
        await refresh

        let arrived = await eventually(timeout: 1) { await hitIDs(of: service, for: "zeppelin") == ["tools#1"] }
        XCTAssertTrue(arrived, "a commit made during a refresh must survive it")

        await service.refresh()
        let refreshed = await hitIDs(of: service, for: "zeppelin")
        XCTAssertEqual(refreshed, ["tools#1"])

        await connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [])
    }

    /// A row moved across a page boundary by a concurrent delete is not lost.
    ///
    /// The engine reads a table with `LIMIT n OFFSET m`, one transaction per page (section 9.2,
    /// rules 1 and 2). A commit that deletes a row of a page already read moves every later row
    /// up by one, so the next page starts one row too far. The change stream reports the commit
    /// while the table is being read, and the engine reads the table again.
    func testARowIsNotSkippedWhenAnEarlierRowIsDeletedBetweenTwoPages() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory)
        let connection = catalog.connection
        let pages = try await watchPageReads(on: connection)
        let (service, diagnostics, sink) = makePagedService(over: catalog)

        // Rows 1 to 50 are the first page. Without row 10, `OFFSET 50` starts at row 52.
        try await waitForFirstPage(in: pages, on: connection)
        try await connection.write { writer in
            _ = try writer.run("DELETE FROM tools WHERE id = 10")
        }
        await service.waitUntilReady()

        let settled = await eventually(timeout: 1) { await service.document(for: "tools#51") != nil }
        XCTAssertTrue(settled, "row 51 was never deleted and must be in the index")
        let deleted = await service.document(for: "tools#10")
        XCTAssertNil(deleted, "the deleted row is gone from the index")

        await service.refresh()
        let present = await service.document(for: "tools#51")
        XCTAssertNotNil(present)
        let count = await service.count
        XCTAssertEqual(count, Self.rowCount - 1)

        await connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [])
    }

    // MARK: The index inside the host database

    func testIndexPersistsInsideTheHostDatabaseAndIsAdoptedByTheNextService() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let catalog = try await makeCatalog(in: directory, at: .file(directory.file("catalog.sqlite"), readonly: false), enablesWAL: true)
        let connection = catalog.connection
        let (configuration, diagnostics, sink) = makeConfiguration()
        let context = SearchContext<CatalogSchema>(
            id: "catalog",
            sources: [.database(connection, [catalog.source])],
            strategy: .indexed,
            localizedStrings: catalog.resolver,
            indexStorage: .database(tablePrefix: "zt_search")
        )

        // The first service builds the index from the rows and persists it through the
        // boundary's write transaction, next to the data.
        do {
            let service = SearchService<CatalogSchema>(context: context, configuration: configuration)
            await service.waitUntilReady()
            let scans = await service.usesScanStrategy
            XCTAssertFalse(scans)
            let sextant = await hitIDs(of: service, for: "sextant")
            XCTAssertEqual(sextant, ["tools#17"])

            // An incremental change on the indexed strategy, then the index is written again.
            try await connection.write { writer in
                _ = try writer.run("UPDATE tools SET summary = 'Portable astrolabe replica' WHERE id = 5")
            }
            let arrived = await eventually { await hitIDs(of: service, for: "astrolabe") == ["tools#5"] }
            XCTAssertTrue(arrived)
            await service.persist()
        }
        let released = await waitUntilUnsubscribed(connection)
        XCTAssertTrue(released, "a service that is gone gives up its change stream")

        let generation = try await connection.read { try $0.scalar("SELECT \"value\" FROM \"zt_search_meta\" WHERE \"key\" = 'generation'") }
        guard case .int(let persisted)? = generation else { return XCTFail("no generation was written: \(String(describing: generation))") }
        XCTAssertGreaterThanOrEqual(persisted, 2, "once after the build, once after the change")
        let sections = try await connection.read { reader in
            try reader.scalar(SearchSQL(template: "SELECT COUNT(*) FROM \"zt_search_docs\" WHERE \"generation\" = ?", bindings: [.int(persisted)]))
        }
        guard case .int(let sectionCount)? = sections else { return XCTFail("unexpected \(String(describing: sections))") }
        XCTAssertGreaterThan(sectionCount, 0)

        // Take the rows away while nobody listens. A service that still finds them can only
        // have them from the index it loaded out of the database.
        try await connection.withConnection { db in try db.execute("DELETE FROM tools WHERE 1") }
        let adopting = SearchService<CatalogSchema>(context: context, configuration: configuration)
        await adopting.waitUntilReady()
        let adoptedCount = await adopting.count
        XCTAssertEqual(adoptedCount, Self.rowCount)
        let fromIndex = await hitIDs(of: adopting, for: "astrolabe")
        XCTAssertEqual(fromIndex, ["tools#5"], "the adopted index holds the state that was persisted")
        let sextant = await hitIDs(of: adopting, for: "sextant")
        XCTAssertEqual(sextant, ["tools#17"])

        // The first change after an adoption makes the service read its table: one row is left.
        let (tools, id, titleKey, summary, platform) = (Self.tools, Self.id, Self.titleKey, Self.summary, Self.platform)
        try await connection.withConnection { db in
            try db.run(tools.insert(id <- 500, titleKey <- "tk0001", summary <- "Lone heliograph mirror", platform <- "mac"))
        }
        let reread = await eventually { await adopting.count == 1 }
        XCTAssertTrue(reread, "the table is read again on the first change")
        let heliograph = await hitIDs(of: adopting, for: "heliograph")
        XCTAssertEqual(heliograph, ["tools#500"])

        await connection.close()
        let reported = await problems(in: diagnostics, sink)
        XCTAssertEqual(reported, [], "the engine met no problem persisting or loading its index")
    }
}
