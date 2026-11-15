import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, "Search contexts (section 9.1)".
final class SearchContextTests: XCTestCase {
    private func settings() -> [SettingEntry] {
        [
            SettingEntry(id: "x1", title: "Lantern brightness", text: "How bright the lantern glows", section: "display"),
            SettingEntry(id: "x2", kind: .action, title: "Reset lantern", text: "Restore the defaults", section: "general"),
            SettingEntry(id: "x3", title: "Notifications", text: "Alerts and sounds", section: "general"),
        ]
    }

    private func catalogItems() -> [AnySearchable<CatalogKind>] {
        [
            AnySearchable(Tool(id: "x1", title: "Lantern planner", text: "Plan lantern routes through the harbor", keywords: ["lantern"])),
            AnySearchable(Tool(id: "x2", title: "Harbor timer", text: "Times the harbor rounds")),
            AnySearchable(MapItem(id: "x9", title: "Lantern district", text: "Streets lit by lanterns")),
        ]
    }

    // MARK: Disjointness

    func testContextsWithCollidingIDsAndDifferentSchemasNeverSeeEachOther() async {
        struct Popular: PopularityProvider {
            let favourite: SearchableID
            func popularity(for id: SearchableID) throws -> Double? { id == favourite ? 1_000_000 : nil }
        }
        // Popularity weighs as much as the specification allows here, so that each context's
        // favourite leads its list. At the default weight it would only break ties.
        var profile = RankingProfile.default
        profile.popularity = SignalSpec(weight: SignalSpec.maximumPopularityWeight)
        let catalog = CatalogService(
            context: SearchContext(id: "catalog", items: catalogItems(), strategy: .scan),
            profile: profile,
            signals: SignalProviders(popularity: Popular(favourite: "x9")),
            configuration: TestSupport.configuration()
        )
        let picker = SearchService<SettingsSchema>(
            context: SearchContext(id: "settings", items: settings(), strategy: .scan),
            profile: profile,
            signals: SignalProviders(popularity: Popular(favourite: "x2")),
            configuration: TestSupport.configuration()
        )

        let fromCatalog = await TestSupport.final(catalog, "lantern")
        let fromPicker = await TestSupport.final(picker, SearchQuery<SettingsSchema>(text: "lantern"))

        // Same ids, different documents: each context returns only its own, typed by its schema.
        XCTAssertEqual(Set(TestSupport.ids(fromCatalog)), ["x1", "x9"])
        XCTAssertEqual(Set(TestSupport.ids(fromPicker)), ["x1", "x2"])
        XCTAssertEqual(Set(fromCatalog?.hits.map(\.kind) ?? []), [.tool, .map])
        XCTAssertEqual(Set(fromPicker?.hits.map(\.kind) ?? []), [.setting, .action])
        let pickerDocument = await picker.document(for: "x1")
        let catalogDocument = await catalog.document(for: "x1")
        XCTAssertEqual(pickerDocument?.title, "Lantern brightness")
        XCTAssertEqual(catalogDocument?.title, "Lantern planner")

        // Every snapshot carries the id of the context that produced it.
        XCTAssertEqual(fromCatalog?.contextID, "catalog")
        XCTAssertEqual(fromPicker?.contextID, "settings")
        XCTAssertEqual(catalog.contextID, "catalog")
        XCTAssertEqual(picker.contextID, "settings")

        // Signals are per context: each popularity provider lifts its own favourite only.
        XCTAssertEqual(fromCatalog?.hits.first?.id, "x9")
        XCTAssertEqual(fromPicker?.hits.first?.id, "x2")

        // Generation counters are independent.
        _ = await TestSupport.final(catalog, "harbor")
        _ = await TestSupport.final(catalog, "timer")
        let again = await TestSupport.final(picker, SearchQuery<SettingsSchema>(text: "lantern"))
        XCTAssertEqual(again?.generation, (fromPicker?.generation ?? 0) + 1)
    }

    func testStatisticsAreNotSharedBetweenContexts() async {
        let lonely = CatalogService(
            context: SearchContext(id: "a", items: catalogItems(), strategy: .scan), configuration: TestSupport.configuration()
        )
        let before = await TestSupport.final(lonely, "lantern")

        // A second context floods the term "lantern". Document frequencies there must not move
        // a single score here.
        let flood: [AnySearchable<CatalogKind>] = (0..<400).map { Tool(id: "flood-\($0)", title: "Lantern \($0)", text: "lantern lantern") }.erased()
        let crowded = CatalogService(
            context: SearchContext(id: "b", items: flood, strategy: .scan), configuration: TestSupport.configuration()
        )
        _ = await TestSupport.final(crowded, "lantern")
        let after = await TestSupport.final(lonely, "lantern")
        XCTAssertEqual(before?.hits.map(\.score), after?.hits.map(\.score))
        XCTAssertEqual(before?.hits.map(\.id), after?.hits.map(\.id))
    }

    // MARK: Strategy

    func testAutomaticStrategyScansUpToFiveHundredDocumentsAndIndexesAbove() async {
        var corpus = RandomCorpus(seed: 3)
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let small = CatalogService(
            context: SearchContext(id: "small", sources: [.memory(corpus.items(500))], indexStorage: .files(directory)),
            configuration: TestSupport.configuration()
        )
        let large = CatalogService(
            context: SearchContext(id: "large", sources: [.memory(corpus.items(501))], indexStorage: .inMemory),
            configuration: TestSupport.configuration()
        )
        let smallScans = await small.usesScanStrategy
        let largeScans = await large.usesScanStrategy
        XCTAssertTrue(smallScans)
        XCTAssertFalse(largeScans)

        // The threshold is per context; a context that outgrows it moves to the index.
        await small.index(corpus.items(1, prefix: "extra"))
        let grown = await small.usesScanStrategy
        let count = await small.count
        XCTAssertFalse(grown)
        XCTAssertEqual(count, 501)
        let snapshot = await TestSupport.final(small, "map")
        XCTAssertFalse(TestSupport.ids(snapshot).isEmpty)
    }

    func testScanContextsPublishOneFinalSnapshotAndNeverDebounce() async {
        let service = CatalogService(
            context: SearchContext(id: "picker", items: catalogItems(), strategy: .scan),
            configuration: TestSupport.configuration(lexicalDebounce: 5, semanticDebounce: 5)
        )
        let started = Date()
        // A keystroke, not a submit: an indexed context would wait for the debounce.
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "lantern"), trigger: .typing)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.isFinal, true)
        XCTAssertEqual(snapshots.first?.degraded, [])
        XCTAssertEqual(snapshots.first?.phase, .lexical)
    }

    func testScanContextWithVectorsRunsSemanticByBruteForceBehindThePause() async {
        let semantic = StubSemantic(dimensions: 3)
        await semantic.setVector([1, 0, 0])
        let items: [AnySearchable<CatalogKind>] = [
            Tip(id: "near", title: "Unrelated words", text: "nothing lexical here", embedding: [0.9, 0.1, 0]),
            Tip(id: "far", title: "Other words", text: "still nothing", embedding: [0, 1, 0]),
            Tip(id: "lexical", title: "Lantern", text: "lantern", embedding: [0, 0, 1]),
        ].erased()
        let service = CatalogService(
            context: SearchContext(id: "vectors", sources: [.memory(items)], strategy: .scan),
            semantic: semantic, configuration: TestSupport.configuration()
        )
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "lantern"))
        XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic])
        XCTAssertEqual(snapshots.map(\.isFinal), [false, true])
        XCTAssertEqual(TestSupport.ids(snapshots.first), ["lexical"])
        // Brute-force dot product over the context: the nearest vector comes right after the lexical hit.
        XCTAssertEqual(TestSupport.ids(snapshots.last), ["lexical", "near", "far"])
        XCTAssertEqual(snapshots.last?.hits[1].channels, [.semantic])
        let encodes = await semantic.encodeCalls
        let nearest = await semantic.nearestCalls
        XCTAssertEqual(encodes, 1, "only the query is encoded")
        XCTAssertEqual(nearest, 0, "never HNSW")

        // Without vectors the same context publishes one final snapshot.
        let plain = TestSupport.scanService(TestSupport.catalog, semantic: semantic)
        let single = await TestSupport.all(plain, CatalogQuery(text: "harbor"))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.degraded, [])
    }

    // MARK: Lifecycle

    func testReplaceItemsIsWholesale() async {
        let service = CatalogService(
            context: SearchContext(id: "picker", items: catalogItems(), strategy: .scan), configuration: TestSupport.configuration()
        )
        await service.replace(items: [Tool(id: "new", title: "Compass", text: "Points north")])
        let count = await service.count
        XCTAssertEqual(count, 1)
        let old = await TestSupport.final(service, "lantern")
        XCTAssertTrue(TestSupport.ids(old).isEmpty)
        let new = await TestSupport.final(service, "compass")
        XCTAssertEqual(TestSupport.ids(new), ["new"])
        // An indexed context replaces too, on the same index.
        let indexed = CatalogService(
            context: SearchContext(id: "indexed", sources: [.memory(catalogItems())], strategy: .indexed, indexStorage: .inMemory),
            configuration: TestSupport.configuration()
        )
        await indexed.replace(items: [Tool(id: "new", title: "Compass", text: "Points north")])
        let indexedCount = await indexed.count
        XCTAssertEqual(indexedCount, 1)
        let gone = await TestSupport.final(indexed, "lantern")
        XCTAssertTrue(TestSupport.ids(gone).isEmpty)
    }

    func testAContextIsAValue() {
        var context = SearchContext<CatalogSchema>(id: "picker", items: [Tool(id: "a", title: "A", text: "a")])
        let copy = context
        context.memoryItems.append(AnySearchable(Tool(id: "b", title: "B", text: "b")))
        XCTAssertEqual(context.memoryItems.count, 2)
        XCTAssertEqual(copy.memoryItems.count, 1, "copies are independent")
        XCTAssertEqual(context.strategy, .automatic)
        XCTAssertFalse(context.hasDatabaseSources)
    }

    @available(macOS 13.0, iOS 16.0, *)
    func testTheSpecificationSpellingWorksWhereTheRuntimeAllowsIt() async {
        // `[any Searchable<Schema.Kind>]`: heterogeneous items, kind checked at compile time.
        let items: [any Searchable<CatalogKind>] = [
            Tool(id: "tool", title: "Lantern planner", text: "x"),
            MapItem(id: "map", title: "Lantern district", text: "y"),
        ]
        var context = SearchContext<CatalogSchema>(id: "spec", items: items, strategy: .scan)
        XCTAssertEqual(context.items.count, 2)
        context.items.append(Tip(id: "tip", title: "Lantern tips", text: "z"))
        XCTAssertEqual(context.memoryItems.count, 3)

        let service = CatalogService(context: context, configuration: TestSupport.configuration())
        await service.index([Game(id: "game", title: "Lantern quest", text: "q")] as [any Searchable<CatalogKind>])
        let snapshot = await TestSupport.final(service, "lantern")
        XCTAssertEqual(Set(snapshot?.hits.map(\.kind) ?? []), [.tool, .map, .tip, .game])
        await service.replace(items: items)
        let count = await service.count
        XCTAssertEqual(count, 2)

        let index = ScanIndex<CatalogSchema>(items: items)
        XCTAssertEqual(index.count, 2)
        if case .memory(let erased) = SearchSource<CatalogSchema>.memory(items) {
            XCTAssertEqual(erased.count, 2)
        } else {
            XCTFail("expected a memory source")
        }
    }

    func testAContextWithItsOwnLocaleNormalizesAndMatchesInThatLocale() async {
        let harbor = MapItem(id: "harbor", title: "Frozen Harbor", text: "x", localizations: ["it": SearchLocalization(title: "Porto Ghiacciato")])
        // The engine default is English; this context searches in Italian.
        let italian = CatalogService(
            context: SearchContext(id: "it", items: [harbor], locale: Locale(identifier: "it_IT"), strategy: .scan),
            configuration: TestSupport.configuration(locale: "en")
        )
        let english = CatalogService(
            context: SearchContext(id: "en", items: [harbor], strategy: .scan),
            configuration: TestSupport.configuration(locale: "en")
        )
        let found = await TestSupport.final(italian, "porto")
        let missing = await TestSupport.final(english, "porto")
        XCTAssertEqual(found?.hits.first?.matchedLanguage, "it")
        XCTAssertTrue(TestSupport.ids(missing).isEmpty)
        let languages = await italian.resolvedLanguages
        XCTAssertEqual(languages.active, "it-IT")
    }

    // MARK: ScanIndex

    @MainActor
    func testScanIndexAnswersSynchronouslyOnTheMainActor() {
        // No `await` anywhere: the call returns in the same run-loop turn it was made in.
        let index = ScanIndex<CatalogSchema>(
            items: TestSupport.catalog, locale: Locale(identifier: "en"), configuration: TestSupport.configuration()
        )
        XCTAssertTrue(Thread.isMainThread)
        let hits = index.hits(for: CatalogQuery(text: "sunkn temple"))
        XCTAssertEqual(hits.first?.id, "map-temple")
        XCTAssertEqual(hits.first?.kind, .map)
        XCTAssertEqual(hits.first?.channels, [.lexical, .fuzzy])
        XCTAssertEqual(index.count, TestSupport.catalog.count)

        var paged = CatalogQuery(text: "harbor")
        paged.limit = 1
        let first = index.snapshot(for: paged)
        XCTAssertEqual(first.hits.count, 1)
        XCTAssertTrue(first.isFinal)
        paged.cursor = first.nextCursor
        let second = index.snapshot(for: paged)
        XCTAssertNotEqual(second.hits.first?.id, first.hits.first?.id)
    }

    func testScanIndexMatchesTheServiceOverTheSameItems() async {
        var corpus = RandomCorpus(seed: 21)
        let items = corpus.items(120)
        let index = ScanIndex<CatalogSchema>(items: items, locale: Locale(identifier: "en"), configuration: TestSupport.configuration())
        let service = TestSupport.scanService(items)
        for _ in 0..<60 {
            let query = corpus.query()
            let fromService = await TestSupport.final(service, query)
            let direct = index.snapshot(for: query)
            XCTAssertEqual(direct.hits.map(\.id), fromService?.hits.map(\.id), query.text)
            XCTAssertEqual(direct.hits.map(\.score), fromService?.hits.map(\.score), query.text)
        }
    }

    // MARK: Cost

    func testAScanContextPerformsNoDiskIO() async {
        let directory = TestSupport.temporaryDirectory()
        do {
            let service = CatalogService(
                context: SearchContext(id: "picker", sources: [.memory(TestSupport.catalog)], indexStorage: .files(directory)),
                configuration: TestSupport.configuration()
            )
            for text in ["harbor", "mystery box", "timr", ""] {
                _ = await TestSupport.final(service, text)
            }
            await service.replace(items: [Tool(id: "new", title: "Compass", text: "Points north")])
            await service.persist()
            await service.refresh()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the scan strategy never touches disk")
    }

    func testAnIndexedContextPersistsUnderItsOwnFileAndReloadsIt() async throws {
        var corpus = RandomCorpus(seed: 5)
        let items = corpus.items(700)
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = SearchContext<CatalogSchema>(id: "catalog/main", sources: [.memory(items)], indexStorage: .files(directory))

        let first = CatalogService(context: context, configuration: TestSupport.configuration())
        await first.persist()
        let file = CatalogService.indexFileURL(in: directory, contextID: "catalog/main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(file.lastPathComponent.hasSuffix(".v\(SearchDocument.projectionVersion).ztsi"), "keyed by contextID and projectionVersion")
        let query = corpus.query()
        let expected = RankingFingerprint(await TestSupport.final(first, query))

        // A second service over the same content memory-maps the file instead of rebuilding.
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let second = CatalogService(context: context, configuration: TestSupport.configuration())
        let restored = RankingFingerprint(await TestSupport.final(second, query))
        XCTAssertEqual(restored, expected)
        let unchanged = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, unchanged)

        // Different content under the same id: the stale file is not trusted.
        var changed = context
        changed.memoryItems.append(AnySearchable(Tool(id: "added", title: "Zeppelin hangar", text: "new")))
        let third = CatalogService(context: changed, configuration: TestSupport.configuration())
        let found = await TestSupport.final(third, "zeppelin")
        XCTAssertEqual(TestSupport.ids(found), ["added"])
    }

    func testCreatingAndReleasingContextsDoesNotGrowMemory() async {
        func footprint() -> Int64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
        }
        var corpus = RandomCorpus(seed: 11)
        let items = corpus.items(40)

        func cycle() async -> Bool {
            weak var released: CatalogService?
            do {
                let service = CatalogService(
                    context: SearchContext(id: "picker", sources: [.memory(items)]), configuration: TestSupport.configuration()
                )
                released = service
                _ = await TestSupport.final(service, "map")
                await service.replace(items: Array(items.prefix(10)))
                _ = await TestSupport.final(service, "box")
            }
            // The task that produced the last stream lets go of the service a moment after its
            // consumer has seen the stream end.
            var waited = 0
            while released != nil && waited < 200 {
                try? await Task.sleep(nanoseconds: 500_000)
                waited += 1
            }
            return released == nil
        }
        // Warm up allocators and caches, then measure.
        for _ in 0..<100 { _ = await cycle() }
        let before = footprint()
        var freed = 0
        for _ in 0..<1_000 where await cycle() { freed += 1 }
        let growth = footprint() - before
        XCTAssertEqual(freed, 1_000, "releasing a context frees the service")
        XCTAssertLessThan(growth, 2 * 1024 * 1024, "no growth across 1,000 create-and-release cycles (grew \(growth) bytes)")
    }
}
