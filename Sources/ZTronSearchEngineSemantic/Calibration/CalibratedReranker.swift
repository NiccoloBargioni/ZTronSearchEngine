import Foundation
import ZTronSearchEngine

/// A reranker behind the calibration gate: what the host injects into core.
///
/// Under ``RerankingMode/auto`` core asks ``isEnabled()`` on first use. The wrapper answers
/// with the gate's verdict, which runs the one-time calibration pass over the wrapped model
/// when no verdict is stored for this app and OS version (specification section 7.4). Scoring
/// and unloading go straight to the wrapped model.
public struct CalibratedReranker: Reranking {
    /// The production model.
    public let base: any Reranking
    /// The gate that holds the verdict for `base`.
    public let gate: RerankCalibrationGate

    /// The id of the wrapped model.
    public var modelID: String { base.modelID }

    /// Wraps `base` behind an existing gate.
    public init(_ base: any Reranking, gate: RerankCalibrationGate) {
        self.base = base
        self.gate = gate
    }

    /// Wraps `base` behind a gate of its own, keyed by the model's id.
    public init(
        _ base: any Reranking,
        store: any CalibrationVerdictStore = UserDefaultsVerdictStore(),
        environment: any CalibrationEnvironment = LiveCalibrationEnvironment(),
        thresholds: RerankCalibrationGate.Thresholds = .default
    ) {
        self.init(base, gate: RerankCalibrationGate(modelID: base.modelID, store: store, environment: environment, thresholds: thresholds))
    }

    /// The persisted calibration verdict, measured on first use.
    public func isEnabled() async -> Bool {
        await gate.isEnabled(calibrating: base)
    }

    /// Scores every (query, passage) pair with the wrapped model, in one batched call.
    public func scores(query: String, passages: [String]) async throws -> [Float] {
        try await base.scores(query: query, passages: passages)
    }

    /// Discards the verdict: the stage is off for this launch and measured again at the next.
    public func invalidateCalibration() async {
        await gate.invalidate()
    }

    /// Releases the wrapped model.
    public func unload() async {
        await base.unload()
    }
}

extension CoreMLCrossEncoder {
    /// This model behind the calibration gate, ready to be injected into core.
    public nonisolated func calibrated(
        store: any CalibrationVerdictStore = UserDefaultsVerdictStore(),
        environment: any CalibrationEnvironment = LiveCalibrationEnvironment(),
        thresholds: RerankCalibrationGate.Thresholds = .default
    ) -> CalibratedReranker {
        CalibratedReranker(self, store: store, environment: environment, thresholds: thresholds)
    }
}
