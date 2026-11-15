import Foundation
import SQLite
import XCTest
@testable import ZTronSearchEngine
import ZTronSearchEngineSQLite

/// The targets of specification section 15.9, measured through the adapter against a SQLite
/// file in write-ahead-log mode: the read is SQLite's, not a test double's.
///
/// The budgets are p95 values on the reference device (iPhone 6s). Off that device the test
/// asserts each budget divided by how much slower the device is, 6 for an Apple-silicon Mac:
/// necessary for the gate, not sufficient. In an unoptimized build the numbers mean nothing and
/// the test skips itself:
///
///     swift test -c release -Xswiftc -enable-testing --filter DatabaseTargetsTests
final class DatabaseTargetsTests: XCTestCase {
    private enum AppKind: String, SearchItemKind { case tool }

    private enum AppFilter: SearchFilter {
        case platform(String)
        var key: String { "platform" }
        var value: String { switch self { case .platform(let platform): return platform } }
        init?(key: String, value: String) {
            guard key == "platform" else { return nil }
            self = .platform(value)
        }
    }

    private enum AppSchema: SearchSchema {
        typealias Kind = AppKind
        typealias Filter = AppFilter
    }

    /// Two languages held in memory: what a strings catalog resolves to.
    private struct Strings: LocalizedStringResolving {
        let tables: [String: [String: String]]
        func string(forKey key: String, table: String?, bundle: SearchBundleID, language: String) -> String? { tables[language]?[key] }
        func languages(bundle: SearchBundleID, table: String?) -> [String] { ["en", "it"] }
    }

    /// How much slower one core of the reference device is than one of this machine.
    private var slowdown: Double {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let model = String(decoding: machine.prefix { $0 != 0 }, as: UTF8.self)
        return model == "iPhone8,1" || model == "iPhone8,2" ? 1 : 6
    }

    private func check(_ name: String, _ measured: TimeInterval, budget: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let allowed = budget / slowdown
        print(String(format: "PERF sqlite %@: %.3f ms measured; budget %.0f ms on the reference device, %.3f ms here (%@)",
                     name, measured * 1000, budget * 1000, allowed * 1000, measured <= allowed ? "within" : "OVER"))
        XCTAssertLessThanOrEqual(measured, allowed, name, file: file, line: line)
    }

    private func seconds(_ body: () async throws -> Void) async rethrows -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private static let words = ["map", "mystery", "box", "round", "harbor", "temple", "frozen", "power", "switch", "door", "timer", "guide",
                                "weapon", "shield", "secret", "perk", "survival", "tracker", "damage", "calculator", "layout", "spawn",
                                "beacon", "lantern", "compass", "sextant", "anchor", "relay", "signal", "tower", "bridge", "garden"]

    func testSection159TargetsOverSQLite() async throws {
        #if DEBUG
        throw XCTSkip("budgets are asserted on optimized builds: swift test -c release -Xswiftc -enable-testing --filter DatabaseTargetsTests")
        #else
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var generator = SystemRandomNumberGenerator()
        func text(_ count: Int) -> String {
            (0..<count).map { _ in Self.words.randomElement(using: &generator)! }.joined(separator: " ")
        }

        // 10,000 rows, three string fields, the title a localization key in two languages.
        let tools = Table("tools")
        let id = SQLite.Expression<Int64>("id")
        let titleKey = SQLite.Expression<String>("title_key")
        let body = SQLite.Expression<String>("body")
        let tags = SQLite.Expression<String>("tags")
        let platform = SQLite.Expression<String>("platform")
        var english: [String: String] = [:]
        var italian: [String: String] = [:]
        let database = SQLiteSearchDatabase(options: .init(enablesWAL: true))
        let connection = try await database.connect(.file(directory.file("catalog.sqlite"), readonly: false))
        var rows: [(Int64, String, String, String, String)] = []
        for row in 1...10_000 {
            english["tool.\(row)"] = text(2)
            italian["tool.\(row)"] = text(2)
            rows.append((Int64(row), "tool.\(row)", text(12), text(1) + "," + text(1), row % 2 == 0 ? "ios" : "mac"))
        }
        let prepared = rows
        try await connection.withConnection { db in
            try db.run(tools.create { table in
                table.column(id, primaryKey: true)
                table.column(titleKey)
                table.column(body)
                table.column(tags)
                table.column(platform)
            })
            try db.transaction {
                for row in prepared {
                    try db.run(tools.insert(id <- row.0, titleKey <- row.1, body <- row.2, tags <- row.3, platform <- row.4))
                }
            }
        }
        let source = SearchTableSource<AppSchema>(
            table: tools, id: id, kind: .tool,
            fields: [
                .init(role: .title, expression: titleKey, encoding: .localizedKey(table: nil, bundle: .main)),
                .init(role: .text, expression: body, encoding: .literal(language: "en")),
                .init(role: .keywords, expression: tags, separator: ","),
            ],
            filters: [.init(key: "platform", expression: platform)]
        )
        let resolver = Strings(tables: ["en": english, "it": italian])
        let configuration = SearchEngineConfiguration(
            locale: Locale(identifier: "en"), followsSystemLocale: false, secondaryLanguages: .explicit(["it"]),
            lexicalDebounce: 0, semanticDebounce: 0
        )
        func context(_ storage: SearchIndexStorage) -> SearchContext<AppSchema> {
            SearchContext(id: "tools", sources: [.database(connection, [source])], strategy: .indexed, localizedStrings: resolver, indexStorage: storage)
        }

        // Context creation: 20 pages of 500 rows read, resolved, projected and indexed.
        var created: SearchService<AppSchema>?
        let creation = await seconds {
            let service = SearchService<AppSchema>(context: context(.inMemory), configuration: configuration)
            await service.waitUntilReady()
            created = service
        }
        let service = try XCTUnwrap(created)
        let count = await service.count
        XCTAssertEqual(count, 10_000)
        check("context creation from 10k rows, 3 string fields, 2 languages", creation, budget: 1.5)

        // One page: read, resolve and project 500 rows.
        let languages = await service.resolvedLanguages
        let projector = SearchRowProjector<AppSchema>(source: source, languages: languages, resolver: resolver, reporter: DiagnosticReporter(configuration))
        var pages: [TimeInterval] = []
        for round in 0..<3 {
            for page in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                let (statement, layout) = SearchSQLComposer.select(from: source, limit: 500, offset: page * 500, rowIDs: nil)
                let read: [SearchRow] = try await connection.read { Array(try $0.rows(statement)) }
                var session = SearchRowProjector<AppSchema>.Session()
                let items = read.compactMap { projector.project($0, layout: layout, session: &session)?.item }
                let documents = SearchService<AppSchema>.project(items, languages: languages, reporter: DiagnosticReporter(configuration)).documents
                XCTAssertEqual(documents.count, 500)
                if round > 0 { pages.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
            }
        }
        pages.sort()
        check("one page: read, resolve and project 500 rows (p95)", pages[Int(Double(pages.count) * 0.95)], budget: 0.040)

        // 100 changed rows in one commit, from the commit to searchable.
        var upserts: [TimeInterval] = []
        for round in 0..<40 {
            let marker = "relit\(round)"
            let first = Int64(round * 100 + 1)
            try await connection.withConnection { db in
                try db.run(tools.filter(id >= first && id < first + 100).update(body <- "\(marker) on the north pier"))
            }
            let committed = DispatchTime.now().uptimeNanoseconds
            var applied = false
            while !applied && Double(DispatchTime.now().uptimeNanoseconds - committed) / 1e9 < 5 {
                applied = await service.document(for: SearchableID("tools#\(first + 99)"))?.text.hasPrefix(marker) == true
                if !applied { await Task.yield() }
            }
            XCTAssertTrue(applied)
            upserts.append(Double(DispatchTime.now().uptimeNanoseconds - committed) / 1e9)
        }
        upserts.sort()
        print(String(format: "PERF sqlite 100 changed rows: p50 %.1f ms, worst %.1f ms", upserts[upserts.count / 2] * 1000, (upserts.last ?? 0) * 1000))
        check("incremental upsert of 100 changed rows, after the commit (p95 of 40 commits)", upserts[Int(Double(upserts.count) * 0.95)], budget: 0.050)

        // The index inside the host database: write, then a second service that loads it.
        let persisting = SearchService<AppSchema>(context: context(.database(tablePrefix: "zt_search")), configuration: configuration)
        await persisting.waitUntilReady()
        let write = await seconds { await persisting.persist() }
        check("index round trip inside the host database, 10k documents: write", write, budget: 0.400)
        let load = await seconds {
            let adopting = SearchService<AppSchema>(context: context(.database(tablePrefix: "zt_search")), configuration: configuration)
            await adopting.waitUntilReady()
            let adopted = await adopting.count
            XCTAssertEqual(adopted, 10_000)
        }
        check("index round trip inside the host database, 10k documents: load", load, budget: 0.250)
        await connection.close()
        #endif
    }
}
