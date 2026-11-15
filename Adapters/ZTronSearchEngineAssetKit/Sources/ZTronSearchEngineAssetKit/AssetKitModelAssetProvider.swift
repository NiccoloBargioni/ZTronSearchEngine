import Foundation
import ZTronAssetKit
import ZTronSearchEngine

/// The model-asset boundary of ZTronSearchEngine over ZTronAssetKit.
///
/// Each `ModelFile` of a `ModelAsset` is one asset of the host's ZTronAssetKit catalog.
/// ZTronAssetKit downloads, verifies, stores and resumes; this provider maps files to catalog
/// assets, checks that what is stored is what the descriptor names, keeps the files from being
/// evicted, and gives the runtime one directory that holds every file under its own name.
///
/// ```swift
/// let assets = AssetKitModelAssetProvider(client: assetClient)
/// let search = ZTronSearch(search: service, assets: assets, languageModel: runtime)
/// ```
///
/// **Verification.** A stored file counts as verified when its blob is named by the file's
/// SHA-256 and has the file's size. ZTronAssetKit names every blob by the SHA-256 it computed
/// from the blob's bytes before publishing it, so no file is hashed again (`StoredBlob` cites the
/// code that guarantees it). The size of each blob on disk is checked whenever the directory is
/// built.
///
/// **Directory.** `Library/Caches/ZTronSearchEngineAssetKit/Models/<id>@<revision>-<digest>/`
/// holds one symbolic link per file, pointing at the file's blob. The store stays the only owner
/// of the bytes (`ModelDirectoryStore` states the trade-offs).
///
/// **Keeping files alive.** The provider pins the catalog assets of a model whenever it reports
/// the model available, so ZTronAssetKit's quota eviction never removes them; `evict(_:)` removes
/// the pins. A pin does not stop a `purge` by the host or a prune after the catalog dropped an
/// entry. After either, `availability(of:)` answers `.missing`, and removes the directory once a
/// link in it is broken; a model that is already loaded keeps running. The provider takes no
/// lease (`AssetClient.withAsset`): a lease on an asset that is not stored downloads it on the
/// user-initiated lane (`Sources/ZTronAssetSync/Engine/EngineCommands.swift:897-933`), which no
/// download policy of the boundary allows.
///
/// **Download policy.** ZTronAssetKit sets network permissions per lane, not per request, so a
/// policy is a choice of lane (`lane(for:under:)`). `.wifiOnly` needs a lane that the host's
/// `NetworkPolicy` keeps off expensive networks; with none, a `.wifiOnly` fetch fails with
/// `.policy` and downloads nothing.
public final class AssetKitModelAssetProvider: ModelAssetProviding {
    /// Maps one file of a model to the asset of the host's catalog that holds its bytes.
    ///
    /// The mapping must give another identifier for another revision of the same model: a
    /// revision is another asset, stored and verified on its own.
    public typealias IdentifierMapping = @Sendable (_ asset: ModelAsset, _ file: ModelFile) -> AssetID

    private let store: ModelAssetStore
    private let directories: ModelDirectoryStore
    private let identifier: IdentifierMapping
    private let coordinator = FetchCoordinator()

    /// Creates a provider over a started or not yet started client.
    ///
    /// - Parameters:
    ///   - client: The host's `AssetClient`, or any other `ModelAssetClient`.
    ///   - directory: Where the model directories are created. `nil` means
    ///     `Library/Caches/ZTronSearchEngineAssetKit/Models`. It must not lie inside
    ///     ZTronAssetKit's store, which deletes names it does not know.
    ///   - identifier: The mapping from a file to its catalog asset.
    ///   - diagnostics: Receives what `ModelAssetError` cannot say. Called from any thread.
    public init(
        client: any ModelAssetClient,
        directory: URL? = nil,
        identifier: @escaping IdentifierMapping = AssetKitModelAssetProvider.defaultIdentifier,
        diagnostics: (@Sendable (AssetKitBridgeDiagnostic) -> Void)? = nil
    ) {
        self.store = ModelAssetStore(client: client, diagnostics: DiagnosticReporter(sink: diagnostics))
        self.directories = ModelDirectoryStore(root: directory ?? ModelDirectoryStore.defaultRoot)
        self.identifier = identifier
    }

    /// The default mapping: `model/<asset id>@<revision>/<file name>`, for example
    /// `model/qwen3-1.7b-4bit@3b1b176/config.json`.
    ///
    /// Every asset of one revision shares the prefix `model/<asset id>@<revision>/`, and every
    /// model the prefix `model/`, which a host can pass to `AssetScope.prefix`.
    public static func defaultIdentifier(asset: ModelAsset, file: ModelFile) -> AssetID {
        AssetID("model/\(asset.id)@\(asset.revision)/\(file.name)")
    }

    /// The lane a fetch under `policy` asks ZTronAssetKit for, given the client's network policy,
    /// or `nil` when the policy cannot download with that client.
    ///
    /// - `.never`: always `nil`.
    /// - `.wifiOnly`: the most urgent lane that `network` keeps off expensive networks:
    ///   `.userInitiated` when `userInitiatedOverridesPolicy` and `prefetchOnExpensive` are both
    ///   `false`, else `.prefetch` when `prefetchOnExpensive` is `false`, else `.bulk` when
    ///   `bulkOnExpensive` is `false`, else `nil`. `NetworkPolicy()` gives `nil`.
    /// - `.allowCellular`: `.userInitiated` when it may use expensive networks, else `.bulk` when
    ///   that lane may, else `.userInitiated`, which then downloads over inexpensive networks.
    ///
    /// The `.bulk` lane publishes no byte progress, so a fetch on it reports whole files only.
    public static func lane(for policy: DownloadPolicy, under network: NetworkPolicy) -> AssetPriority? {
        DownloadLane.lane(for: policy, network: network, power: PowerPolicy())?.priority
    }

    /// The catalog assets a model consists of, in file order, each once. Empty for a descriptor
    /// the provider cannot serve.
    public func identifiers(of asset: ModelAsset) -> [AssetID] {
        (try? ModelAssetPlan(asset: asset, identifier: identifier))?.identifiers ?? []
    }

    // MARK: - ModelAssetProviding

    /// Whether every file of `asset` is stored and verified.
    ///
    /// - `.available(directory)`: the store holds every file, each blob is named by the file's
    ///   SHA-256 and has its size on disk, the directory holds a link per file, and the assets
    ///   are pinned. A directory that is already right is not touched.
    /// - `.downloading`: something is missing and a fetch of this provider is running.
    /// - `.missing`: something is missing or holds other bytes, and nothing is running. A
    ///   directory left from before is removed once one of its links is broken on disk.
    /// - `.failed(.checksum)`: the descriptor is unusable, or a fetch of this provider found that
    ///   the catalog holds other bytes than the descriptor names.
    /// - `.failed(.offline)` or `.failed(.diskFull)`: the client could not be started.
    ///
    /// Reads the client's snapshot and never downloads. The snapshot can trail a download that
    /// finished on the prefetch or bulk lane by about 0.2 s
    /// (`README.md:131-134` of ZTronAssetKit); the last element of `fetch` is exact.
    public func availability(of asset: ModelAsset) async -> ModelAssetAvailability {
        guard let plan = plan(for: asset) else {
            return .failed(.checksum)
        }
        if await coordinator.isRejected(asset) {
            return .failed(.checksum)
        }
        do {
            try await store.client.start()
        } catch {
            guard let reported = ModelAssetError(error) else {
                // The caller's task was cancelled: nothing was learned.
                return .missing
            }
            store.diagnostics.report(.clientFailed(.start, error, reportedAs: reported))
            return .failed(reported)
        }

        let inspection = await store.inspect(plan)
        if inspection.isComplete {
            do {
                let directory = try await directories.materialize(plan, blobs: inspection.verified)
                await store.pin(plan)
                return .available(directory)
            } catch {
                switch error {
                case .damagedBlobs(let names):
                    for entry in plan.entries where names.contains(entry.file.name) {
                        store.diagnostics.report(.damagedBlob(identifier: entry.identifier, fileName: entry.file.name))
                    }
                case .diskFull:
                    return .failed(.diskFull)
                case .failed(let message):
                    store.diagnostics.report(.directoryFailed(message))
                    return .failed(.diskFull)
                }
            }
        }
        if let progress = await coordinator.progress(of: asset) {
            return progress
        }
        await directories.removeIfBroken(plan)
        return .missing
    }

    /// Makes every file of `asset` available, downloading what is missing under `policy`.
    ///
    /// The stream yields `.downloading(bytes:of:)` with a byte count that never falls, then
    /// `.available(directory)`, and finishes. When nothing has to be downloaded it yields only
    /// `.available`. It fails with a `ModelAssetError`:
    ///
    /// - `.policy`: something is missing and `policy` is `.never`; or `policy` is `.wifiOnly` and
    ///   the client has no lane that stays off expensive networks; or the network in use (or Low
    ///   Power Mode) is refused for the lane, at the start or later.
    /// - `.checksum`: ZTronAssetKit rejected downloaded bytes, the catalog does not list a file,
    ///   or the catalog holds other bytes than the descriptor names. In the last case the stored
    ///   asset is deleted through `AssetClient.purge` first, and this provider does not fetch the
    ///   model again until `evict(_:)`.
    /// - `.offline`: no usable network, or the origin refused or failed.
    /// - `.diskFull`: no room, or the store cannot be used.
    ///
    /// A file that is stored and verified is never requested again. Fetches of one asset under
    /// one policy share their work, and the last element reaches each of their streams.
    /// Cancelling the task that reads a stream, or dropping the stream, detaches it; when no
    /// stream is left, every request made of ZTronAssetKit is withdrawn. ZTronAssetKit then
    /// discards the part of a file that was in transit, so a later fetch starts that file again;
    /// stored files are kept.
    ///
    /// A reader that falls more than 128 elements behind skips the oldest ones; the last element
    /// is never skipped.
    public func fetch(_ asset: ModelAsset, policy: DownloadPolicy) -> AsyncThrowingStream<ModelAssetAvailability, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ModelAssetAvailability.self,
            throwing: (any Error).self,
            bufferingPolicy: .bufferingNewest(128)
        )
        guard let plan = plan(for: asset) else {
            continuation.finish(throwing: ModelAssetError.checksum)
            return stream
        }
        let coordinator = self.coordinator
        let key = FetchCoordinator.Key(asset: asset, policy: policy)
        let operation = FetchOperation(plan: plan, policy: policy, store: store, directories: directories, coordinator: coordinator)
        let attachment = Task {
            await coordinator.attach(continuation, to: key) { report in
                await operation.run(report: report)
            }
        }
        // Ordered after the attachment, so a stream dropped at once still releases what it began.
        continuation.onTermination = { _ in
            Task {
                await coordinator.detach(await attachment.value, from: key)
            }
        }
        return stream
    }

    /// Stops every fetch of `asset`, removes its directory and its pins, and deletes its files
    /// from ZTronAssetKit's store. Afterwards `availability(of:)` answers `.missing`.
    ///
    /// The files are deleted with `AssetClient.purge(.scope(.identifiers(…)))`. A purge ends a
    /// catalog sync that is running and makes the next one due
    /// (`Sources/ZTronAssetSync/Engine/EngineCommands.swift:966-968` of ZTronAssetKit), and it
    /// returns once the store has unlinked the files, which the store does after its deletion
    /// grace: `evict` takes at least that long, 10 s by default. Content that another catalog
    /// asset also holds stays stored for that asset.
    ///
    /// - Throws: The `ModelAssetError` of a purge that failed, or `CancellationError` when the
    ///   caller was cancelled while the purge waited; the purge is committed all the same.
    public func evict(_ asset: ModelAsset) async throws {
        await coordinator.cancelFetches(of: asset)
        await coordinator.forgetRejection(of: asset)
        guard let plan = plan(for: asset) else {
            return
        }
        await directories.remove(plan)
        let identifiers = Set(plan.identifiers)
        guard !identifiers.isEmpty else {
            return
        }
        do {
            try await store.client.unpin(identifiers)
        } catch {
            store.diagnostics.report(.clientFailed(.unpin, error, reportedAs: nil))
        }
        if let error = await store.purge(identifiers) {
            guard let reported = ModelAssetError(error) else {
                throw CancellationError()
            }
            store.diagnostics.report(.clientFailed(.purge, error, reportedAs: reported))
            throw reported
        }
    }

    // MARK: - Private

    /// The checked descriptor, or `nil` after reporting why it cannot be served.
    private func plan(for asset: ModelAsset) -> ModelAssetPlan? {
        do {
            return try ModelAssetPlan(asset: asset, identifier: identifier)
        } catch {
            store.diagnostics.report(.invalidDescriptor(assetID: asset.id, revision: asset.revision, reason: error.reason))
            return nil
        }
    }
}
