import XCTest
import ZTronSearchEngineUIParity

/// The UI-test side of the channel: launches the host app, sends it commands, and performs the
/// steps of a script with real touches and key events.
@MainActor
final class ParityRemote {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let app: XCUIApplication
    let channel: ParityChannel
    private var nextRequest = 1
    /// Where the keys of the on-screen keyboard are, once looked up: the keyboard does not
    /// move while the app runs, and finding a key costs more than touching it.
    private var keyFrames: [String: RectValue] = [:]
    /// The name under which each special key of the hardware keyboard reached a field.
    private var hardwareKeys: [String: String] = [:]

    /// Launches the host app in a language and region, with a fresh channel directory.
    init(channelDirectory: URL, language: String, region: String) throws {
        try? FileManager.default.removeItem(at: channelDirectory)
        try FileManager.default.createDirectory(at: channelDirectory, withIntermediateDirectories: true)
        channel = ParityChannel(directory: channelDirectory)
        app = XCUIApplication()
        app.launchEnvironment[ParityHost.channelVariable] = channelDirectory.path
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", "\(language)_\(region)"]
        app.launch()
    }

    /// Sends one command and waits for the app's answer.
    @discardableResult
    func send(_ command: ParityCommand, timeout: TimeInterval = 30) throws -> ParityResponse {
        let id = nextRequest
        nextRequest += 1
        try channel.write(ParityRequest(id: id, command: command), to: channel.requestURL(id))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = channel.read(ParityResponse.self, from: channel.responseURL(id)) {
                try? FileManager.default.removeItem(at: channel.requestURL(id))
                try? FileManager.default.removeItem(at: channel.responseURL(id))
                if let error = response.error { throw Failure(description: "the host app answered \(Self.name(of: command)) with: \(error)") }
                return response
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        throw Failure(description: "the host app did not answer \(Self.name(of: command)) within \(Int(timeout)) s")
    }

    private static func name(of command: ParityCommand) -> String {
        String(String(describing: command).prefix { $0 != "(" })
    }

    func geometry(_ side: FieldSide) throws -> FieldGeometry {
        guard let geometry = try send(.geometry(side: side)).geometry else {
            throw Failure(description: "the host app reported no geometry for the \(side.rawValue)")
        }
        return geometry
    }

    // MARK: Input

    /// A real touch at the middle of a rectangle of the screen, in points.
    func tap(_ rect: RectValue) {
        timed { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap() }
    }

    /// One key event of a hardware keyboard.
    private func pressKey(_ key: String) {
        timed { app.typeKey(key, modifierFlags: []) }
    }

    /// The app stopped reporting itself idle. Before every event XCUITest waits for the app to
    /// be idle, a minute at most; now and then an app process gets into a state in which it
    /// never reports that again, and every event from then on costs that minute. The process
    /// is of no further use: the cell under way is not counted, and the next gets a fresh app.
    private(set) var isStalled = false

    private func timed(_ event: () -> Void) {
        let start = Date()
        event()
        if Date().timeIntervalSince(start) > 30 { isStalled = true }
    }

    /// Keys go to whatever has focus, so a step that types first makes sure it is the field.
    /// Returns how many entries the field's log holds.
    @discardableResult
    private func requireFocus(_ side: FieldSide, for step: ScriptStep) throws -> Int {
        let state = try geometry(side)
        guard state.isEditing else {
            throw Failure(description: "the \(side.rawValue) does not have keyboard focus for \(step)")
        }
        return state.events.count
    }

    /// Presses a key of the hardware keyboard that is not a character: delete, return.
    ///
    /// XCUITest names these keys in more than one way and not every name reaches an iOS
    /// simulator, so the names are tried in turn until the field's log shows the key arrived;
    /// the one that worked is used from then on. The scripts press these keys only where the
    /// reference logs something for them. A key no name delivers is reported as undelivered,
    /// which makes the cell not runnable: it must never count as a pass that neither field
    /// was given the key.
    private func pressHardwareKey(_ name: String, _ candidates: [String], on side: FieldSide, logged: Int) throws {
        for key in hardwareKeys[name].map({ [$0] }) ?? candidates {
            pressKey(key)
            if try geometry(side).events.count > logged {
                hardwareKeys[name] = key
                return
            }
        }
        throw Failure(description: "\(ParitySession.undeliveredKeyMarker) \(name) key to the \(side.rawValue)")
    }

    /// Touches a key of the on-screen keyboard.
    private func tapSoftwareKey(_ name: String) throws {
        if let frame = keyFrames[name] {
            tap(frame)
            return
        }
        let key = app.keyboards.keys[name]
        if !key.waitForExistence(timeout: 3) {
            // The scripts type the same Latin text under every layout direction. Under an
            // Arabic interface the keyboard comes up Arabic: go on to the next keyboard, as a
            // user would, until the key is there.
            let next = app.keyboards.buttons["Next keyboard"]
            var switches = 0
            while !key.exists, next.exists, switches < 3 {
                next.tap()
                keyFrames.removeAll()
                switches += 1
                _ = key.waitForExistence(timeout: 2)
            }
        }
        guard key.exists else {
            throw Failure(description: "\(ParitySession.missingKeyMarker) \"\(name)\" key")
        }
        let frame = RectValue(key.frame)
        keyFrames[name] = frame
        tap(frame)
    }

    /// Touches the return key. The field asks for a search key, so that is what the key is
    /// called; on a phone it is also the keyboard's last button, which serves where the name
    /// does not (a localized keyboard). On an iPad the last button puts the keyboard away,
    /// so there the key has to be found by name.
    private func tapReturnKey() throws {
        if let frame = keyFrames["\n"] {
            tap(frame)
            return
        }
        let buttons = app.keyboards.buttons
        guard buttons.firstMatch.waitForExistence(timeout: 3) else {
            throw Failure(description: "\(ParitySession.missingKeyMarker) return key")
        }
        var key = buttons.element(boundBy: buttons.count - 1)
        for name in ["Search", "search", "Return", "return"] where buttons[name].exists {
            key = buttons[name]
            break
        }
        let frame = RectValue(key.frame)
        keyFrames["\n"] = frame
        tap(frame)
    }

    /// Performs one step on one field the way a user would: touches for taps, and for keys
    /// either taps on the on-screen keyboard or key events of a hardware keyboard.
    func perform(_ step: ScriptStep, on side: FieldSide, input: ParityInput) throws {
        switch step {
        case .tapField:
            tap(try geometry(side).textPoint)
        case .tapToken(let index), .tapTokenTrailingHalf(let index):
            let state = try geometry(side)
            guard let token = state.tokens[index] else {
                throw Failure(description: "the \(side.rawValue) shows no token \(index) to tap")
            }
            // A quarter of the way in from the leading edge, or from the trailing one.
            var fraction = 0.25
            if case .tapTokenTrailingHalf = step { fraction = 0.75 }
            if state.isRightToLeft { fraction = 1 - fraction }
            tap(RectValue(x: token.x + token.width * fraction - 1, y: token.midY - 1, width: 2, height: 2))
        case .tapText:
            let state = try geometry(side)
            guard let run = state.textRun else {
                throw Failure(description: "the \(side.rawValue) shows no text to tap")
            }
            let fraction = state.isRightToLeft ? 0.25 : 0.75
            tap(RectValue(x: run.x + run.width * fraction - 1, y: run.midY - 1, width: 2, height: 2))
        case .tapClear:
            guard let clear = try geometry(side).clearButton else {
                throw Failure(description: "the \(side.rawValue) shows no clear button to tap")
            }
            tap(clear)
        case .tapCancel:
            guard let cancel = try geometry(side).cancelButton else {
                throw Failure(description: "the \(side.rawValue) shows no Cancel button to tap")
            }
            tap(cancel)
        case .type(let text):
            let logged = try requireFocus(side, for: step)
            for character in text {
                switch input {
                case .hardware: pressKey(String(character))
                case .software: try tapSoftwareKey(character == " " ? "space" : String(character))
                }
            }
            // A typed character always shows in the log; if nothing did, the keys went nowhere.
            guard try geometry(side).events.count > logged else {
                keyFrames.removeAll()
                throw Failure(description: "the \(input.rawValue) keyboard delivered nothing to the \(side.rawValue) for \(step)")
            }
        case .backspace:
            let state = try requireFocus(side, for: step)
            switch input {
            case .hardware:
                try pressHardwareKey("delete", [XCUIKeyboardKey.delete.rawValue, "\u{8}", "\u{7F}"], on: side, logged: state)
            case .software: try tapSoftwareKey("delete")
            }
        case .submit:
            let state = try requireFocus(side, for: step)
            switch input {
            case .hardware:
                try pressHardwareKey("return", [XCUIKeyboardKey.return.rawValue, "\r", "\n", XCUIKeyboardKey.enter.rawValue], on: side, logged: state)
            case .software: try tapReturnKey()
            }
        case .setFocus, .settle, .watchAnimation:
            try send(.perform(side: side, step: step))
        }
    }

    // MARK: Accessibility

    /// The accessibility tree under one field, as the accessibility runtime hands it to
    /// XCUITest: every node below the field's container, in order.
    ///
    /// Buttons, images, links and static texts are leaves: an assistive technology lands on
    /// the button, never on the label inside it, so what a toolkit builds a leaf from is not
    /// part of the tree. A text field is not a leaf: its glyph, its tokens and its clear button
    /// are elements of their own.
    func accessibilityNodes(of identifier: String) throws -> [AccessibilityNode] {
        let container = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard container.exists else {
            throw Failure(description: "the accessibility tree has no element identified \(identifier)")
        }
        let leaves: Set<XCUIElement.ElementType> = [.button, .image, .icon, .link, .staticText, .switch, .toggle, .slider]
        func text(_ value: String?) -> String? {
            // No string and an empty string say the same thing to a user: nothing.
            (value ?? "").isEmpty ? nil : value
        }
        var nodes: [AccessibilityNode] = []
        func visit(_ snapshot: XCUIElementSnapshot, depth: Int) {
            for child in snapshot.children {
                nodes.append(AccessibilityNode(
                    type: Self.name(of: child.elementType), label: child.label,
                    value: text((child.value as? String) ?? (child.value as? NSNumber)?.stringValue),
                    placeholder: text(child.placeholderValue), identifier: child.identifier, isSelected: child.isSelected,
                    isEnabled: child.isEnabled, depth: depth, frame: RectValue(child.frame)
                ))
                if !leaves.contains(child.elementType) { visit(child, depth: depth + 1) }
            }
        }
        visit(try container.snapshot(), depth: 0)
        return nodes
    }

    private static func name(of type: XCUIElement.ElementType) -> String {
        switch type {
        case .other: return "Other"
        case .group: return "Group"
        case .button: return "Button"
        case .link: return "Link"
        case .image: return "Image"
        case .icon: return "Icon"
        case .searchField: return "SearchField"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .staticText: return "StaticText"
        case .scrollView: return "ScrollView"
        case .cell: return "Cell"
        case .switch: return "Switch"
        case .toggle: return "Toggle"
        case .slider: return "Slider"
        case .keyboard: return "Keyboard"
        case .key: return "Key"
        default: return "Type\(type.rawValue)"
        }
    }

    // MARK: Cells

    /// Runs one cell: the script on the reference, then on the clone, with a capture at every
    /// checkpoint, and then the app's comparison of the two.
    func run(_ cell: ParityCell, options: FinishOptions) throws -> CellSummary {
        var options = options
        let script = cell.script
        try send(.begin(script.setup))
        for side in FieldSide.allCases {
            do {
                if side == .clone { try send(.rebuild(script.setup)) }
                let identifier = try geometry(side).containerIdentifier
                try send(.capture(side: side, checkpoint: "initial", nodes: try accessibilityNodes(of: identifier)))
                for action in script.actions {
                    switch action {
                    case .step(let step):
                        try perform(step, on: side, input: cell.input)
                        if isStalled {
                            throw Failure(description: "\(ParitySession.stalledMarker): XCUITest waited more than 30 s for it before \(step)")
                        }
                    case .checkpoint(let name):
                        try send(.capture(side: side, checkpoint: name, nodes: try accessibilityNodes(of: identifier)))
                    }
                }
            } catch {
                options.driverProblems.append("\(side.rawValue): \(error)")
            }
            if isStalled { break }
        }
        guard let summary = try send(.finish(cell: cell, options: options)).summary else {
            throw Failure(description: "the host app reported no result for the cell")
        }
        return summary
    }
}
