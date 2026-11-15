import Foundation
import ZTronSearchEngine

/// A deterministic `Reranking` for tests (specification section 7.4).
///
/// By default a passage scores the share of the query it covers, counted in lexicon concepts:
/// a passage that mentions every concept of the query scores 1, whatever language either is
/// written in. Tests can script the scores instead, delay the answer, make it throw, set the
/// calibration verdict and read how often each entry point was called.
public actor FakeReranker: Reranking {
    /// Identity of the fake model.
    public nonisolated let modelID: String

    private var verdict: Bool
    private var delay: UInt64 = 0
    private var shouldThrow = false
    private var scriptedScores: [Float]?
    private var scoring: (@Sendable (String, [String]) -> [Float])?

    /// Calls to ``scores(query:passages:)``, counted when the call starts.
    public private(set) var scoresCallCount = 0
    /// Calls to ``isEnabled()``.
    public private(set) var isEnabledCallCount = 0
    /// Calls to ``invalidateCalibration()``.
    public private(set) var invalidateCalibrationCallCount = 0
    /// Calls to ``unload()``.
    public private(set) var unloadCallCount = 0
    /// The query of the latest ``scores(query:passages:)`` call.
    public private(set) var lastQuery: String?
    /// The passages of the latest ``scores(query:passages:)`` call.
    public private(set) var lastPassages: [String] = []

    /// Creates a reranker whose calibration verdict is `isEnabled`.
    public init(modelID: String = "fake-lexicon-reranker-v1", isEnabled: Bool = true) {
        self.modelID = modelID
        self.verdict = isEnabled
    }

    // MARK: Test hooks

    /// Sets the calibration verdict ``isEnabled()`` reports.
    public func setEnabled(_ flag: Bool) {
        verdict = flag
    }

    /// Makes every later ``scores(query:passages:)`` wait this long before it answers. The wait
    /// is cancellable: a cancelled call throws `CancellationError`.
    public func setDelay(nanoseconds: UInt64) {
        delay = nanoseconds
    }

    /// Makes ``scores(query:passages:)`` throw ``FakeSemanticError/scripted`` until switched off.
    public func setShouldThrow(_ flag: Bool) {
        shouldThrow = flag
    }

    /// Scripts the scores: they are returned as they are, whatever the passages. A list whose
    /// length differs from the number of passages is how a test provokes a malformed answer.
    /// `nil` goes back to the default scoring.
    public func setScriptedScores(_ scores: [Float]?) {
        scriptedScores = scores
    }

    /// Replaces the default scoring with a function of the query and the passages. `nil` goes
    /// back to the default. Scripted scores, when set, win over it.
    public func setScoring(_ scoring: (@Sendable (String, [String]) -> [Float])?) {
        self.scoring = scoring
    }

    /// Sets every counter back to zero and forgets the recorded call.
    public func resetCounters() {
        scoresCallCount = 0
        isEnabledCallCount = 0
        invalidateCalibrationCallCount = 0
        unloadCallCount = 0
        lastQuery = nil
        lastPassages = []
    }

    // MARK: Reranking

    /// The calibration verdict: the one given at creation or set with ``setEnabled(_:)``.
    public func isEnabled() async -> Bool {
        isEnabledCallCount += 1
        return verdict
    }

    /// One score per passage, higher for more relevant: the scripted scores, else the scoring
    /// function, else ``overlapScores(query:passages:)``. Waits for the delay first, and throws
    /// when asked to.
    public func scores(query: String, passages: [String]) async throws -> [Float] {
        scoresCallCount += 1
        lastQuery = query
        lastPassages = passages
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if shouldThrow { throw FakeSemanticError.scripted }
        if let scriptedScores { return scriptedScores }
        if let scoring { return scoring(query, passages) }
        return Self.overlapScores(query: query, passages: passages)
    }

    /// Counts the call. The verdict itself is left as it is: a test decides what a new
    /// calibration would say with ``setEnabled(_:)``.
    public func invalidateCalibration() async {
        invalidateCalibrationCallCount += 1
    }

    /// Counts the call. There is no model to release.
    public func unload() async {
        unloadCallCount += 1
    }

    // MARK: Default scoring

    /// The default scores: for each passage, the share of the query's distinct units it also
    /// contains, in `0...1`. A unit is a lexicon concept, or a folded word the lexicon does not
    /// know. A query without any unit scores every passage 0.
    public static func overlapScores(query: String, passages: [String]) -> [Float] {
        let wanted = units(of: query)
        guard !wanted.isEmpty else { return [Float](repeating: 0, count: passages.count) }
        return passages.map { passage in
            Float(wanted.intersection(units(of: passage)).count) / Float(wanted.count)
        }
    }

    private enum Unit: Hashable {
        case concept(Int)
        case word(String)
    }

    private static func units(of text: String) -> Set<Unit> {
        var units = Set<Unit>()
        let index = FixtureLexicon.index
        FixtureText.scan(text) { piece in
            switch piece {
            case .latin(let bytes):
                if let id = index.table.lookup(bytes) {
                    units.insert(.concept(id))
                } else {
                    units.insert(.word(String(decoding: bytes, as: UTF8.self)))
                }
            case .japanese(let scalars):
                index.matchJapanese(scalars, onConcept: { units.insert(.concept($0)) }, onUnknown: { run in
                    var view = String.UnicodeScalarView()
                    for value in run {
                        if let scalar = Unicode.Scalar(value) { view.append(scalar) }
                    }
                    units.insert(.word(String(view)))
                })
            }
        }
        return units
    }
}
