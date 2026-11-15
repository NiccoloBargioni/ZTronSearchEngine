import Foundation

/// Failures of a chat turn.
public enum ChatError: Error, Sendable, Hashable {
    case unknownSession
    /// The model is not loaded and cannot be loaded without `prepare(policy:)`.
    case notReady(ChatReadiness)
    /// The system prompt, the sources and the message alone exceed the context budget.
    case messageTooLong(required: Int, budget: Int)
    case generationFailed(String)
}

/// Grounded chat over the indexed corpus through a local language model
/// (specification section 14.3).
///
/// Core never links a runtime or an asset library: both boundaries arrive as existentials
/// through ``ZTronSearch``. Everything runs on device.
///
/// Lifecycle, seven states: the device gate decides first (Unavailable), then the model is
/// fetched (Fetching, resumable), verified (On disk), loaded (Loading), and is Ready until
/// 120 s of idleness or a memory warning unloads it back to On disk; Generating runs one
/// generation at a time; Failed allows a retry.
public actor ChatService<Schema: SearchSchema> {
    public typealias Grounding = ChatGrounding<Schema.Kind>

    nonisolated let search: SearchService<Schema>
    nonisolated let assets: any ModelAssetProviding
    nonisolated let model: any LocalLanguageModel
    nonisolated let configuration: ChatConfiguration
    nonisolated let reporter: DiagnosticReporter

    enum Lifecycle: Sendable {
        /// Nothing asked yet.
        case idle
        /// The gate failed.
        case unavailable(UnavailableReason)
        case fetching
        /// Files verified on disk; weights not in memory.
        case onDisk(URL)
        case loading(URL)
        case ready(URL)
        case generating(URL)
        /// Fetching or loading failed; a retry is allowed.
        case failed(UnavailableReason)
    }

    private struct Session {
        var system: String?
        var grounding: Grounding
        var history: [ChatMessage] = []
        var turn: UUID?
        var task: Task<Void, Never>?
    }

    private(set) var lifecycle: Lifecycle = .idle
    private var currentReadiness: ChatReadiness = .checking
    private var observers: [UUID: AsyncStream<ChatReadiness>.Continuation] = [:]
    private var preparation: Task<Void, Never>?
    private var sessions: [ChatSessionID: Session] = [:]
    private var generationLock = AsyncLock()
    private var use: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    private var memoryObserver: Task<Void, Never>?
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []

    init(search: SearchService<Schema>, assets: any ModelAssetProviding, model: any LocalLanguageModel, configuration: ChatConfiguration) {
        self.search = search
        self.assets = assets
        self.model = model
        self.configuration = configuration
        self.reporter = DiagnosticReporter(sink: configuration.diagnostics, assertsOnProgrammerError: false)
    }

    deinit {
        preparation?.cancel()
        idleTask?.cancel()
        memoryObserver?.cancel()
        for session in sessions.values { session.task?.cancel() }
    }

    // MARK: Readiness

    /// What the readiness card shows right now.
    public var readiness: ChatReadiness {
        switch lifecycle {
        case .idle: return .checking
        case .unavailable(let reason), .failed(let reason): return .unavailable(reason)
        case .fetching: return currentReadiness
        case .loading: return .loading
        // On disk counts as ready: the next message only reloads the weights.
        case .onDisk, .ready, .generating: return .ready
        }
    }

    /// What a host can show before anything was prepared: the device gate, then whether the
    /// files are already on disk. The asset provider is consulted only when the gate passes.
    ///
    /// `.unavailable(.device)`: show no entry point. `.unavailable(.downloadNotAllowed)`: the
    /// files are missing; ask for consent, then call `prepare(policy:)`.
    public func gate() async -> ChatReadiness {
        // A preparation in flight is the authority on readiness.
        guard case .idle = lifecycle, preparation == nil else { return readiness }
        if let reason = await gateFailure() {
            if case .idle = lifecycle, preparation == nil { lifecycle = .unavailable(reason) }
            return .unavailable(reason)
        }
        guard case .idle = lifecycle, preparation == nil else { return readiness }
        let availability = await assets.availability(of: model.descriptor.asset)
        guard case .idle = lifecycle, preparation == nil else { return readiness }
        switch availability {
        case .available(let directory):
            lifecycle = .onDisk(directory)
            return .ready
        case .downloading(let bytes, let total):
            return .downloading(bytes: bytes, of: total)
        case .missing:
            return .unavailable(.downloadNotAllowed)
        case .failed(let error):
            return .unavailable(.assetFailed(error))
        }
    }

    /// Makes the model ready: the device gate first, then available-or-download, then load.
    ///
    /// `.available` loads, `.missing` fetches under the download policy, and a preparation that
    /// is already running is attached to instead of started again. The stream ends on `.ready`
    /// or `.unavailable`; cancelling its consumer cancels a download in flight, which resumes on
    /// the next call.
    public func prepare(policy: DownloadPolicy = .wifiOnly) -> AsyncStream<ChatReadiness> {
        startMemoryObserver()
        let (stream, continuation) = AsyncStream<ChatReadiness>.makeStream()
        switch lifecycle {
        case .ready, .generating:
            continuation.yield(.ready)
            continuation.finish()
            return stream
        case .unavailable(let reason) where !reason.isRetryable:
            continuation.yield(.unavailable(reason))
            continuation.finish()
            return stream
        default:
            break
        }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        if preparation == nil {
            preparation = Task { await self.runPreparation(policy: policy) }
        } else {
            continuation.yield(readiness)
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        guard observers.removeValue(forKey: id) != nil else { return }
        // Nobody is watching the download any more: stop it. It resumes on the next prepare.
        if observers.isEmpty, case .fetching = lifecycle {
            preparation?.cancel()
        }
    }

    private func publish(_ readiness: ChatReadiness) {
        currentReadiness = readiness
        for observer in observers.values { observer.yield(readiness) }
    }

    private func finishObservers() {
        for observer in observers.values { observer.finish() }
        observers = [:]
    }

    private func settle(_ lifecycle: Lifecycle, _ readiness: ChatReadiness) {
        self.lifecycle = lifecycle
        publish(readiness)
    }

    private func runPreparation(policy: DownloadPolicy) async {
        defer {
            preparation = nil
            finishObservers()
            let waiters = preparationWaiters
            preparationWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        publish(.checking)

        // The device gate decides first, without touching the asset provider.
        if let reason = await gateFailure() {
            settle(.unavailable(reason), .unavailable(reason))
            return
        }
        guard !Task.isCancelled else { return }

        let asset = model.descriptor.asset
        var directory: URL?
        let availability = await assets.availability(of: asset)
        guard !Task.isCancelled else { return }
        if case .available(let url) = availability {
            directory = url
        } else {
            guard policy != .never else {
                settle(.failed(.downloadNotAllowed), .unavailable(.downloadNotAllowed))
                return
            }
            // Free disk of at least twice the asset before a download starts.
            if case .missing = availability, let free = device.freeDiskBytes, free < 2 * asset.totalBytes {
                settle(.failed(.insufficientDisk), .unavailable(.insufficientDisk))
                return
            }
            lifecycle = .fetching
            // Progress is only ever what the provider reports: a resumed download does not
            // flash back to zero.
            if case .downloading(let bytes, let total) = availability {
                publish(.downloading(bytes: bytes, of: total))
            }
            do {
                // `fetch` is resumable: a retry re-verifies and resumes instead of starting over,
                // and a fetch that is already running is attached to by the provider.
                for try await event in assets.fetch(asset, policy: policy) {
                    try Task.checkCancellation()
                    switch event {
                    case .downloading(let bytes, let total): publish(.downloading(bytes: bytes, of: total))
                    case .available(let url): directory = url
                    case .failed(let error): throw error
                    case .missing: break
                    }
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                lifecycle = .idle
                return
            } catch let error as ModelAssetError {
                settle(.failed(.assetFailed(error)), .unavailable(.assetFailed(error)))
                return
            } catch {
                settle(.failed(.assetFailed(.offline)), .unavailable(.assetFailed(.offline)))
                return
            }
        }
        guard let directory else {
            settle(.failed(.assetFailed(.offline)), .unavailable(.assetFailed(.offline)))
            return
        }
        lifecycle = .onDisk(directory)
        _ = await load(from: directory)
    }

    private var device: ChatDeviceProfile {
        configuration.device ?? ChatDeviceProfile.current
    }

    private var calibrationKey: String {
        let asset = model.descriptor.asset
        return "chat-calibration|\(device.buildFingerprint)|\(asset.id)@\(asset.revision)"
    }

    private var calibrationStore: any ChatCalibrationStoring {
        configuration.calibrationStore ?? UserDefaultsCalibrationStore()
    }

    /// OS, physical memory and a calibration verdict already on record.
    private func gateFailure() async -> UnavailableReason? {
        switch configuration.availability {
        case .off:
            return .disabled
        case .on:
            return nil
        case .auto:
            let descriptor = model.descriptor
            let device = device
            guard ChatDeviceProfile.version(device.operatingSystem, isAtLeast: descriptor.minimumOS),
                  device.physicalMemory >= descriptor.minimumPhysicalMemory else { return .device }
            if await calibrationStore.verdict(forKey: calibrationKey) == false { return .device }
            return nil
        }
    }

    /// Loads the weights, then, once per app and OS version, calibrates.
    private func load(from directory: URL) async -> Bool {
        settle(.loading(directory), .loading)
        do {
            try await model.load(from: directory)
        } catch {
            settle(.failed(.loadFailed), .unavailable(.loadFailed))
            return false
        }
        if configuration.availability == .auto, !(await calibrationPasses()) {
            await model.unload()
            settle(.unavailable(.device), .unavailable(.device))
            return false
        }
        settle(.ready(directory), .ready)
        noteUse()
        return true
    }

    /// One-time calibration after the first load: prefill 512 tokens and decode 64; enabled only
    /// when the first token arrives within the limit and decoding keeps the minimum rate. The
    /// verdict is persisted and measured again after an app or OS update.
    private func calibrationPasses() async -> Bool {
        let store = calibrationStore
        let key = calibrationKey
        if let verdict = await store.verdict(forKey: key) { return verdict }

        let sentence = "The quick brown fox jumps over the lazy dog near the quiet river bank. "
        let perSentence = max(1, await model.countTokens(sentence))
        let prompt = String(repeating: sentence, count: max(1, 512 / perSentence))
        var options = configuration.options
        options.maxNewTokens = 64
        options.seed = 0
        let request = GenerationRequest(messages: [ChatMessage(role: .user, content: prompt)], options: options)

        let started = DispatchTime.now().uptimeNanoseconds
        var first: UInt64?
        var last = started
        var pieces = 0
        var reported: Int?
        do {
            for try await event in model.generate(request) {
                switch event {
                case .delta:
                    let now = DispatchTime.now().uptimeNanoseconds
                    if first == nil { first = now }
                    last = now
                    pieces += 1
                case .usage(_, let generated):
                    reported = generated
                case .finished:
                    break
                }
            }
        } catch {
            return false
        }
        guard let first else {
            await store.setVerdict(false, forKey: key)
            return false
        }
        let timeToFirstToken = Double(first - started) / 1_000_000_000
        let generated = max(reported ?? pieces, pieces)
        let decodeSeconds = Double(last - first) / 1_000_000_000
        // The first token belongs to the prefill; the rate is measured over the rest.
        let rate = generated > 1 && decodeSeconds > 0 ? Double(generated - 1) / decodeSeconds : Double.infinity
        let verdict = timeToFirstToken <= configuration.maximumTimeToFirstToken && rate >= configuration.minimumTokensPerSecond
        await store.setVerdict(verdict, forKey: key)
        return verdict
    }

    // MARK: Sessions

    public func newSession(system: String? = nil, grounding: Grounding = .corpus(topK: 6, kinds: nil)) -> ChatSessionID {
        let id = ChatSessionID()
        sessions[id] = Session(system: system, grounding: grounding)
        return id
    }

    /// The messages exchanged in a session so far. A session keeps its history across unloads.
    public func history(of session: ChatSessionID) -> [ChatMessage] {
        sessions[session]?.history ?? []
    }

    public func endSession(_ session: ChatSessionID) {
        sessions[session]?.task?.cancel()
        sessions[session] = nil
    }

    // MARK: Sending

    /// Answers a message: retrieval, prompt assembly, then generation streamed as `.delta`.
    ///
    /// One generation at a time on the device: a new `send` in the same session cancels the one
    /// in flight; other sessions queue. The model loads lazily on the first send when its files
    /// are already on disk; it is never downloaded from here.
    public func send(_ text: String, in session: ChatSessionID) -> AsyncThrowingStream<ChatEvent<Schema.Kind>, Error> {
        startMemoryObserver()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent<Schema.Kind>, Error>.makeStream()
        guard sessions[session] != nil else {
            continuation.finish(throwing: ChatError.unknownSession)
            return stream
        }
        sessions[session]?.task?.cancel()
        let turn = UUID()
        let task = Task {
            do {
                try await self.runTurn(text, session: session, turn: turn) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        sessions[session]?.turn = turn
        sessions[session]?.task = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Cancels the generation in flight in a session.
    public func cancel(_ session: ChatSessionID) async {
        sessions[session]?.task?.cancel()
    }

    /// Releases the weights. The files and every session's history stay, so the next message
    /// only reloads the weights.
    public func unload() async {
        idleTask?.cancel()
        use &+= 1
        for session in sessions.values { session.task?.cancel() }
        switch lifecycle {
        case .ready(let directory), .generating(let directory), .loading(let directory):
            await model.unload()
            lifecycle = .onDisk(directory)
        default:
            break
        }
    }

    private func acquireGenerationLock() async {
        if generationLock.tryAcquire() { return }
        await withCheckedContinuation { continuation in
            generationLock.enqueue(continuation)
        }
    }

    private func runTurn(
        _ text: String,
        session id: ChatSessionID,
        turn: UUID,
        emit: (ChatEvent<Schema.Kind>) -> Void
    ) async throws {
        await acquireGenerationLock()
        defer { generationLock.release() }
        try Task.checkCancellation()
        guard let session = sessions[id], session.turn == turn else { throw CancellationError() }

        let directory = try await ensureLoaded()
        try Task.checkCancellation()

        // 1. Retrieval: the final snapshot for the message, restricted to the session's kinds.
        var hits: [SearchHit<Schema.Kind>] = []
        var rendered: [String] = []
        var grounded = false
        if case .corpus(let topK, let kinds) = session.grounding {
            grounded = true
            var query = SearchQuery<Schema>(text: text, kinds: kinds)
            query.limit = max(1, topK)
            if let snapshot = await search.retrieve(query) {
                hits = Array(snapshot.hits.prefix(max(0, topK)))
            }
            try Task.checkCancellation()
            emit(.sources(hits))
            for hit in hits {
                rendered.append(await render(hit))
            }
        }

        // 2. Prompt assembly inside contextWindow - maxNewTokens - margin.
        let window = min(configuration.contextWindow, model.descriptor.contextWindow)
        let budget = window - configuration.options.maxNewTokens - configuration.safetyMargin
        let model = model
        let assembler = PromptAssembler(budget: budget) { await model.countTokens($0) }
        let assembly: PromptAssembler.Assembly
        do {
            assembly = try await assembler.assemble(
                system: session.system, sources: rendered, grounded: grounded, history: session.history, message: text
            )
        } catch PromptAssembler.Failure.exceedsBudget(let required, let budget) {
            throw ChatError.messageTooLong(required: required, budget: budget)
        }
        try Task.checkCancellation()

        // 3. Generation, with citations parsed incrementally.
        lifecycle = .generating(directory)
        defer {
            if case .generating(let directory) = lifecycle { lifecycle = .ready(directory) }
            noteUse()
        }
        var parser = CitationParser(sources: Set(hits.map(\.id))) { Schema.Kind(rawValue: $0) != nil }
        var raw = ""
        var promptTokens = assembly.promptTokens
        var generatedTokens = 0
        var stop = StopReason.endOfTurn
        func forward(_ outputs: [CitationParser.Output]) {
            for output in outputs {
                switch output {
                case .text(let text): emit(.delta(text))
                case .citation(let id): emit(.citation(id))
                // Unknown ids are dropped and logged.
                case .unknown(let id): reporter.report(.unknownCitation(id: id))
                }
            }
        }
        func remember() {
            sessions[id]?.history.append(ChatMessage(role: .user, content: text))
            if !raw.isEmpty {
                sessions[id]?.history.append(ChatMessage(role: .assistant, content: raw))
            }
        }
        do {
            for try await event in model.generate(GenerationRequest(messages: assembly.messages, options: configuration.options)) {
                switch event {
                case .delta(let delta):
                    raw += delta
                    forward(parser.consume(delta))
                case .usage(let prompt, let generated):
                    promptTokens = prompt
                    generatedTokens = generated
                case .finished(let reason):
                    stop = reason
                }
            }
        } catch is CancellationError {
            forward(parser.finish())
            remember()
            throw CancellationError()
        } catch {
            throw ChatError.generationFailed(String(describing: error))
        }
        forward(parser.finish())
        remember()
        if Task.isCancelled {
            throw CancellationError()
        }
        emit(.finished(ChatUsage(promptTokens: promptTokens, generatedTokens: generatedTokens, stopReason: stop)))
    }

    /// The weights, loaded lazily. Nothing is downloaded from here: that needs `prepare(policy:)`.
    private func ensureLoaded() async throws -> URL {
        // A message sent while the model is being fetched or loaded waits for that to end.
        if preparation != nil {
            await withCheckedContinuation { continuation in
                preparationWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
        switch lifecycle {
        case .ready(let directory), .generating(let directory):
            return directory
        case .onDisk(let directory):
            guard await load(from: directory) else { throw ChatError.notReady(readiness) }
            return directory
        case .idle:
            if let reason = await gateFailure() {
                lifecycle = .unavailable(reason)
                throw ChatError.notReady(.unavailable(reason))
            }
            guard case .available(let directory) = await assets.availability(of: model.descriptor.asset) else {
                throw ChatError.notReady(.unavailable(.downloadNotAllowed))
            }
            guard await load(from: directory) else { throw ChatError.notReady(readiness) }
            return directory
        case .unavailable(let reason), .failed(let reason):
            throw ChatError.notReady(.unavailable(reason))
        case .fetching, .loading:
            throw ChatError.notReady(readiness)
        }
    }

    /// `[kind:id] title, caption` from the hit's localized surface, at most 80 tokens.
    private func render(_ hit: SearchHit<Schema.Kind>) async -> String {
        let marker = "[\(hit.kind.rawValue):\(hit.id.rawValue)]"
        guard let document = await search.document(for: hit.id) else { return marker }
        var parts: [String] = []
        if let title = SearchProjector.nonEmpty(document.title) { parts.append(title) }
        if let caption = SearchProjector.nonEmpty(document.caption) {
            parts.append(caption)
        } else if let text = SearchProjector.nonEmpty(document.text) {
            parts.append(text)
        }
        let model = model
        return await PromptAssembler.truncate(
            marker + " " + parts.joined(separator: ", "),
            toTokens: configuration.maximumSourceTokens
        ) { await model.countTokens($0) }
    }

    // MARK: Idle and memory

    private func noteUse() {
        use &+= 1
        let current = use
        let idle = configuration.idleUnload
        idleTask?.cancel()
        guard idle > 0 else { return }
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            } catch {
                return
            }
            await self?.unloadIfIdle(since: current)
        }
    }

    private func unloadIfIdle(since current: UInt64) async {
        guard current == use, case .ready = lifecycle else { return }
        await unload()
    }

    /// A memory warning unloads the model. The name is spelled out so no UI framework is imported.
    private func startMemoryObserver() {
        guard memoryObserver == nil else { return }
        memoryObserver = Task { [weak self] in
            let name = Notification.Name("UIApplicationDidReceiveMemoryWarningNotification")
            for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                guard let self else { return }
                await self.unload()
            }
        }
    }
}

extension ChatDeviceProfile {
    /// The device the process runs on.
    public static var current: ChatDeviceProfile {
        let process = ProcessInfo.processInfo
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "0")(\(info?["CFBundleVersion"] as? String ?? "0"))"
        return ChatDeviceProfile(
            operatingSystem: process.operatingSystemVersion,
            physicalMemory: Int64(clamping: process.physicalMemory),
            freeDiskBytes: free,
            buildFingerprint: "\(app)|\(process.operatingSystemVersionString)"
        )
    }

    static func version(_ version: OperatingSystemVersion, isAtLeast minimum: OperatingSystemVersion) -> Bool {
        if version.majorVersion != minimum.majorVersion { return version.majorVersion > minimum.majorVersion }
        if version.minorVersion != minimum.minorVersion { return version.minorVersion > minimum.minorVersion }
        return version.patchVersion >= minimum.patchVersion
    }
}

/// The default calibration store: one boolean per key in `UserDefaults`.
public struct UserDefaultsCalibrationStore: ChatCalibrationStoring {
    public let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func verdict(forKey key: String) async -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    public func setVerdict(_ verdict: Bool, forKey key: String) async {
        defaults.set(verdict, forKey: key)
    }
}

/// The facade the host wires once (specification section 14.1).
///
/// The asset provider (the host's adapter over ZTronAssetKit) and the runtime (for example
/// ZTronSearchEngineMLX) are injected here; `chat` is `nil` when either boundary is absent.
public final class ZTronSearch<Schema: SearchSchema>: Sendable {
    public let search: SearchService<Schema>
    /// `nil` when either boundary is absent.
    public let chat: ChatService<Schema>?

    public init(
        search: SearchService<Schema>,
        assets: (any ModelAssetProviding)? = nil,
        languageModel: (any LocalLanguageModel)? = nil,
        chat configuration: ChatConfiguration = .default
    ) {
        self.search = search
        if let assets, let languageModel {
            let service = ChatService(search: search, assets: assets, model: languageModel, configuration: configuration)
            chat = service
            // On a memory warning the language model unloads before the embedding model.
            Task {
                await search.setMemoryWarningPredecessor { await service.unload() }
            }
        } else {
            chat = nil
        }
    }
}
