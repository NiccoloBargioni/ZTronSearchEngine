import Foundation
import ZTronAssetKit
import ZTronSearchEngine
import os

/// What the bridge knows beyond the four cases of `ModelAssetError`.
///
/// `ModelAssetError` has to fold nine ZTronAssetKit errors and the bridge's own findings into
/// `.offline`, `.checksum`, `.diskFull` and `.policy`. Every time it does, and every time a step
/// that must not fail the caller goes wrong, the provider reports the cause here, so the host can
/// log it or show a more exact message.
public enum AssetKitBridgeDiagnostic: Sendable, Hashable {
    /// What the provider was doing when ZTronAssetKit failed.
    public enum Operation: String, Sendable, Hashable {
        /// Opening the store (`AssetClient.start`).
        case start
        /// Subscribing to the client's events.
        case subscribe
        /// Asking for one file (`AssetClient.resolve`).
        case resolve
        /// Pinning the files of a model.
        case pin
        /// Removing the pins of a model.
        case unpin
        /// Deleting stored files (`AssetClient.purge`).
        case purge
    }

    /// The descriptor cannot be served whatever is downloaded: a file without a usable SHA-256,
    /// an unsafe or repeated name, two different files mapped to one catalog asset, or a size
    /// that the stored blob of the file's own SHA-256 does not have. Reported as
    /// `ModelAssetError.checksum`.
    case invalidDescriptor(assetID: String, revision: String, reason: String)
    /// `DownloadPolicy.wifiOnly` was asked of a client whose `NetworkPolicy` lets every lane use
    /// expensive networks, so nothing could keep the download off cellular. The fetch failed with
    /// `ModelAssetError.policy` and downloaded nothing.
    case wifiOnlyNotEnforceable
    /// The network in use, or Low Power Mode, is refused for the lane of this fetch. The fetch
    /// failed with `ModelAssetError.policy`.
    case networkRefused(DownloadPolicy, DeviceConditions)
    /// A ZTronAssetKit call failed. `reportedAs` is the `ModelAssetError` the caller received, or
    /// `nil` when the call was not essential (a pin, a cleanup) and the caller was not failed.
    case clientFailed(Operation, AssetError, reportedAs: ModelAssetError?)
    /// The catalog's content of this asset is not the bytes the descriptor names: the store
    /// holds a blob of another SHA-256 for it. `storedSHA256` is `nil` when the stored file is
    /// not a content-addressed blob. The bridge deletes the stored asset through
    /// `AssetClient.purge` and fails the fetch with `ModelAssetError.checksum`.
    case contentMismatch(identifier: AssetID, fileName: String, expectedSHA256: String, storedSHA256: String?)
    /// The store lists the file as present, but its blob is missing on disk or has another size.
    case damagedBlob(identifier: AssetID, fileName: String)
    /// The directory of links could not be written.
    case directoryFailed(String)
}

extension AssetKitBridgeDiagnostic: CustomStringConvertible {
    /// One sentence for a log. It names catalog identifiers and file names, never a path.
    public var description: String {
        switch self {
        case .invalidDescriptor(let assetID, let revision, let reason):
            return "Model asset \(assetID)@\(revision) cannot be served: \(reason)."
        case .wifiOnlyNotEnforceable:
            return "DownloadPolicy.wifiOnly cannot be enforced: the client's NetworkPolicy lets every lane use expensive networks. Nothing was downloaded."
        case .networkRefused(let policy, let conditions):
            return "The fetch under \(policy) stopped: the network (expensive: \(conditions.network.expensive), constrained: \(conditions.network.constrained)) or Low Power Mode (\(conditions.power.lowPowerMode)) is refused for its lane."
        case .clientFailed(let operation, let error, let reportedAs):
            let outcome = reportedAs.map { "reported as .\($0)" } ?? "not reported to the caller"
            return "ZTronAssetKit failed during \(operation.rawValue): \(error); \(outcome)."
        case .contentMismatch(let identifier, let fileName, let expected, let stored):
            return "Asset '\(identifier.rawValue)' does not hold '\(fileName)': expected SHA-256 \(expected), stored \(stored ?? "no content-addressed blob")."
        case .damagedBlob(let identifier, let fileName):
            return "The blob of '\(fileName)' (asset '\(identifier.rawValue)') is missing on disk or has another size."
        case .directoryFailed(let message):
            return "The model directory could not be written: \(message)."
        }
    }
}

/// Sends diagnostics to the unified log and to the host's sink.
struct DiagnosticReporter: Sendable {
    private static let logger = Logger(subsystem: "com.ztron.searchengine.assetkit", category: "bridge")

    let sink: (@Sendable (AssetKitBridgeDiagnostic) -> Void)?

    func report(_ diagnostic: AssetKitBridgeDiagnostic) {
        // Identifiers and file names come from the host's own catalog and descriptor: no user data.
        Self.logger.notice("\(diagnostic.description, privacy: .public)")
        sink?(diagnostic)
    }
}

extension ModelAssetError {
    /// The boundary error a ZTronAssetKit error is reported as, or `nil` for a cancellation, which
    /// is not a failure.
    ///
    /// | `AssetError` | `ModelAssetError` | Why |
    /// |---|---|---|
    /// | `.offline`, `.serverUnavailable`, `.authRejected`, `.shutDown` | `.offline` | The bytes cannot be had from the origin now. |
    /// | `.integrityFailure`, `.notFound` | `.checksum` | The origin does not hold the bytes the descriptor names. |
    /// | `.insufficientSpace`, `.storageUnavailable` | `.diskFull` | The device's store cannot take or serve the bytes. |
    /// | `.cancelled` | none | The caller withdrew. |
    ///
    /// `.policy` never comes from an `AssetError`: ZTronAssetKit parks work its policy refuses
    /// instead of failing it, so the bridge derives `.policy` from the device conditions.
    init?(_ error: AssetError) {
        switch error {
        case .offline, .serverUnavailable, .authRejected, .shutDown:
            self = .offline
        case .integrityFailure, .notFound:
            self = .checksum
        case .insufficientSpace, .storageUnavailable:
            self = .diskFull
        case .cancelled:
            return nil
        }
    }
}
