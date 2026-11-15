import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, "Database sources (section 9.2)": an in-memory fake of the boundary and a fake
/// resolver, no SQLite.
final class DatabaseSourceTests: XCTestCase {
    // MARK: Fixtures

    private static let toolColumns = ["id", "title", "body", "tags", "platform", "category", "hidden", "updated"]

    /// Tools: every string a literal, tagged English.
    private func toolsSource(predicate: SearchSQL? = nil) -> SearchTableSource<CatalogSchema> {
        SearchTableSource(
            table: .identifier("tools"),
            id: .column("id"),
            kind: .tool,
            fields: [
                SearchStringField(role: .title, expression: .column("title"), encoding: .literal(language: "en")),
                SearchStringField(role: .text, expression: .column("body"), encoding: .literal(language: "en")),
                SearchStringField(role: .keywords, expression: .column("tags"), encoding: .literal(language: "en"), separator: ","),
            ],
            filters: [
                SearchFilterColumn(key: "platform", expression: .column("platform"), separator: ","),
                SearchFilterColumn(key: "category", expression: .column("category")),
            ],
            predicate: predicate,
            updatedAt: .column("updated")
        )
    }

    /// Maps: the title is a key in a strings catalog, the body a literal.
    private func mapsSource() -> SearchTableSource<CatalogSchema> {
        SearchTableSource(
            table: .identifier("maps"),
            id: .column("slug"),
            kind: .map,
            fields: [
                SearchStringField(role: .title, expression: .column("title_key"), encoding: .localizedKey(table: "Maps", bundle: .main)),
                SearchStringField(role: .text, expression: .column("body"), encoding: .literal(language: "en")),
            ]
        )
    }

    private let resolver = FakeLocalizedStringResolver(
        languageOrder: ["en", "it", "ja"],
        strings: [
            "en": ["map.harbor": "Frozen Harbor", "map.temple": "Sunken Temple", "map.base-only": "Quiet Meadow", "tip.note": "Keep moving"],
            "it": ["map.harbor": "Porto Ghiacciato", "map.temple": "Tempio Sommerso"],
            "ja": ["map.harbor": "凍った港"],
        ],
        table: "Maps"
    )

    private func toolRow(_ id: Int, _ title: String, _ body: String, tags: String = "", platform: String = "ios", category: String = "trackers") -> [String: SearchBindingValue] {
        ["id": .int(Int64(id)), "title": .text(title), "body": .text(body), "tags": .text(tags), "platform": .text(platform),
         "category": .text(category), "hidden": .int(0), "updated": .int(1_799_000_000 + Int64(id))]
    }

    private func seededConnection() async -> FakeSearchDatabaseConnection {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("tools", columns: Self.toolColumns)
        await connection.createTable("maps", columns: ["slug", "title_key", "body"])
        await connection.insert(into: "tools", rows: [
            toolRow(1, "Mystery Box Tracker", "Track every mystery box location.", tags: "box, tracker"),
            toolRow(2, "Round Timer", "A timer for high rounds.", tags: "timer", platform: "mac"),
            toolRow(3, "Damage Calculator", "Compute weapon damage per round.", tags: "calculator,damage", platform: "ios,mac", category: "calculators"),
        ])
        await connection.insert(into: "maps", rows: [
            ["slug": .text("harbor"), "title_key": .text("map.harbor"), "body": .text("Layout of the harbor with every door.")],
            ["slug": .text("temple"), "title_key": .text("map.temple"), "body": .text("The temple layout and its box.")],
        ])
        await connection.resetLog()
        return connection
    }

    private func service(
        _ connection: FakeSearchDatabaseConnection,
        tables: [SearchTableSource<CatalogSchema>],
        memory: [AnySearchable<CatalogKind>] = [],
        id: SearchContextID = "db",
        strategy: SearchStrategy = .automatic,
        storage: SearchIndexStorage = .inMemory,
        configuration: SearchEngineConfiguration = TestSupport.configuration()
    ) async -> CatalogService {
        var sources: [SearchSource<CatalogSchema>] = []
        if !memory.isEmpty { sources.append(.memory(memory)) }
        sources.append(.database(connection, tables))
        let subscribers = await connection.subscriberCount()
        let service = CatalogService(
            context: SearchContext(id: id, sources: sources, strategy: strategy, localizedStrings: resolver, indexStorage: storage),
            configuration: configuration
        )
        await service.waitUntilReady()
        // The fake registers a subscription on its own actor; wait until it is in.
        _ = await eventually { await connection.subscriberCount() == subscribers + 1 }
        return service
    }

    // MARK: SQL composition

    func testSQLCompositionSnapshots() {
        // The one shape: SELECT <id>, <fields> FROM <table> WHERE <predicate> LIMIT 500 OFFSET n.
        let plain = SearchSQLComposer.select(from: toolsSource(), limit: 500, offset: 0)
        XCTAssertEqual(
            plain.statement.template,
            "SELECT \"id\", rowid, \"title\", \"body\", \"tags\", \"platform\", \"category\", \"updated\" FROM \"tools\" LIMIT 500 OFFSET 0"
        )
        XCTAssertEqual(plain.statement.bindings, [])
        XCTAssertEqual(plain.layout.id, 0)
        XCTAssertEqual(plain.layout.rowID, 1)
        XCTAssertEqual(plain.layout.fields.map(\.value), [2, 3, 4])
        XCTAssertEqual(plain.layout.filters, [5, 6])
        XCTAssertEqual(plain.layout.updatedAt, 7)

        // Predicate and paging; the predicate's binding passes through untouched.
        let predicate = SearchSQL(template: "\"hidden\" = ?", bindings: [.int(0)])
        let paged = SearchSQLComposer.select(from: toolsSource(predicate: predicate), limit: 500, offset: 1_500)
        XCTAssertEqual(
            paged.statement.template,
            "SELECT \"id\", rowid, \"title\", \"body\", \"tags\", \"platform\", \"category\", \"updated\" FROM \"tools\" WHERE \"hidden\" = ? LIMIT 500 OFFSET 1500"
        )
        XCTAssertEqual(paged.statement.bindings, [.int(0)])

        // Changed rowids: the same shape with the predicate extended.
        let changed = SearchSQLComposer.select(from: toolsSource(predicate: predicate), limit: 500, offset: 0, rowIDs: [3, 9])
        XCTAssertTrue(changed.statement.template.hasSuffix("FROM \"tools\" WHERE (\"hidden\" = ?) AND (rowid IN (?, ?)) LIMIT 500 OFFSET 0"))
        XCTAssertEqual(changed.statement.bindings, [.int(0), .int(3), .int(9)])
    }

    func testIdentifiersAreQuotedAndBindingsKeepStatementOrder() {
        XCTAssertEqual(SearchSQL.identifier("tools").template, "\"tools\"")
        XCTAssertEqual(SearchSQL.identifier("my \"odd\" table").template, "\"my \"\"odd\"\" table\"")
        XCTAssertEqual(SearchSQL.column("title", in: "tools").template, "\"tools\".\"title\"")

        // Every fragment carries a binding: they must come out in the order the fragments appear.
        let source = SearchTableSource<CatalogSchema>(
            table: SearchSQL(template: "(SELECT * FROM \"tools\" WHERE \"tier\" = ?)", bindings: [.text("table")]),
            name: "tools",
            id: SearchSQL(template: "\"id\" || ?", bindings: [.text("id")]),
            kind: .tool,
            fields: [
                SearchStringField(role: .title, expression: SearchSQL(template: "coalesce(\"title\", ?)", bindings: [.text("title")])),
                SearchStringField(
                    role: .text, expression: SearchSQL(template: "\"body\"", bindings: []),
                    encoding: .perRow(isKey: SearchSQL(template: "\"is_key\" = ?", bindings: [.int(1)]), table: nil, bundle: .main)
                ),
            ],
            filters: [SearchFilterColumn(key: "platform", expression: SearchSQL(template: "lower(?)", bindings: [.text("filter")]))],
            predicate: SearchSQL(template: "\"hidden\" = ? AND \"score\" > ?", bindings: [.int(0), .real(1.5)]),
            updatedAt: SearchSQL(template: "\"updated\" + ?", bindings: [.blob(Data([1, 2]))]),
            rowID: nil
        )
        let composed = SearchSQLComposer.select(from: source, limit: 500, offset: 0)
        XCTAssertEqual(
            composed.statement.template,
            "SELECT \"id\" || ?, coalesce(\"title\", ?), \"body\", \"is_key\" = ?, lower(?), \"updated\" + ? "
                + "FROM (SELECT * FROM \"tools\" WHERE \"tier\" = ?) WHERE \"hidden\" = ? AND \"score\" > ? LIMIT 500 OFFSET 0"
        )
        XCTAssertEqual(composed.statement.bindings, [
            .text("id"), .text("title"), .int(1), .text("filter"), .blob(Data([1, 2])), .text("table"), .int(0), .real(1.5),
        ])
        XCTAssertNil(composed.layout.rowID)
        XCTAssertEqual(composed.layout.fields.map(\.isKey), [nil, 3])
        // The default table name is derived from a plain identifier.
        XCTAssertEqual(toolsSource().name, "tools")
        XCTAssertEqual(SearchTableSource<CatalogSchema>(table: "legacy_items", id: "id", kind: .tool, fields: []).name, "legacy_items")
    }

    func testCoreOnlyEverRunsTheOneSelectShapeAgainstHostTables() async {
        let connection = await seededConnection()
        let service = await service(connection, tables: [toolsSource(), mapsSource()])
        await connection.insert(into: "tools", toolRow(4, "Shield Planner", "Plan shield parts."))
        _ = await eventually { TestSupport.ids(await TestSupport.final(service, "shield")) == ["tools#4"] }
        await service.refresh()

        let statements = await connection.statements()
        XCTAssertFalse(statements.isEmpty)
        for statement in statements {
            XCTAssertFalse(statement.isWrite, "core never writes to host tables: \(statement.sql.template)")
            XCTAssertTrue(statement.sql.template.hasPrefix("SELECT "), statement.sql.template)
            XCTAssertTrue(statement.sql.template.contains(" LIMIT 500 OFFSET "), statement.sql.template)
        }
    }

    // MARK: Paging

    func testPagedReadsUseOneReadTransactionPerPage() async {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("tools", columns: Self.toolColumns)
        await connection.insert(into: "tools", rows: (1...1_234).map { toolRow($0, "Tool \($0)", "Body \($0)") })
        await connection.resetLog()
        let service = await service(connection, tables: [toolsSource()])
        let count = await service.count
        XCTAssertEqual(count, 1_234)

        let statements = await connection.statements()
        // 1,234 rows in pages of 500: three pages.
        XCTAssertEqual(statements.map { $0.sql.template.components(separatedBy: " LIMIT ").last }, ["500 OFFSET 0", "500 OFFSET 500", "500 OFFSET 1000"])
        XCTAssertEqual(Set(statements.map(\.transaction)).count, 3, "each page is read inside its own read transaction")
        let indexed = await service.usesScanStrategy
        XCTAssertFalse(indexed, "above 500 documents the context is indexed")
    }

    func testAPageIsAConsistentSnapshot() async {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("tools", columns: Self.toolColumns)
        await connection.insert(into: "tools", rows: (1...40).map { toolRow($0, "Tool \($0)", "Body") })
        // A slow read: the host deletes rows while the page is being read.
        await connection.setReadDelay(nanoseconds: 80_000_000)
        let source = toolsSource()
        let rows: [SearchRow]? = try? await withThrowingTaskGroup(of: [SearchRow]?.self) { group in
            group.addTask {
                var collected: [SearchRow] = []
                try await SearchRowReader.forEachPage(of: source, on: connection, pageSize: 500) { page, _ in
                    collected.append(contentsOf: page)
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000)
                await connection.delete(from: "tools", rowIDs: Set(1...30))
                return nil
            }
            var result: [SearchRow]?
            for try await value in group { result = value ?? result }
            return result
        }
        XCTAssertEqual(rows?.count, 40, "the page sees the table as it was when its transaction began")
    }

    func testCancellationBetweenPages() async {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("tools", columns: Self.toolColumns)
        await connection.insert(into: "tools", rows: (1...2_600).map { toolRow($0, "Tool \($0)", "Body") })
        await connection.resetLog()
        await connection.setReadDelay(nanoseconds: 40_000_000)

        let source = toolsSource()
        let task = Task { () -> (pages: Int, cancelled: Bool) in
            var pages = 0
            do {
                try await SearchRowReader.forEachPage(of: source, on: connection, pageSize: 500) { _, _ in pages += 1 }
                return (pages, false)
            } catch is CancellationError {
                return (pages, true)
            } catch {
                return (pages, false)
            }
        }
        _ = await eventually { await connection.statements().count >= 2 }
        task.cancel()
        let outcome = await task.value
        XCTAssertTrue(outcome.cancelled)
        XCTAssertLessThan(outcome.pages, 6, "reading stops between pages")
        let statements = await connection.statements().count
        XCTAssertLessThan(statements, 6)
    }

    // MARK: Projection

    func testLiteralLocalizedKeyAndPerRowFieldsInOneRow() async {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("notes", columns: ["id", "title_key", "body", "caption", "caption_is_key"])
        await connection.insert(into: "notes", rows: [
            ["id": .int(1), "title_key": .text("map.harbor"), "body": .text("Literal body in English."), "caption": .text("tip.note"), "caption_is_key": .int(1)],
            ["id": .int(2), "title_key": .text("map.temple"), "body": .text("Another body."), "caption": .text("A literal caption"), "caption_is_key": .int(0)],
        ])
        let source = SearchTableSource<CatalogSchema>(
            table: .identifier("notes"), id: .column("id"), kind: .tip,
            fields: [
                SearchStringField(role: .title, expression: .column("title_key"), encoding: .localizedKey(table: "Maps", bundle: .main)),
                SearchStringField(role: .text, expression: .column("body"), encoding: .literal(language: "en")),
                SearchStringField(role: .caption, expression: .column("caption"), encoding: .perRow(isKey: .column("caption_is_key"), table: "Maps", bundle: .main)),
            ]
        )
        let service = await service(connection, tables: [source], configuration: TestSupport.configuration(locale: "it", secondary: .explicit(["ja"])))

        let first = await service.document(for: "notes#1")
        // The key is resolved for the active locale; the literal keeps its declared language.
        XCTAssertEqual(first?.title, "Porto Ghiacciato")
        XCTAssertEqual(first?.languages.title, "it")
        XCTAssertEqual(first?.text, "Literal body in English.")
        XCTAssertEqual(first?.languages.text, "en")
        // Per row: this row's caption is a key, resolved; it has no Italian string, so the base stands.
        XCTAssertEqual(first?.caption, "Keep moving")
        // The other preferred languages and the shadowed base feed localizedAlt.
        XCTAssertEqual(first?.localizedAlt, ["Frozen Harbor", "凍った港"])
        XCTAssertEqual(first?.languages.localizedAlt, ["en", "ja"])

        let second = await service.document(for: "notes#2")
        XCTAssertEqual(second?.title, "Tempio Sommerso")
        XCTAssertEqual(second?.caption, "A literal caption", "this row's caption is the text itself")
        XCTAssertEqual(second?.kind, "tip")
    }

    func testLocalizedKeysFollowTheFallbackChain() async {
        let connection = await seededConnection()
        await connection.insert(into: "maps", ["slug": .text("meadow"), "title_key": .text("map.base-only"), "body": .text("A meadow.")])
        for (locale, harbor, temple, meadow) in [
            ("it_IT", "Porto Ghiacciato", "Tempio Sommerso", "Quiet Meadow"),   // language match, then base
            ("ja", "凍った港", "Sunken Temple", "Quiet Meadow"),                  // exact for one, base for the rest
            ("fr", "Frozen Harbor", "Sunken Temple", "Quiet Meadow"),            // nothing matches: base
        ] {
            let service = await service(connection, tables: [mapsSource()], configuration: TestSupport.configuration(locale: locale))
            let titles = await [service.document(for: "maps#harbor")?.title, service.document(for: "maps#temple")?.title, service.document(for: "maps#meadow")?.title]
            XCTAssertEqual(titles, [harbor, temple, meadow], locale)
        }
        let italian = await service(connection, tables: [mapsSource()], configuration: TestSupport.configuration(locale: "it"))
        let snapshot = await TestSupport.final(italian, "porto")
        XCTAssertEqual(TestSupport.ids(snapshot), ["maps#harbor"])
        XCTAssertEqual(snapshot?.hits.first?.matchedLanguage, "it")
    }

    func testUnresolvedKeysIndexNothingAndTheRawKeyNeverEntersTheIndex() async {
        let recorder = DiagnosticsRecorder()
        let connection = await seededConnection()
        await connection.insert(into: "maps", ["slug": .text("ghost"), "title_key": .text("map.unknown-key"), "body": .text("A body that is indexed.")])
        let service = await service(connection, tables: [mapsSource()], configuration: TestSupport.configuration(diagnostics: recorder.sink))

        let document = await service.document(for: "maps#ghost")
        XCTAssertNil(document?.title, "an unresolved key indexes nothing for that field")
        XCTAssertEqual(document?.text, "A body that is indexed.")
        for query in ["map.unknown-key", "unknown-key", "unknown", "map.unknown"] {
            let snapshot = await TestSupport.final(service, query)
            XCTAssertTrue(TestSupport.ids(snapshot).isEmpty, "the raw key is absent from the index (\(query))")
        }
        let body = await TestSupport.final(service, "indexed")
        XCTAssertEqual(TestSupport.ids(body), ["maps#ghost"])
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains(.unresolvedLocalizationKey(key: "map.unknown-key", table: "Maps", language: "en")))
    }

    func testAContextWithoutAResolverIndexesNothingForKeyedFields() async {
        let connection = await seededConnection()
        let service = CatalogService(
            context: SearchContext(id: "no-resolver", sources: [.database(connection, [mapsSource()])], indexStorage: .inMemory),
            configuration: TestSupport.configuration()
        )
        await service.waitUntilReady()
        let document = await service.document(for: "maps#harbor")
        XCTAssertNil(document?.title)
        let key = await TestSupport.final(service, "map.harbor")
        XCTAssertTrue(TestSupport.ids(key).isEmpty)
    }

    func testTypedFiltersAreRebuiltFromFilterColumnsAndUnknownValuesAreIgnored() async {
        let recorder = DiagnosticsRecorder()
        let connection = await seededConnection()
        await connection.insert(into: "tools", toolRow(9, "Odd Tool", "Has a platform this build does not know.", platform: "ios,vr"))
        let service = await service(connection, tables: [toolsSource()], configuration: TestSupport.configuration(diagnostics: recorder.sink))

        let calculator = await service.document(for: "tools#3")
        XCTAssertEqual(calculator?.filters, [
            FilterRecord(key: "category", value: "calculators"), FilterRecord(key: "platform", value: "ios"), FilterRecord(key: "platform", value: "mac"),
        ])
        var query = CatalogQuery(text: "", filters: [.platform(.mac)])
        query.limit = 50
        let mac = await TestSupport.final(service, query)
        XCTAssertEqual(Set(TestSupport.ids(mac)), ["tools#2", "tools#3"])
        let both = await TestSupport.final(service, CatalogQuery(text: "", filters: [.platform(.ios), .category(.calculators)]))
        XCTAssertEqual(TestSupport.ids(both), ["tools#3"])

        let odd = await service.document(for: "tools#9")
        XCTAssertEqual(odd?.filters, [FilterRecord(key: "category", value: "trackers"), FilterRecord(key: "platform", value: "ios")])
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains(.unknownFilter(id: "tools#9", record: FilterRecord(key: "platform", value: "vr"))))
    }

    func testRowsGetTemporalSemanticsFromUpdatedAt() async {
        let connection = await seededConnection()
        let service = await service(connection, tables: [toolsSource(), mapsSource()])
        let tool = await service.document(for: "tools#2")
        XCTAssertEqual(tool?.updatedAt, Date(timeIntervalSince1970: 1_799_000_002))
        let map = await service.document(for: "maps#harbor")
        XCTAssertNil(map?.updatedAt)
        XCTAssertEqual(SearchBindingValue.text("2026-11-05T10:00:00Z").dateValue, Date(timeIntervalSince1970: 1_793_872_800))
        XCTAssertEqual(SearchBindingValue.text("2026-11-05T10:00:00.250").dateValue, Date(timeIntervalSince1970: 1_793_872_800.25))
        XCTAssertEqual(SearchBindingValue.real(12.5).dateValue, Date(timeIntervalSince1970: 12.5))
    }

    func testRowIdentityMapping() async {
        let connection = await seededConnection()
        var verbatim = toolsSource()
        verbatim.identity = .verbatim
        var prefixed = mapsSource()
        prefixed.identity = .prefixed("m:")
        let service = await service(connection, tables: [verbatim, prefixed])
        let ids = TestSupport.ids(await TestSupport.final(service, CatalogQuery(text: "", tokens: [.kind(.tool)])))
        XCTAssertEqual(Set(ids), ["1", "2", "3"])
        let map = await service.document(for: "m:harbor")
        XCTAssertEqual(map?.title, "Frozen Harbor")
    }

    // MARK: Mixed contexts

    func testAMixedContextRanksIdenticallyToAnAllMemoryContextHoldingTheSameDocuments() async {
        let connection = await seededConnection()
        // Memory items of the mixed context.
        let memory: [AnySearchable<CatalogKind>] = [
            AnySearchable(Tip(id: "tip-1", title: "Surviving round thirty", text: "Stay near the mystery box and keep moving.",
                              updatedAt: Date(timeIntervalSince1970: 1_799_000_000))),
            AnySearchable(Game(id: "game-1", title: "Harbor Protocol", text: "A survival game set in a frozen harbor.", keywords: ["survival"])),
        ]
        // The same documents, all held in memory.
        func date(_ id: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1_799_000_000 + id)) }
        struct DatedTool: Searchable, TitledSearchable, KeywordSearchable, FilterableSearchable, LocalizedSearchable, TemporalSearchable {
            var base: Tool
            var updatedAt: Date
            var createdAt: Date { updatedAt }
            var searchID: SearchableID { base.searchID }
            var searchKind: CatalogKind { .tool }
            var searchText: String { base.searchText }
            var searchTitle: String { base.searchTitle }
            var searchKeywords: [String] { base.searchKeywords }
            var searchFilters: Set<CatalogFilter> { base.searchFilters }
            var searchLanguage: String? { base.searchLanguage }
            var searchLocalizations: [String: SearchLocalization] { base.searchLocalizations }
        }
        let twins: [AnySearchable<CatalogKind>] = memory + [
            AnySearchable(DatedTool(base: Tool(id: "tools#1", title: "Mystery Box Tracker", text: "Track every mystery box location.",
                                               keywords: ["box", "tracker"], filters: [.platform(.ios), .category(.trackers)]), updatedAt: date(1))),
            AnySearchable(DatedTool(base: Tool(id: "tools#2", title: "Round Timer", text: "A timer for high rounds.",
                                               keywords: ["timer"], filters: [.platform(.mac), .category(.trackers)]), updatedAt: date(2))),
            AnySearchable(DatedTool(base: Tool(id: "tools#3", title: "Damage Calculator", text: "Compute weapon damage per round.",
                                               keywords: ["calculator", "damage"], filters: [.platform(.ios), .platform(.mac), .category(.calculators)]), updatedAt: date(3))),
            AnySearchable(MapItem(id: "maps#harbor", title: "Frozen Harbor", text: "Layout of the harbor with every door.", localizations: [
                "en": SearchLocalization(title: "Frozen Harbor"), "it": SearchLocalization(title: "Porto Ghiacciato"), "ja": SearchLocalization(title: "凍った港"),
            ])),
            AnySearchable(MapItem(id: "maps#temple", title: "Sunken Temple", text: "The temple layout and its box.", localizations: [
                "en": SearchLocalization(title: "Sunken Temple"), "it": SearchLocalization(title: "Tempio Sommerso"),
            ])),
        ]

        for (locale, secondary) in [("en", SecondaryLanguages.none), ("it", .explicit(["ja", "en"])), ("ja", .none)] {
            let configuration = TestSupport.configuration(locale: locale, secondary: secondary)
            let mixed = await service(connection, tables: [toolsSource(), mapsSource()], memory: memory, id: "mixed", configuration: configuration)
            let allMemory = CatalogService(context: SearchContext(id: "memory", sources: [.memory(twins)], strategy: .scan), configuration: configuration)
            let mixedCount = await mixed.count
            XCTAssertEqual(mixedCount, 7, "memory arrays and any number of tables yield one document set")

            // One document set, one strategy, one ranking: identical score and order.
            for ordinal in ["tools#1", "tools#3", "maps#harbor", "maps#temple", "tip-1", "game-1"] {
                let lhs = await mixed.document(for: SearchableID(ordinal))
                let rhs = await allMemory.document(for: SearchableID(ordinal))
                XCTAssertEqual(lhs, rhs, "\(ordinal) in \(locale)")
            }
            for text in ["mystery box", "harbor", "round", "frozn harbr", "porto", "tempio sommerso", "凍った", "survival", "timer mac", "calc", "the"] {
                var query = CatalogQuery(text: text)
                query.limit = 50
                let lhs = RankingFingerprint(await TestSupport.final(mixed, query))
                let rhs = RankingFingerprint(await TestSupport.final(allMemory, query))
                XCTAssertEqual(lhs, rhs, "'\(text)' in \(locale)")
            }
            var filtered = CatalogQuery(text: "round", filters: [.platform(.mac)])
            filtered.limit = 50
            let lhs = RankingFingerprint(await TestSupport.final(mixed, filtered))
            let rhs = RankingFingerprint(await TestSupport.final(allMemory, filtered))
            XCTAssertEqual(lhs, rhs)
            XCTAssertFalse(lhs.ids.isEmpty)
        }
    }

    func testIDCollisionsAcrossSourcesAreDebugAsserted() async {
        let recorder = DiagnosticsRecorder()
        let connection = await seededConnection()
        // A memory item that claims the id of a row.
        let memory = [AnySearchable<CatalogKind>(Tool(id: "tools#2", title: "Impostor", text: "Not the row."))]
        let service = await service(connection, tables: [toolsSource()], memory: memory, configuration: TestSupport.configuration(diagnostics: recorder.sink))
        let count = await service.count
        XCTAssertEqual(count, 3, "one document per id")
        let diagnostics = await recorder.finish()
        let collision = diagnostics.first { $0 == .duplicateID(id: "tools#2") }
        XCTAssertNotNil(collision)
        XCTAssertEqual(collision?.isProgrammerError, true, "a debug assertion")
    }

    func testADatabaseFailureIsReportedAndTheRestOfTheContextStillLoads() async {
        let recorder = DiagnosticsRecorder()
        let connection = await seededConnection()
        var broken = mapsSource()
        broken.table = .identifier("no_such_table")
        broken.name = "no_such_table"
        let service = await service(connection, tables: [toolsSource(), broken], configuration: TestSupport.configuration(diagnostics: recorder.sink))
        let count = await service.count
        XCTAssertEqual(count, 3)
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains { if case .databaseFailure(table: "no_such_table", _) = $0 { return true } else { return false } })
    }

    // MARK: Change stream

    func testChangeStreamUpsertsChangedRows() async {
        let connection = await seededConnection()
        let service = await service(connection, tables: [toolsSource(), mapsSource()])
        let before = await TestSupport.final(service, "zeppelin")
        XCTAssertTrue(TestSupport.ids(before).isEmpty)

        // Insert.
        let rowID = await connection.insert(into: "tools", toolRow(7, "Zeppelin Hangar", "Dock the zeppelin."))
        let inserted = await eventually { TestSupport.ids(await TestSupport.final(service, "zeppelin")) == ["tools#7"] }
        XCTAssertTrue(inserted)
        // Update: the new text matches, the old text no longer does.
        await connection.update("tools", rowID: rowID, ["title": .text("Balloon Hangar"), "body": .text("Dock the balloon.")])
        let updated = await eventually {
            let old = TestSupport.ids(await TestSupport.final(service, "zeppelin"))
            let new = TestSupport.ids(await TestSupport.final(service, "balloon"))
            return old.isEmpty && new == ["tools#7"]
        }
        XCTAssertTrue(updated)
        let count = await service.count
        XCTAssertEqual(count, 6)
    }

    func testChangeStreamRemovesDeletedRowsAndRowsThatLeaveThePredicate() async {
        let connection = await seededConnection()
        let predicate = SearchSQL(template: "\"hidden\" = ?", bindings: [.int(0)])
        let service = await service(connection, tables: [toolsSource(predicate: predicate)])
        let all = await service.count
        XCTAssertEqual(all, 3)

        await connection.delete(from: "tools", rowIDs: [2])
        let deleted = await eventually { await service.count == 2 }
        XCTAssertTrue(deleted)
        let timer = await TestSupport.final(service, "timer")
        XCTAssertTrue(TestSupport.ids(timer).isEmpty)

        // A row that stops satisfying the predicate is no longer searchable.
        await connection.update("tools", rowID: 3, ["hidden": .int(1)])
        let hidden = await eventually { await service.count == 1 }
        XCTAssertTrue(hidden)
        let calculator = await TestSupport.final(service, "calculator")
        XCTAssertTrue(TestSupport.ids(calculator).isEmpty)
        // And one that satisfies it again comes back.
        await connection.update("tools", rowID: 3, ["hidden": .int(0)])
        let shown = await eventually { TestSupport.ids(await TestSupport.final(service, "calculator")) == ["tools#3"] }
        XCTAssertTrue(shown)
    }

    func testAChangeWithoutRowIDsRefreshesItsTable() async {
        let connection = await seededConnection()
        let service = await service(connection, tables: [toolsSource(), mapsSource()])
        // The host changes rows without telling which.
        await connection.setSilent(true)
        await connection.delete(from: "tools", rowIDs: [1])
        await connection.update("tools", rowID: 2, ["title": .text("Countdown Clock")])
        await connection.insert(into: "tools", toolRow(8, "Compass", "Points north."))
        await connection.resetLog()
        await connection.emit(SearchDatabaseChange(table: "tools", rowIDs: nil))

        let refreshed = await eventually {
            let compass = TestSupport.ids(await TestSupport.final(service, "compass"))
            let clock = TestSupport.ids(await TestSupport.final(service, "countdown"))
            let gone = TestSupport.ids(await TestSupport.final(service, "tracker"))
            return compass == ["tools#8"] && clock == ["tools#2"] && gone.isEmpty
        }
        XCTAssertTrue(refreshed)
        let count = await service.count
        XCTAssertEqual(count, 5, "3 tools and 2 maps")
        // Only the table that changed was re-read.
        let statements = await connection.statements()
        XCTAssertTrue(statements.allSatisfy { $0.sql.template.contains("FROM \"tools\"") })
        XCTAssertTrue(statements.allSatisfy { !$0.sql.template.contains(" IN (") })
    }

    func testChangesAreBatchedPerCommit() async {
        let connection = await seededConnection()
        let service = await service(connection, tables: [toolsSource()])
        await connection.resetLog()
        // One commit that touches 100 rows: one change, one re-read, one upsert.
        await connection.insert(into: "tools", rows: (100..<200).map { toolRow($0, "Bulk Tool \($0)", "Inserted in one commit.") })
        let applied = await eventually { await service.count == 103 }
        XCTAssertTrue(applied)
        let statements = await connection.statements()
        XCTAssertEqual(statements.count, 1, "the 100 changed rowids are re-read in one statement")
        XCTAssertTrue(statements[0].sql.template.contains("rowid IN ("))
        XCTAssertEqual(statements[0].sql.bindings.count, 100)

        // A commit that touches two tables yields one change per table.
        let mixed = await self.service(connection, tables: [toolsSource(), mapsSource()], id: "two-tables")
        await connection.resetLog()
        await connection.transaction([
            (table: "tools", rowID: nil, values: toolRow(300, "Twin Tool", "Committed together.")),
            (table: "maps", rowID: nil, values: ["slug": .text("twin"), "title_key": .text("map.temple"), "body": .text("Committed together too.")]),
        ])
        let both = await eventually {
            TestSupport.ids(await TestSupport.final(mixed, "committed")).count == 2
        }
        XCTAssertTrue(both)
    }

    func testAChangeBatchReadUnderAnOlderGenerationIsDropped() async {
        let connection = await seededConnection()
        let service = await service(connection, tables: [toolsSource()])

        // 1. A row is inserted: the change stream starts re-reading it, slowly.
        await connection.scriptReadDelays(nanoseconds: [400_000_000])
        let rowID = await connection.insert(into: "tools", toolRow(50, "Alpha Version", "The stale text."))
        _ = await eventually { await connection.transactions() >= 3 }
        // 2. Meanwhile the row changes again, silently, and the host asks for a full refresh.
        await connection.setSilent(true)
        await connection.update("tools", rowID: rowID, ["title": .text("Beta Version"), "body": .text("The current text.")])
        await service.refresh()
        let current = await TestSupport.final(service, "beta")
        XCTAssertEqual(TestSupport.ids(current), ["tools#50"])

        // 3. The slow read now returns the row as it was. It was read under the generation the
        //    refresh replaced, so it must not be applied.
        try? await Task.sleep(nanoseconds: 600_000_000)
        let stale = await TestSupport.final(service, "alpha")
        XCTAssertTrue(TestSupport.ids(stale).isEmpty, "a stale batch overwrote the refreshed document")
        let stillCurrent = await TestSupport.final(service, "beta")
        XCTAssertEqual(TestSupport.ids(stillCurrent), ["tools#50"])
    }

    // MARK: Commits that land while a table is being read

    /// A context over `tools` whose pages hold two rows and take a moment to read, not waited for.
    private func slowlyLoadingService(
        _ connection: FakeSearchDatabaseConnection,
        pageDelay: UInt64 = 60_000_000,
        diagnostics: (@Sendable (SearchDiagnostic) -> Void)? = nil
    ) async -> CatalogService {
        await connection.setReadDelay(nanoseconds: pageDelay)
        var configuration = TestSupport.configuration(diagnostics: diagnostics)
        configuration.databasePageSize = 2
        let transactions = await connection.transactions()
        let service = CatalogService(
            context: SearchContext(id: "paged", sources: [.database(connection, [toolsSource()])], localizedStrings: resolver, indexStorage: .inMemory),
            configuration: configuration
        )
        // The service listens before it reads; wait until its first page is being read.
        _ = await eventually { await connection.subscriberCount() == 1 }
        _ = await eventually { await connection.transactions() > transactions }
        return service
    }

    private func fiveTools() async -> FakeSearchDatabaseConnection {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("tools", columns: Self.toolColumns)
        await connection.insert(into: "tools", rows: (1...5).map { toolRow($0, "Tool \($0)", "Body of tool \($0).") })
        await connection.resetLog()
        return connection
    }

    func testAChangeCommittedWhileAContextLoadsReachesTheIndex() async {
        let connection = await fiveTools()
        let service = await slowlyLoadingService(connection)
        // Row 1 is on the page being read, which sees it as it was when the read began.
        await connection.update("tools", rowID: 1, ["title": .text("Zeppelin Hangar")])
        await service.waitUntilReady()
        let arrived = await eventually { TestSupport.ids(await TestSupport.final(service, "zeppelin")) == ["tools#1"] }
        XCTAssertTrue(arrived, "a commit made during the load must reach the index")
        let count = await service.count
        XCTAssertEqual(count, 5)
    }

    func testAChangeCommittedDuringARefreshSurvivesIt() async {
        let connection = await fiveTools()
        var configuration = TestSupport.configuration()
        configuration.databasePageSize = 2
        let service = await service(connection, tables: [toolsSource()], configuration: configuration)
        await connection.setReadDelay(nanoseconds: 60_000_000)
        let transactions = await connection.transactions()
        async let refresh: Void = service.refresh()
        _ = await eventually { await connection.transactions() > transactions }
        await connection.update("tools", rowID: 1, ["title": .text("Zeppelin Hangar")])
        await refresh
        let arrived = await eventually { TestSupport.ids(await TestSupport.final(service, "zeppelin")) == ["tools#1"] }
        XCTAssertTrue(arrived, "the refresh must not put back the row as an earlier page saw it")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let stays = await TestSupport.final(service, "zeppelin")
        XCTAssertEqual(TestSupport.ids(stays), ["tools#1"])
    }

    func testARowMovedAcrossAPageBoundaryByADeleteIsNotLost() async {
        // Pages of two: [1, 2] [3, 4] [5]. Deleting row 1 after the first page was read makes
        // `OFFSET 2` start at row 4, so row 3 is on no page of that read.
        let connection = await fiveTools()
        let service = await slowlyLoadingService(connection)
        await connection.delete(from: "tools", rowIDs: [1])
        await service.waitUntilReady()
        let settled = await eventually { await service.count == 4 }
        XCTAssertTrue(settled)
        for id in 2...5 {
            let document = await service.document(for: SearchableID("tools#\(id)"))
            XCTAssertNotNil(document, "row \(id) was never deleted")
        }
        let deleted = await service.document(for: "tools#1")
        XCTAssertNil(deleted)
        // The table was read a second time, in full.
        let wholeReads = await connection.statements().filter { $0.sql.template.hasSuffix("OFFSET 0") && !$0.sql.template.contains(" IN (") }
        XCTAssertGreaterThanOrEqual(wholeReads.count, 2)
    }

    func testATableThatNeverRestsIsReportedAndItsChangesStillArrive() async {
        let connection = await fiveTools()
        let recorder = DiagnosticsRecorder()
        let service = await slowlyLoadingService(connection, pageDelay: 30_000_000, diagnostics: recorder.sink)
        // A host that commits every few milliseconds for as long as the engine keeps reading.
        let writer = Task {
            var round = 0
            while !Task.isCancelled {
                round += 1
                await connection.update("tools", rowID: 2, ["title": .text("Version \(round)")])
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        await service.waitUntilReady()
        writer.cancel()
        _ = await writer.value
        await connection.update("tools", rowID: 2, ["title": .text("Settled Lighthouse")])

        let arrived = await eventually(timeout: 5) { TestSupport.ids(await TestSupport.final(service, "lighthouse")) == ["tools#2"] }
        XCTAssertTrue(arrived, "the changes that arrived during the last read are applied after it")
        let count = await service.count
        XCTAssertEqual(count, 5)
        let reported = await recorder.finish()
        XCTAssertTrue(reported.contains(.sourceChangedWhileReading(table: "tools")), "three reads in a row were overtaken by a commit: \(reported)")
    }

    func testCommitsThatQueueUpBehindOneAnotherAreAppliedTogether() async {
        let connection = await fiveTools()
        let service = await service(connection, tables: [toolsSource()])
        await connection.resetLog()
        await connection.setReadDelay(nanoseconds: 120_000_000)
        // Five commits while the first one is still being re-read.
        for id in 1...5 {
            await connection.update("tools", rowID: Int64(id), ["title": .text("Renamed Beacon \(id)")])
        }
        let applied = await eventually(timeout: 5) { TestSupport.ids(await TestSupport.final(service, "beacon")).count == 5 }
        XCTAssertTrue(applied)
        let reads = await connection.statements().filter { $0.sql.template.contains(" IN (") }
        XCTAssertLessThanOrEqual(reads.count, 2, "one read for the first commit, one for those that queued up behind it")
        let rowIDs = Set(reads.flatMap { $0.sql.bindings.compactMap { $0.integerValue } })
        XCTAssertEqual(rowIDs, Set(1...5))
    }

    func testReleasingAContextEndsItsSubscription() async {
        let connection = await seededConnection()
        do {
            let service = await service(connection, tables: [toolsSource()])
            _ = await eventually { await connection.subscriberCount() == 1 }
            let subscribed = await connection.subscriberCount()
            XCTAssertEqual(subscribed, 1)
            _ = await TestSupport.final(service, "timer")
        }
        let released = await eventually { await connection.subscriberCount() == 0 }
        XCTAssertTrue(released, "the change stream is cancelled when the service goes away")
    }

    // MARK: Index in the database

    private func largeConnection() async -> FakeSearchDatabaseConnection {
        let connection = FakeSearchDatabaseConnection()
        await connection.createTable("tools", columns: Self.toolColumns)
        var corpus = RandomCorpus(seed: 12)
        await connection.insert(into: "tools", rows: (1...900).map { toolRow($0, corpus.words(1..<4), corpus.words(4..<16), tags: corpus.word()) })
        await connection.resetLog()
        return connection
    }

    func testIndexInDatabaseRoundTrip() async {
        let connection = await largeConnection()
        let first = await service(connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"))
        await first.persist()
        let names = await connection.tableNames()
        XCTAssertEqual(Set(names), ["tools", "zts_meta", "zts_docs", "zts_terms", "zts_postings"])
        var corpus = RandomCorpus(seed: 13)
        let queries = (0..<30).map { _ in corpus.query() }
        var expected: [RankingFingerprint] = []
        for query in queries { expected.append(RankingFingerprint(await TestSupport.final(first, query))) }

        // A second service starts from the persisted index: the host table is not read at all.
        await connection.resetLog()
        let second = await service(connection, tables: [toolsSource()], id: "db", storage: .database(tablePrefix: "zts"))
        let statements = await connection.statements()
        XCTAssertFalse(statements.contains { $0.sql.template.contains("FROM \"tools\"") }, "loaded from the index tables, rows not re-read")
        XCTAssertTrue(statements.contains { $0.sql.template.contains("\"zts_postings\"") })
        let count = await second.count
        XCTAssertEqual(count, 900)
        for (query, fingerprint) in zip(queries, expected) {
            let restored = RankingFingerprint(await TestSupport.final(second, query))
            XCTAssertEqual(restored, fingerprint, query.text)
        }

        // A change after adoption still lands: the table is read on demand.
        await connection.insert(into: "tools", toolRow(5_000, "Zeppelin Hangar", "Dock the zeppelin."))
        let applied = await eventually { TestSupport.ids(await TestSupport.final(second, "zeppelin")) == ["tools#5000"] }
        XCTAssertTrue(applied)
    }

    func testGenerationsSwapAtomically() async {
        let recorder = DiagnosticsRecorder()
        let connection = await largeConnection()
        let service = await service(
            connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"),
            configuration: TestSupport.configuration(diagnostics: recorder.sink)
        )
        await service.persist()
        func generation() async -> SearchBindingValue? {
            await connection.rows(of: "zts_meta").first { $0["key"] == .text("generation") }?["value"]
        }
        func generations(in table: String) async -> Set<SearchBindingValue> {
            Set(await connection.rows(of: table).compactMap { $0["generation"] })
        }
        let firstGeneration = await generation()
        let firstRows = await connection.rows(of: "zts_postings")
        XCTAssertNotNil(firstGeneration)

        // A second save moves the pointer and leaves exactly one generation behind.
        await service.index([Tool(id: "extra", title: "Zeppelin Hangar", text: "Dock the zeppelin.")])
        await service.persist()
        let secondGeneration = await generation()
        XCTAssertEqual(secondGeneration?.integerValue, (firstGeneration?.integerValue ?? 0) + 1)
        for table in ["zts_docs", "zts_terms", "zts_postings"] {
            let present = await generations(in: table)
            XCTAssertEqual(present, [secondGeneration!], "\(table) holds only the current generation")
        }

        // A save that fails halfway is rolled back as a whole: pointer and rows are untouched.
        let before = await connection.rows(of: "zts_postings")
        await service.index([Tool(id: "extra-2", title: "Balloon Hangar", text: "Dock the balloon.")])
        await connection.failWrites(afterStatements: 6)
        await service.persist()
        await connection.failWrites(afterStatements: nil)
        let afterFailure = await generation()
        XCTAssertEqual(afterFailure, secondGeneration, "the generation pointer did not move")
        let after = await connection.rows(of: "zts_postings")
        XCTAssertEqual(after, before, "no partial generation is visible")
        XCTAssertNotEqual(firstRows, before)
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains { if case .persistenceFailed = $0 { return true } else { return false } })

        // The index still loads, as the generation that committed.
        let restored = await self.service(connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"))
        let count = await restored.count
        XCTAssertEqual(count, 901)
    }

    func testAStoredIndexOfAnotherVersionIsRebuilt() async throws {
        let connection = await largeConnection()
        let first = await service(connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"))
        await first.persist()

        // Another projection version wrote the stored index.
        _ = try await connection.write { writer in
            try writer.run(SearchSQL(
                template: "INSERT OR REPLACE INTO \"zts_meta\" (\"key\", \"value\") VALUES (?, ?)",
                bindings: [.text("projectionVersion"), .int(Int64(SearchDocument.projectionVersion + 1))]
            ))
        }
        await connection.resetLog()
        let second = await service(connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"))
        let statements = await connection.statements()
        XCTAssertTrue(statements.contains { $0.sql.template.contains("FROM \"tools\"") }, "the rows are read again and the index rebuilt")
        let count = await second.count
        XCTAssertEqual(count, 900)
        // The rebuild wrote a fresh index under the current version.
        let version = await connection.rows(of: "zts_meta").first { $0["key"] == .text("projectionVersion") }?["value"]
        XCTAssertEqual(version, .int(Int64(SearchDocument.projectionVersion)))
    }

    func testAStoredIndexForAnotherLocaleIsRebuilt() async {
        let connection = await largeConnection()
        let english = await service(connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"))
        await english.persist()
        await connection.resetLog()
        let italian = await service(connection, tables: [toolsSource()], storage: .database(tablePrefix: "zts"), configuration: TestSupport.configuration(locale: "it"))
        let statements = await connection.statements()
        XCTAssertTrue(statements.contains { $0.sql.template.contains("FROM \"tools\"") })
        let languages = await italian.resolvedLanguages
        XCTAssertEqual(languages.active, "it")
    }
}
