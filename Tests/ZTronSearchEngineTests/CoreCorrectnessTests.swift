import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, "Core correctness".
final class CoreCorrectnessTests: XCTestCase {
    private var service: CatalogService!

    override func setUp() async throws {
        service = await TestSupport.indexedService(TestSupport.catalog)
    }

    // MARK: Exact-title ranking; body and caption matching; prefix matching

    func testExactTitleRanksFirst() async {
        for (title, id) in [
            ("Mystery Box Tracker", "tool-box"), ("round timer", "tool-timer"), ("FROZEN HARBOR", "map-harbor"),
            ("Sunken Temple", "map-temple"), ("Surviving round thirty", "tip-thirty"), ("Outbreak Protocol", "game-outbreak"),
            ("Harbor at dawn", "image-harbor"),
        ] {
            let snapshot = await TestSupport.final(service, title)
            XCTAssertEqual(snapshot?.hits.first?.id.rawValue, id, title)
            XCTAssertEqual(snapshot?.hits.first?.matchedField, .title, title)
        }
    }

    func testBodyMatching() async {
        let snapshot = await TestSupport.final(service, "circles")
        XCTAssertEqual(TestSupport.ids(snapshot), ["tip-thirty"])
        XCTAssertEqual(snapshot?.hits.first?.matchedField, .text)
    }

    func testCaptionAndOCRMatching() async {
        let caption = await TestSupport.final(service, "lighthouse")
        XCTAssertEqual(TestSupport.ids(caption), ["image-harbor"])
        XCTAssertEqual(caption?.hits.first?.matchedField, .caption)
        let ocr = await TestSupport.final(service, "dock")
        XCTAssertEqual(TestSupport.ids(ocr), ["image-harbor"])
        XCTAssertEqual(ocr?.hits.first?.matchedField, .ocrText)
    }

    func testKeywordMatchingOutranksBody() async {
        // "tracker" is a keyword and a title word of tool-box only.
        let snapshot = await TestSupport.final(service, "tracker")
        XCTAssertEqual(snapshot?.hits.first?.id, "tool-box")
    }

    func testPrefixMatchingOnTheLastToken() async {
        let prefix = await TestSupport.final(service, "outb")
        XCTAssertEqual(TestSupport.ids(prefix), ["game-outbreak"])
        let twoWords = await TestSupport.final(service, "sunken tem")
        XCTAssertEqual(twoWords?.hits.first?.id, "map-temple")
        // Only the last token expands: "sunk temple" has no exact "sunk".
        let middle = await TestSupport.final(service, "outb protocol")
        XCTAssertEqual(middle?.hits.first?.id, "game-outbreak")
        XCTAssertEqual(middle?.hits.first?.channels.contains(.lexical), true)
    }

    func testAnExactTokenOutranksItsCompletion() async {
        let items: [AnySearchable<CatalogKind>] = [
            Tool(id: "boxes", title: "Boxes", text: "many"),
            Tool(id: "box", title: "Box", text: "one"),
            Tool(id: "boxer", title: "Boxer", text: "fighter"),
        ].erased()
        let service = await TestSupport.indexedService(items)
        let snapshot = await TestSupport.final(service, "box")
        XCTAssertEqual(snapshot?.hits.first?.id, "box")
        XCTAssertEqual(Set(TestSupport.ids(snapshot)), ["box", "boxes", "boxer"])
    }

    // MARK: Empty and too-short queries

    func testEmptyAndTooShortQueriesReturnAnEmptyFinalSnapshotWithoutTouchingTheSemanticChannel() async {
        let semantic = StubSemantic()
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: semantic)
        for text in ["", "   ", "m", "?!", "\n"] {
            let snapshots = await TestSupport.all(service, CatalogQuery(text: text))
            XCTAssertEqual(snapshots.count, 1, "'\(text)'")
            XCTAssertEqual(snapshots.first?.isFinal, true, "'\(text)'")
            XCTAssertEqual(snapshots.first?.hits.isEmpty, true, "'\(text)'")
            XCTAssertNil(snapshots.first?.nextCursor)
        }
        let encodes = await semantic.encodeCalls
        let nearest = await semantic.nearestCalls
        XCTAssertEqual(encodes, 0)
        XCTAssertEqual(nearest, 0)
    }

    func testShortQueriesSkipTheSemanticPhaseWithDegradedSet() async {
        let semantic = StubSemantic()
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: semantic)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "bo"))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.phase, .lexical)
        XCTAssertEqual(snapshots.first?.isFinal, true)
        XCTAssertEqual(snapshots.first?.degraded, [.semantic])
        XCTAssertFalse(snapshots.first?.hits.isEmpty ?? true)
        let encodes = await semantic.encodeCalls
        XCTAssertEqual(encodes, 0)
    }

    func testASingleCJKCharacterIsNotTooShort() async {
        let snapshot = await TestSupport.final(
            await TestSupport.indexedService(TestSupport.catalog, configuration: TestSupport.configuration(locale: "ja")), "神"
        )
        XCTAssertEqual(snapshot?.hits.first?.id, "map-temple")
    }

    // MARK: Fuzzy

    func testFuzzyCorrectionAtDistanceOne() async {
        // 3 to 5 characters: one edit.
        let snapshot = await TestSupport.final(service, "timr")
        XCTAssertEqual(snapshot?.hits.first?.id, "tool-timer")
        XCTAssertEqual(snapshot?.hits.first?.channels, [.fuzzy])
    }

    func testFuzzyCorrectionAtDistanceTwo() async {
        // 6 or more characters: two edits.
        for typo in ["outbraek", "outbrek", "otbrak", "outbbreakk"] {
            let snapshot = await TestSupport.final(service, typo)
            XCTAssertEqual(snapshot?.hits.first?.id, "game-outbreak", typo)
            XCTAssertEqual(snapshot?.hits.first?.channels, [.fuzzy], typo)
        }
    }

    func testEditBudgetIsRespected() async {
        // Three edits on a long token, two on a short one: no correction.
        let long = await TestSupport.final(service, "otbrakk")
        XCTAssertTrue(TestSupport.ids(long).isEmpty)
        let short = await TestSupport.final(service, "tmmr")
        XCTAssertFalse(TestSupport.ids(short).contains("tool-timer"))
        // One or two characters: none.
        let tiny = await TestSupport.final(service, "bx")
        XCTAssertFalse(TestSupport.ids(tiny).contains("tool-box"))
    }

    func testNoExpansionForIdentifiersURLsAndModelNumbers() async {
        // The exact identifier matches.
        let exact = await TestSupport.final(service, "m1911-a1")
        XCTAssertEqual(TestSupport.ids(exact), ["tool-timer"])
        // One edit away: an identifier is never fuzzed.
        for near in ["m1912-a1", "m1911-a2", "m1911-a", "v1.2.4", "v1.2", "example.co", "exemple.com"] {
            let snapshot = await TestSupport.final(service, near)
            XCTAssertTrue(TestSupport.ids(snapshot).isEmpty, "\(near) found \(TestSupport.ids(snapshot))")
        }
        // The parts of an indexed identifier are still reachable on their own.
        let part = await TestSupport.final(service, "m1911")
        XCTAssertEqual(TestSupport.ids(part), ["tool-timer"])
        // A model number is never completed either.
        let prefix = await TestSupport.final(service, "m19")
        XCTAssertTrue(TestSupport.ids(prefix).isEmpty)
        let version = await TestSupport.final(service, "v1.2.3")
        XCTAssertEqual(TestSupport.ids(version), ["tool-timer"])
        let url = await TestSupport.final(service, "example.com")
        XCTAssertEqual(url?.hits.first?.id, "tool-calc")
    }

    func testPhraseTokensAreExactAndRequired() async {
        // "mystery box" appears as a phrase in three documents.
        let phrase = await TestSupport.final(service, CatalogQuery(text: "", tokens: [.phrase("mystery box")]))
        XCTAssertEqual(Set(TestSupport.ids(phrase)), ["tool-box", "map-temple", "tip-thirty"])
        // Reversed order is not the phrase.
        let reversed = await TestSupport.final(service, CatalogQuery(text: "", tokens: [.phrase("box mystery")]))
        XCTAssertTrue(TestSupport.ids(reversed).isEmpty)
        // A typo inside a phrase is not corrected, and a phrase is not completed.
        let typo = await TestSupport.final(service, CatalogQuery(text: "", tokens: [.phrase("mystry box")]))
        XCTAssertTrue(TestSupport.ids(typo).isEmpty)
        let partial = await TestSupport.final(service, CatalogQuery(text: "", tokens: [.phrase("mystery bo")]))
        XCTAssertTrue(TestSupport.ids(partial).isEmpty)
        // Quoted text is a phrase too, and constrains the rest of the query.
        let quoted = await TestSupport.final(service, "\"mystery box\" spawn")
        let quotedIDs = TestSupport.ids(quoted)
        XCTAssertEqual(Set(quotedIDs), ["tool-box", "map-temple", "tip-thirty"])
        // The title match leads; among the body matches the one that also has "spawn" is ahead.
        XCTAssertEqual(quotedIDs.first, "tool-box")
        XCTAssertLessThan(quotedIDs.firstIndex(of: "map-temple")!, quotedIDs.firstIndex(of: "tip-thirty")!)
    }

    // MARK: Kinds

    func testEveryHitCarriesAValidKindAndHitsByKindPartitionsWithoutLossOrReordering() async {
        var query = CatalogQuery(text: "harbor box round")
        query.limit = 50
        let snapshot = await TestSupport.final(service, query)
        let hits = snapshot?.hits ?? []
        XCTAssertGreaterThan(hits.count, 4)
        for hit in hits {
            XCTAssertTrue(CatalogKind.allCases.contains(hit.kind))
            XCTAssertEqual(hit.kind.rawValue, String(hit.id.rawValue.prefix { $0 != "-" }))
        }
        let groups = snapshot?.hitsByKind ?? [:]
        XCTAssertEqual(groups.values.reduce(0) { $0 + $1.count }, hits.count, "no loss")
        for (kind, group) in groups {
            XCTAssertEqual(group.map(\.id), hits.filter { $0.kind == kind }.map(\.id), "fused order kept inside \(kind)")
        }
    }

    func testADocumentWithAnUnknownKindIsDroppedAndLogged() async {
        let recorder = DiagnosticsRecorder()
        let index = LexicalIndex()
        // An index written by another app version: a kind this build does not know.
        await index.upsert([
            SearchDocument(id: "known", kind: "tool", title: "Lantern planner", text: "plan lantern routes"),
            SearchDocument(id: "alien", kind: "hologram", title: "Lantern hologram", text: "lantern lantern lantern"),
        ])
        let service = CatalogService(index: index, configuration: TestSupport.configuration(diagnostics: recorder.sink))
        let snapshot = await TestSupport.final(service, "lantern")
        XCTAssertEqual(TestSupport.ids(snapshot), ["known"])
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains(.unknownKind(id: "alien", rawKind: "hologram")))
    }

    // MARK: Filters

    func testTypedFiltersRoundTripThroughTheIndexAsRecords() async {
        let document = await service.document(for: "tool-calc")
        XCTAssertEqual(document?.filters, [
            FilterRecord(key: "category", value: "calculators"),
            FilterRecord(key: "platform", value: "ios"),
            FilterRecord(key: "platform", value: "mac"),
        ])
        // Rebuilt through Filter.init?(key:value:).
        let rebuilt = Set(document?.filters.compactMap { CatalogFilter(key: $0.key, value: $0.value) } ?? [])
        XCTAssertEqual(rebuilt, [.category(.calculators), .platform(.ios), .platform(.mac)])
        XCTAssertNil(CatalogFilter(key: "platform", value: "vr"), "a record unknown to this build")
    }

    func testFilterRecordsUnknownToTheBuildAreIgnoredAndLogged() async {
        let recorder = DiagnosticsRecorder()
        // "platform=vr" cannot be rebuilt by CatalogFilter: unknown to this build.
        struct Legacy: Searchable, FilterableSearchable {
            var searchID: SearchableID { "legacy" }
            var searchKind: CatalogKind { .tool }
            var searchText: String { "lantern planner" }
            var searchFilters: Set<CatalogFilter> { [.string(key: "platform", value: "vr"), .category(.guides)] }
        }
        let service = await TestSupport.indexedService([AnySearchable(Legacy())], configuration: TestSupport.configuration(diagnostics: recorder.sink))
        let document = await service.document(for: "legacy")
        XCTAssertEqual(document?.filters, [FilterRecord(key: "category", value: "guides")])
        let diagnostics = await recorder.finish()
        XCTAssertTrue(diagnostics.contains(.unknownFilter(id: "legacy", record: FilterRecord(key: "platform", value: "vr"))))
    }

    func testAnItemWithAForeignFilterTypeLosesItsFilters() async {
        let recorder = DiagnosticsRecorder()
        // The item declares SettingsFilter but the schema's filter is CatalogFilter: programmer error.
        struct Misfiled: Searchable, FilterableSearchable {
            var searchID: SearchableID { "misfiled" }
            var searchKind: CatalogKind { .tool }
            var searchText: String { "lantern planner" }
            var searchFilters: Set<SettingsFilter> { [.section("general")] }
        }
        let service = await TestSupport.indexedService([AnySearchable(Misfiled())], configuration: TestSupport.configuration(diagnostics: recorder.sink))
        let document = await service.document(for: "misfiled")
        XCTAssertEqual(document?.filters, [])
        let diagnostics = await recorder.finish()
        let mismatch = diagnostics.first { if case .filterTypeMismatch = $0 { return true } else { return false } }
        XCTAssertNotNil(mismatch)
        XCTAssertEqual(mismatch?.isProgrammerError, true, "a debug assertion")
    }

    func testFiltersAreANDAcrossKeysAndORWithinAKey() async {
        func ids(_ filters: Set<CatalogFilter>, text: String = "") async -> Set<String> {
            var query = CatalogQuery(text: text, filters: filters)
            query.limit = 50
            return Set(TestSupport.ids(await TestSupport.final(service, query)))
        }
        // One key, one value.
        let ios = await ids([.platform(.ios)])
        XCTAssertEqual(ios, ["tool-box", "tool-calc", "map-harbor"])
        // OR among values of the same key.
        let iosOrMac = await ids([.platform(.ios), .platform(.mac)])
        XCTAssertEqual(iosOrMac, ["tool-box", "tool-calc", "map-harbor", "tool-timer"])
        // AND across keys: {platform: ios, platform: mac, category: maps} means (ios or mac) and maps.
        let both = await ids([.platform(.ios), .platform(.mac), .category(.maps)])
        XCTAssertEqual(both, ["map-harbor"])
        let none = await ids([.platform(.tv), .category(.maps)])
        XCTAssertEqual(none, [])
        // The escape hatch behaves like any other key.
        let adhoc = await ids([.string(key: "region", value: "IT")])
        XCTAssertEqual(adhoc, ["map-harbor"])
    }

    func testFiltersAndKindTokensAreHardConstraints() async {
        // "harbor" matches a map, a tip and an image; tokens cut the list before retrieval.
        var query = CatalogQuery(text: "harbor", tokens: [.kind(.map)])
        query.limit = 50
        let maps = await TestSupport.final(service, query)
        XCTAssertEqual(TestSupport.ids(maps), ["map-harbor"])
        XCTAssertEqual(query.kinds, [.map], ".kind tokens join SearchQuery.kinds")

        let twoKinds = await TestSupport.final(service, CatalogQuery(text: "harbor", tokens: [.kind(.map), .kind(.image)]))
        XCTAssertEqual(Set(TestSupport.ids(twoKinds)), ["map-harbor", "image-harbor"])

        let filtered = CatalogQuery(text: "harbor", tokens: [.filter(.region(.italy))])
        XCTAssertEqual(filtered.filters, [.region(.italy)], ".filter tokens join SearchQuery.filters")
        let italy = await TestSupport.final(service, filtered)
        XCTAssertEqual(TestSupport.ids(italy), ["map-harbor"])

        // A boost only reorders what survived: it can never bring a filtered document back.
        var profile = RankingProfile.default
        profile.kindBoosts = ["tip": 10]
        await service.setProfile(profile)
        let boosted = await TestSupport.final(service, query)
        XCTAssertEqual(TestSupport.ids(boosted), ["map-harbor"])
    }

    func testFiltersAreNeverFuzzedPrefixMatchedOrLocalized() async {
        // A filter value is matched by equality on the record only.
        let near = await TestSupport.final(service, CatalogQuery(text: "", filters: [.string(key: "platform", value: "io")]))
        XCTAssertTrue(TestSupport.ids(near).isEmpty)
        let cased = await TestSupport.final(service, CatalogQuery(text: "", filters: [.string(key: "platform", value: "IOS")]))
        XCTAssertTrue(TestSupport.ids(cased).isEmpty)
        // A filter value is not text: typing it finds nothing by that alone.
        let typed = await TestSupport.final(service, "calculators")
        XCTAssertFalse(TestSupport.ids(typed).contains("tool-timer"))
    }

    func testPureTokenQueriesSkipSemanticAndReturnWhatSurvivesTheConstraints() async {
        let semantic = StubSemantic()
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: semantic)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "", tokens: [.kind(.tool)]))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.degraded, [.semantic])
        XCTAssertEqual(Set(TestSupport.ids(snapshots.first)), ["tool-box", "tool-timer", "tool-calc"])
        let encodes = await semantic.encodeCalls
        XCTAssertEqual(encodes, 0)
    }

    // MARK: Fallback schema

    func testStringSchemaBehavesLikeTheOriginalStringDesign() async {
        struct Note: Searchable, TitledSearchable, FilterableSearchable {
            var searchID: SearchableID
            var searchKind: ZTronStringKind
            var searchText: String
            var searchTitle: String
            var searchFilters: Set<ZTronStringFilter>
        }
        let notes = [
            Note(searchID: "n1", searchKind: "note", searchText: "buy lantern oil", searchTitle: "Shopping",
                 searchFilters: [.string(key: "tag", value: "home"), .string(key: "color", value: "red")]),
            Note(searchID: "n2", searchKind: "reminder", searchText: "lantern festival tonight", searchTitle: "Festival",
                 searchFilters: [.string(key: "tag", value: "fun"), .string(key: "color", value: "red")]),
            Note(searchID: "n3", searchKind: "anything-goes", searchText: "lantern repair", searchTitle: "Repair",
                 searchFilters: [.string(key: "tag", value: "home"), .string(key: "color", value: "blue")]),
        ]
        let service = ZTronSearchService(index: LexicalIndex(), configuration: TestSupport.configuration())
        await service.index(notes)

        // Any string is a kind; every hit reports it.
        let all = await TestSupport.final(service, SearchQuery<ZTronStringSchema>(text: "lantern"))
        XCTAssertEqual(Set(all?.hits.map(\.kind.rawValue) ?? []), ["note", "reminder", "anything-goes"])
        // Key and value both count: AND across keys, OR within a key.
        let homeRed = await TestSupport.final(service, SearchQuery<ZTronStringSchema>(
            text: "lantern", filters: [.string(key: "tag", value: "home"), .string(key: "color", value: "red")]
        ))
        XCTAssertEqual(TestSupport.ids(homeRed), ["n1"])
        let homeOrFun = await TestSupport.final(service, SearchQuery<ZTronStringSchema>(
            text: "lantern", filters: [.string(key: "tag", value: "home"), .string(key: "tag", value: "fun")]
        ))
        XCTAssertEqual(Set(TestSupport.ids(homeOrFun)), ["n1", "n2", "n3"])
        // The same value under another key is another dimension.
        let wrongKey = await TestSupport.final(service, SearchQuery<ZTronStringSchema>(
            text: "lantern", filters: [.string(key: "color", value: "home")]
        ))
        XCTAssertTrue(TestSupport.ids(wrongKey).isEmpty)
        let kind = await TestSupport.final(service, SearchQuery<ZTronStringSchema>(text: "lantern", kinds: ["reminder"]))
        XCTAssertEqual(TestSupport.ids(kind), ["n2"])
    }

    // MARK: Token-to-query mapping (section 12.2, rule 10)

    func testTokenToQueryMappingIsPure() {
        let query = CatalogQuery(
            text: "harbor",
            tokens: [.filter(.platform(.ios)), .kind(.map), .phrase("power switch"), .filter(.category(.maps)), .kind(.tip)],
            filters: [.region(.italy)],
            kinds: nil
        )
        XCTAssertEqual(query.filters, [.platform(.ios), .category(.maps), .region(.italy)])
        XCTAssertEqual(query.kinds, [.map, .tip])
        XCTAssertEqual(query.phrases, ["power switch"])
        XCTAssertEqual(query, CatalogQuery(
            text: "harbor",
            tokens: [.filter(.platform(.ios)), .kind(.map), .phrase("power switch"), .filter(.category(.maps)), .kind(.tip)],
            filters: [.region(.italy)]
        ))
        XCTAssertNil(CatalogQuery(text: "x").kinds, "nil = every kind")
        XCTAssertEqual(CatalogQuery(text: "x").limit, 20)
    }

    // MARK: Highlights

    func testHitsReportTheMatchedFieldLanguageAndHighlightRanges() async throws {
        let snapshot = await TestSupport.final(service, "frozn harbr")
        let hit = try XCTUnwrap(snapshot?.hits.first)
        XCTAssertEqual(hit.id, "map-harbor")
        XCTAssertEqual(hit.matchedField, .title)
        XCTAssertEqual(hit.matchedLanguage, "en")
        let document = await service.document(for: hit.id)
        let surface = try XCTUnwrap(document?.surface(for: .title))
        XCTAssertEqual(hit.highlights.map { String(surface[$0]) }, ["Frozen", "Harbor"])
    }
}
