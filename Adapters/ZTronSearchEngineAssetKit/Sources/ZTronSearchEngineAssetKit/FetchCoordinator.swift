import Foundation
import ZTronSearchEngine

/// How the work of one fetch ended.
enum FetchOutcome: Sendable, Hashable {
    /// Every file is stored, verified and linked in this directory.
    case available(URL)
    case failed(ModelAssetError)
    /// The work was stopped before it could end: its last consumer left, the asset was evicted,
    /// or ZTronAssetKit cancelled the request.
    case cancelled
}

/// Shares one running fetch among every stream that asks for the same asset under the same
/// policy, and stops the work when the last of those streams is gone.
///
/// Fetches of one asset under different policies are separate sessions: each asks ZTronAssetKit
/// on its own lane and judges the network by its own policy. They still share every transfer,
/// because ZTronAssetKit runs one transfer per content however many callers wait
/// (`README.md:138-139` of ZTronAssetKit).
actor FetchCoordinator {
    typealias Continuation = AsyncThrowingStream<ModelAssetAvailability, any Error>.Continuation
    /// Reports the bytes stored so far and the total.
    typealias Report = @Sendable (_ bytes: Int64, _ total: Int64) async -> Void
    typealias Work = @Sendable (_ report: @escaping Report) async -> FetchOutcome

    struct Key: Hashable, Sendable {
        let asset: ModelAsset
        let policy: DownloadPolicy
    }

    private struct Session {
        /// Tells this session from an earlier one of the same key whose task is still unwinding.
        let id: UInt64
        var task: Task<Void, Never>?
        var consumers: [UInt64: Continuation] = [:]
        /// The last `.downloading` value, replayed to a stream that attaches later.
        var progress: ModelAssetAvailability?
    }

    private var sessions: [Key: Session] = [:]
    /// Assets whose stored bytes contradicted their descriptor: not fetched again by this
    /// provider until they are evicted.
    private var rejected: Set<ModelAsset> = []
    private var lastToken: UInt64 = 0

    // MARK: - Streams

    /// Adds a stream to the session of `key`, starting `work` when no session runs. Returns the
    /// token `detach` takes.
    func attach(_ continuation: Continuation, to key: Key, work: @escaping Work) -> UInt64 {
        lastToken += 1
        let consumer = lastToken
        if sessions[key] != nil {
            if let progress = sessions[key]?.progress {
                continuation.yield(progress)
            }
            sessions[key]?.consumers[consumer] = continuation
            return consumer
        }
        lastToken += 1
        let id = lastToken
        var session = Session(id: id)
        session.consumers[consumer] = continuation
        // The task starts on this actor, so it cannot report before the session is in the table.
        session.task = Task {
            let outcome = await work { bytes, total in
                await self.publish(.downloading(bytes: bytes, of: total), for: key, session: id)
            }
            self.finish(key, session: id, outcome: outcome)
        }
        sessions[key] = session
        return consumer
    }

    /// Removes a stream. The session of its key is cancelled when no stream is left, which
    /// withdraws every request the work made of ZTronAssetKit.
    func detach(_ consumer: UInt64, from key: Key) {
        guard sessions[key]?.consumers.removeValue(forKey: consumer) != nil else {
            return
        }
        if sessions[key]?.consumers.isEmpty == true {
            sessions.removeValue(forKey: key)?.task?.cancel()
        }
    }

    /// The progress of the fetches of `asset` that are running now, whatever their policy: the
    /// largest byte count any of them reported.
    func progress(of asset: ModelAsset) -> ModelAssetAvailability? {
        var best: (bytes: Int64, value: ModelAssetAvailability)?
        for (key, session) in sessions where key.asset == asset {
            guard let progress = session.progress, case .downloading(let bytes, _) = progress else {
                continue
            }
            if best.map({ bytes > $0.bytes }) ?? true {
                best = (bytes, progress)
            }
        }
        return best?.value
    }

    /// Stops every fetch of `asset`. Their streams end by throwing `CancellationError`.
    func cancelFetches(of asset: ModelAsset) {
        for key in sessions.keys.filter({ $0.asset == asset }) {
            guard let session = sessions.removeValue(forKey: key) else {
                continue
            }
            session.task?.cancel()
            for continuation in session.consumers.values {
                continuation.finish(throwing: CancellationError())
            }
        }
    }

    // MARK: - Rejected assets

    func reject(_ asset: ModelAsset) {
        rejected.insert(asset)
    }

    func isRejected(_ asset: ModelAsset) -> Bool {
        rejected.contains(asset)
    }

    func forgetRejection(of asset: ModelAsset) {
        rejected.remove(asset)
    }

    // MARK: - Session results

    private func publish(_ progress: ModelAssetAvailability, for key: Key, session id: UInt64) {
        guard sessions[key]?.id == id else {
            return
        }
        sessions[key]?.progress = progress
        guard let consumers = sessions[key]?.consumers else {
            return
        }
        for continuation in consumers.values {
            continuation.yield(progress)
        }
    }

    private func finish(_ key: Key, session id: UInt64, outcome: FetchOutcome) {
        guard sessions[key]?.id == id, let session = sessions.removeValue(forKey: key) else {
            return
        }
        for continuation in session.consumers.values {
            switch outcome {
            case .available(let directory):
                continuation.yield(.available(directory))
                continuation.finish()
            case .failed(let error):
                continuation.finish(throwing: error)
            case .cancelled:
                continuation.finish(throwing: CancellationError())
            }
        }
    }
}
