import Foundation
import ZTronAssetKit

/// The part of ZTronAssetKit's `AssetClient` the bridge talks to.
///
/// `AssetClient` conforms in this package, so a host passes its client as is. Tests pass a
/// scripted conformer and run without a network or a store.
public protocol ModelAssetClient: Sendable {
    /// Which lanes may use which networks. Fixed for the client's lifetime.
    var networkPolicy: NetworkPolicy { get }
    /// Which lanes may run in Low Power Mode. Fixed for the client's lifetime.
    var powerPolicy: PowerPolicy { get }

    /// Opens the store and installs the first snapshot. Idempotent.
    func start() async throws(AssetError)

    /// The stored location of each identifier the client's current snapshot holds. Never
    /// downloads and does no file-system work.
    func locations(of identifiers: [AssetID]) async -> [AssetID: AssetLocation]

    /// The URL of the asset's blob, downloading it at `priority` when it is not stored. The
    /// caller's cancellation withdraws only this caller's interest.
    func resolve(_ identifier: AssetID, priority: AssetPriority) async throws(AssetError) -> URL

    /// An event stream that is registered before it is returned and replays the current device
    /// conditions.
    func subscribe() async throws(AssetError) -> AsyncStream<AssetEvent>

    /// Keeps the assets away from quota eviction. Persisted by the store.
    func pin(_ identifiers: Set<AssetID>) async throws(AssetError)

    /// Removes pins.
    func unpin(_ identifiers: Set<AssetID>) async throws(AssetError)

    /// Deletes stored assets.
    func purge(_ request: PurgeRequest) async throws(AssetError) -> PurgeResult
}

extension AssetClient: ModelAssetClient {
    /// `configuration.network`.
    public var networkPolicy: NetworkPolicy {
        configuration.network
    }

    /// `configuration.power`.
    public var powerPolicy: PowerPolicy {
        configuration.power
    }

    /// Reads the main-actor snapshot mirror once for every identifier (`AssetClient.lookup`).
    public func locations(of identifiers: [AssetID]) async -> [AssetID: AssetLocation] {
        await MainActor.run {
            var found: [AssetID: AssetLocation] = [:]
            for identifier in identifiers {
                if let location = self.lookup(identifier) {
                    found[identifier] = location
                }
            }
            return found
        }
    }
}
