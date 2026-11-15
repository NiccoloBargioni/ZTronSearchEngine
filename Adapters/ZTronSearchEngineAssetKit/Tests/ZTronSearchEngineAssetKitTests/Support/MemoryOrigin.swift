import Foundation
import ZTronAssetKit

// An origin that lives in memory, for the tests that drive a real `AssetClient`.
//
// ZTronAssetKit's HTTP transport contacts HTTPS origins only, and the fakes of its own test
// support are not part of its product. What its product does expose is the seam the transport
// itself plugs into: `AssetEnvironment.remoteSources` takes any `RemoteSourceFactory`, and
// `AssetEnvironment.conditions` any `DeviceConditionsSource`. The types below conform to those
// public protocols, so the engine, the store, the index and the snapshot under test are the real
// ones, the bytes land in a real store directory, and no socket is opened.

/// A catalog and its payloads, with a script for what each transfer does and a log of what the
/// engine asked for.
actor MemoryOrigin {
    /// One published asset.
    struct Entry: Sendable {
        var identifier: AssetID
        var fileExtension: String
        var remotePath: String
        /// The bytes the origin serves.
        var data: Data
        /// The checksum and size the manifest announces: those of `data` unless a test says otherwise.
        var checksum: String
        var byteSize: Int64
        var policy: String = "onDemand"
    }

    /// What a transfer of one path does.
    enum Behavior: Sendable {
        /// Serves the published bytes.
        case serve
        /// Serves other bytes than the manifest announces.
        case serveInstead(Data)
        case fail(TransferError)
    }

    struct Census: Sendable {
        /// Paths whose transfer waits at its gate.
        var waiting: Set<String>
        /// Transfers that have not delivered their terminal element.
        var active: Int
        /// Transfers the engine paused or cancelled.
        var stopped: Int
        var requests: Int
    }

    private var entries: [String: Entry] = [:]
    private var behaviors: [String: Behavior] = [:]
    private var gated: Set<String> = []
    private var revision = 1

    private(set) var requests: [TransferRequest] = []
    private(set) var stops: [(path: String, control: TransferControl)] = []
    private(set) var manifestFetches = 0

    private var active = 0
    private var lastToken: UInt64 = 0
    private var atGate: [UInt64: (path: String, continuation: CheckedContinuation<TransferError?, Never>)] = [:]
    private var waiters: [UInt64: (predicate: @Sendable (Census) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]

    // MARK: - Script

    func publish(_ entry: Entry) {
        entries[entry.remotePath] = entry
        revision += 1
    }

    func script(_ behavior: Behavior, for remotePath: String) {
        behaviors[remotePath] = behavior
    }

    /// Makes the transfer of `remotePath` stop after its first chunk until `open(_:)` or
    /// `fail(_:with:)`.
    func gate(_ remotePath: String) {
        gated.insert(remotePath)
    }

    /// Lets the transfer waiting at the gate of `remotePath` go on, and later ones pass.
    func open(_ remotePath: String) {
        release(remotePath, with: nil)
    }

    /// Makes the transfer waiting at the gate of `remotePath` fail, and removes the gate.
    func fail(_ remotePath: String, with error: TransferError) {
        release(remotePath, with: error)
    }

    private func release(_ remotePath: String, with error: TransferError?) {
        gated.remove(remotePath)
        for (token, waiting) in atGate where waiting.path == remotePath {
            atGate[token] = nil
            waiting.continuation.resume(returning: error)
        }
        notify()
    }

    // MARK: - Observation

    var census: Census {
        Census(waiting: Set(atGate.values.map(\.path)), active: active, stopped: stops.count, requests: requests.count)
    }

    func requests(for remotePath: String) -> [TransferRequest] {
        requests.filter { $0.remotePath == remotePath }
    }

    func wait(until predicate: @escaping @Sendable (Census) -> Bool) async {
        if predicate(census) {
            return
        }
        lastToken += 1
        let token = lastToken
        // A wait that never comes true ends with its task, so a time limit can fail the test.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[token] = (predicate, continuation)
                }
            }
        } onCancel: {
            Task {
                await self.abandonWait(token)
            }
        }
    }

    private func abandonWait(_ token: UInt64) {
        waiters.removeValue(forKey: token)?.continuation.resume()
    }

    // MARK: - For the source

    func manifest(for request: ManifestRequest) throws(TransferError) -> ManifestFetchResult {
        manifestFetches += 1
        guard let tag = ETag(rawValue: "\"revision-\(revision)\"") else {
            throw .transient(.badServerResponse, retryAfter: nil)
        }
        if request.ifNoneMatch == tag {
            return .notModified(removedSources: [])
        }
        let assets: [[String: Any]] = entries.values.sorted { $0.remotePath < $1.remotePath }.map { entry in
            [
                "identifier": entry.identifier.rawValue,
                "fileExtension": entry.fileExtension,
                "remotePath": entry.remotePath,
                "localPathComponents": ["Models"],
                "byteSize": entry.byteSize,
                "checksum": entry.checksum,
                "policy": entry.policy,
                "tags": ["model"],
            ]
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: assets) else {
            throw .transient(.badServerResponse, retryAfter: nil)
        }
        return .fetched(ManifestPayload(bytes: bytes, etag: tag, origin: .network))
    }

    /// Logs a transfer request and says what it does and which bytes it serves.
    func begin(_ request: TransferRequest) -> (behavior: Behavior, data: Data?) {
        requests.append(request)
        active += 1
        notify()
        return (behaviors[request.remotePath] ?? .serve, entries[request.remotePath]?.data)
    }

    func end(_ request: TransferRequest, stoppedBy control: TransferControl?) {
        active -= 1
        if let control {
            stops.append((request.remotePath, control))
        }
        notify()
    }

    /// Suspends at the gate of `remotePath`, if it has one, until it opens, a test fails the
    /// transfer there (the error is returned) or the caller is cancelled.
    func passGate(of remotePath: String) async -> TransferError? {
        guard gated.contains(remotePath) else {
            return nil
        }
        lastToken += 1
        let token = lastToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TransferError?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    atGate[token] = (remotePath, continuation)
                    notify()
                }
            }
        } onCancel: {
            Task {
                await self.leaveGate(token)
            }
        }
    }

    /// Returns once no transfer is running, as `RemoteSource.invalidate()` must.
    func quiesce() async {
        await wait { $0.active == 0 }
    }

    // MARK: - Private

    private func leaveGate(_ token: UInt64) {
        guard let waiting = atGate.removeValue(forKey: token) else {
            return
        }
        waiting.continuation.resume(returning: nil)
        notify()
    }

    private func notify() {
        let census = self.census
        for (token, waiter) in waiters where waiter.predicate(census) {
            waiters[token] = nil
            waiter.continuation.resume()
        }
    }
}

/// The `RemoteSource` of a `MemoryOrigin`: transfers write into the store's real staging directory.
struct MemoryRemoteSource: RemoteSource {
    let origin: MemoryOrigin
    let staging: any StagingSink
    /// Staging writes are blocking units: they run here, not on the cooperative pool.
    let queue = DispatchQueue(label: "ZTronSearchEngineAssetKitTests.memory-origin")

    let originID = "https://models.invalid:443"
    let capabilities = RemoteSourceCapabilities(
        tier: .aws,
        supportsPriority: true,
        supportsResume: false,
        supportsBackground: false,
        keepsSourceCopies: false
    )

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        try await origin.manifest(for: request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        MemoryTransferHandle(request: request, source: self)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        []
    }

    func cancelTransfer(_ name: StagingFileName) async {}

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        ReclaimReport()
    }

    func sourceCopyBytes() async -> Int64 {
        0
    }

    func handleBackgroundEvents(identifier: String) async {}

    func invalidate() async {
        await origin.quiesce()
    }

    /// Runs one staging unit on the queue.
    func stage<Value: Sendable>(_ unit: @escaping @Sendable () throws(StagingError) -> Value) async -> Result<Value, StagingError> {
        await withCheckedContinuation { continuation in
            queue.async {
                do throws(StagingError) {
                    continuation.resume(returning: .success(try unit()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }
}

struct MemoryRemoteSourceFactory: RemoteSourceFactory {
    let origin: MemoryOrigin

    func makeRemoteSource(
        configuration: RemoteConfiguration,
        staging: any StagingSink,
        log: LogRoute
    ) async throws(AssetError) -> any RemoteSource {
        MemoryRemoteSource(origin: origin, staging: staging)
    }
}

/// One attempt. Controls are synchronous, as the protocol asks; they reach the driving task
/// through a stream, in the order they were made.
final class MemoryTransferHandle: TransferHandle {
    let id: TransferID
    let attempt: TransferAttempt
    let updates: AsyncStream<TransferUpdate>
    private let controls: AsyncStream<TransferControl>.Continuation

    private enum Step: Sendable {
        case finished(TransferUpdate)
        case stopped(TransferControl)
    }

    init(request: TransferRequest, source: MemoryRemoteSource) {
        id = request.id
        attempt = request.attempt
        let (updates, sink) = AsyncStream.makeStream(of: TransferUpdate.self)
        let (controls, controlSink) = AsyncStream.makeStream(of: TransferControl.self)
        self.updates = updates
        self.controls = controlSink
        // A consumer that drops the stream cancels the transfer.
        sink.onTermination = { _ in
            controlSink.yield(.cancel)
        }
        Task {
            await Self.drive(request, source: source, sink: sink, controls: controls)
        }
    }

    func setPriority(_ priority: AssetPriority) {
        controls.yield(.setPriority(priority))
    }

    func pause() {
        controls.yield(.pause)
    }

    func cancel() {
        controls.yield(.cancel)
    }

    private static func drive(
        _ request: TransferRequest,
        source: MemoryRemoteSource,
        sink: AsyncStream<TransferUpdate>.Continuation,
        controls: AsyncStream<TransferControl>
    ) async {
        let (behavior, data) = await source.origin.begin(request)
        var stoppedBy: TransferControl?
        let terminal = await withTaskGroup(of: Step.self) { group in
            group.addTask {
                .finished(await perform(request, behavior: behavior, data: data, source: source, sink: sink))
            }
            group.addTask {
                for await control in controls {
                    if control == .pause || control == .cancel {
                        return .stopped(control)
                    }
                }
                return .stopped(.cancel)
            }
            guard let first = await group.next() else {
                return TransferUpdate.failed(.transient(.incompleteCallbackSequence, retryAfter: nil))
            }
            group.cancelAll()
            switch first {
            case .finished(let update):
                return update
            case .stopped(let control):
                // The writer has to be done before its partial is discarded.
                _ = await group.next()
                await source.staging.discard(request.partialName)
                stoppedBy = control
                return control == .pause ? .paused(resumable: false) : .failed(.cancelled(.byClient))
            }
        }
        // The engine waits for the origin to quiesce at shutdown, so the count falls before the stream ends.
        await source.origin.end(request, stoppedBy: stoppedBy)
        sink.yield(terminal)
        sink.finish()
    }

    /// Stages the bytes in four chunks, reporting progress after each.
    private static func perform(
        _ request: TransferRequest,
        behavior: MemoryOrigin.Behavior,
        data published: Data?,
        source: MemoryRemoteSource,
        sink: AsyncStream<TransferUpdate>.Continuation
    ) async -> TransferUpdate {
        let data: Data
        switch behavior {
        case .fail(let error):
            return .failed(error)
        case .serveInstead(let other):
            data = other
        case .serve:
            guard let published else {
                return .failed(.permanentMissing(httpStatus: 404))
            }
            data = published
        }
        let staging = source.staging
        let name = request.partialName
        if case .failure(let error) = await source.stage({ () throws(StagingError) in try staging.createPartial(name) }) {
            return .failed(transferError(error, bytes: data.count))
        }
        let chunkSize = max(1, (data.count + 3) / 4)
        var offset = 0
        var written: Int64 = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + chunkSize, data.count))
            switch await source.stage({ () throws(StagingError) -> Int64 in try staging.appendPartial(chunk, to: name) }) {
            case .success(let size):
                written = size
            case .failure(let error):
                return .failed(transferError(error, bytes: data.count))
            }
            sink.yield(.progress(received: written, expected: Int64(data.count)))
            offset += chunk.count
            if offset < data.count, let error = await source.origin.passGate(of: request.remotePath) {
                await staging.discard(name)
                return .failed(error)
            }
            if Task.isCancelled {
                return .failed(.cancelled(.byClient))
            }
        }
        return .staged(StagedFile(name: name, byteCount: written, resumed: false, httpStatus: 200, etag: nil))
    }

    private static func transferError(_ error: StagingError, bytes: Int) -> TransferError {
        switch error {
        case .insufficientSpace:
            return .insufficientSpace(requiredBytes: Int64(bytes))
        case .io(let code):
            return .transient(.localIO(posixCode: code), retryAfter: nil)
        case .tooLarge(let limit):
            return .integrity(.oversize(announced: nil, limit: limit))
        case .source, .nameInUse:
            return .transient(.unknown(urlErrorCode: 0), retryAfter: nil)
        }
    }
}

/// Device conditions a test sets.
actor ScriptedConditions: DeviceConditionsSource {
    private var current: DeviceConditions
    private var observers: [UInt64: AsyncStream<DeviceConditions>.Continuation] = [:]
    private var lastToken: UInt64 = 0

    init(_ conditions: DeviceConditions) {
        current = conditions
    }

    func conditions() async -> AsyncStream<DeviceConditions> {
        lastToken += 1
        let token = lastToken
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceConditions.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { _ in
            Task {
                await self.remove(token)
            }
        }
        continuation.yield(current)
        observers[token] = continuation
        return stream
    }

    func set(_ conditions: DeviceConditions) {
        current = conditions
        for continuation in observers.values {
            continuation.yield(conditions)
        }
    }

    private func remove(_ token: UInt64) {
        observers[token] = nil
    }
}

/// No prior-art sync stamp: these tests never read the user's defaults.
struct NoLegacyDefaults: LegacyDefaults {
    func string(forKey key: String) -> String? {
        nil
    }

    func removeValue(forKey key: String) {}
}
