import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, "Internationalization", and the projection rules of sections 5 and 6.
final class InternationalizationTests: XCTestCase {
    private let harbor = MapItem(
        id: "harbor", title: "Frozen Harbor", text: "Layout of the harbor.",
        localizations: [
            "it": SearchLocalization(title: "Porto Ghiacciato", text: "Mappa del porto."),
            "it-CH": SearchLocalization(title: "Porto Gelato", text: ""),
            "de": SearchLocalization(title: "Gefrorener Hafen", text: "Karte des Hafens."),
            "ja": SearchLocalization(title: "凍った港", text: "港の地図。"),
        ]
    )

    private func project(_ item: any Searchable, _ locale: String, secondary: [String] = []) -> SearchDocument {
        SearchProjector.project(item, locale: Locale(identifier: locale), secondaryLanguages: secondary)
    }

    // MARK: Projection

    func testProjectionIsPure() {
        let first = project(harbor, "it_IT", secondary: ["de", "ja"])
        let second = project(harbor, "it_IT", secondary: ["de", "ja"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(SearchDocument.projectionVersion, 1)
    }

    func testLocalizedTitleWinsOverTheBaseTitleForTheActiveLocale() {
        let document = project(harbor, "it")
        XCTAssertEqual(document.title, "Porto Ghiacciato")
        XCTAssertEqual(document.text, "Mappa del porto.")
        XCTAssertEqual(document.language, "it")
        XCTAssertEqual(document.languages.title, "it")
        // The shadowed base surface stays reachable at low weight.
        XCTAssertEqual(document.localizedAlt, ["Frozen Harbor", "Layout of the harbor."])
        XCTAssertEqual(document.languages.localizedAlt, ["en", "en"])
    }

    func testBaseWinsWhenTheLocalizationIsEmpty() {
        let item = MapItem(id: "m", title: "Frozen Harbor", text: "Layout.", localizations: [
            "it": SearchLocalization(title: "", text: "Mappa."),
            "de": SearchLocalization(title: "   ", text: nil),
        ])
        let italian = project(item, "it")
        XCTAssertEqual(italian.title, "Frozen Harbor", "an empty localized title falls back to the base title")
        XCTAssertEqual(italian.languages.title, "en")
        XCTAssertEqual(italian.text, "Mappa.", "each surface resolves on its own")
        XCTAssertEqual(italian.languages.text, "it")
        let german = project(item, "de")
        XCTAssertEqual(german.title, "Frozen Harbor")
        XCTAssertEqual(german.text, "Layout.")
        XCTAssertEqual(german.language, "en")
    }

    func testFallbackChainExactTagThenLanguageThenBase() {
        // it-CH: exact tag for the title, language match for the text the exact entry leaves empty.
        let swiss = project(harbor, "it_CH")
        XCTAssertEqual(swiss.title, "Porto Gelato")
        XCTAssertEqual(swiss.languages.title, "it-CH")
        XCTAssertEqual(swiss.text, "Mappa del porto.")
        XCTAssertEqual(swiss.languages.text, "it")
        // it-IT: no exact entry, the language match wins.
        let italy = project(harbor, "it_IT")
        XCTAssertEqual(italy.title, "Porto Ghiacciato")
        XCTAssertEqual(italy.languages.title, "it")
        // fr: nothing matches, the base surface is the fallback.
        let french = project(harbor, "fr_FR")
        XCTAssertEqual(french.title, "Frozen Harbor")
        XCTAssertEqual(french.language, "en")
        XCTAssertTrue(french.localizedAlt.isEmpty)
        XCTAssertEqual(LanguageTag.chain(available: ["de", "it", "it-CH", "ja"], preference: "it-CH"), ["it-CH", "it"])
        XCTAssertEqual(LanguageTag.chain(available: ["de", "it", "ja"], preference: "it-IT"), ["it"])
        XCTAssertEqual(LanguageTag.chain(available: ["de", "ja"], preference: "it-IT"), [])
    }

    func testSecondaryLanguagesFeedLocalizedAlt() {
        let document = project(harbor, "en", secondary: ["en-US", "de-DE", "ja"])
        XCTAssertEqual(document.title, "Frozen Harbor")
        XCTAssertEqual(document.localizedAlt, ["Gefrorener Hafen", "Karte des Hafens.", "凍った港", "港の地図。"])
        XCTAssertEqual(document.languages.localizedAlt, ["de", "de", "ja", "ja"])
        // .none: no secondary language at all.
        XCTAssertTrue(project(harbor, "en").localizedAlt.isEmpty)
    }

    func testAllLanguagesPolicyIndexesEveryLocalization() {
        let configuration = SearchEngineConfiguration(
            locale: Locale(identifier: "en"), secondaryLanguages: .all, preferredLanguages: { ["en"] }
        )
        let languages = ResolvedLanguages(locale: configuration.locale, configuration: configuration)
        let document = SearchProjector(languages: languages).project(harbor)
        XCTAssertEqual(Set(document.languages.localizedAlt.compactMap { $0 }), ["de", "it", "it-CH", "ja"])
    }

    func testPreferredLanguagesPolicyUsesTheOtherPreferredLanguages() {
        let configuration = SearchEngineConfiguration(
            locale: Locale(identifier: "it_IT"), secondaryLanguages: .preferredLanguages, preferredLanguages: { ["it-IT", "ja-JP", "en-GB"] }
        )
        let languages = ResolvedLanguages(locale: configuration.locale, configuration: configuration)
        XCTAssertEqual(languages.active, "it-IT")
        XCTAssertEqual(languages.secondary, ["ja-JP", "en-GB"])
        let document = SearchProjector(languages: languages).project(harbor)
        // Japanese as a secondary language, and the shadowed English base.
        XCTAssertEqual(Set(document.languages.localizedAlt.compactMap { $0 }), ["en", "ja"])
    }

    func testCapabilitiesAreDetectedByConformance() {
        struct Bare: Searchable {
            var searchID: SearchableID { "bare" }
            var searchKind: CatalogKind { .tool }
            var searchText: String { "just text" }
        }
        let bare = project(Bare(), "en")
        XCTAssertNil(bare.title)
        XCTAssertTrue(bare.keywords.isEmpty)
        XCTAssertNil(bare.updatedAt)
        XCTAssertNil(bare.language, "unknown base language")
        XCTAssertEqual(bare.kind, "tool")

        let image = ImageItem(id: "i", title: "Dawn", altText: "alt", tags: ["a", "b"], caption: "cap", ocrText: "EXIT")
        let projected = project(image, "en")
        XCTAssertEqual(projected.caption, "cap")
        XCTAssertEqual(projected.ocrText, "EXIT")
        XCTAssertEqual(projected.keywords, ["a", "b"])
        let tip = Tip(id: "t", title: "T", text: "x", updatedAt: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(project(tip, "en").updatedAt, Date(timeIntervalSince1970: 42))
        // An erased item projects exactly like the item it wraps.
        XCTAssertEqual(project(AnySearchable(image), "en"), projected)
    }

    // MARK: Search

    func testLocalizedTitleWinsInSearch() async {
        // Two items collide on the string "porto": one as its Italian title, one as its base title.
        let items: [AnySearchable<CatalogKind>] = [
            MapItem(id: "localized", title: "Frozen Harbor", text: "x", localizations: ["it": SearchLocalization(title: "Porto Ghiacciato")]),
            MapItem(id: "base", title: "Porto Ghiacciato", text: "y", localizations: ["it": SearchLocalization(title: "Baia Calma")]),
        ].erased()
        let italian = await TestSupport.indexedService(items, configuration: TestSupport.configuration(locale: "it"))
        let snapshot = await TestSupport.final(italian, "porto ghiacciato")
        // The localized value must beat the base value.
        XCTAssertEqual(TestSupport.ids(snapshot), ["localized", "base"])
        XCTAssertEqual(snapshot?.hits.first?.matchedField, .title)
        XCTAssertEqual(snapshot?.hits.first?.matchedLanguage, "it")
        XCTAssertEqual(snapshot?.hits.last?.matchedField, .localizedAlt)
        XCTAssertEqual(snapshot?.hits.last?.matchedLanguage, "en")

        // Under English the roles swap.
        let english = await TestSupport.indexedService(items, configuration: TestSupport.configuration(locale: "en"))
        let reversed = await TestSupport.final(english, "porto ghiacciato")
        XCTAssertEqual(TestSupport.ids(reversed), ["base"], "with no secondary language the Italian surface is not indexed")
    }

    func testSecondaryPreferredLanguagesHitThroughLocalizedAltAtLowWeight() async {
        let items: [AnySearchable<CatalogKind>] = [
            MapItem(id: "harbor", title: "Frozen Harbor", text: "x", localizations: ["de": SearchLocalization(title: "Gefrorener Hafen")]),
            MapItem(id: "hafen", title: "Hafen", text: "y"),
        ].erased()
        let service = await TestSupport.indexedService(items, configuration: TestSupport.configuration(locale: "en", secondary: .explicit(["de"])))
        let snapshot = await TestSupport.final(service, "hafen")
        // A query typed in a second installed language still hits, below the title match.
        XCTAssertEqual(TestSupport.ids(snapshot), ["hafen", "harbor"])
        let alt = snapshot?.hits.last
        XCTAssertEqual(alt?.matchedField, .localizedAlt)
        XCTAssertEqual(alt?.matchedLanguage, "de")
        XCTAssertLessThan(alt?.score ?? 1, snapshot?.hits.first?.score ?? 0)
    }

    func testCJKBigramTokenizationAndPrefixMatching() async {
        let items: [AnySearchable<CatalogKind>] = [
            MapItem(id: "tower", title: "東京タワーの地図", text: "東京タワーの入口と出口。", language: "ja"),
            MapItem(id: "university", title: "北京大学の案内", text: "大学の地図。", language: "ja"),
            MapItem(id: "latin", title: "Tower map", text: "A plain map."),
        ].erased()
        let service = await TestSupport.indexedService(items, configuration: TestSupport.configuration(locale: "ja"))
        // A whole word, a prefix of a word, and a pair of characters that straddles two words.
        for (query, expected) in [("東京", "tower"), ("東", "tower"), ("タワ", "tower"), ("京タ", "tower"), ("北京大", "university"), ("大学", "university")] {
            let snapshot = await TestSupport.final(service, query)
            XCTAssertEqual(snapshot?.hits.first?.id.rawValue, expected, query)
        }
        let shared = await TestSupport.final(service, "地図")
        XCTAssertEqual(Set(TestSupport.ids(shared)), ["tower", "university"])
    }

    func testAnElidedNounIsFoundWithAndWithoutItsArticle() async {
        let items: [AnySearchable<CatalogKind>] = [
            AnySearchable(MapItem(id: "isola", title: "L'isola del tesoro", text: "La mappa dell’isola con ogni porta.", language: "it")),
            AnySearchable(MapItem(id: "porto", title: "Porto ghiacciato", text: "Il molo e le banchine.", language: "it")),
        ]
        for service in [
            await TestSupport.indexedService(items, configuration: TestSupport.configuration(locale: "it")),
            TestSupport.scanService(items, configuration: TestSupport.configuration(locale: "it")),
        ] {
            for query in ["isola", "l'isola", "dell'isola", "L’ISOLA", "tesoro isol"] {
                let found = await TestSupport.final(service, query)
                XCTAssertEqual(TestSupport.ids(found).first, "isola", query)
            }
            let phrase = await TestSupport.final(service, SearchQuery(text: "", tokens: [.phrase("isola del tesoro")]))
            XCTAssertEqual(TestSupport.ids(phrase), ["isola"])
            let hit = await TestSupport.final(service, "isola")
            let document = await service.document(for: "isola")
            let title = document?.surface(for: .title) ?? ""
            XCTAssertEqual(hit?.hits.first?.matchedField, .title)
            XCTAssertEqual(hit?.hits.first?.highlights.map { String(title[$0]) }, ["isola"], "the noun is highlighted, not the article")
        }
    }

    func testQueryNormalizationFollowsTheFoldingRules() async {
        let items: [AnySearchable<CatalogKind>] = [
            Tool(id: "resume", title: "Résumé Builder", text: "x"),
            Tool(id: "wide", title: "ＡＢＣ Tracker", text: "y"),
            Tool(id: "turkish", title: "İstanbul Rehberi", text: "z", language: "tr"),
        ].erased()
        let service = await TestSupport.indexedService(items)
        for (query, expected) in [("resume", "resume"), ("RÉSUMÉ", "resume"), ("abc", "wide"), ("ａｂｃ", "wide"), ("istanbul", "turkish"), ("ISTANBUL", "turkish")] {
            let snapshot = await TestSupport.final(service, query)
            XCTAssertEqual(snapshot?.hits.first?.id.rawValue, expected, query)
        }
    }

    func testAQueryMayCarryItsOwnLocale() async {
        let items: [AnySearchable<CatalogKind>] = [MapItem(id: "tower", title: "東京タワー", text: "x", language: "ja")].erased()
        let service = await TestSupport.indexedService(items)
        var query = CatalogQuery(text: "東京")
        query.locale = Locale(identifier: "ja")
        let snapshot = await TestSupport.final(service, query)
        XCTAssertEqual(TestSupport.ids(snapshot), ["tower"])
    }

    // MARK: Locale change

    func testLocaleChangeRebuildsUnderANewGenerationWhileQueriesKeepWorking() async throws {
        var corpus = RandomCorpus(seed: 99)
        var items = corpus.items(6_000)
        items.append(AnySearchable(harbor))
        // An item that reads the same under every locale: it must be found before, during and
        // after the rebuild, whichever index answers.
        items.append(AnySearchable(Tool(id: "probe", title: "Zyxquartz beacon", text: "The same in every language.")))
        let service = await TestSupport.indexedService(items, configuration: TestSupport.configuration(locale: "en"))

        let before = await TestSupport.final(service, "porto ghiacciato")
        XCTAssertTrue(TestSupport.ids(before).isEmpty, "the Italian surface is not indexed under English")
        var pageQuery = CatalogQuery(text: "map")
        pageQuery.limit = 5
        let pageSnapshot = await TestSupport.final(service, pageQuery)
        let firstPage = try XCTUnwrap(pageSnapshot)
        let cursor = try XCTUnwrap(firstPage.nextCursor)

        // Queries issued while the rebuild runs are answered from the old index.
        async let rebuild: Void = service.setLocale(Locale(identifier: "it_IT"))
        var answered = 0
        var cancelled = 0
        for _ in 0..<20 {
            // The one search in flight when the locale changes is cancelled, by design; every
            // other query is answered from the old index.
            guard let snapshot = await TestSupport.final(service, "zyxquartz") else {
                cancelled += 1
                continue
            }
            XCTAssertEqual(snapshot.hits.first?.id, "probe")
            answered += 1
        }
        await rebuild
        XCTAssertLessThanOrEqual(cancelled, 1)
        XCTAssertEqual(answered + cancelled, 20, "no query comes back wrong or empty during the rebuild")

        let languages = await service.resolvedLanguages
        XCTAssertEqual(languages.active, "it-IT")
        let after = await TestSupport.final(service, "porto ghiacciato")
        XCTAssertEqual(after?.hits.first?.id, "harbor")
        XCTAssertEqual(after?.hits.first?.matchedLanguage, "it")
        let count = await service.count
        XCTAssertEqual(count, 6_002)

        // The rebuild is a new generation: a cursor from before it is stale.
        do {
            _ = try await service.page(after: cursor, generation: firstPage.generation)
            XCTFail("a cursor from before the locale change must be stale")
        } catch let error as SearchError {
            XCTAssertEqual(error, .staleGeneration)
        }
    }

    func testLocaleChangeCancelsTheSearchInFlight() async {
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: TestSupport.configuration(lexicalDebounce: 0.25))
        let stream = await service.results(for: CatalogQuery(text: "harbor"))
        await service.setLocale(Locale(identifier: "de"))
        var received = 0
        for await _ in stream { received += 1 }
        XCTAssertEqual(received, 0, "search tasks are cancelled on locale change")
    }

    func testSemanticChannelIsToldAboutTheLocale() async {
        let semantic = StubSemantic()
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: semantic)
        await service.setLocale(Locale(identifier: "ja_JP"))
        let tags = await semantic.localeTags
        XCTAssertEqual(tags, ["ja-JP"])
    }
}
