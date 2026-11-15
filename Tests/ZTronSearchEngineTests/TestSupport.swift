import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

typealias CatalogService = SearchService<CatalogSchema>
typealias CatalogQuery = SearchQuery<CatalogSchema>
typealias CatalogSnapshot = SearchSnapshot<CatalogSchema>

/// Collects diagnostics without locks: the sink yields into a stream the test drains afterwards.
struct DiagnosticsRecorder: Sendable {
    let sink: @Sendable (SearchDiagnostic) -> Void
    private let stream: AsyncStream<SearchDiagnostic>
    private let continuation: AsyncStream<SearchDiagnostic>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<SearchDiagnostic>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.sink = { continuation.yield($0) }
    }

    /// Everything reported so far. Ends the recording.
    func finish() async -> [SearchDiagnostic] {
        continuation.finish()
        var all: [SearchDiagnostic] = []
        for await diagnostic in stream { all.append(diagnostic) }
        return all
    }
}

enum TestSupport {
    /// A deterministic engine configuration: English, no secondary language, no debounce,
    /// programmer errors reported instead of trapped.
    static func configuration(
        locale: String = "en",
        secondary: SecondaryLanguages = .none,
        diagnostics: (@Sendable (SearchDiagnostic) -> Void)? = nil,
        lexicalDebounce: TimeInterval = 0,
        semanticDebounce: TimeInterval = 0
    ) -> SearchEngineConfiguration {
        SearchEngineConfiguration(
            locale: Locale(identifier: locale),
            followsSystemLocale: false,
            secondaryLanguages: secondary,
            preferredLanguages: { [] },
            lexicalDebounce: lexicalDebounce,
            semanticDebounce: semanticDebounce,
            diagnostics: diagnostics,
            assertsOnProgrammerError: false,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    /// The final snapshot of a submitted query.
    static func final<Schema: SearchSchema>(
        _ service: SearchService<Schema>,
        _ query: SearchQuery<Schema>,
        trigger: SearchTrigger = .submit
    ) async -> SearchSnapshot<Schema>? {
        var last: SearchSnapshot<Schema>?
        for await snapshot in await service.results(for: query, trigger: trigger) {
            last = snapshot
        }
        return last
    }

    static func final<Schema: SearchSchema>(_ service: SearchService<Schema>, _ text: String) async -> SearchSnapshot<Schema>? {
        await final(service, SearchQuery<Schema>(text: text))
    }

    /// Every snapshot of a submitted query, in order.
    static func all<Schema: SearchSchema>(
        _ service: SearchService<Schema>,
        _ query: SearchQuery<Schema>,
        trigger: SearchTrigger = .submit
    ) async -> [SearchSnapshot<Schema>] {
        var snapshots: [SearchSnapshot<Schema>] = []
        for await snapshot in await service.results(for: query, trigger: trigger) {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    static func ids<Schema: SearchSchema>(_ snapshot: SearchSnapshot<Schema>?) -> [String] {
        snapshot?.hits.map(\.id.rawValue) ?? []
    }

    static func indexedService(
        _ items: [AnySearchable<CatalogKind>],
        configuration: SearchEngineConfiguration = configuration(),
        profile: RankingProfile = .default,
        signals: SignalProviders = .none,
        semantic: (any SemanticSearching)? = nil,
        reranker: (any Reranking)? = nil
    ) async -> CatalogService {
        let service = CatalogService(
            index: LexicalIndex(), semantic: semantic, reranker: reranker, profile: profile, signals: signals, configuration: configuration
        )
        await service.index(items)
        return service
    }

    static func scanService(
        _ items: [AnySearchable<CatalogKind>],
        id: SearchContextID = "scan",
        configuration: SearchEngineConfiguration = configuration(),
        profile: RankingProfile = .default,
        signals: SignalProviders = .none,
        semantic: (any SemanticSearching)? = nil
    ) -> CatalogService {
        CatalogService(
            context: SearchContext(id: id, sources: [.memory(items)], strategy: .scan, indexStorage: .inMemory),
            semantic: semantic, profile: profile, signals: signals, configuration: configuration
        )
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ztron-search-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A small hand-written catalog with every kind, filters and localizations.
    static let catalog: [AnySearchable<CatalogKind>] = {
        let tools = [
            Tool(id: "tool-box", title: "Mystery Box Tracker", text: "Track every mystery box location round by round.",
                 keywords: ["box", "tracker"], filters: [.platform(.ios), .category(.trackers)]),
            Tool(id: "tool-timer", title: "Round Timer", text: "A timer for high rounds with m1911-a1 presets and v1.2.3 notes.",
                 keywords: ["timer", "rounds"], filters: [.platform(.mac), .category(.trackers)]),
            Tool(id: "tool-calc", title: "Damage Calculator", text: "Compute weapon damage per round at example.com/calc.",
                 keywords: ["calculator", "damage"], filters: [.platform(.ios), .platform(.mac), .category(.calculators)]),
        ]
        let maps = [
            MapItem(id: "map-harbor", title: "Frozen Harbor", text: "Layout of the harbor with every door and power switch.",
                    filters: [.category(.maps), .platform(.ios), .region(.italy)],
                    localizations: [
                        "it": SearchLocalization(title: "Porto Ghiacciato", text: "Mappa del porto con ogni porta e interruttore."),
                        "de": SearchLocalization(title: "Gefrorener Hafen", text: "Karte des Hafens mit jeder Tür."),
                    ]),
            MapItem(id: "map-temple", title: "Sunken Temple", text: "The temple layout with the mystery box spawn points.",
                    filters: [.category(.maps), .region(.japan)],
                    localizations: ["ja": SearchLocalization(title: "沈んだ神殿", text: "神殿の地図と宝箱の出現場所。")]),
        ]
        let tips = [
            Tip(id: "tip-thirty", title: "Surviving round thirty", text: "Stay near the mystery box and keep moving in circles.",
                updatedAt: Date(timeIntervalSince1970: 1_799_000_000)),
            Tip(id: "tip-doors", title: "Which doors to open first", text: "Open the harbor gate before buying the power switch.",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let games = [
            Game(id: "game-outbreak", title: "Outbreak Protocol", text: "A cooperative survival game set in a frozen research base.",
                 keywords: ["coop", "survival"], filters: [.platform(.tv), .category(.guides)]),
        ]
        let images = [
            ImageItem(id: "image-harbor", title: "Harbor at dawn", altText: "A screenshot of the frozen harbor at sunrise.",
                      tags: ["harbor", "screenshot"], caption: "The lighthouse over the frozen harbor", ocrText: "DOCK 7 EXIT"),
        ]
        return tools.erased() + maps.erased() + tips.erased() + games.erased() + images.erased()
    }()
}

/// A scripted semantic channel: fixed matches per query text, with delay and failure hooks.
actor StubSemantic: SemanticSearching {
    nonisolated let modelID: String
    nonisolated let dimensions: Int
    private var matches: [String: [SemanticMatch]] = [:]
    private var vector: [Float]
    private var delay: UInt64 = 0
    private var fails = false
    private(set) var encodeCalls = 0
    private(set) var nearestCalls = 0
    private(set) var unloadCalls = 0
    private(set) var upserted: [SearchableID: [Float]] = [:]
    private(set) var removed: [SearchableID] = []
    private(set) var localeTags: [String] = []
    private var lastQuery = ""

    init(modelID: String = "stub-model", dimensions: Int = 4) {
        self.modelID = modelID
        self.dimensions = dimensions
        vector = [Float](repeating: 0.5, count: dimensions)
    }

    func script(_ query: String, _ ids: [String]) {
        matches[query] = ids.enumerated().map { SemanticMatch(id: SearchableID($1), similarity: 0.9 - Float($0) * 0.01) }
    }

    func setDelay(seconds: Double) { delay = UInt64(seconds * 1_000_000_000) }
    func setFails(_ fails: Bool) { self.fails = fails }
    func setVector(_ vector: [Float]) { self.vector = vector }

    func encodeQuery(_ text: String, locale: Locale?) async throws -> [Float] {
        encodeCalls += 1
        lastQuery = text
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw SearchError.unsupported("stub failure") }
        return vector
    }

    func nearest(to vector: [Float], limit: Int) async throws -> [SemanticMatch] {
        nearestCalls += 1
        return Array((matches[lastQuery] ?? []).prefix(limit))
    }

    func upsert(_ vectors: [SearchableID: [Float]]) async throws {
        upserted.merge(vectors) { _, new in new }
    }

    func remove(_ ids: [SearchableID]) async {
        removed.append(contentsOf: ids)
    }

    func setLocale(_ languageTag: String) async {
        localeTags.append(languageTag)
    }

    func unload() async {
        unloadCalls += 1
    }
}

/// A scripted cross-encoder.
actor StubReranker: Reranking {
    nonisolated let modelID = "stub-reranker"
    private var enabled: Bool
    private var delay: UInt64 = 0
    private var scorer: @Sendable (String, [String]) -> [Float]
    private(set) var scoreCalls = 0
    private(set) var enabledCalls = 0
    private(set) var unloadCalls = 0
    private(set) var invalidations = 0
    private(set) var lastPassages: [String] = []

    init(enabled: Bool = true, scorer: @escaping @Sendable (String, [String]) -> [Float] = { _, passages in
        passages.indices.map { Float(passages.count - $0) }
    }) {
        self.enabled = enabled
        self.scorer = scorer
    }

    func setDelay(seconds: Double) { delay = UInt64(seconds * 1_000_000_000) }
    func setScorer(_ scorer: @escaping @Sendable (String, [String]) -> [Float]) { self.scorer = scorer }

    func isEnabled() async -> Bool {
        enabledCalls += 1
        return enabled
    }

    func scores(query: String, passages: [String]) async throws -> [Float] {
        scoreCalls += 1
        lastPassages = passages
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return scorer(query, passages)
    }

    func invalidateCalibration() async {
        invalidations += 1
    }

    func unload() async {
        unloadCalls += 1
    }
}

/// Polls a condition until it holds or the timeout passes. Never sleeps blindly.
func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
