import Foundation
import ZTronAssetKit
import ZTronSearchEngine

/// What the store holds for the catalog assets of one plan, judged from the store's answers.
struct StoreInspection: Sendable {
    /// The blob of every catalog asset that holds the described bytes: named by the file's
    /// SHA-256 (`StoredBlob`) and of the file's size.
    var verified: [AssetID: URL] = [:]
    /// Catalog assets that hold other bytes than the descriptor names.
    var mismatched: [AssetID: AssetLocation] = [:]
    /// Catalog assets with nothing stored.
    var absent: [AssetID] = []

    var isComplete: Bool {
        mismatched.isEmpty && absent.isEmpty
    }
}

/// The calls `availability`, `fetch` and `evict` make of the client, with their diagnostics.
struct ModelAssetStore: Sendable {
    let client: any ModelAssetClient
    let diagnostics: DiagnosticReporter

    /// Reads the client's snapshot once and sorts the catalog assets of `plan`. Never downloads.
    func inspect(_ plan: ModelAssetPlan) async -> StoreInspection {
        let locations = await client.locations(of: plan.identifiers)
        var inspection = StoreInspection()
        for identifier in plan.identifiers {
            guard let location = locations[identifier] else {
                inspection.absent.append(identifier)
                continue
            }
            // Every entry of one identifier has the same content (`ModelAssetPlan.init`).
            let holdsDescribedBytes = plan.entries(of: identifier).allSatisfy { entry in
                StoredBlob.contentHash(of: location.url) == entry.sha256 && location.byteSize == entry.file.byteCount
            }
            if holdsDescribedBytes {
                inspection.verified[identifier] = location.url
            } else {
                inspection.mismatched[identifier] = location
            }
        }
        return inspection
    }

    /// Pins every catalog asset of `plan`, so quota eviction never removes a model that is in
    /// use. A failure is reported and otherwise ignored: the files are stored either way.
    ///
    /// The store ignores an asset that is pinned already and commits nothing then
    /// (`Sources/ZTronAssetStorage/Eviction/StoreEviction.swift:30-53`), so pinning on every
    /// `availability(of:)` costs one actor hop.
    func pin(_ plan: ModelAssetPlan) async {
        do {
            try await client.pin(Set(plan.identifiers))
        } catch {
            diagnostics.report(.clientFailed(.pin, error, reportedAs: nil))
        }
    }

    /// Deletes stored assets with `purge(.scope(.identifiers(…)))`, which schedules no download
    /// of what it deletes. Returns the error instead of throwing, for the caller to weigh.
    func purge(_ identifiers: Set<AssetID>) async -> AssetError? {
        do {
            _ = try await client.purge(.scope(.identifiers(identifiers)))
            return nil
        } catch {
            return error
        }
    }

    func reportMismatch(of identifier: AssetID, storedAt url: URL, in plan: ModelAssetPlan) {
        for entry in plan.entries(of: identifier) {
            diagnostics.report(
                .contentMismatch(
                    identifier: identifier,
                    fileName: entry.file.name,
                    expectedSHA256: entry.sha256,
                    storedSHA256: StoredBlob.contentHash(of: url)
                )
            )
        }
    }
}

/// The work of one fetch session (`FetchCoordinator`): inspect the store, ask ZTronAssetKit for
/// what is missing, verify what it returns, then pin and link the files.
struct FetchOperation: Sendable {
    let plan: ModelAssetPlan
    let policy: DownloadPolicy
    let store: ModelAssetStore
    let directories: ModelDirectoryStore
    let coordinator: FetchCoordinator

    private var client: any ModelAssetClient {
        store.client
    }

    private var diagnostics: DiagnosticReporter {
        store.diagnostics
    }

    func run(report: @escaping FetchCoordinator.Report) async -> FetchOutcome {
        if await coordinator.isRejected(plan.asset) {
            return .failed(.checksum)
        }
        do {
            try await client.start()
        } catch {
            return failure(.start, error)
        }

        var inspection = await store.inspect(plan)

        // The catalog's current content of an asset is not what the descriptor names, so a
        // download would store the same bytes again. The model is not fetched, now or later.
        let contradicted = inspection.mismatched.filter { !$0.value.isStale }
        if !contradicted.isEmpty {
            var otherBytes: Set<AssetID> = []
            for (identifier, location) in contradicted {
                if plan.entries(of: identifier).allSatisfy({ StoredBlob.contentHash(of: location.url) == $0.sha256 }) {
                    // The stored blob has the described SHA-256 and another size than the descriptor
                    // states: the descriptor contradicts itself. The bytes are kept.
                    reportSizeConflict(of: identifier, storedBytes: location.byteSize)
                } else {
                    store.reportMismatch(of: identifier, storedAt: location.url, in: plan)
                    otherBytes.insert(identifier)
                }
            }
            if !otherBytes.isEmpty {
                await delete(otherBytes)
            }
            return await rejected()
        }

        // Bytes to replace: an older blob while the catalog announces newer content, and a blob
        // the store lists but the disk no longer holds. `resolve` answers a stored asset without
        // a transfer, so the stored copy has to go before a fresh one can come.
        var replaced = Set(inspection.mismatched.keys)
        for entry in await directories.damagedFiles(of: plan, blobs: inspection.verified) {
            diagnostics.report(.damagedBlob(identifier: entry.identifier, fileName: entry.file.name))
            replaced.insert(entry.identifier)
        }
        if !replaced.isEmpty {
            guard policy != .never else {
                return .failed(.policy)
            }
            if let error = await store.purge(replaced) {
                return failure(.purge, error)
            }
            for identifier in replaced {
                inspection.verified[identifier] = nil
            }
        }

        let pending = plan.identifiers.filter { inspection.verified[$0] == nil }
        if pending.isEmpty {
            return await link(inspection.verified)
        }
        guard let lane = DownloadLane.lane(for: policy, network: client.networkPolicy, power: client.powerPolicy) else {
            if policy == .wifiOnly {
                diagnostics.report(.wifiOnlyNotEnforceable)
            }
            return .failed(.policy)
        }
        if Task.isCancelled {
            return .cancelled
        }

        let events: AsyncStream<AssetEvent>
        do {
            events = try await client.subscribe()
        } catch {
            return failure(.subscribe, error)
        }
        switch await download(pending, on: lane, events: events, stored: inspection.verified, report: report) {
        case .stopped(let outcome):
            return outcome
        case .stored(let blobs):
            return await link(blobs)
        case .contradicted(let identifier, let url):
            // Every other request is withdrawn by now, so nothing keeps downloading while the
            // stored asset is deleted.
            store.reportMismatch(of: identifier, storedAt: url, in: plan)
            await delete([identifier])
            return await rejected()
        }
    }

    // MARK: - Download

    private enum Signal: Sendable {
        case progress(AssetID, received: Int64)
        case conditions(DeviceConditions)
        case resolved(AssetID, Result<URL, AssetError>)
    }

    private enum Download: Sendable {
        /// Every pending asset is stored, with its blob named by its file's SHA-256.
        case stored([AssetID: URL])
        case stopped(FetchOutcome)
        /// ZTronAssetKit stored, for this asset, a blob that is not the described one.
        case contradicted(AssetID, URL)
    }

    /// Asks ZTronAssetKit for every pending asset on `lane` and follows its events until each is
    /// stored and verified, one fails or is not the described file, or the conditions refuse the
    /// lane.
    ///
    /// Leaving this function cancels every request still waiting, which withdraws this fetch's
    /// interest: ZTronAssetKit stops a transfer when nobody else waits for it.
    private func download(
        _ pending: [AssetID],
        on lane: DownloadLane,
        events: AsyncStream<AssetEvent>,
        stored: [AssetID: URL],
        report: @escaping FetchCoordinator.Report
    ) async -> Download {
        let total = plan.asset.totalBytes
        var ledger = ProgressLedger(plan: plan, stored: Set(stored.keys))
        // The first element says where this fetch starts: at the bytes that are stored already.
        await report(ledger.bytes, total)

        let client = self.client
        let (signals, sink) = AsyncStream.makeStream(of: Signal.self)
        return await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .transferProgress(let identifier, let progress):
                        sink.yield(.progress(identifier, received: progress.received))
                    case .conditionsChanged(let conditions):
                        sink.yield(.conditions(conditions))
                    default:
                        break
                    }
                }
            }
            for identifier in pending {
                group.addTask {
                    do throws(AssetError) {
                        let url = try await client.resolve(identifier, priority: lane.priority)
                        sink.yield(.resolved(identifier, .success(url)))
                    } catch {
                        sink.yield(.resolved(identifier, .failure(error)))
                    }
                }
            }

            var blobs = stored
            var remaining = Set(pending)
            var stopped: Download?
            // The iteration ends by itself when this task is cancelled.
            loop: for await signal in signals {
                switch signal {
                case .progress(let identifier, let received):
                    if ledger.record(received, for: identifier) {
                        await report(ledger.bytes, total)
                    }
                case .conditions(let conditions):
                    if lane.isRefused(under: conditions) {
                        diagnostics.report(.networkRefused(policy, conditions))
                        stopped = .stopped(.failed(.policy))
                        break loop
                    }
                case .resolved(let identifier, .success(let url)):
                    guard plan.entries(of: identifier).allSatisfy({ StoredBlob.contentHash(of: url) == $0.sha256 }) else {
                        stopped = .contradicted(identifier, url)
                        break loop
                    }
                    blobs[identifier] = url
                    remaining.remove(identifier)
                    if ledger.complete(identifier) {
                        await report(ledger.bytes, total)
                    }
                    if remaining.isEmpty {
                        break loop
                    }
                case .resolved(_, .failure(let error)):
                    stopped = .stopped(failure(.resolve, error))
                    break loop
                }
            }
            group.cancelAll()
            if let stopped {
                return stopped
            }
            return remaining.isEmpty ? .stored(blobs) : .stopped(.cancelled)
        }
    }

    // MARK: - Steps

    /// Checks the blobs on disk, links them, then pins the assets.
    private func link(_ blobs: [AssetID: URL]) async -> FetchOutcome {
        if Task.isCancelled {
            return .cancelled
        }
        do {
            let directory = try await directories.materialize(plan, blobs: blobs)
            await store.pin(plan)
            return .available(directory)
        } catch {
            switch error {
            case .damagedBlobs(let names):
                for entry in plan.entries where names.contains(entry.file.name) {
                    diagnostics.report(.damagedBlob(identifier: entry.identifier, fileName: entry.file.name))
                }
                return .failed(.checksum)
            case .diskFull:
                return .failed(.diskFull)
            case .failed(let message):
                diagnostics.report(.directoryFailed(message))
                return .failed(.diskFull)
            }
        }
    }

    /// Remembers that the catalog contradicts the descriptor, so the model is not downloaded
    /// again by this provider, and fails the fetch with `.checksum`.
    ///
    /// A session that was stopped meanwhile remembers nothing: `evict(_:)` stops the fetches of
    /// an asset and then forgets its rejection, and a session that is still unwinding must not
    /// bring the rejection back.
    private func rejected() async -> FetchOutcome {
        if Task.isCancelled {
            return .cancelled
        }
        await coordinator.reject(plan.asset)
        return .failed(.checksum)
    }

    /// Deletes stored bytes that are not the model's. The fetch fails with `.checksum` whether
    /// or not the deletion succeeds, so its failure is only reported.
    ///
    /// `AssetClient.purge` returns once the store has unlinked the files, which it does after its
    /// deletion grace (10 s by default). A fetch whose last reader leaves meanwhile gets
    /// `.cancelled` from a purge that is committed all the same; that is not a failure.
    private func delete(_ identifiers: Set<AssetID>) async {
        if let error = await store.purge(identifiers), error != .cancelled {
            diagnostics.report(.clientFailed(.purge, error, reportedAs: nil))
        }
    }

    private func reportSizeConflict(of identifier: AssetID, storedBytes: Int64) {
        for entry in plan.entries(of: identifier) {
            diagnostics.report(
                .invalidDescriptor(
                    assetID: plan.asset.id,
                    revision: plan.asset.revision,
                    reason: "'\(entry.file.name)' states \(entry.file.byteCount) bytes, but the blob of its SHA-256 has \(storedBytes)"
                )
            )
        }
    }

    private func failure(_ operation: AssetKitBridgeDiagnostic.Operation, _ error: AssetError) -> FetchOutcome {
        guard let reported = ModelAssetError(error) else {
            return .cancelled
        }
        diagnostics.report(.clientFailed(operation, error, reportedAs: reported))
        return .failed(reported)
    }
}

/// The bytes of a model that are on the device, counted per file so the sum never goes down.
///
/// ZTronAssetKit reports the progress of a transfer under one asset identifier of the content
/// being transferred (`Sources/ZTronAssetSync/Engine/EngineDispatch.swift:906-916`), so a count is
/// credited to every file of the model with that content. A count that falls (a transfer that
/// started again) is ignored.
struct ProgressLedger: Sendable {
    private let entries: [ModelAssetPlan.Entry]
    private var counts: [Int64]
    /// The sum over every file.
    private(set) var bytes: Int64

    /// Starts with the files of `stored` counted in full.
    init(plan: ModelAssetPlan, stored: Set<AssetID>) {
        entries = plan.entries
        counts = plan.entries.map { stored.contains($0.identifier) ? $0.file.byteCount : 0 }
        bytes = counts.reduce(0, +)
    }

    /// Records that `received` bytes of the content of `identifier` arrived. `true` when the sum
    /// grew.
    mutating func record(_ received: Int64, for identifier: AssetID) -> Bool {
        guard let content = entries.first(where: { $0.identifier == identifier })?.sha256 else {
            return false
        }
        return raise(to: received) { $0.sha256 == content }
    }

    /// Records that the files of `identifier` are stored. `true` when the sum grew.
    mutating func complete(_ identifier: AssetID) -> Bool {
        raise(to: .max) { $0.identifier == identifier }
    }

    private mutating func raise(to count: Int64, where matches: (ModelAssetPlan.Entry) -> Bool) -> Bool {
        var grew = false
        for (index, entry) in entries.enumerated() where matches(entry) {
            let value = min(max(count, 0), entry.file.byteCount)
            if value > counts[index] {
                bytes += value - counts[index]
                counts[index] = value
                grew = true
            }
        }
        return grew
    }
}
