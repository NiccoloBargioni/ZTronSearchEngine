import Foundation

/// Whether the two fields are in the same state at a checkpoint: a precondition of every other
/// comparison there, and a finding of its own when it fails.
public struct StateComparison: Codable, Sendable {
    public var differences: [String]
    public var passes: Bool

    static func compare(reference: FieldCapture, clone: FieldCapture) -> StateComparison {
        var differences: [String] = []
        if reference.text != clone.text {
            differences.append("text: reference \(ParityEvent.quoted(reference.text)), clone \(ParityEvent.quoted(clone.text))")
        }
        if reference.tokens != clone.tokens { differences.append("tokens: reference \(reference.tokens), clone \(clone.tokens)") }
        if reference.selectedTokens != clone.selectedTokens {
            differences.append("selected tokens: reference \(reference.selectedTokens), clone \(clone.selectedTokens)")
        }
        if reference.isEditing != clone.isEditing {
            differences.append("editing: reference \(reference.isEditing), clone \(clone.isEditing)")
        }
        return StateComparison(differences: differences, passes: differences.isEmpty)
    }
}

/// The comparisons made at one checkpoint of a script.
public struct CheckpointResult: Codable, Sendable {
    public var name: String
    public var state: StateComparison
    /// With the caret masked, and the handles of a range selection where the reference shows
    /// them (tolerated deviation, specification 12.5).
    public var pixels: PixelComparison
    /// With the caret masked and nothing else. Present when it differs from `pixels`.
    public var pixelsCaretOnly: PixelComparison?
    public var metrics: MetricsComparison
    public var accessibility: AccessibilityComparison
    /// What was left out of the pixel comparison, in the slot's coordinates: the caret of
    /// each field that shows one, and what the reference draws for a range selection (the
    /// handles with their shadows, and the corners its highlight squares off).
    public var referenceCaret: RectValue?
    public var cloneCaret: RectValue?
    public var selectionHandles: [RectValue]
    /// Snapshot files written next to the result, when any were.
    public var artifacts: [String]

    public var passes: Bool { state.passes && pixels.passes && metrics.passes && accessibility.passes }
}

/// The outcome of one cell of the matrix.
public struct CellResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Every comparison is within its threshold.
        case pass
        /// At least one comparison is outside its threshold.
        case fail
        /// The cell could not be run here; `reason` says why.
        case notRunnable = "not-runnable"
        /// The cell makes no sense for this configuration; `reason` says why.
        case notApplicable = "not-applicable"
    }

    public var cell: ParityCell
    public var status: Status
    /// Why the cell did not run, or the first thing that failed.
    public var reason: String?
    public var environment: HostEnvironment?
    /// How the script's steps were delivered ("XCUITest: touches and on-screen keys", ...).
    public var driver: String
    /// Hardware key presses the app saw while the script ran on each field.
    public var referenceKeyPresses: Int
    public var cloneKeyPresses: Int
    public var checkpoints: [CheckpointResult]
    public var eventLog: EventLogComparison?
    public var animation: AnimationComparison?
    /// One line per failed comparison.
    public var failures: [String]
    /// The tolerated deviations of specification 12.5 that were applied, and how.
    public var toleratedDeviations: [String]
    /// The worst numbers over all checkpoints.
    public var worstPixelPercent: Double
    public var worstDeltaE: Double
    public var worstMetricDeviation: Double
    public var durationSeconds: Double
    public var date: String

    public init(cell: ParityCell, status: Status, reason: String?, environment: HostEnvironment? = nil, driver: String = "") {
        self.cell = cell
        self.status = status
        self.reason = reason
        self.environment = environment
        self.driver = driver
        referenceKeyPresses = 0
        cloneKeyPresses = 0
        checkpoints = []
        failures = []
        toleratedDeviations = []
        worstPixelPercent = 0
        worstDeltaE = 0
        worstMetricDeviation = 0
        durationSeconds = 0
        date = ISO8601DateFormatter().string(from: Date())
    }

    /// Writes the result to `<directory>/<cell path>.json`.
    public func write(under directory: URL) throws {
        let url = directory.appendingPathComponent(cell.relativePath + ".json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What the app tells the driver about a finished cell.
public struct CellSummary: Codable, Sendable {
    public var status: CellResult.Status
    public var failures: [String]
    public var path: String
}
