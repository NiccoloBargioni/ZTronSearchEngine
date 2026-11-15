import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

final class SmokeTests: XCTestCase {
    static let items: [AnySearchable<CatalogKind>] = {
        let tools = [
            Tool(id: "tool-1", title: "Mystery Box Tracker", text: "Track every mystery box location round by round.", keywords: ["box", "tracker"], filters: [.platform(.ios), .category(.trackers)]),
            Tool(id: "tool-2", title: "Round Timer", text: "A timer for high rounds with m1911-a1 presets.", keywords: ["timer"], filters: [.platform(.mac)]),
        ]
        let maps = [
            MapItem(id: "map-1", title: "Frozen Harbor", text: "Layout of the harbor with every door and power switch.", filters: [.category(.maps), .platform(.ios)],
                    localizations: ["it": SearchLocalization(title: "Porto Ghiacciato", text: "Mappa del porto con ogni porta.")]),
            MapItem(id: "map-2", title: "Sunken Temple", text: "The temple layout with the mystery box spawn points.", filters: [.category(.maps)]),
        ]
        let tips = [
            Tip(id: "tip-1", title: "Surviving round thirty", text: "Stay near the mystery box and keep moving in circles."),
        ]
        return tools.erased() + maps.erased() + tips.erased()
    }()

    func configuration() -> SearchEngineConfiguration {
        SearchEngineConfiguration(
            locale: Locale(identifier: "en"),
            secondaryLanguages: .none,
            lexicalDebounce: 0,
            semanticDebounce: 0,
            assertsOnProgrammerError: false
        )
    }

    func finalSnapshot(_ service: SearchService<CatalogSchema>, _ text: String) async -> SearchSnapshot<CatalogSchema>? {
        var last: SearchSnapshot<CatalogSchema>?
        for await snapshot in await service.results(for: SearchQuery(text: text), trigger: .submit) {
            last = snapshot
        }
        return last
    }

    func testIndexedServiceFindsExactTitle() async {
        let service = SearchService<CatalogSchema>(index: LexicalIndex(), configuration: configuration())
        await service.index(Self.items)
        let snapshot = await finalSnapshot(service, "frozen harbor")
        XCTAssertEqual(snapshot?.hits.first?.id, "map-1")
        XCTAssertEqual(snapshot?.hits.first?.kind, .map)
        XCTAssertEqual(snapshot?.isFinal, true)
    }

    func testScanAndIndexedAgree() async {
        let scan = SearchService<CatalogSchema>(
            context: SearchContext(id: "scan", sources: [.memory(Self.items)], strategy: .scan),
            configuration: configuration()
        )
        let indexed = SearchService<CatalogSchema>(
            context: SearchContext(id: "indexed", sources: [.memory(Self.items)], strategy: .indexed, indexStorage: .inMemory),
            configuration: configuration()
        )
        for query in ["mystery box", "mystry", "harbr", "round", "temple layout", "m1911-a1", "tim", "\"mystery box\" spawn"] {
            let lhs = await finalSnapshot(scan, query)
            let rhs = await finalSnapshot(indexed, query)
            XCTAssertEqual(lhs?.hits.map(\.id), rhs?.hits.map(\.id), "ids differ for \(query)")
            XCTAssertEqual(lhs?.hits.map(\.score), rhs?.hits.map(\.score), "scores differ for \(query)")
            XCTAssertFalse(lhs?.hits.isEmpty ?? true, "no hits for \(query)")
        }
    }

    func testTypoAndHighlights() async {
        let index = ScanIndex<CatalogSchema>(items: Self.items, locale: Locale(identifier: "en"), profile: .default, configuration: configuration())
        let hits = index.hits(for: SearchQuery(text: "sunkn temple"))
        XCTAssertEqual(hits.first?.id, "map-2")
        let hit = try? XCTUnwrap(hits.first)
        XCTAssertEqual(hit?.matchedField, .title)
        if let hit, let document = index.document(for: hit.id), let field = hit.matchedField, let surface = document.surface(for: field) {
            XCTAssertEqual(hit.highlights.map { String(surface[$0]) }, ["Sunken", "Temple"])
        }
    }
}
