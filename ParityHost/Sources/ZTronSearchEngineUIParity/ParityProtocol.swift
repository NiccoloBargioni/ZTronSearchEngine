import Foundation

/// One user action of a scenario script. The same steps drive both fields.
///
/// Touches and keys are delivered by the UI test, as real events; the steps that stand for
/// what a host does in code (`setFocus`) or for waiting are performed inside the app.
public enum ScriptStep: Codable, Hashable, Sendable {
    /// Tap the text area of the field: it takes focus, and a selected token is deselected.
    case tapField
    /// Type the characters one key at a time.
    case type(String)
    /// One press of the delete key.
    case backspace
    /// The search (return) key.
    case submit
    /// Tap the token at this index, a quarter of its width in from its leading edge. Where a
    /// token is touched matters: the reference selects it from its leading half only.
    case tapToken(Int)
    /// Tap the token at this index, three quarters of its width in: its trailing half.
    case tapTokenTrailingHalf(Int)
    /// Tap the typed text, three quarters of its width in: its caret goes to the end of the
    /// word under the touch.
    case tapText
    /// Tap the clear button.
    case tapClear
    /// Tap the Cancel button.
    case tapCancel
    /// The host sets focus: `becomeFirstResponder()` / `resignFirstResponder()` on the
    /// reference, the `.focused` binding on the clone.
    case setFocus(Bool)
    /// Let animations finish.
    case settle(Double)
    /// Record the field frame by frame for this many seconds, to time what the next steps
    /// animate.
    case watchAnimation(Double)

    /// The step is performed inside the app, not by an input event.
    public var isPerformedInProcess: Bool {
        switch self {
        case .setFocus, .settle, .watchAnimation: return true
        case .tapField, .tapText, .type, .backspace, .submit, .tapToken, .tapTokenTrailingHalf, .tapClear, .tapCancel: return false
        }
    }
}

/// What the driver asks of the app that hosts the two fields.
public enum ParityCommand: Codable, Sendable {
    /// What the app runs under.
    case environment
    /// A new cell: fresh fields, and everything captured so far is forgotten.
    case begin(FieldSetup)
    /// Fresh fields for the second field's turn; what the first field's turn captured is kept.
    case rebuild(FieldSetup)
    /// Where one field's parts are on screen, so that a UI test knows where to tap.
    case geometry(side: FieldSide)
    /// Perform one in-process step on one field.
    case perform(side: FieldSide, step: ScriptStep)
    /// Record one field at a checkpoint. `nodes` is its accessibility tree as the UI test
    /// read it from the accessibility runtime.
    case capture(side: FieldSide, checkpoint: String, nodes: [AccessibilityNode])
    /// Compare everything captured since `begin`, write the cell's result, and report it.
    case finish(cell: ParityCell, options: FinishOptions)
    /// Sample the UIKit reference under the current environment (see ``ReferenceSampler``).
    case sample
    /// Write what is known about both fields to `<name>.txt` and `<name>.png`, for diagnosis.
    case dump(name: String)
}

public struct FinishOptions: Codable, Sendable {
    /// The directory results are written under.
    public var resultsDirectory: String
    /// How the steps were delivered, for the record.
    public var driver: String
    /// Problems the driver met while running the script; any makes the cell fail.
    public var driverProblems: [String]
    /// Write the snapshots of every checkpoint, not only of failing ones.
    public var keepsAllSnapshots: Bool
    /// Also write the reference's snapshots under this directory (the per-release recordings).
    public var referenceSnapshotsDirectory: String?

    public init(
        resultsDirectory: String, driver: String, driverProblems: [String] = [], keepsAllSnapshots: Bool = false,
        referenceSnapshotsDirectory: String? = nil
    ) {
        self.resultsDirectory = resultsDirectory
        self.driver = driver
        self.driverProblems = driverProblems
        self.keepsAllSnapshots = keepsAllSnapshots
        self.referenceSnapshotsDirectory = referenceSnapshotsDirectory
    }
}

public struct ParityRequest: Codable, Sendable {
    public var id: Int
    public var command: ParityCommand

    public init(id: Int, command: ParityCommand) {
        self.id = id
        self.command = command
    }
}

/// Screen positions, in points, of what a script taps on one field.
public struct FieldGeometry: Codable, Sendable {
    /// The field's slot: what its snapshots cover.
    public var slot: RectValue
    /// A point past the end of the content, on no token and on no button.
    public var textPoint: RectValue
    /// The typed text, when there is any.
    public var textRun: RectValue?
    /// The tokens on screen, by index.
    public var tokens: [Int: RectValue]
    public var clearButton: RectValue?
    public var cancelButton: RectValue?
    /// The field's text input is first responder.
    public var isEditing: Bool
    /// The textual portion, the token labels and the labels of the selected tokens.
    public var text: String
    public var tokenLabels: [String]
    public var selectedLabels: [String]
    /// The field's log so far.
    public var events: [ParityEvent]
    /// The layout runs right to left: a token's leading half is its right half.
    public var isRightToLeft: Bool
    /// The accessibility identifier of the view that holds the field.
    public var containerIdentifier: String
}

public struct ParityResponse: Codable, Sendable {
    public var id: Int
    public var error: String?
    public var environment: HostEnvironment?
    public var geometry: FieldGeometry?
    public var summary: CellSummary?
    public var sample: ReferenceSample?

    public init(id: Int) {
        self.id = id
    }
}

/// The file-based channel between a driver and the app: requests and responses are JSON files
/// in a directory both can reach. On a simulator that is any directory of the Mac.
public struct ParityChannel: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func requestURL(_ id: Int) -> URL { directory.appendingPathComponent("request-\(id).json") }
    public func responseURL(_ id: Int) -> URL { directory.appendingPathComponent("response-\(id).json") }

    public func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    public func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
