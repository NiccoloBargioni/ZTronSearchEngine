import Foundation
import SQLite
import XCTest
@testable import ZTronSearchEngine
@testable import ZTronSearchEngineSQLite

/// Rendering of SQLite.swift expressions and tables to the fragments core composes
/// (specification section 9.2, rules 1 and 8), and the composed SELECT run against real data.
final class ExpressionRenderingTests: XCTestCase {
    private let tools = Table("tools")
    private let id = SQLite.Expression<Int64>("id")
    private let title = SQLite.Expression<String>("title")
    private let subtitle = SQLite.Expression<String?>("subtitle")
    private let price = SQLite.Expression<Double>("price")
    private let isPublished = SQLite.Expression<Bool>("is_published")
    private let isFeatured = SQLite.Expression<Bool?>("is_featured")
    private let platform = SQLite.Expression<String?>("platform")
    private let updatedAt = SQLite.Expression<Double?>("updated_at")

    // MARK: Expressions

    func testStringExpressionsRenderAsQuotedIdentifiers() {
        XCTAssertEqual(SearchSQL(title), SearchSQL(template: "\"title\""))
        XCTAssertEqual(SearchSQL(subtitle), SearchSQL(template: "\"subtitle\""))
        XCTAssertEqual(SearchSQL(tools[title]), SearchSQL(template: "\"tools\".\"title\""))
        XCTAssertEqual(SearchSQL(SQLite.Expression<String>("we\"ird name")), SearchSQL(template: "\"we\"\"ird name\""))
        // The same quoting core applies to an identifier of its own.
        XCTAssertEqual(SearchSQL(title), SearchSQL.identifier("title"))
        XCTAssertEqual(SearchSQL(tools[title]), SearchSQL.column("title", in: "tools"))
    }

    func testTemplatesAndBindingsPassThroughUntouched() {
        let coalesced: SQLite.Expression<String> = subtitle ?? "none"
        XCTAssertEqual(SearchSQL(coalesced), SearchSQL(template: "ifnull(\"subtitle\", ?)", bindings: [.text("none")]))
        XCTAssertEqual(SearchSQL(title.lowercaseString), SearchSQL(template: "lower(\"title\")"))
        XCTAssertEqual(SearchSQL(price > 10.5), SearchSQL(template: "(\"price\" > ?)", bindings: [.real(10.5)]))
        XCTAssertEqual(SearchSQL(id == 7), SearchSQL(template: "(\"id\" = ?)", bindings: [.int(7)]))
        XCTAssertEqual(SearchSQL(isPublished == true), SearchSQL(template: "(\"is_published\" = ?)", bindings: [.int(1)]))
        XCTAssertEqual(SearchSQL(subtitle == nil), SearchSQL(template: "(\"subtitle\" IS ?)", bindings: [.null]))
        XCTAssertEqual(
            SearchSQL(isPublished && title != "it's"),
            SearchSQL(template: "(\"is_published\" AND (\"title\" != ?))", bindings: [.text("it's")])
        )
        XCTAssertEqual(
            SearchSQL([3, 5, 8].contains(id)),
            SearchSQL(template: "(\"id\" IN (?, ?, ?))", bindings: [.int(3), .int(5), .int(8)])
        )
        XCTAssertEqual(
            SearchSQL(SQLite.Expression<Data>("payload") == Data([0, 1, 255])),
            SearchSQL(template: "(\"payload\" = ?)", bindings: [.blob(Data([0, 1, 255]))])
        )

        // A template written by hand, with the three kinds of value SQLite.swift accepts beside
        // its own storage types: `Int`, `Bool` and a missing value.
        let raw = SQLite.Expression<Bool>("\"price\" BETWEEN ? AND ? OR ? OR \"subtitle\" IS ?", [1, 2.5, true, nil])
        XCTAssertEqual(
            SearchSQL(raw),
            SearchSQL(template: "\"price\" BETWEEN ? AND ? OR ? OR \"subtitle\" IS ?", bindings: [.int(1), .real(2.5), .int(1), .null])
        )

        // Whatever SQLite.swift rendered is what core receives.
        let expressions: [any ExpressionType] = [title, subtitle, coalesced, price > 10.5, title.lowercaseString, raw, tools[*]]
        for expression in expressions {
            let fragment = SearchSQL(expression)
            XCTAssertEqual(fragment.template, expression.template)
            XCTAssertEqual(fragment.bindings, expression.bindings.map { SearchBindingValue($0) })
        }
    }

    func testOtherExpressiblesRenderTheirExpression() {
        XCTAssertEqual(SearchSQL(expressible: "plain"), SearchSQL(template: "?", bindings: [.text("plain")]))
        XCTAssertEqual(SearchSQL(expressible: 42), SearchSQL(template: "?", bindings: [.int(42)]))
        XCTAssertEqual(SearchSQL(expressible: 1.5), SearchSQL(template: "?", bindings: [.real(1.5)]))
        XCTAssertEqual(SearchSQL(expressible: title), SearchSQL(title))
        // A query is its SELECT statement here; `init(table:)` is what names a table.
        XCTAssertEqual(
            SearchSQL(expressible: tools.select(title).filter(id == 1)),
            SearchSQL(template: "SELECT \"title\" FROM \"tools\" WHERE (\"id\" = ?)", bindings: [.int(1)])
        )
    }

    // MARK: Tables

    func testTablesWithoutClausesRenderAsTheirQuotedName() {
        XCTAssertEqual(SearchSQL(table: tools), SearchSQL(template: "\"tools\""))
        XCTAssertEqual(SearchSQL(table: Table("tools", database: "catalog")), SearchSQL(template: "\"catalog\".\"tools\""))
        XCTAssertEqual(SearchSQL(table: tools.alias("t")), SearchSQL(template: "\"tools\" AS \"t\""))
        XCTAssertEqual(SearchSQL(table: Table("we\"ird.name")), SearchSQL(template: "\"we\"\"ird.name\""))
        XCTAssertEqual(SearchSQL(table: View("published_tools")), SearchSQL(template: "\"published_tools\""))
        XCTAssertEqual(SearchSQL(table: VirtualTable("tool_index")), SearchSQL(template: "\"tool_index\""))

        // The name is the table's own, unquoted, whatever qualifies or renames it.
        for table in [tools, Table("tools", database: "catalog"), tools.alias("t")] {
            let rendering = SQLiteTableRendering(table)
            XCTAssertEqual(rendering.name, "tools")
            XCTAssertFalse(rendering.isSubselect)
        }
        XCTAssertEqual(SQLiteTableRendering(Table("we\"ird.name")).name, "we\"ird.name")
        // Core derives the same name from the rendered fragment.
        XCTAssertEqual(SearchTableSource<CatalogSchema>.derivedName(from: SearchSQL(table: tools)), "tools")
    }

    func testTablesWithClausesRenderAsSubselects() {
        let filtered = tools.filter(isPublished && price > 10)
        XCTAssertEqual(
            SearchSQL(table: filtered),
            SearchSQL(
                template: "(SELECT * FROM \"tools\" WHERE (\"is_published\" AND (\"price\" > ?))) AS \"tools\"",
                bindings: [.real(10)]
            )
        )
        XCTAssertEqual(
            SearchSQL(table: tools.alias("t").filter(price > 10)),
            SearchSQL(template: "(SELECT * FROM \"tools\" AS \"t\" WHERE (\"price\" > ?)) AS \"t\"", bindings: [.real(10)])
        )
        XCTAssertEqual(
            SearchSQL(table: Table("tools", database: "catalog").filter(id == 1)),
            SearchSQL(template: "(SELECT * FROM \"catalog\".\"tools\" WHERE (\"id\" = ?)) AS \"tools\"", bindings: [.int(1)])
        )
        XCTAssertEqual(
            SearchSQL(table: tools.select(id, title)),
            SearchSQL(template: "(SELECT \"id\", \"title\" FROM \"tools\") AS \"tools\"")
        )
        XCTAssertEqual(
            SearchSQL(table: tools.order(title).limit(5)),
            SearchSQL(template: "(SELECT * FROM \"tools\" ORDER BY \"title\" LIMIT 5) AS \"tools\"")
        )

        XCTAssertEqual(
            SearchSQL(table: tools.filter(isPublished)),
            SearchSQL(template: "(SELECT * FROM \"tools\" WHERE \"is_published\") AS \"tools\"")
        )

        let queries: [Table] = [filtered, tools.alias("t").filter(price > 10), tools.select(id, title), tools.order(title).limit(5)]
        for query in queries {
            let rendering = SQLiteTableRendering(query)
            XCTAssertEqual(rendering.name, "tools", rendering.from.template)
            XCTAssertTrue(rendering.isSubselect, rendering.from.template)
            // The sub-select is the table's own SELECT, to the letter.
            XCTAssertTrue(rendering.from.template.hasPrefix("(" + query.expression.template + ") AS "))
            XCTAssertEqual(rendering.from.bindings, query.expression.bindings.map { SearchBindingValue($0) })
        }
    }

    // MARK: Sources

    func testSourceIsDeclaredFromTypedColumns() {
        let source = SearchTableSource<CatalogSchema>(
            table: tools,
            id: id,
            kind: .tool,
            fields: [
                .init(role: .title, expression: title, encoding: .localizedKey(table: "Catalog", bundle: "fixture")),
                .init(role: .text, expression: subtitle, encoding: .literal(language: "en")),
                .init(role: .keywords, expression: platform, separator: ","),
                .init(role: .caption, expression: subtitle, encoding: .perRow(isKey: isPublished, table: nil, bundle: .main)),
                .init(role: .ocrText, expression: title, encoding: .perRow(isKey: isFeatured, table: "Catalog", bundle: "fixture")),
            ],
            filters: [.init(key: "platform", expression: platform, separator: ","), .init(key: "price", expression: price)],
            predicate: isPublished && price > 10,
            updatedAt: updatedAt
        )

        XCTAssertEqual(source.table, SearchSQL(template: "\"tools\""))
        XCTAssertEqual(source.name, "tools")
        XCTAssertEqual(source.id, SearchSQL(template: "\"id\""))
        XCTAssertEqual(source.kind, .tool)
        XCTAssertEqual(source.fields, [
            SearchStringField(role: .title, expression: "\"title\"", encoding: .localizedKey(table: "Catalog", bundle: "fixture")),
            SearchStringField(role: .text, expression: "\"subtitle\"", encoding: .literal(language: "en")),
            SearchStringField(role: .keywords, expression: "\"platform\"", encoding: .literal(language: nil), separator: ","),
            SearchStringField(role: .caption, expression: "\"subtitle\"", encoding: .perRow(isKey: "\"is_published\"", table: nil, bundle: .main)),
            SearchStringField(role: .ocrText, expression: "\"title\"", encoding: .perRow(isKey: "\"is_featured\"", table: "Catalog", bundle: "fixture")),
        ])
        XCTAssertEqual(source.filters, [
            SearchFilterColumn(key: "platform", expression: "\"platform\"", separator: ","),
            SearchFilterColumn(key: "price", expression: "\"price\""),
        ])
        XCTAssertEqual(source.predicate, SearchSQL(template: "(\"is_published\" AND (\"price\" > ?))", bindings: [.real(10)]))
        XCTAssertEqual(source.updatedAt, SearchSQL(template: "\"updated_at\""))
        XCTAssertEqual(source.identity, .tablePrefixed)
        XCTAssertEqual(source.rowID, SearchSQL(template: "rowid"), "a table rendered by name is read row by row")
    }

    func testSourceKnowsWhereARowIDExists() {
        func source<T: SchemaType>(_ table: T, name: String? = nil, rowID: SQLiteRowID = .automatic) -> SearchTableSource<CatalogSchema> {
            SearchTableSource(table: table, name: name, id: id, kind: .tool, fields: [.init(role: .title, expression: title)], rowID: rowID)
        }

        XCTAssertEqual(source(tools).rowID, SearchSQL(template: "rowid"))
        XCTAssertEqual(source(tools.alias("t")).rowID, SearchSQL(template: "rowid"))
        XCTAssertEqual(source(VirtualTable("tool_index")).rowID, SearchSQL(template: "rowid"))
        // A sub-select and a view have none: a change reads the source again as a whole.
        XCTAssertNil(source(tools.filter(isPublished)).rowID)
        XCTAssertNil(source(View("published_tools")).rowID)
        XCTAssertNil(source(tools, rowID: .unavailable).rowID)
        XCTAssertEqual(source(tools.select(SQLite.Expression<Int64>(literal: "rowid AS rid"), tools[*]), rowID: .expression("rid")).rowID, SearchSQL(template: "rid"))

        // A filtered table still refreshes with its table, and still names its rows after it.
        XCTAssertEqual(source(tools.filter(isPublished)).name, "tools")
        XCTAssertEqual(source(tools.alias("t")).name, "tools")
        XCTAssertEqual(source(tools, name: "items").name, "items")

        // A condition that may be NULL is a predicate like any other.
        let nullable = SearchTableSource<CatalogSchema>(
            table: tools, id: id, kind: .tip, fields: [.init(role: .text, expression: subtitle)], predicate: isFeatured
        )
        XCTAssertEqual(nullable.predicate, SearchSQL(template: "\"is_featured\""))
        XCTAssertEqual(nullable.kind, .tip)
        let unconditional = SearchTableSource<CatalogSchema>(table: tools, id: id, kind: .tool, fields: [])
        XCTAssertNil(unconditional.predicate)
        XCTAssertNil(unconditional.updatedAt)
    }

    // MARK: Composition with core

    private func makeCatalog() async throws -> SQLiteSearchConnection {
        let connection = try await SQLiteSearchDatabase().connect(.inMemory)
        try await connection.execute([
            """
            CREATE TABLE tools (id INTEGER PRIMARY KEY, title TEXT NOT NULL, subtitle TEXT, price REAL NOT NULL,
            is_published INTEGER NOT NULL, platform TEXT, updated_at REAL)
            """,
            """
            INSERT INTO tools (id, title, subtitle, price, is_published, platform, updated_at) VALUES
            (1, 'Compass', 'Finds north', 12.5, 1, 'ios', 1700000000.5),
            (2, 'Sextant', NULL, 99.0, 1, 'ios,mac', 1700000100.0),
            (3, 'Barometer', 'Weather', 5.0, 1, 'mac', NULL),
            (4, 'Astrolabe', 'Stars', 250.0, 0, 'mac', 1700000200.0),
            (5, 'Quadrant', 'Angles', 40.0, 1, NULL, 1700000300.0)
            """,
        ])
        return connection
    }

    func testComposedSelectOfATypedSourceRunsAgainstRealData() async throws {
        let connection = try await makeCatalog()
        let source = SearchTableSource<CatalogSchema>(
            table: tools,
            id: id,
            kind: .tool,
            fields: [.init(role: .title, expression: title), .init(role: .text, expression: subtitle)],
            filters: [.init(key: "platform", expression: platform, separator: ",")],
            predicate: isPublished && price > 10,
            updatedAt: updatedAt
        )

        let (statement, layout) = SearchSQLComposer.select(from: source, limit: 500, offset: 0)
        XCTAssertEqual(statement, SearchSQL(
            template: """
            SELECT "id", rowid, "title", "subtitle", "platform", "updated_at" FROM "tools" \
            WHERE ("is_published" AND ("price" > ?)) LIMIT 500 OFFSET 0
            """,
            bindings: [.real(10)]
        ))
        XCTAssertEqual(layout.id, 0)
        XCTAssertEqual(layout.rowID, 1)
        XCTAssertEqual(layout.fields.map(\.value), [2, 3])
        XCTAssertEqual(layout.filters, [4])
        XCTAssertEqual(layout.updatedAt, 5)

        let rows = try await connection.allRows(statement)
        XCTAssertEqual(rows, [
            [.int(1), .int(1), .text("Compass"), .text("Finds north"), .text("ios"), .real(1_700_000_000.5)],
            [.int(2), .int(2), .text("Sextant"), .null, .text("ios,mac"), .real(1_700_000_100)],
            [.int(5), .int(5), .text("Quadrant"), .text("Angles"), .null, .real(1_700_000_300)],
        ])

        // Paging, and the re-read of changed rows by rowid.
        let secondPage = SearchSQLComposer.select(from: source, limit: 2, offset: 2).statement
        let paged = try await connection.allRows(secondPage)
        XCTAssertEqual(paged.map { $0[0] }, [.int(5)])
        let changed = SearchSQLComposer.select(from: source, limit: 500, offset: 0, rowIDs: [2, 4, 5]).statement
        XCTAssertEqual(changed.bindings, [.real(10), .int(2), .int(4), .int(5)])
        let reread = try await connection.allRows(changed)
        XCTAssertEqual(reread.map { $0[0] }, [.int(2), .int(5)], "row 4 is not published, so it does not come back")
        await connection.close()
    }

    func testComposedSelectOfAFilteredTableKeepsEveryBindingInItsPlace() async throws {
        let connection = try await makeCatalog()
        // Bindings in the column list, in the sub-select and in the predicate: they have to
        // reach SQLite in the order their placeholders appear.
        let source = SearchTableSource<CatalogSchema>(
            table: tools.filter(price > 10),
            id: tools[id],
            kind: .tool,
            fields: [.init(role: .title, expression: tools[title]), .init(role: .text, expression: subtitle ?? "none")],
            predicate: title != "Sextant"
        )
        XCTAssertNil(source.rowID)

        let (statement, layout) = SearchSQLComposer.select(from: source, limit: 500, offset: 0)
        XCTAssertEqual(statement, SearchSQL(
            template: """
            SELECT "tools"."id", "tools"."title", ifnull("subtitle", ?) FROM (SELECT * FROM "tools" WHERE ("price" > ?)) AS "tools" \
            WHERE ("title" != ?) LIMIT 500 OFFSET 0
            """,
            bindings: [.text("none"), .real(10), .text("Sextant")]
        ))
        XCTAssertNil(layout.rowID)

        let rows = try await connection.allRows(statement)
        XCTAssertEqual(rows, [
            [.int(1), .text("Compass"), .text("Finds north")],
            [.int(4), .text("Astrolabe"), .text("Stars")],
            [.int(5), .text("Quadrant"), .text("Angles")],
        ])
        await connection.close()
    }

    func testComposedSelectOfAViewAndOfAliasedTablesRunAgainstRealData() async throws {
        let connection = try await makeCatalog()
        try await connection.execute(["CREATE VIEW published_tools AS SELECT * FROM tools WHERE is_published"])

        // A view has no rowid: the source is declared without one and the SELECT asks for none.
        let view = SearchTableSource<CatalogSchema>(
            table: View("published_tools"), id: id, kind: .tool, fields: [.init(role: .title, expression: title)]
        )
        let fromView = SearchSQLComposer.select(from: view, limit: 500, offset: 0).statement
        XCTAssertEqual(fromView, SearchSQL(template: "SELECT \"id\", \"title\" FROM \"published_tools\" LIMIT 500 OFFSET 0"))
        let published = try await connection.allRows(fromView)
        XCTAssertEqual(published.map { $0[0] }, [.int(1), .int(2), .int(3), .int(5)])

        // An aliased table is still a table: it keeps its rowid, and its columns go by the alias.
        let t = tools.alias("t")
        let aliased = SearchTableSource<CatalogSchema>(
            table: t, id: t[id], kind: .tool, fields: [.init(role: .title, expression: t[title])], predicate: t[price] < 50
        )
        let fromAlias = SearchSQLComposer.select(from: aliased, limit: 500, offset: 0, rowIDs: [1, 2, 3]).statement
        XCTAssertEqual(fromAlias, SearchSQL(
            template: """
            SELECT "t"."id", rowid, "t"."title" FROM "tools" AS "t" WHERE (("t"."price" < ?)) AND (rowid IN (?, ?, ?)) LIMIT 500 OFFSET 0
            """,
            bindings: [.real(50), .int(1), .int(2), .int(3)]
        ))
        let cheap = try await connection.allRows(fromAlias)
        XCTAssertEqual(cheap, [[.int(1), .int(1), .text("Compass")], [.int(3), .int(3), .text("Barometer")]])

        // An aliased table with a filter is a sub-select under the alias.
        let filtered = SearchTableSource<CatalogSchema>(
            table: t.filter(price < 50), id: t[id], kind: .tool, fields: [.init(role: .title, expression: t[title])]
        )
        XCTAssertEqual(filtered.name, "tools")
        let fromFiltered = SearchSQLComposer.select(from: filtered, limit: 500, offset: 0).statement
        XCTAssertEqual(fromFiltered, SearchSQL(
            template: """
            SELECT "t"."id", "t"."title" FROM (SELECT * FROM "tools" AS "t" WHERE ("price" < ?)) AS "t" LIMIT 500 OFFSET 0
            """,
            bindings: [.real(50)]
        ))
        let underAlias = try await connection.allRows(fromFiltered)
        XCTAssertEqual(underAlias.map { $0[1] }, [.text("Compass"), .text("Barometer"), .text("Quadrant")])
        await connection.close()
    }

    func testComposedSelectReadsThroughCoreInPages() async throws {
        let connection = try await makeCatalog()
        let source = SearchTableSource<CatalogSchema>(
            table: tools, id: id, kind: .tool, fields: [.init(role: .title, expression: title)]
        )
        // Core's own page reader, on the real connection: five rows in pages of two.
        var pages: [[SearchBindingValue?]] = []
        try await SearchRowReader.forEachPage(of: source, on: connection, pageSize: 2) { rows, layout in
            pages.append(rows.map { $0.values[layout.fields[0].value] })
        }
        XCTAssertEqual(pages, [[.text("Compass"), .text("Sextant")], [.text("Barometer"), .text("Astrolabe")], [.text("Quadrant")]])
        await connection.close()
    }
}
