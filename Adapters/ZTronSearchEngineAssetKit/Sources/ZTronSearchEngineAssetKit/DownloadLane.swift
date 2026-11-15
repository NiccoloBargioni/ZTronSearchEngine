import Foundation
import ZTronAssetKit
import ZTronSearchEngine

/// The engine lane a download policy runs on, with what that lane may use.
///
/// ZTronAssetKit has no network permission per request. Its engine derives the permissions of
/// every request from the request's lane and the client-wide `NetworkPolicy`
/// (`Sources/ZTronAssetSync/Engine/EngineDispatch.swift:559-569`, `SyncEngine.access(for:)`), and
/// its transport sets them on the `URLRequest` as `allowsCellularAccess`,
/// `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess`
/// (`Sources/ZTronAssetTransport/Policy/RequestFactory.swift:26-28`), so the operating system
/// enforces them. A download policy is therefore implemented by choosing a lane, and
/// `.wifiOnly` exists only when the host's `NetworkPolicy` leaves a lane that refuses expensive
/// networks.
///
/// The three stored permissions repeat the engine's own rule for the lane. The integration tests
/// read `TransferRequest.access` of a real `AssetClient` and fail if the two ever disagree.
struct DownloadLane: Sendable, Hashable {
    /// The lane every `resolve` of the fetch asks for.
    let priority: AssetPriority
    /// Whether requests on this lane may use cellular and other expensive networks.
    let allowsExpensive: Bool
    /// Whether requests on this lane may run in Low Data Mode.
    let allowsConstrained: Bool
    /// Whether the engine starts work of this lane in Low Power Mode.
    let allowsLowPowerMode: Bool

    /// The permissions the engine gives `priority` under `network` and `power`.
    init(priority: AssetPriority, network: NetworkPolicy, power: PowerPolicy) {
        self.priority = priority
        switch priority {
        case .userInitiated:
            // Explicit requests ignore the network rules when the override is on; without it they
            // follow the prefetch lane's network rules. Power never pauses them.
            allowsExpensive = network.userInitiatedOverridesPolicy || network.prefetchOnExpensive
            allowsConstrained = network.userInitiatedOverridesPolicy || network.prefetchOnConstrained
            allowsLowPowerMode = true
        case .prefetch:
            allowsExpensive = network.prefetchOnExpensive
            allowsConstrained = network.prefetchOnConstrained
            allowsLowPowerMode = power.prefetchInLowPowerMode
        case .bulk:
            allowsExpensive = network.bulkOnExpensive
            allowsConstrained = network.bulkOnConstrained
            allowsLowPowerMode = power.bulkInLowPowerMode
        }
    }

    /// The lane `policy` downloads on, or `nil` when it must not download with this client.
    ///
    /// - `.never`: `nil`.
    /// - `.wifiOnly`: the most urgent lane that refuses expensive networks, in the order
    ///   user-initiated, prefetch, bulk. `nil` when every lane may use them, which is the case
    ///   under `NetworkPolicy()`'s defaults.
    /// - `.allowCellular`: the most urgent lane that may use expensive networks. When the host
    ///   forbids them on every lane, the user-initiated lane, which then downloads over
    ///   inexpensive networks only.
    static func lane(for policy: DownloadPolicy, network: NetworkPolicy, power: PowerPolicy) -> DownloadLane? {
        let lanes = [AssetPriority.userInitiated, .prefetch, .bulk].map {
            DownloadLane(priority: $0, network: network, power: power)
        }
        switch policy {
        case .never:
            return nil
        case .wifiOnly:
            return lanes.first { !$0.allowsExpensive }
        case .allowCellular:
            return lanes.first { $0.allowsExpensive } ?? lanes[0]
        }
    }

    /// Whether the engine keeps this lane's work parked under `conditions`, because the network
    /// in use or Low Power Mode is refused
    /// (`Sources/ZTronAssetSync/Engine/EngineSupport.swift:220-300`, `LaneAdmission`). The engine
    /// answers no waiter while a lane is parked by policy, so a fetch fails with `.policy` here
    /// instead of waiting for a change that may never come.
    ///
    /// An unsatisfied path is not a refusal: the engine answers it with `AssetError.offline`. A
    /// thermal pause is not one either: it ends by itself, and the engine resumes the transfer.
    func isRefused(under conditions: DeviceConditions) -> Bool {
        guard conditions.network.satisfied else {
            return false
        }
        if conditions.network.expensive, !allowsExpensive {
            return true
        }
        if conditions.network.constrained, !allowsConstrained {
            return true
        }
        return conditions.power.lowPowerMode && !allowsLowPowerMode
    }
}
