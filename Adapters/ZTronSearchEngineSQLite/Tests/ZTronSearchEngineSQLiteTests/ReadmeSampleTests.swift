import Foundation
import SQLite
import XCTest
import ZTronSearchEngine
import ZTronSearchEngineSQLite

/// The host wiring sample of the README, compiled and run. If this file has to change, so does
/// the README.
final class ReadmeSampleTests: XCTestCase {
    private enum AppKind: String, SearchItemKind {
        case tool
    }

    private enum AppFilter: SearchFilter {
        case platform(String)

        var key: String { "platform" }

        var value: String {
            switch self { case .platform(let platform): return platform }
        }

        init?(key: String, value: String) {
            guard key == "platform" else { return nil }
            self = .platform(value)
        }
    }

    private enum AppSchema: SearchSchema {
        typealias Kind = AppKind
        typealias Filter = AppFilter
    }

    func testHostWiringSample() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let databaseURL = directory.file("app.sqlite")
        // The sample resolves from `Bundle.main`; the test puts a strings bundle in its place.
        let strings = try makeStringsBundle(in: directory.url, developmentRegion: "en", tables: [
            "en": ["Catalog": ["tool.17": "Brass Sextant", "tool.18": "Pocket Compass", "tool.19": "Hidden Astrolabe"]],
            "it": ["Catalog": ["tool.17": "Sestante di ottone", "tool.18": "Bussola tascabile"]],
        ])

        // 1. The host's schema.
        let tools = Table("tools")
        let id = SQLite.Expression<Int64>("id")
        let titleKey = SQLite.Expression<String>("title_key")
        let summary = SQLite.Expression<String>("summary")
        let tags = SQLite.Expression<String?>("tags")
        let platform = SQLite.Expression<String>("platform")
        let isPublished = SQLite.Expression<Bool>("is_published")
        let updatedAt = SQLite.Expression<Date?>("updated_at")

        // 2. Open the database through the adapter.
        let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))
        let connection = try await database.connect(.file(databaseURL, readonly: false))

        // The host creates and fills its table with its own statements.
        try await connection.withConnection { db in
            try db.run(tools.create { table in
                table.column(id, primaryKey: true)
                table.column(titleKey)
                table.column(summary)
                table.column(tags)
                table.column(platform)
                table.column(isPublished, defaultValue: true)
                table.column(updatedAt)
            })
            try db.run(tools.insert(
                id <- 17, titleKey <- "tool.17", summary <- "Measures the angle between two visible objects",
                tags <- "navigation, brass", platform <- "ios,mac", updatedAt <- Date(timeIntervalSince1970: 1_700_000_000)
            ))
            try db.run(tools.insert(id <- 18, titleKey <- "tool.18", summary <- "Points north", platform <- "ios"))
            try db.run(tools.insert(id <- 19, titleKey <- "tool.19", summary <- "Not released yet", platform <- "mac", isPublished <- false))
        }

        // 3. Say what to search, from the typed columns.
        let source = SearchTableSource<AppSchema>(
            table: tools,
            id: id,
            kind: .tool,
            fields: [
                .init(role: .title, expression: titleKey, encoding: .localizedKey(table: "Catalog", bundle: .main)),
                .init(role: .text, expression: summary, encoding: .literal(language: "en")),
                .init(role: .keywords, expression: tags, separator: ","),
            ],
            filters: [.init(key: "platform", expression: platform, separator: ",")],
            predicate: isPublished,
            updatedAt: updatedAt
        )

        // 4. One context and its service.
        let context = SearchContext<AppSchema>(
            id: "catalog",
            sources: [.database(connection, [source])],
            localizedStrings: BundleLocalizedStringResolver(bundles: [.main: strings]),
            indexStorage: .database(tablePrefix: "zt_search")
        )
        let service = SearchService<AppSchema>(
            context: context,
            configuration: SearchEngineConfiguration(locale: Locale(identifier: "en"), secondaryLanguages: .none, lexicalDebounce: 0, semanticDebounce: 0)
        )
        await service.waitUntilReady()

        var hits: [SearchableID] = []
        for await snapshot in await service.results(for: SearchQuery(text: "sextant"), trigger: .submit) {
            hits = snapshot.hits.map(\.id)
        }
        XCTAssertEqual(hits, ["tools#17"])
        let count = await service.count
        XCTAssertEqual(count, 2, "the unpublished row is left out by the predicate")
        let document = await service.document(for: "tools#17")
        XCTAssertEqual(document?.title, "Brass Sextant")
        XCTAssertEqual(document?.keywords, ["navigation", "brass"])
        XCTAssertEqual(document?.updatedAt, Date(timeIntervalSince1970: 1_700_000_000), "a `Date` column is read the way SQLite.swift stores it")
        let onMac = await finalSnapshot(of: service, for: SearchQuery(text: "north", filters: [.platform("mac")]))
        XCTAssertEqual(onMac?.hits.map(\.id), [])

        // 5. The host writes through the same connection, so the engine hears about it.
        try await connection.withConnection { db in
            try db.run(tools.filter(id == 17).update(summary <- "Brass sextant with its case"))
        }
        let arrived = await eventually { await hitIDs(of: service, for: "case") == ["tools#17"] }
        XCTAssertTrue(arrived)

        await connection.close()
    }
}
