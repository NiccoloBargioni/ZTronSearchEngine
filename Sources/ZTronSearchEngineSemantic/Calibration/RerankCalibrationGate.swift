import Foundation
import ZTronSearchEngine

/// The outcome of a calibration pass, as it is persisted.
public struct RerankCalibrationVerdict: Sendable, Hashable, Codable {
    /// Why the stage is enabled or not.
    public enum Reason: String, Sendable, Hashable, Codable {
        /// Every threshold was met.
        case withinBudget
        /// The device has less memory than the stage needs; the model was never loaded.
        case insufficientMemory
        /// The model ran, too slowly.
        case tooSlow
    }

    /// Whether the stage runs on this device.
    public var isEnabled: Bool
    /// Why.
    public var reason: Reason
    /// The model the verdict is about.
    public var modelID: String
    /// The app and OS version the verdict was reached under.
    public var fingerprint: String
    /// The 95th percentile of the time one pair took, in seconds; `nil` when the model never ran.
    public var p95PerPair: TimeInterval?
    /// Physical memory of the device, in bytes.
    public var physicalMemory: UInt64
    /// When the verdict was reached.
    public var measuredAt: Date

    /// Creates a verdict.
    public init(
        isEnabled: Bool,
        reason: Reason,
        modelID: String,
        fingerprint: String,
        p95PerPair: TimeInterval?,
        physicalMemory: UInt64,
        measuredAt: Date
    ) {
        self.isEnabled = isEnabled
        self.reason = reason
        self.modelID = modelID
        self.fingerprint = fingerprint
        self.p95PerPair = p95PerPair
        self.physicalMemory = physicalMemory
        self.measuredAt = measuredAt
    }
}

/// The capability gate of the cross-encoder stage (specification section 7.4).
///
/// Whether a device can afford the stage is measured, never read off a chip name. On first use
/// the gate reranks 16 synthetic pairs with the production model and enables the stage only
/// when
///
/// - the 95th percentile of the time per pair is 15 ms or less,
/// - the device has at least 3 GB of memory, and
/// - no memory warning arrived in the last 10 minutes.
///
/// The verdict is persisted and reused, so the model is never loaded just to decide again; it
/// is measured anew after an app or OS update, because it is stored with a fingerprint of both.
///
/// What is persisted, and what is not:
///
/// - Too little memory is a fact about the device. It is decided before the model is loaded,
///   so a 2 GB device never loads the cross-encoder, and it is persisted.
/// - A measurement, fast or slow, is persisted.
/// - A recent memory warning is a passing condition. The stage stays off, nothing is measured
///   and nothing is persisted: persisting it would switch the stage off on a capable device
///   until its next update. The next call decides again.
/// - A model that fails to load or run keeps the stage off for the launch and is not persisted.
///
/// The memory threshold is compared with the device's memory rounded to whole gigabytes: a
/// 3 GB iPhone reports about 2.8 GB to `ProcessInfo`, and it is a 3 GB device.
public actor RerankCalibrationGate {
    /// The thresholds of the gate; the defaults are the specification's.
    public struct Thresholds: Sendable, Hashable {
        /// Synthetic pairs the calibration pass reranks.
        public var pairCount: Int
        /// The most the 95th percentile of the time per pair may be, in seconds.
        public var maximumP95PerPair: TimeInterval
        /// The least memory the device must have, in whole gigabytes.
        public var minimumMemoryGigabytes: Int
        /// How long ago the last memory warning must be, in seconds.
        public var memoryWarningQuietPeriod: TimeInterval

        /// Creates thresholds; at least one pair is measured.
        public init(
            pairCount: Int = 16,
            maximumP95PerPair: TimeInterval = 0.015,
            minimumMemoryGigabytes: Int = 3,
            memoryWarningQuietPeriod: TimeInterval = 600
        ) {
            self.pairCount = max(1, pairCount)
            self.maximumP95PerPair = maximumP95PerPair
            self.minimumMemoryGigabytes = minimumMemoryGigabytes
            self.memoryWarningQuietPeriod = memoryWarningQuietPeriod
        }

        /// The specification's thresholds: 16 pairs, 15 ms, 3 GB, 10 minutes.
        public static let `default` = Thresholds()
    }

    /// The model the gate decides about; the verdict is stored under it.
    public nonisolated let modelID: String
    /// The thresholds the gate decides with.
    public nonisolated let thresholds: Thresholds

    private let store: any CalibrationVerdictStore
    private let environment: any CalibrationEnvironment
    /// The answer for the rest of this launch, once there is one.
    private var decided: Bool?
    private var isInvalidated = false
    /// The decision in progress, shared by every caller that arrives while it runs.
    private var pending: Task<Bool, Never>?

    /// Creates a gate.
    ///
    /// - Parameters:
    ///   - modelID: The model the verdict is about; verdicts are stored per model.
    ///   - store: Where the verdict is kept between launches. `UserDefaults` by default.
    ///   - environment: Clock, memory, memory warnings and versions. The real device by default;
    ///     its memory-warning monitor starts observing now, so create the gate at launch.
    ///   - thresholds: What the device must meet.
    public init(
        modelID: String,
        store: any CalibrationVerdictStore = UserDefaultsVerdictStore(),
        environment: any CalibrationEnvironment = LiveCalibrationEnvironment(),
        thresholds: Thresholds = .default
    ) {
        self.modelID = modelID
        self.store = store
        self.environment = environment
        self.thresholds = thresholds
    }

    /// The key the verdict of `modelID` is stored under.
    public nonisolated var storageKey: String {
        "com.ztron.searchengine.rerank-calibration." + modelID
    }

    /// Whether the stage runs on this device: the stored verdict when there is one for this app
    /// and OS version, else the result of a calibration pass over `reranker`.
    ///
    /// Callers that arrive while a pass is running share its result; the model is measured once.
    public func isEnabled(calibrating reranker: any Reranking) async -> Bool {
        if let decided { return decided }
        if let pending { return await pending.value }
        let task = Task { await self.decide(calibrating: reranker) }
        pending = task
        let enabled = await task.value
        pending = nil
        return enabled
    }

    /// Discards the verdict: the stage is off for the rest of this launch and the next launch
    /// measures again. Core calls this after three consecutive breaches of the rerank cap.
    public func invalidate() async {
        isInvalidated = true
        decided = false
        await store.setVerdictData(nil, forKey: storageKey)
    }

    /// The verdict that is persisted for this model, whatever fingerprint it carries.
    public func storedVerdict() async -> RerankCalibrationVerdict? {
        guard let data = await store.verdictData(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(RerankCalibrationVerdict.self, from: data)
    }

    // MARK: Decision

    private func decide(calibrating reranker: any Reranking) async -> Bool {
        if let decided { return decided }
        let fingerprint = await environment.fingerprint()

        // A verdict reached under this app and OS version stands: the model is not touched.
        if let stored = await storedVerdict(), stored.fingerprint == fingerprint, stored.modelID == modelID {
            return settle(stored.isEnabled)
        }

        // Memory is a fact about the device, decided before the model is loaded.
        let memory = await environment.physicalMemory()
        guard Self.wholeGigabytes(memory) >= thresholds.minimumMemoryGigabytes else {
            await persist(RerankCalibrationVerdict(
                isEnabled: false, reason: .insufficientMemory, modelID: modelID, fingerprint: fingerprint,
                p95PerPair: nil, physicalMemory: memory, measuredAt: await environment.now()
            ))
            return settle(false)
        }

        // A recent memory warning: off for now, nothing measured, nothing persisted.
        let started = await environment.now()
        if let warning = await environment.lastMemoryWarning(),
           started.timeIntervalSince(warning) < thresholds.memoryWarningQuietPeriod {
            return false
        }

        let samples: [TimeInterval]
        do {
            samples = try await measure(reranker)
        } catch {
            await reranker.unload()
            return settle(false)
        }
        // A warning during the pass voids it: the device was under pressure while it was timed.
        if let warning = await environment.lastMemoryWarning(), warning >= started {
            await reranker.unload()
            return false
        }

        let p95 = Self.percentile(samples, 0.95)
        let enabled = p95 <= thresholds.maximumP95PerPair
        if !enabled {
            // The model was loaded only to be measured, and will not be used.
            await reranker.unload()
        }
        guard !isInvalidated else { return false }
        await persist(RerankCalibrationVerdict(
            isEnabled: enabled, reason: enabled ? .withinBudget : .tooSlow, modelID: modelID, fingerprint: fingerprint,
            p95PerPair: p95, physicalMemory: memory, measuredAt: await environment.now()
        ))
        return settle(enabled)
    }

    private func settle(_ enabled: Bool) -> Bool {
        if isInvalidated { return false }
        decided = enabled
        return enabled
    }

    /// Times the production model on synthetic pairs, one pair per call.
    ///
    /// The first call loads the model and lets Core ML specialize it for its processors; it is
    /// not timed. Timing single pairs gives one sample per pair, which is what a percentile
    /// needs, and errs on the cautious side: a batched call shares its fixed cost among the
    /// pairs, a single call carries all of it.
    private func measure(_ reranker: any Reranking) async throws -> [TimeInterval] {
        let pairs = Self.syntheticPairs(count: thresholds.pairCount)
        _ = try await reranker.scores(query: pairs[0].query, passages: [pairs[0].passage])
        var samples: [TimeInterval] = []
        samples.reserveCapacity(pairs.count)
        for pair in pairs {
            let start = await environment.uptimeNanoseconds()
            let scores = try await reranker.scores(query: pair.query, passages: [pair.passage])
            let end = await environment.uptimeNanoseconds()
            guard scores.count == 1 else {
                throw SemanticError.unexpectedModelOutput("\(scores.count) scores for one pair")
            }
            samples.append(Double(end >= start ? end - start : 0) / 1_000_000_000)
        }
        return samples
    }

    private func persist(_ verdict: RerankCalibrationVerdict) async {
        guard let data = try? JSONEncoder().encode(verdict) else { return }
        await store.setVerdictData(data, forKey: storageKey)
    }

    // MARK: Arithmetic

    /// Memory in whole gigabytes, rounded to the nearest: what the device is sold as.
    public static func wholeGigabytes(_ bytes: UInt64) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    /// The `fraction` quantile of `samples` by the nearest-rank method: the smallest sample
    /// that at least that share of the samples does not exceed. With 16 samples the 95th
    /// percentile is the slowest one, the cautious reading for a gate.
    public static func percentile(_ samples: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !samples.isEmpty else { return .infinity }
        let sorted = samples.sorted()
        let rank = Int((min(max(fraction, 0), 1) * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    /// Deterministic (query, passage) pairs in several languages and scripts, the passages
    /// long enough to fill the 128-token window.
    public static func syntheticPairs(count: Int) -> [(query: String, passage: String)] {
        let queries = [
            "offline maps of the old town", "consigli per la batteria", "Werkzeug zum Messen von Entfernungen",
            "jeux de cartes à deux", "как сбросить настройки", "地図をダウンロードする方法", "أفضل نصائح التصوير", "tip for faster search",
        ]
        let sentences = [
            "The map shows every street of the old town and can be downloaded for offline use.",
            "Questo consiglio spiega come prolungare la durata della batteria durante i viaggi lunghi.",
            "Mit diesem Werkzeug lassen sich Entfernungen und Flächen direkt auf der Karte messen.",
            "Ce jeu de cartes se joue à deux et une partie dure environ vingt minutes.",
            "Чтобы сбросить настройки, откройте меню и выберите пункт восстановления.",
            "地図は事前にダウンロードしておくと、電波の届かない場所でも利用できます。",
            "تعرض هذه الصورة غروب الشمس فوق البحر مع قارب صغير في المقدمة.",
            "Search works without a connection because the index ships with the app.",
        ]
        return (0..<max(0, count)).map { index in
            let passage = (0..<6).map { sentences[(index + $0 * 3) % sentences.count] }.joined(separator: " ")
            return (query: queries[index % queries.count], passage: passage)
        }
    }
}
