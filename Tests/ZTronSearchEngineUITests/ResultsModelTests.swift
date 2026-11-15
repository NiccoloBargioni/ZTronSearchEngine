import Combine
import XCTest
import ZTronSearchEngine
import ZTronSearchFixtures
@testable import ZTronSearchEngineUI

/// The results and suggestions models (specification section 13).
@MainActor
final class ResultsModelTests: XCTestCase {
    private func idle(_ model: CatalogResults) async {
        let done = await eventually { !model.isLoading }
        XCTAssertTrue(done, "the model never finished loading")
    }

    // MARK: Updates

    func testUpdatePublishesTheSnapshotOfTheCurrentQuery() async {
        let model = CatalogResults(service: await UIFixtures.service())
        XCTAssertNil(model.phase)
        XCTAssertFalse(model.isLoading)
        model.update(text: "frozen harbor", tokens: [])
        XCTAssertTrue(model.isLoading, "loading from the first keystroke")
        await idle(model)
        XCTAssertEqual(model.hits.first?.id, "map-harbor")
        XCTAssertEqual(model.hits.first?.kind, .map)
        XCTAssertEqual(model.phase, .lexical)
        XCTAssertEqual(model.degraded, [])
        XCTAssertNil(model.error)
        XCTAssertEqual(model.query.text, "frozen harbor")
    }

    func testUpdateReturnsEarlyWhenTheQueryDidNotChange() async {
        let model = CatalogResults(service: await UIFixtures.service())
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        model.update(text: "harbor", tokens: [])
        await idle(model)
        let settled = changes
        XCTAssertGreaterThan(settled, 0)
        // The same text and tokens again, as every re-render does.
        for _ in 0..<50 { model.update(text: "harbor", tokens: []) }
        await settle()
        XCTAssertEqual(changes, settled, "an equal query publishes nothing and starts nothing")
        // Token ids are not part of the query: a re-created chip for the same filter is equal.
        model.update(text: "harbor", tokens: [CatalogToken(kind: .kind(.map), text: "Maps")])
        await idle(model)
        let afterToken = changes
        model.update(text: "harbor", tokens: [CatalogToken(kind: .kind(.map), text: "Maps again")])
        await settle()
        XCTAssertEqual(changes, afterToken)
        XCTAssertEqual(model.hits.map(\.id), ["map-harbor"])
    }

    func testTokensConstrainTheResults() async {
        let model = CatalogResults(service: await UIFixtures.service())
        model.update(text: "harbor", tokens: [CatalogToken(kind: .kind(.tip), text: "Tips")])
        await idle(model)
        XCTAssertEqual(model.hits.map(\.id), ["tip-harbor"])
        model.update(text: "lantern", tokens: [CatalogToken(kind: .filter(.platform(.mac)), text: "Mac")])
        await idle(model)
        XCTAssertEqual(model.hits.count, 20)
        XCTAssertTrue(model.hits.allSatisfy { Int($0.id.rawValue.suffix(2))! % 2 == 1 })
    }

    func testHitsByKindPartitionsTheHits() async {
        let model = CatalogResults(service: await UIFixtures.service())
        model.update(text: "harbor", tokens: [])
        await idle(model)
        let groups = model.hitsByKind
        XCTAssertEqual(Set(groups.keys), [.map, .tip])
        XCTAssertEqual(groups.values.reduce(0) { $0 + $1.count }, model.hits.count)
        for (kind, group) in groups {
            XCTAssertEqual(group.map(\.id), model.hits.filter { $0.kind == kind }.map(\.id))
        }
    }

    func testIsLoadingEndsOnTheFinalSnapshotOrACancellation() async {
        let semantic = FakeSemanticStub()
        await semantic.setDelay(0.15)
        let model = CatalogResults(service: await UIFixtures.service(semantic: semantic))
        model.update(text: "harbor", tokens: [])
        // The lexical snapshot arrives first and is not final: still loading.
        let lexical = await eventually { model.phase == .lexical }
        XCTAssertTrue(lexical)
        XCTAssertTrue(model.isLoading, "loading until the final snapshot")
        XCTAssertFalse(model.hasMore)
        let final = await eventually { model.phase == .semantic }
        XCTAssertTrue(final)
        XCTAssertFalse(model.isLoading)

        // A cancellation ends loading too.
        model.update(text: "lantern", tokens: [])
        XCTAssertTrue(model.isLoading)
        model.reset()
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertNil(model.phase)
        await settle(0.3)
        XCTAssertTrue(model.hits.isEmpty, "nothing is published after a reset")
    }

    func testSubmitRunsEveryPhaseImmediately() async {
        let semantic = FakeSemanticStub()
        let service = CatalogSearch(index: LexicalIndex(), semantic: semantic, configuration: UIFixtures.configuration(lexicalDebounce: 5, semanticDebounce: 10))
        await service.index(UIFixtures.items)
        let model = CatalogResults(service: service)
        model.update(text: "harbor", tokens: [])
        await settle(0.1)
        XCTAssertTrue(model.hits.isEmpty, "still inside the debounce")
        model.submit()
        let done = await eventually(timeout: 2) { model.phase == .semantic && !model.isLoading }
        XCTAssertTrue(done, "submit skips both timers")
    }

    // MARK: Stale results

    /// Zero stale snapshots published over a randomized sequence of 10,000 query changes.
    func testNoStaleSnapshotsOverTenThousandRandomizedQueryChanges() async {
        // Every query text maps to exactly one item, so a published hit names its query.
        let items: [AnySearchable<CatalogKind>] = (0..<40).map { AnySearchable(Tool(id: "item-\($0)", title: "unique\($0)word", text: "x")) }
        let semantic = FakeSemanticStub()
        let service = CatalogSearch(index: LexicalIndex(), semantic: semantic, configuration: UIFixtures.configuration(lexicalDebounce: 0.0005, semanticDebounce: 0.001))
        await service.index(items)
        let model = CatalogResults(service: service)

        var stale = 0
        var published = 0
        let observation = model.$hits.dropFirst().sink { hits in
            guard let first = hits.first else { return }
            published += 1
            // The hit that was just published must answer the query the model holds right now.
            if "unique\(first.id.rawValue.dropFirst(5))word" != model.query.text { stale += 1 }
        }
        defer { observation.cancel() }

        var generator = SystemRandomNumberGenerator()
        for step in 0..<10_000 {
            model.update(text: "unique\(Int.random(in: 0..<40, using: &generator))word", tokens: [])
            switch step % 7 {
            case 0: try? await Task.sleep(nanoseconds: 1_500_000)
            case 1, 2, 3: await Task.yield()
            default: break
            }
            if step % 997 == 0 { model.submit() }
        }
        await idle(model)
        XCTAssertEqual(stale, 0, "\(stale) stale snapshots out of \(published) published")
        XCTAssertGreaterThan(published, 50, "the test must actually publish")
        XCTAssertEqual(model.hits.first.map { "unique\($0.id.rawValue.dropFirst(5))word" }, model.query.text)
    }

    func testASnapshotOfAnotherQueryIsNotApplied() async {
        let model = CatalogResults(service: await UIFixtures.service())
        model.update(text: "harbor", tokens: [])
        await idle(model)
        let before = model.hits
        // A late snapshot for a query the model has left behind.
        let foreign = SearchSnapshot<CatalogSchema>(
            query: SearchQuery(text: "lantern"), generation: 999, phase: .semantic,
            hits: [SearchHit(id: "ghost", kind: .tool, score: 1, channels: [.lexical])], isFinal: true
        )
        model.applyForTesting(foreign)
        XCTAssertEqual(model.hits, before, "the UI boundary checks query equality before publishing")
        XCTAssertEqual(model.phase, .lexical)
    }

    // MARK: Paging

    func testPagingAppendsAndStopsAtTheEnd() async {
        let model = CatalogResults(service: await UIFixtures.service())
        model.update(text: "lantern", tokens: [])
        await idle(model)
        XCTAssertEqual(model.hits.count, 20)
        XCTAssertTrue(model.hasMore)

        model.loadNextPage()
        let second = await eventually { model.hits.count == 40 }
        XCTAssertTrue(second)
        model.loadNextPage()
        let third = await eventually { model.hits.count == 60 }
        XCTAssertTrue(third)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(Set(model.hits.map(\.id)).count, 60, "no hit is repeated")
        // Past the end nothing is requested.
        let requests = model.pageRequestCount
        model.loadNextPage()
        await settle()
        XCTAssertEqual(model.pageRequestCount, requests)
        XCTAssertEqual(model.hits.count, 60)
    }

    func testARepeatedTriggerNeverDuplicatesAPageRequest() async {
        let model = CatalogResults(service: await UIFixtures.service())
        model.update(text: "lantern", tokens: [])
        await idle(model)
        // List prefetching fires the trigger early and often.
        for _ in 0..<200 { model.loadNextPage() }
        XCTAssertEqual(model.pageRequestCount, 1, "one request per cursor")
        let appended = await eventually { model.hits.count == 40 }
        XCTAssertTrue(appended)
        for _ in 0..<200 { model.loadNextPage() }
        XCTAssertEqual(model.pageRequestCount, 2)
        let all = await eventually { model.hits.count == 60 }
        XCTAssertTrue(all)
        XCTAssertEqual(Set(model.hits.map(\.id)).count, 60, "zero duplicate page requests, zero duplicate hits")
    }

    func testAQueryChangeCancelsThePageInFlightAndClearsTheCursor() async {
        let model = CatalogResults(service: await UIFixtures.service())
        model.update(text: "lantern", tokens: [])
        await idle(model)
        XCTAssertTrue(model.hasMore)
        model.loadNextPage()
        // The query changes before the page lands.
        model.update(text: "harbor", tokens: [])
        XCTAssertFalse(model.hasMore, "the cursor is cleared at once")
        await idle(model)
        await settle(0.1)
        XCTAssertEqual(Set(model.hits.map(\.id)), ["map-harbor", "tip-harbor"], "the late page is not appended to the new results")
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error, "a stale page is not an error")
    }

    // MARK: Scan contexts

    func testAScanModelPublishesTheFinalSnapshotInTheSameTurn() {
        let model = CatalogResults(scan: UIFixtures.scanIndex())
        var loadingStates: [Bool] = []
        let observation = model.$isLoading.sink { loadingStates.append($0) }
        defer { observation.cancel() }

        // No `await` between the keystroke and the assertion: no debounce, no actor hop.
        model.update(text: "frozen harbor", tokens: [])
        XCTAssertEqual(model.hits.first?.id, "map-harbor")
        XCTAssertEqual(model.phase, .lexical)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(loadingStates, [false], "a scan model never even enters the loading state")

        model.update(text: "lantern", tokens: [CatalogToken(kind: .filter(.platform(.ios)), text: "iOS")])
        XCTAssertEqual(model.hits.count, 20)
        XCTAssertTrue(model.hasMore)
        // Paging is synchronous too.
        model.loadNextPage()
        XCTAssertEqual(model.hits.count, 30)
        XCTAssertFalse(model.hasMore)
        model.update(text: "", tokens: [])
        XCTAssertTrue(model.hits.isEmpty)
    }

    func testSeveralModelsForSeveralContextsLiveSideBySide() async {
        let catalog = CatalogResults(service: await UIFixtures.service())
        let picker = ZTronSearchResultsModel<SettingsSchema>(scan: ScanIndex(
            items: [SettingEntry(id: "lantern-00", title: "Lantern brightness"), SettingEntry(id: "s2", kind: .action, title: "Reset")],
            locale: Locale(identifier: "en"), configuration: UIFixtures.configuration()
        ))
        catalog.update(text: "lantern 0", tokens: [])
        picker.update(text: "lantern", tokens: [])
        await idle(catalog)
        // The same id, two contexts, two schemas: neither sees the other.
        XCTAssertEqual(picker.hits.map(\.kind), [.setting])
        XCTAssertEqual(catalog.hits.first?.kind, .tool)
        XCTAssertEqual(picker.hits.first?.id, catalog.hits.first?.id)
    }

    // MARK: Cost

    func testPublishingTwentyHitsCostsUnderAMillisecondOnMain() {
        let model = CatalogResults(scan: UIFixtures.scanIndex())
        model.update(text: "anything", tokens: [])
        let hits = (0..<20).map { SearchHit<CatalogKind>(id: SearchableID("hit-\($0)"), kind: .tool, score: Double(20 - $0), channels: [.lexical, .fuzzy], matchedField: .title, matchedLanguage: "en") }
        var durations: [TimeInterval] = []
        for round in 0..<400 {
            // Alternate two different lists so every round really publishes 20 new hits.
            let snapshot = SearchSnapshot<CatalogSchema>(
                query: model.query, generation: UInt64(round), phase: .lexical,
                hits: round % 2 == 0 ? hits : Array(hits.reversed()),
                nextCursor: SearchCursor(offset: 20), isFinal: true
            )
            let start = DispatchTime.now().uptimeNanoseconds
            model.applyForTesting(snapshot)
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        XCTAssertEqual(model.hits.count, 20)
        // Every target is a p95. The budget is 1 ms on the reference device; this machine must
        // beat it by the factor the reference device is slower.
        let p95 = Measure.p95(durations)
        XCTAssertLessThan(p95, ReferenceDevice.scaled(PerformanceBudget.publish), "publishing took \(p95 * 1000) ms at p95")
    }

    // MARK: Suggestions

    func testSuggestionsAreDisabledBelowTheMinimumLengthAndPaged() async {
        let service = await UIFixtures.service()
        let model = ZTronSuggestionsModel<CatalogSchema>(service: service, minimumQueryLength: 2, pageSize: 3, debounce: 0)
        model.update(prefix: "l")
        await settle()
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertEqual(model.requestCount, 0, "below the minimum the service is not even asked")

        model.update(prefix: "la")
        let first = await eventually { model.suggestions.count == 3 }
        XCTAssertTrue(first, "at most pageSize per page")
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.requestCount, 1)
        model.loadNextPage()
        let second = await eventually { model.suggestions.count == 6 }
        XCTAssertTrue(second)
        XCTAssertEqual(Set(model.suggestions.map(\.id)).count, 6)

        // Dropping back below the minimum clears at once.
        model.update(prefix: "l")
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertFalse(model.hasMore)
    }

    func testSuggestionsShareTheLexicalTimer() async {
        let service = await UIFixtures.service()
        let model = ZTronSuggestionsModel<CatalogSchema>(service: service, debounce: 0.12)
        // Keystrokes inside the debounce: one request, for the last prefix.
        for prefix in ["fr", "fro", "froz", "froze"] {
            model.update(prefix: prefix)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.requestCount, 0, "nothing is asked before the timer fires")
        let arrived = await eventually { model.suggestions.first?.text == "Frozen Harbor" }
        XCTAssertTrue(arrived)
        XCTAssertEqual(model.requestCount, 1)
    }
}

/// A semantic channel that returns nothing, after an optional delay.
actor FakeSemanticStub: SemanticSearching {
    nonisolated let modelID = "ui-stub"
    nonisolated let dimensions = 2
    private var delay: UInt64 = 0

    func setDelay(_ seconds: Double) { delay = UInt64(seconds * 1_000_000_000) }

    func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return [1, 0]
    }

    func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] { [] }
    func upsert(_ vectors: [SearchableID: [Float]]) async throws {}
    func remove(_ ids: [SearchableID]) async {}
    func unload() async {}
}
