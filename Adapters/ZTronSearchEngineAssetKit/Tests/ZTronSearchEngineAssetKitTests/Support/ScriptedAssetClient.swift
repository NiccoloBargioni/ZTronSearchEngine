import CryptoKit
import Foundation
import ZTronAssetKit
@testable import ZTronSearchEngineAssetKit

/// A `ModelAssetClient` that a test scripts: what is stored, what a download does, which events
/// arrive. It keeps a log of every call, so a test can assert what the provider asked for.
///
/// Stored assets are real files laid out as ZTronAssetKit lays out blobs,
/// `<root>/blobs/<aa>/<sha256>.<ext>`, because the provider reads their names and sizes.
actor ScriptedAssetClient: ModelAssetClient {
    enum Call: Hashable, Sendable {
        case start
        case locations([AssetID])
        case resolve(AssetID, AssetPriority)
        case subscribe
        case pin(Set<AssetID>)
        case unpin(Set<AssetID>)
        case purge(PurgeRequest)
    }

    /// What `resolve` does for an asset that is not stored.
    enum Download: Sendable {
        /// Publishes one `transferProgress` per count, then stores the bytes.
        case deliver(Data, fileExtension: String = "bin", progress: [Int64] = [])
        /// Waits for `complete(_:)`, `fail(_:with:)` or the caller's cancellation.
        case hold(Data, fileExtension: String = "bin")
        /// Fails as ZTronAssetKit would.
        case fail(AssetError)
    }

    nonisolated let networkPolicy: NetworkPolicy
    nonisolated let powerPolicy: PowerPolicy
    nonisolated let root: URL

    private(set) var calls: [Call] = []
    private(set) var pinned: Set<AssetID> = []
    /// Assets whose `resolve` was withdrawn by its caller's cancellation, in order.
    private(set) var cancelledResolves: [AssetID] = []
    /// How many `resolve` calls were still waiting when each purge arrived.
    private(set) var heldResolvesAtPurge: [Int] = []

    private var stored: [AssetID: AssetLocation] = [:]
    private var downloads: [AssetID: Download] = [:]
    private var startError: AssetError?
    private var subscribeError: AssetError?
    private var purgeError: AssetError?
    private var conditions: DeviceConditions?

    private var lastToken: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<AssetEvent>.Continuation] = [:]
    private var held: [UInt64: (identifier: AssetID, continuation: CheckedContinuation<Result<Data, AssetError>, Never>)] = [:]
    private var waiters: [UInt64: (predicate: @Sendable (Census) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]

    /// Counts a test can wait for.
    struct Census: Sendable {
        /// `resolve` calls waiting in a `.hold` download.
        var heldResolves: Int
        /// Event streams that are still open.
        var subscribers: Int
        /// `resolve` calls withdrawn by their caller's cancellation.
        var cancelledResolves: Int
        /// Assets stored.
        var stored: Int
    }

    init(root: URL, network: NetworkPolicy = NetworkPolicy(), power: PowerPolicy = PowerPolicy()) {
        self.root = root
        self.networkPolicy = network
        self.powerPolicy = power
    }

    // MARK: - Script

    /// Stores `data` for `identifier` as ZTronAssetKit would after a verified download.
    @discardableResult
    func preload(_ data: Data, for identifier: AssetID, fileExtension: String = "bin", isStale: Bool = false) throws -> URL {
        guard let blobExtension = AssetFileExtension(fileExtension) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = try write(data, fileExtension: blobExtension.rawValue)
        stored[identifier] = AssetLocation(
            id: identifier,
            url: url,
            fileExtension: blobExtension,
            byteSize: Int64(data.count),
            integrity: .verified,
            isStale: isStale
        )
        notify()
        return url
    }

    /// Lists `location` as stored without touching the disk.
    func preload(_ location: AssetLocation) {
        stored[location.id] = location
    }

    /// Stops listing `identifier` without touching its blob: what a snapshot that trails the
    /// store looks like, or a blob inside the store's deletion grace.
    func unlist(_ identifier: AssetID) {
        stored[identifier] = nil
        notify()
    }

    func script(_ download: Download, for identifier: AssetID) {
        downloads[identifier] = download
    }

    func failStart(with error: AssetError?) {
        startError = error
    }

    func failSubscribe(with error: AssetError?) {
        subscribeError = error
    }

    func failPurge(with error: AssetError?) {
        purgeError = error
    }

    /// Sets the device conditions: replayed to every later subscriber and sent to current ones.
    func setConditions(_ conditions: DeviceConditions) {
        self.conditions = conditions
        emit(.conditionsChanged(conditions))
    }

    func emit(_ event: AssetEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// Lets every held `resolve` of `identifier` store its bytes and return.
    func complete(_ identifier: AssetID) {
        guard case .hold(let data, _)? = downloads[identifier] else {
            return
        }
        for (token, waiting) in held where waiting.identifier == identifier {
            held[token] = nil
            waiting.continuation.resume(returning: .success(data))
        }
        notify()
    }

    /// Makes every held `resolve` of `identifier` fail.
    func fail(_ identifier: AssetID, with error: AssetError) {
        for (token, waiting) in held where waiting.identifier == identifier {
            held[token] = nil
            waiting.continuation.resume(returning: .failure(error))
        }
        notify()
    }

    // MARK: - Observation

    var census: Census {
        Census(heldResolves: held.count, subscribers: subscribers.count, cancelledResolves: cancelledResolves.count, stored: stored.count)
    }

    var storedIdentifiers: Set<AssetID> {
        Set(stored.keys)
    }

    func location(of identifier: AssetID) -> AssetLocation? {
        stored[identifier]
    }

    /// The assets `resolve` was called for, in call order.
    var resolved: [AssetID] {
        calls.compactMap { call in
            if case .resolve(let identifier, _) = call {
                return identifier
            }
            return nil
        }
    }

    /// The lanes `resolve` was called on.
    var lanes: Set<AssetPriority> {
        Set(calls.compactMap { call in
            if case .resolve(_, let priority) = call {
                return priority
            }
            return nil
        })
    }

    func count(of call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    /// Suspends until `predicate` holds for the census.
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

    // MARK: - ModelAssetClient

    func start() async throws(AssetError) {
        calls.append(.start)
        if let startError {
            throw startError
        }
    }

    func locations(of identifiers: [AssetID]) async -> [AssetID: AssetLocation] {
        calls.append(.locations(identifiers))
        return stored.filter { identifiers.contains($0.key) }
    }

    func resolve(_ identifier: AssetID, priority: AssetPriority) async throws(AssetError) -> URL {
        calls.append(.resolve(identifier, priority))
        if let location = stored[identifier] {
            return location.url
        }
        guard let download = downloads[identifier] else {
            throw .notFound
        }
        switch download {
        case .fail(let error):
            throw error
        case .deliver(let data, let fileExtension, let progress):
            for count in progress {
                emit(.transferProgress(identifier, TransferProgress(received: count, expected: Int64(data.count))))
            }
            return try store(data, for: identifier, fileExtension: fileExtension)
        case .hold(_, let fileExtension):
            lastToken += 1
            let token = lastToken
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, AssetError>, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: .failure(.cancelled))
                    } else {
                        held[token] = (identifier, continuation)
                        notify()
                    }
                }
            } onCancel: {
                Task {
                    await self.withdraw(token)
                }
            }
            let data = try result.get()
            return try store(data, for: identifier, fileExtension: fileExtension)
        }
    }

    func subscribe() async throws(AssetError) -> AsyncStream<AssetEvent> {
        calls.append(.subscribe)
        if let subscribeError {
            throw subscribeError
        }
        lastToken += 1
        let token = lastToken
        let (stream, continuation) = AsyncStream.makeStream(of: AssetEvent.self)
        continuation.onTermination = { _ in
            Task {
                await self.unsubscribe(token)
            }
        }
        if let conditions {
            continuation.yield(.conditionsChanged(conditions))
        }
        subscribers[token] = continuation
        notify()
        return stream
    }

    func pin(_ identifiers: Set<AssetID>) async throws(AssetError) {
        calls.append(.pin(identifiers))
        pinned.formUnion(identifiers)
    }

    func unpin(_ identifiers: Set<AssetID>) async throws(AssetError) {
        calls.append(.unpin(identifiers))
        pinned.subtract(identifiers)
    }

    func purge(_ request: PurgeRequest) async throws(AssetError) -> PurgeResult {
        calls.append(.purge(request))
        heldResolvesAtPurge.append(held.count)
        if let purgeError {
            throw purgeError
        }
        guard case .scope(.identifiers(let identifiers)) = request else {
            return PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 0)
        }
        var freed: Int64 = 0
        var removed = 0
        for identifier in identifiers {
            guard let location = stored.removeValue(forKey: identifier) else {
                continue
            }
            removed += 1
            // A blob another asset still holds stays, as in the real store.
            if !stored.values.contains(where: { $0.url == location.url }) {
                try? FileManager.default.removeItem(at: location.url)
                freed += location.byteSize
            }
        }
        return PurgeResult(bytesFreed: freed, bytesDeferred: 0, assetsRemoved: removed)
    }

    // MARK: - Private

    private func store(_ data: Data, for identifier: AssetID, fileExtension: String) throws(AssetError) -> URL {
        do {
            return try preload(data, for: identifier, fileExtension: fileExtension)
        } catch {
            throw .storageUnavailable(.ioFailure)
        }
    }

    private func write(_ data: Data, fileExtension: String) throws -> URL {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(hex).\(fileExtension)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
        }
        return url
    }

    private func withdraw(_ token: UInt64) {
        guard let waiting = held.removeValue(forKey: token) else {
            return
        }
        cancelledResolves.append(waiting.identifier)
        waiting.continuation.resume(returning: .failure(.cancelled))
        notify()
    }

    private func unsubscribe(_ token: UInt64) {
        subscribers[token] = nil
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
