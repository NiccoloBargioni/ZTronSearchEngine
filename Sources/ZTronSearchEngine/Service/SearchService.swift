import Foundation

/// The search engine of one context (specification section 9).
///
/// A query yields a stream of snapshots, each tagged with a generation, so the UI can show
/// lexical results in milliseconds and refine them when the semantic channel lands.
///
/// Concurrency (section 11): all mutable search state lives in this actor. A newer query cancels
/// the prior task before any work starts on the new one, and every `await` inside the service is
/// followed by a generation check before state is touched, which is what guards the actor's
/// reentrancy.
public actor SearchService<Schema: SearchSchema> {
    /// The context this service searches. Every snapshot it produces carries the same id.
    public nonisolated let contextID: SearchContextID

    nonisolated let semantic: (any SemanticSearching)?
    nonisolated let reranker: (any Reranking)?
    nonisolated let signals: SignalProviders
    nonisolated let reporter: DiagnosticReporter
    nonisolated let strategy: SearchStrategy
    nonisolated let indexStorage: SearchIndexStorage
    nonisolated let localizedStrings: (any LocalizedStringResolving)?
    nonisolated let databaseSources: [DatabaseSource]

    var profile: RankingProfile
    var configuration: SearchEngineConfiguration
    var languages: ResolvedLanguages
    var storage: SearchStorage
    let tokenizer = TokenizerSession()

    // Sources, kept so the projection can be rebuilt under another locale.
    var memoryItems: [AnySearchable<Schema.Kind>]
    /// Where each id sits in `memoryItems`, so replacing or removing an item costs the same
    /// however many the service holds.
    var memoryPositions: [SearchableID: Int]
    /// Vectors the items of a scan context carry; the scan strategy compares them by brute force.
    var scanEmbeddings: [SearchableID: [Float]]
    var tables: [TableState] = []
    /// Changes received from the boundary and not applied yet, in arrival order.
    var pendingChanges: [PendingChange] = []
    var changeProcessor: Task<Void, Never>?
    /// Per table: bumped whenever the boundary reports a commit on it.
    var changeSerials: [TableKey: UInt64] = [:]
    /// Per table: whole-table reads in flight, and the changes that arrived during the current one.
    var readsInFlight: [TableKey: Int] = [:]
    var deferredChanges: [TableKey: [SearchDatabaseChange]] = [:]
    var persistTask: Task<Void, Never>?
    /// Bumped by every wholesale rebuild; a change batch read under an older value is dropped.
    var sourceRevision: UInt64 = 0
    var isReady: Bool
    var readyWaiters: [CheckedContinuation<Void, Never>] = []
    var maintenanceTasks: [Task<Void, Never>] = []
    var rebuildLock = AsyncLock()

    // Query state.
    var generation: UInt64 = 0
    var detachedGeneration: UInt64 = 1 << 63
    var activeTask: Task<Void, Never>?
    var retained: Retained?

    // Degradation policy (section 15.5).
    var semanticBreaches = 0
    var semanticDisabled = false
    var rerankBreaches = 0
    var rerankDisabled = false
    var rerankGate: GateState = .unknown
    var modelUse: UInt64 = 0
    var idleTask: Task<Void, Never>?
    var observersStarted = false
    var memoryWarningPredecessor: (@Sendable () async -> Void)?

    struct Retained {
        let generation: UInt64
        let query: SearchQuery<Schema>
        let documents: [FusedDocument]
        let phase: SearchPhase
        let degraded: Set<SearchChannel>
        let matchTerms: [String: Double]
    }

    enum GateState: Sendable {
        case unknown
        case measuring
        case enabled
        case disabled
    }

    struct DatabaseSource: Sendable {
        let connection: any SearchDatabaseConnection
        let tables: [SearchTableSource<Schema>]
    }

    struct TableKey: Hashable, Sendable {
        let source: Int
        let table: Int
    }

    struct PendingChange: Sendable {
        let source: Int
        var change: SearchDatabaseChange
    }

    struct TableState: Sendable {
        let source: Int
        let table: Int
        var ids: Set<SearchableID> = []
        var rows: [Int64: SearchableID] = [:]
        /// `false` until the table's rows have been read by this process.
        var isKnown = false
    }

    // MARK: Construction

    /// Everything a service starts from.
    struct Setup {
        var contextID: SearchContextID = .default
        var semantic: (any SemanticSearching)?
        var reranker: (any Reranking)?
        var signals: SignalProviders = .none
        var profile: RankingProfile = .default
        var configuration: SearchEngineConfiguration = .default
        var languages: ResolvedLanguages
        var storage: SearchStorage
        var strategy: SearchStrategy = .indexed
        var indexStorage: SearchIndexStorage = .inMemory
        var localizedStrings: (any LocalizedStringResolving)?
        var databaseSources: [DatabaseSource] = []
        var memoryItems: [AnySearchable<Schema.Kind>] = []
        var scanEmbeddings: [SearchableID: [Float]] = [:]
        var isReady = true
    }

    init(setup: Setup) {
        self.contextID = setup.contextID
        self.semantic = setup.semantic
        self.reranker = setup.reranker
        self.signals = setup.signals
        self.reporter = DiagnosticReporter(setup.configuration)
        self.strategy = setup.strategy
        self.indexStorage = setup.indexStorage
        self.localizedStrings = setup.localizedStrings
        self.databaseSources = setup.databaseSources
        self.profile = setup.profile
        self.configuration = setup.configuration
        self.languages = setup.languages
        self.storage = setup.storage
        self.memoryItems = setup.memoryItems
        self.memoryPositions = Self.positions(of: setup.memoryItems)
        self.scanEmbeddings = setup.scanEmbeddings
        self.isReady = setup.isReady
    }

    /// A service over an index the host owns. Items arrive through ``index(_:)``.
    public init(
        index: LexicalIndex,
        semantic: (any SemanticSearching)? = nil,
        reranker: (any Reranking)? = nil,
        profile: RankingProfile = .default,
        signals: SignalProviders = .none,
        configuration: SearchEngineConfiguration = .default
    ) {
        self.init(setup: Setup(
            semantic: semantic,
            reranker: reranker,
            signals: signals,
            profile: profile,
            configuration: configuration,
            languages: ResolvedLanguages(locale: configuration.locale, configuration: configuration),
            storage: .indexed(index)
        ))
    }

    deinit {
        activeTask?.cancel()
        idleTask?.cancel()
        persistTask?.cancel()
        changeProcessor?.cancel()
        for task in maintenanceTasks { task.cancel() }
    }

    // MARK: Indexing

    /// Indexes items, replacing any with the same id. Filters are read from any
    /// `FilterableSearchable` whose `Filter` is the schema's.
    ///
    /// Indexing is incremental: the items are searchable by the next query, without a rebuild.
    public func index<Item: Searchable>(_ items: [Item]) async where Item.Kind == Schema.Kind {
        await upsert(items.map(AnySearchable.init))
    }

    /// The specification's spelling, where the runtime supports constrained existentials.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    @_disfavoredOverload
    public func index(_ items: [any Searchable<Schema.Kind>]) async {
        await upsert(items.map { AnySearchable($0) })
    }

    /// Removes items. They stop matching from the next query on.
    public func remove(_ ids: [SearchableID]) async {
        guard !ids.isEmpty else { return }
        startObservers()
        forgetMemoryItems(ids)
        for id in ids { scanEmbeddings[id] = nil }
        await mutateDocuments(upserting: [], removing: ids)
        await semantic?.remove(ids)
        schedulePersist()
    }

    /// Keeps the items so a locale change can project them again: the last item of an id wins.
    func rememberMemoryItems(_ items: [AnySearchable<Schema.Kind>]) {
        for item in items {
            let id = item.searchID
            if let position = memoryPositions[id] {
                memoryItems[position] = item
            } else {
                memoryPositions[id] = memoryItems.count
                memoryItems.append(item)
            }
        }
    }

    func forgetMemoryItems(_ ids: [SearchableID]) {
        for id in ids {
            guard let position = memoryPositions.removeValue(forKey: id) else { continue }
            let last = memoryItems.count - 1
            if position != last {
                let moved = memoryItems[last]
                memoryItems[position] = moved
                memoryPositions[moved.searchID] = position
            }
            memoryItems.removeLast()
        }
    }

    static func positions(of items: [AnySearchable<Schema.Kind>]) -> [SearchableID: Int] {
        var positions: [SearchableID: Int] = [:]
        positions.reserveCapacity(items.count)
        for (index, item) in items.enumerated() { positions[item.searchID] = index }
        return positions
    }

    func upsert(_ items: [AnySearchable<Schema.Kind>]) async {
        guard !items.isEmpty else { return }
        startObservers()
        let projection = await project(items, languages: languages)
        rememberMemoryItems(items)
        await reportKindCollisions(projection.documents)
        if storage.isScan {
            scanEmbeddings.merge(projection.embeddings) { _, new in new }
        }
        await mutateDocuments(upserting: projection.documents, removing: [])
        await upsertVectors(projection.embeddings)
        await rebalanceStrategy()
        schedulePersist()
    }

    /// Hands item vectors to the semantic channel. A refusal (a vector of the wrong size, say)
    /// costs the items their semantic reach, not their place in the lexical index, and is reported.
    func upsertVectors(_ vectors: [SearchableID: [Float]]) async {
        guard !vectors.isEmpty, let semantic else { return }
        do {
            try await semantic.upsert(vectors)
        } catch {
            reporter.report(.channelDegraded(channel: .semantic, reason: "item vectors were refused: \(error)"))
        }
    }

    // MARK: Searching

    /// Searches, publishing one snapshot per phase.
    ///
    /// 1. `.lexical`: lexical and fuzzy hits fused by RRF, within the lexical budget.
    /// 2. `.semantic`: the cached lexical lists re-fused with the semantic list.
    /// 3. `.reranked`: on devices past the calibration gate, the head of the second reordered.
    ///
    /// `isFinal` is `true` on the last snapshot that will come. Cancelling the consuming task
    /// terminates the stream and cancels the producer.
    public func results(for query: SearchQuery<Schema>, trigger: SearchTrigger = .typing) -> AsyncStream<SearchSnapshot<Schema>> {
        startObservers()
        generation &+= 1
        let generation = self.generation
        // A newer query cancels the prior task before any work starts on the new one.
        activeTask?.cancel()
        retained = nil

        let (stream, continuation) = AsyncStream<SearchSnapshot<Schema>>.makeStream()
        let task = Task {
            await self.run(query, lane: .interactive(generation), trigger: trigger) { snapshot in
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        activeTask = task
        return stream
    }

    /// Continues the final snapshot's list. A cursor from a stale generation throws
    /// ``SearchError/staleGeneration``.
    public func page(after cursor: SearchCursor, generation: UInt64) async throws -> SearchSnapshot<Schema> {
        guard let retained, retained.generation == generation else { throw SearchError.staleGeneration }
        guard cursor.offset >= 0, cursor.offset <= retained.documents.count else { throw SearchError.invalidCursor }
        let snapshot = await snapshot(of: retained, from: cursor.offset, isFinal: true)
        // The hits were described across an await: the query may have been replaced meanwhile.
        guard self.retained?.generation == generation else { throw SearchError.staleGeneration }
        return snapshot
    }

    /// Cancels the search in flight and forgets its results. Cursors of earlier generations
    /// become stale.
    public func cancel() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        retained = nil
    }

    /// The final snapshot of a query, with every phase run immediately. It neither cancels nor
    /// is cancelled by the interactive stream, and it cannot be paged. Used by chat grounding.
    func retrieve(_ query: SearchQuery<Schema>) async -> SearchSnapshot<Schema>? {
        detachedGeneration &+= 1
        var final: SearchSnapshot<Schema>?
        await run(query, lane: .detached(detachedGeneration), trigger: .submit) { snapshot in
            if snapshot.isFinal { final = snapshot }
        }
        return final
    }

    /// The stored projection of an item: the surfaces a hit's highlights index into.
    public func document(for id: SearchableID) async -> SearchDocument? {
        switch storage {
        case .indexed(let index): return await index.document(for: id)
        case .scan(let engine): return engine.document(for: id)
        }
    }

    /// Documents in the context.
    public var count: Int {
        get async {
            switch storage {
            case .indexed(let index): return await index.count
            case .scan(let engine): return engine.count
            }
        }
    }

    // MARK: Pipeline

    enum Lane: Sendable {
        /// The stream of ``results(for:trigger:)``: only the latest generation may publish.
        case interactive(UInt64)
        /// A one-shot retrieval that lives and dies with its caller.
        case detached(UInt64)

        var generation: UInt64 {
            switch self {
            case .interactive(let generation), .detached(let generation): return generation
            }
        }
    }

    private func isCurrent(_ lane: Lane) -> Bool {
        if Task.isCancelled { return false }
        if case .interactive(let generation) = lane { return generation == self.generation }
        return true
    }

    private func run(
        _ query: SearchQuery<Schema>,
        lane: Lane,
        trigger: SearchTrigger,
        emit: (SearchSnapshot<Schema>) -> Void
    ) async {
        let started = DispatchTime.now().uptimeNanoseconds
        let prepared = SearchPipeline.prepare(query, configuration: configuration, languages: languages, session: tokenizer)

        func publish(_ phase: SearchPhase, _ documents: [FusedDocument], matchTerms: [String: Double], degraded: Set<SearchChannel>, isFinal: Bool) async -> Bool {
            let state = Retained(generation: lane.generation, query: query, documents: documents, phase: phase, degraded: degraded, matchTerms: matchTerms)
            let snapshot = await snapshot(of: state, from: query.cursor?.offset ?? 0, isFinal: isFinal)
            guard isCurrent(lane) else { return false }
            if isFinal, case .interactive = lane { retained = state }
            emit(snapshot)
            return true
        }

        // Empty and too-short queries: an empty final snapshot, no channel touched.
        if prepared.isEmpty {
            _ = await publish(.lexical, [], matchTerms: [:], degraded: [], isFinal: true)
            return
        }

        // Lexical phase: every debounced keystroke. Scan contexts have no debounce.
        if !storage.isScan && trigger == .typing {
            guard await pause(configuration.lexicalDebounce), isCurrent(lane) else { return }
        }
        let lexical: LexicalResponse
        do {
            lexical = try await lexicalSearch(SearchPipeline.request(for: prepared, profile: profile, configuration: configuration))
        } catch {
            return
        }
        guard isCurrent(lane) else { return }

        let semanticState = semanticAvailability(for: prepared)
        let rerankState = rerankAvailability(for: query, semanticWillRun: semanticState == .run)
        var degraded: Set<SearchChannel> = []
        if semanticState == .skipped { degraded.insert(.semantic) }
        if rerankState == .skipped { degraded.insert(.rerank) }

        let ranker = ResultRanker(profile: profile, signals: signals, now: configuration.now(), reporter: reporter)
        func fused(_ semanticDocuments: [RankedDocument]?) -> [FusedDocument] {
            SearchPipeline.droppingUnknownKinds(
                SearchPipeline.fuse(lexical: lexical, semantic: semanticDocuments, profile: profile, signals: signals, configuration: configuration, reporter: reporter),
                as: Schema.Kind.self,
                reporter: reporter
            )
        }

        let lexicalList = ranker.applyingPins(to: fused(nil))
        let lexicalIsFinal = semanticState != .run
        guard await publish(.lexical, lexicalList, matchTerms: lexical.matchTerms, degraded: degraded, isFinal: lexicalIsFinal),
              !lexicalIsFinal else { return }

        // Semantic phase: only after the typing pause, or immediately on submit.
        if trigger == .typing {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            guard await pause(configuration.semanticDebounce - elapsed), isCurrent(lane) else { return }
        }
        let semanticOutcome = await semanticPhase(prepared)
        guard isCurrent(lane) else { return }
        guard case .documents(let semanticDocuments) = semanticOutcome else {
            if case .cancelled = semanticOutcome { return }
            // The channel is skipped for this snapshot; the lexical snapshot is never withheld
            // and now stands as final.
            degraded.insert(.semantic)
            if rerankState != .notConfigured { degraded.insert(.rerank) }
            _ = await publish(.lexical, lexicalList, matchTerms: lexical.matchTerms, degraded: degraded, isFinal: true)
            return
        }

        let semanticRanked = fused(semanticDocuments)
        let semanticList = ranker.applyingPins(to: semanticRanked)
        let willRerank = rerankState == .run && !semanticRanked.isEmpty
        let published = await publish(.semantic, semanticList, matchTerms: lexical.matchTerms, degraded: degraded, isFinal: !willRerank)
        if published { beginRerankCalibration() }
        guard published, willRerank, let spec = profile.rerank else { return }

        // Rerank stage: once per query, after the semantic snapshot.
        let rerankOutcome = await rerankPhase(query: prepared.text, head: Array(semanticRanked.prefix(spec.topN)))
        guard isCurrent(lane) else { return }
        switch rerankOutcome {
        case .scores(let scores):
            let reranked = ranker.applyingPins(to: SearchPipeline.reranked(semanticRanked, scores: scores, spec: spec))
            _ = await publish(.reranked, reranked, matchTerms: lexical.matchTerms, degraded: degraded, isFinal: true)
        case .breached, .failed:
            // The fused order stands.
            degraded.insert(.rerank)
            _ = await publish(.semantic, semanticList, matchTerms: lexical.matchTerms, degraded: degraded, isFinal: true)
        case .cancelled:
            return
        }
    }

    private func snapshot(of state: Retained, from offset: Int, isFinal: Bool) async -> SearchSnapshot<Schema> {
        let start = min(max(0, offset), state.documents.count)
        let end = min(state.documents.count, start + max(0, state.query.limit))
        let slice = state.documents[start..<end]
        let descriptions = await describe(slice.map(\.id), matchTerms: state.matchTerms)
        return SearchSnapshot(
            query: state.query,
            generation: state.generation,
            phase: state.phase,
            hits: SearchPipeline.hits(slice, descriptions: descriptions, as: Schema.Kind.self),
            nextCursor: isFinal && end < state.documents.count ? SearchCursor(offset: end) : nil,
            degraded: state.degraded,
            isFinal: isFinal,
            contextID: contextID
        )
    }

    /// Debounce: `Task.sleep(nanoseconds:)`, cancelled by the next keystroke. `false` = cancelled.
    private func pause(_ seconds: TimeInterval) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }

    // MARK: Storage access

    func lexicalSearch(_ request: LexicalRequest) async throws -> LexicalResponse {
        switch storage {
        case .indexed(let index): return try await index.search(request)
        case .scan(let engine): return try engine.search(request, session: tokenizer)
        }
    }

    private func describe(_ ids: [SearchableID], matchTerms: [String: Double]) async -> [MatchDescription] {
        guard !ids.isEmpty else { return [] }
        let weights = SearchPipeline.fieldWeights(profile)
        switch storage {
        case .indexed(let index): return await index.describe(ids, matchTerms: matchTerms, fieldWeights: weights)
        case .scan(let engine): return engine.describe(ids, matchTerms: matchTerms, fieldWeights: weights, session: tokenizer)
        }
    }

    // MARK: Semantic channel

    private enum ChannelState {
        /// The host injected no such channel, or the device does not run it.
        case notConfigured
        /// The channel exists but will not run for this query: reported as degraded.
        case skipped
        case run
    }

    private func semanticAvailability(for prepared: PreparedQuery) -> ChannelState {
        guard semantic != nil else { return .notConfigured }
        if case .scan(let engine) = storage, !engine.hasVectors { return .notConfigured }
        if semanticDisabled || !prepared.isSemanticEligible { return .skipped }
        return .run
    }

    private enum SemanticOutcome {
        case documents([RankedDocument])
        case breached
        case failed
        case cancelled
    }

    private enum SemanticRace: Sendable {
        case matches([SemanticMatch])
        case vector([Float])
        case timeout
        case failed
        case cancelled
    }

    /// Encodes the query and finds its neighbours under the hard cap.
    ///
    /// The work and the timer are unstructured on purpose: when the cap is breached the channel
    /// must be skipped at once, and a structured scope would wait for an inference that cannot
    /// be interrupted. Both tasks are cancelled before this method returns.
    private func semanticPhase(_ prepared: PreparedQuery) async -> SemanticOutcome {
        guard let semantic else { return .failed }
        noteModelUse()
        let text = prepared.text
        let locale = Locale(identifier: prepared.language)
        let neighbours = configuration.limits.semanticNeighbours
        let phrases = prepared.parsed.phrases
        // The neighbours come back without regard to the hard constraints, which are applied to
        // them afterwards. A constrained query asks for more, so that what survives is still a
        // list worth fusing; the work stays bounded.
        let isConstrained = !prepared.constraints.isEmpty || !phrases.isEmpty
        let requested = isConstrained ? min(neighbours * 4, max(neighbours, 200)) : neighbours
        let wantsNeighbours = !storage.isScan
        let cap = configuration.semanticHardCap

        let (stream, continuation) = AsyncStream<SemanticRace>.makeStream()
        let work = Task {
            do {
                let vector = try await semantic.encodeQuery(text, locale: locale)
                if wantsNeighbours {
                    continuation.yield(.matches(try await semantic.nearest(to: vector, limit: requested)))
                } else {
                    continuation.yield(.vector(vector))
                }
            } catch is CancellationError {
                continuation.yield(.cancelled)
            } catch {
                continuation.yield(.failed)
            }
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, cap) * 1_000_000_000))
            continuation.yield(.timeout)
            continuation.finish()
        }
        var first = SemanticRace.cancelled
        for await value in stream {
            first = value
            break
        }
        timer.cancel()

        switch first {
        case .timeout:
            work.cancel()
            recordSemanticBreach()
            return .breached
        case .failed:
            reporter.report(.channelDegraded(channel: .semantic, reason: "the embedding provider failed"))
            return .failed
        case .cancelled:
            work.cancel()
            return .cancelled
        case .matches(let matches):
            semanticBreaches = 0
            switch storage {
            case .indexed(let index):
                return .documents(await index.resolve(matches, constraints: prepared.constraints, phrases: phrases, limit: neighbours))
            case .scan(let engine):
                return .documents(engine.resolve(matches, constraints: prepared.constraints, phrases: phrases, limit: neighbours, session: tokenizer))
            }
        case .vector(let vector):
            semanticBreaches = 0
            guard case .scan(let engine) = storage else { return .failed }
            return .documents(engine.nearest(to: vector, limit: neighbours, constraints: prepared.constraints, phrases: phrases, session: tokenizer))
        }
    }

    private func recordSemanticBreach() {
        semanticBreaches += 1
        reporter.report(.channelDegraded(channel: .semantic, reason: "hard cap of \(Int(configuration.semanticHardCap * 1000)) ms breached"))
        if semanticBreaches >= configuration.breachesBeforeDisable && !semanticDisabled {
            semanticDisabled = true
            reporter.report(.channelDisabled(channel: .semantic, reason: "\(semanticBreaches) consecutive breaches"))
        }
    }

    // MARK: Rerank stage

    private func rerankAvailability(for query: SearchQuery<Schema>, semanticWillRun: Bool) -> ChannelState {
        guard reranker != nil, profile.rerank != nil else { return .notConfigured }
        switch configuration.reranking {
        case .off:
            return .notConfigured
        case .on:
            break
        case .auto:
            switch rerankGate {
            case .enabled:
                break
            case .disabled, .measuring:
                return .notConfigured
            case .unknown:
                // Not measured yet: the calibration starts once this query's semantic snapshot
                // is out (`beginRerankCalibration`), and applies from the next query on.
                return .notConfigured
            }
        }
        if rerankDisabled || !semanticWillRun || query.isTokensOnly { return .skipped }
        return .run
    }

    /// One-time calibration on first use (section 7.4). It starts after a semantic snapshot has
    /// been published, so it neither delays a snapshot nor times itself against the query
    /// embedding of the query that triggered it.
    private func beginRerankCalibration() {
        guard let reranker, profile.rerank != nil, configuration.reranking == .auto, rerankGate == .unknown else { return }
        rerankGate = .measuring
        maintenanceTasks.append(Task { [weak self] in
            let enabled = await reranker.isEnabled()
            await self?.setRerankGate(enabled)
        })
    }

    private func setRerankGate(_ enabled: Bool) {
        rerankGate = enabled ? .enabled : .disabled
    }

    private enum RerankOutcome {
        case scores([Float])
        case breached
        case failed
        case cancelled
    }

    private enum RerankRace: Sendable {
        case scores([Float])
        case timeout
        case failed
        case cancelled
    }

    /// Scores the head in one batched call under the hard cap.
    private func rerankPhase(query: String, head: [FusedDocument]) async -> RerankOutcome {
        guard let reranker, !head.isEmpty else { return .failed }
        noteModelUse()
        var collected: [String] = []
        collected.reserveCapacity(head.count)
        for document in head {
            collected.append((await self.document(for: document.id)).map(SearchPipeline.passage(for:)) ?? "")
        }
        // Immutable from here on: the scoring task reads it while this method goes on.
        let passages = collected
        let cap = configuration.rerankHardCap

        let (stream, continuation) = AsyncStream<RerankRace>.makeStream()
        let work = Task {
            do {
                continuation.yield(.scores(try await reranker.scores(query: query, passages: passages)))
            } catch is CancellationError {
                continuation.yield(.cancelled)
            } catch {
                continuation.yield(.failed)
            }
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, cap) * 1_000_000_000))
            continuation.yield(.timeout)
            continuation.finish()
        }
        var first = RerankRace.cancelled
        for await value in stream {
            first = value
            break
        }
        timer.cancel()

        switch first {
        case .scores(let scores) where scores.count == passages.count:
            rerankBreaches = 0
            return .scores(scores)
        case .scores, .failed:
            reporter.report(.channelDegraded(channel: .rerank, reason: "the reranker failed"))
            return .failed
        case .cancelled:
            work.cancel()
            return .cancelled
        case .timeout:
            work.cancel()
            rerankBreaches += 1
            reporter.report(.channelDegraded(channel: .rerank, reason: "hard cap of \(Int(cap * 1000)) ms breached"))
            if rerankBreaches >= configuration.breachesBeforeDisable && !rerankDisabled {
                // Disabled for the session; recalibrated at the next launch.
                rerankDisabled = true
                reporter.report(.channelDisabled(channel: .rerank, reason: "\(rerankBreaches) consecutive breaches"))
                maintenanceTasks.append(Task { await reranker.invalidateCalibration() })
            }
            return .breached
        }
    }

    // MARK: Model lifecycle

    /// Restarts the idle clock: the embedding model and the reranker unload together after
    /// `modelIdleUnload` seconds without a semantic query.
    private func noteModelUse() {
        modelUse &+= 1
        let use = modelUse
        let idle = configuration.modelIdleUnload
        idleTask?.cancel()
        guard idle > 0 else { return }
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            } catch {
                return
            }
            await self?.unloadModels(ifIdleSince: use)
        }
    }

    private func unloadModels(ifIdleSince use: UInt64) async {
        guard use == modelUse else { return }
        await semantic?.unload()
        await reranker?.unload()
    }

    /// A memory warning disables the semantic channel for the session and unloads the models.
    public func handleMemoryWarning() async {
        idleTask?.cancel()
        modelUse &+= 1
        if semantic != nil && !semanticDisabled {
            semanticDisabled = true
            reporter.report(.channelDisabled(channel: .semantic, reason: "memory warning"))
        }
        // A local language model, when there is one, unloads before the embedding model.
        await memoryWarningPredecessor?()
        await semantic?.unload()
        await reranker?.unload()
    }

    /// The next foreground re-enables a semantic channel that breaches or a memory warning
    /// disabled.
    public func handleForeground() {
        semanticDisabled = false
        semanticBreaches = 0
    }

    func setMemoryWarningPredecessor(_ predecessor: (@Sendable () async -> Void)?) {
        memoryWarningPredecessor = predecessor
    }

    /// Observes the system notifications the policies react to. The names are spelled out so
    /// that no UI framework is imported.
    func startObservers() {
        guard !observersStarted else { return }
        observersStarted = true
        if semantic != nil || reranker != nil {
            observe("UIApplicationDidReceiveMemoryWarningNotification") { await $0.handleMemoryWarning() }
            observe("UIApplicationWillEnterForegroundNotification") { await $0.handleForeground() }
        }
        if configuration.followsSystemLocale {
            observe(NSLocale.currentLocaleDidChangeNotification.rawValue) { await $0.setLocale(Locale.current) }
        }
    }

    private func observe(_ name: String, _ handler: @escaping @Sendable (SearchService) async -> Void) {
        maintenanceTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Notification.Name(name)).map({ _ in () }) {
                guard let self else { return }
                await handler(self)
            }
        })
    }

    // MARK: Suggestions

    /// Autocomplete proposals for a typed prefix: titles that continue it, then vocabulary
    /// terms that complete its last word. Empty below the minimum query length.
    public func suggestions(for prefix: String, limit: Int) async -> [SearchSuggestion] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, typed.count >= configuration.minimumQueryLength || typed.contains(where: ScriptClass.isUnspaced) else { return [] }
        let language = languages.active
        let tokens = tokenizer.tokenize(prefix, language: language).filter { $0.kind == .word }
        guard let last = tokens.last else { return [] }
        let words = tokens.map(\.term)
        let endsWithSpace = prefix.last.map(\.isWhitespace) ?? false
        let typedKey = SearchNormalizer.normalize(typed, language: language)

        var suggestions: [SearchSuggestion] = []
        var seen: Set<String> = [typedKey]
        func add(_ text: String, _ source: SearchSuggestion.Source, _ id: SearchableID?, _ score: Double) {
            guard suggestions.count < limit, seen.insert(SearchNormalizer.normalize(text, language: language)).inserted else { return }
            suggestions.append(SearchSuggestion(text: text, source: source, itemID: id, score: score))
        }

        // Titles: the lexical channel without corrections, kept when the title continues the words.
        var limits = configuration.limits
        limits.fusionEntriesPerChannel = max(limit * 4, 16)
        let parsed = QueryParser.parse(text: prefix, phrases: [], language: language, minimumFuzzyLength: configuration.minimumFuzzyTokenLength, session: tokenizer)
        let request = LexicalRequest(
            parsed: parsed, constraints: HardConstraints(), profile: profile, limits: limits,
            fuzzyEnabled: false, minimumFuzzyLength: configuration.minimumFuzzyTokenLength
        )
        if let response = try? await lexicalSearch(request) {
            for candidate in response.lexical {
                if suggestions.count >= limit { break }
                guard let title = await document(for: candidate.id).flatMap(\.title) else { continue }
                let titleWords = tokenizer.words(title, language: language)
                if Self.continues(titleWords, words, lastIsPrefix: !endsWithSpace) {
                    add(title, .title, candidate.id, candidate.score)
                }
            }
        }

        // Terms: completions of the last word, most frequent first.
        if !endsWithSpace && !last.isExactOnly && suggestions.count < limit {
            let completions: [(term: String, documentFrequency: Int)]
            switch storage {
            case .indexed(let index): completions = await index.completions(of: last.term, limit: limit + 1)
            case .scan(let engine): completions = engine.completions(of: last.term, limit: limit + 1)
            }
            let stem = String(prefix[..<last.range.lowerBound])
            for completion in completions {
                add(stem + completion.term, .term, nil, Double(completion.documentFrequency))
            }
        }
        return suggestions
    }

    /// `true` when `title` holds `words` consecutively, the last one possibly as a prefix.
    private static func continues(_ title: [String], _ words: [String], lastIsPrefix: Bool) -> Bool {
        guard !words.isEmpty, title.count >= words.count else { return false }
        for start in 0...(title.count - words.count) {
            var matches = true
            for (offset, word) in words.enumerated() {
                let candidate = title[start + offset]
                let isLast = offset == words.count - 1
                if isLast && lastIsPrefix ? !candidate.utf8.starts(with: word.utf8) : candidate != word {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    // MARK: Locale

    /// Changes the active locale: the projection and the lexical index are rebuilt in the
    /// background under a new generation. In-flight and new searches keep using the old index
    /// until the swap; search tasks are cancelled.
    public func setLocale(_ locale: Locale) async {
        var updated = configuration
        updated.locale = locale
        let resolved = ResolvedLanguages(locale: locale, configuration: updated)
        configuration = updated
        guard resolved != languages else { return }
        cancel()
        // The semantic channel switches to the vector set of the new locale first, so the
        // vectors the rebuild hands over land in it once.
        await semantic?.setLocale(resolved.active)
        await rebuild(languages: resolved, scope: .localeChange)
    }

    /// The active locale's BCP 47 tag and the secondary languages of the current index generation.
    public var resolvedLanguages: ResolvedLanguages { languages }

    /// Replaces the ranking profile. Ranking is retuned without touching a domain type or the index.
    public func setProfile(_ profile: RankingProfile) {
        self.profile = profile
    }

    // MARK: Projection

    struct ProjectionOutput: Sendable {
        var documents: [SearchDocument] = []
        var embeddings: [SearchableID: [Float]] = [:]
    }

    /// Projects items: in place for a few, on the cooperative pool in parallel chunks for many.
    func project(_ items: [AnySearchable<Schema.Kind>], languages: ResolvedLanguages) async -> ProjectionOutput {
        let reporter = reporter
        if items.count < 2_000 {
            return Self.project(items, languages: languages, reporter: reporter)
        }
        return await withTaskGroup(of: ProjectionOutput.self, returning: ProjectionOutput.self) { group in
            group.addTask(priority: .utility) {
                await Self.projectInChunks(items, languages: languages, reporter: reporter)
            }
            return await group.next() ?? ProjectionOutput()
        }
    }

    private static func projectInChunks(
        _ items: [AnySearchable<Schema.Kind>],
        languages: ResolvedLanguages,
        reporter: DiagnosticReporter
    ) async -> ProjectionOutput {
        let chunkSize = max(2_000, (items.count + 7) / 8)
        let chunkCount = (items.count + chunkSize - 1) / chunkSize
        let outputs = await withTaskGroup(of: (Int, ProjectionOutput).self, returning: [ProjectionOutput].self) { group in
            for chunk in 0..<chunkCount {
                let slice = Array(items[(chunk * chunkSize)..<min(items.count, (chunk + 1) * chunkSize)])
                group.addTask(priority: .utility) {
                    (chunk, project(slice, languages: languages, reporter: reporter))
                }
            }
            var results = [ProjectionOutput?](repeating: nil, count: chunkCount)
            for await (chunk, output) in group {
                results[chunk] = output
            }
            return results.compactMap { $0 }
        }
        // An id repeated across two chunks: the last one wins, as it does inside a chunk.
        var merged = ProjectionOutput()
        merged.documents.reserveCapacity(items.count)
        var positions: [SearchableID: Int] = [:]
        positions.reserveCapacity(items.count)
        for output in outputs {
            for document in output.documents {
                if let position = positions[document.id] {
                    reporter.report(.duplicateID(id: document.id))
                    merged.documents[position] = document
                } else {
                    positions[document.id] = merged.documents.count
                    merged.documents.append(document)
                }
            }
            merged.embeddings.merge(output.embeddings) { _, new in new }
        }
        return merged
    }

    /// The projection is pure; the schema checks around it are what this adds: an item whose
    /// `Filter` differs from the schema's loses its filters, records unknown to this build are
    /// ignored, and an id used twice is reported.
    static func project(_ items: [AnySearchable<Schema.Kind>], languages: ResolvedLanguages, reporter: DiagnosticReporter) -> ProjectionOutput {
        let projector = SearchProjector(languages: languages)
        var session = SearchProjector.Session()
        var output = ProjectionOutput()
        output.documents.reserveCapacity(items.count)
        var positions: [SearchableID: Int] = [:]
        positions.reserveCapacity(items.count)
        let schemaFilter = ObjectIdentifier(Schema.Filter.self)

        for item in items {
            let projection = projector.project(item, session: &session)
            var document = projection.document
            if let filterType = projection.filterType, !document.filters.isEmpty {
                if ObjectIdentifier(filterType) != schemaFilter {
                    reporter.report(.filterTypeMismatch(id: document.id, itemFilter: String(describing: filterType), schemaFilter: String(describing: Schema.Filter.self)))
                    document = document.replacingFilters([])
                } else {
                    let known = document.filters.filter { record in
                        if Schema.Filter(key: record.key, value: record.value) != nil { return true }
                        reporter.report(.unknownFilter(id: document.id, record: record))
                        return false
                    }
                    if known.count != document.filters.count { document = document.replacingFilters(known) }
                }
            }
            if let position = positions[document.id] {
                reporter.report(.duplicateID(id: document.id))
                output.documents[position] = document
            } else {
                positions[document.id] = output.documents.count
                output.documents.append(document)
            }
            if let embedding = projection.embedding {
                output.embeddings[document.id] = embedding
            }
        }
        return output
    }

    /// The last item of each id, in first-seen order.
    static func lastOccurrences(_ items: [AnySearchable<Schema.Kind>]) -> [AnySearchable<Schema.Kind>] {
        var positions: [SearchableID: Int] = [:]
        var unique: [AnySearchable<Schema.Kind>] = []
        unique.reserveCapacity(items.count)
        for item in items {
            if let position = positions[item.searchID] {
                unique[position] = item
            } else {
                positions[item.searchID] = unique.count
                unique.append(item)
            }
        }
        return unique
    }

    /// An id that is already indexed under another kind is a collision across kinds.
    private func reportKindCollisions(_ documents: [SearchDocument]) async {
        guard documents.count <= 512 else { return }
        let stored: [String?]
        switch storage {
        case .indexed(let index): stored = await index.rawKinds(of: documents.map(\.id))
        case .scan(let engine): stored = documents.map { engine.document(for: $0.id)?.kind }
        }
        for (document, kind) in zip(documents, stored) {
            if let kind, kind != document.kind {
                reporter.report(.duplicateID(id: document.id))
            }
        }
    }

    /// `true` when the projection of an item can depend on the active locale: only an item
    /// that carries localizations.
    static func isLocalized(_ item: AnySearchable<Schema.Kind>) -> Bool {
        guard let localized = item.base as? any LocalizedSearchable else { return false }
        return !localized.searchLocalizations.isEmpty
    }
}

extension SearchDocument {
    func replacingFilters(_ filters: [FilterRecord]) -> SearchDocument {
        SearchDocument(
            id: id, kind: kind, language: language, title: title, text: text, keywords: keywords,
            caption: caption, ocrText: ocrText, localizedAlt: localizedAlt, filters: filters,
            updatedAt: updatedAt, languages: languages
        )
    }
}
