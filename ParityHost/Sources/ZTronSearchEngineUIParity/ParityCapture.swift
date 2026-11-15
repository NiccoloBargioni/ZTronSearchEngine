import UIKit

/// One node of a field's accessibility tree, as the accessibility runtime hands it to a
/// client. The UI test reads it from an XCUITest snapshot; the app adds the names of the
/// custom actions, which no snapshot exposes, by matching frames.
public struct AccessibilityNode: Codable, Hashable, Sendable {
    /// The element type the node's traits resolve to ("SearchField", "Button", "Other", ...).
    public var type: String
    public var label: String
    public var value: String?
    public var placeholder: String?
    public var identifier: String
    public var isSelected: Bool
    public var isEnabled: Bool
    /// Depth below the field's root. Recorded, not compared.
    public var depth: Int
    /// In screen coordinates. Recorded, not compared.
    public var frame: RectValue
    /// Names of the custom actions, in order.
    public var actions: [String]

    public init(
        type: String, label: String, value: String?, placeholder: String?, identifier: String, isSelected: Bool,
        isEnabled: Bool, depth: Int, frame: RectValue, actions: [String] = []
    ) {
        self.type = type
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.depth = depth
        self.frame = frame
        self.actions = actions
    }

    /// A node that tells an assistive technology something. Containers without a label, a
    /// value, a placeholder or an identifier are scaffolding and are left out of comparisons.
    public var hasContent: Bool {
        !label.isEmpty || !(value ?? "").isEmpty || !(placeholder ?? "").isEmpty || !identifier.isEmpty
    }
}

/// Everything recorded about one field at one checkpoint of a script.
public struct FieldCapture: Codable, Sendable {
    public var side: FieldSide
    public var checkpoint: String
    /// The textual portion.
    public var text: String
    public var tokens: [String]
    public var selectedTokens: [String]
    public var isEditing: Bool
    public var metrics: LayoutMetrics
    public var accessibility: [AccessibilityNode]
    /// The caret, in slot coordinates: left out of the pixel comparison.
    public var caret: RectValue?
    /// The handles of a range selection, in slot coordinates (the reference only).
    public var selectionHandles: [RectValue]
    /// Entries in the field's log when the capture was taken.
    public var eventCount: Int
    /// Key presses of a hardware keyboard the app has seen since the script began.
    public var keyPresses: Int
}

/// A capture and the pixels that go with it.
struct CapturedField {
    var capture: FieldCapture
    var image: PixelImage
    var scale: CGFloat
}

extension ParityStageController {
    /// The environment the stage runs in, read from the stage itself.
    var hostEnvironment: HostEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        return HostEnvironment(
            osVersion: "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            modelIdentifier: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "device",
            screenWidth: Double(screen.bounds.width),
            screenHeight: Double(screen.bounds.height),
            scale: Double(screen.scale),
            contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
            isDark: traitCollection.userInterfaceStyle == .dark,
            isHighContrast: traitCollection.accessibilityContrast == .high,
            isReduceTransparencyEnabled: UIAccessibility.isReduceTransparencyEnabled,
            isBoldTextEnabled: UIAccessibility.isBoldTextEnabled,
            isRightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            language: Locale.preferredLanguages.first ?? "",
            locale: Locale.current.identifier
        )
    }

    /// Renders the stage as it is on screen and returns the pixels of both slots.
    func snapshot() -> (reference: PixelImage, clone: PixelImage, scale: CGFloat)? {
        let scale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage, let pixels = PixelImage(cgImage) else { return nil }
        let reference = pixels.cropped(to: PixelRect(slot(.reference), scale: scale))
        let clone = pixels.cropped(to: PixelRect(slot(.clone), scale: scale))
        return (reference, clone, scale)
    }

    /// Records one field at a checkpoint. `nodes` is the field's accessibility tree as the UI
    /// test read it from the accessibility runtime.
    func capture(_ side: FieldSide, checkpoint: String, nodes: [AccessibilityNode]) throws -> CapturedField {
        view.layoutIfNeeded()
        guard let pixels = snapshot() else { throw ParityError("the stage could not be rendered") }
        let slot = slot(side)
        let actions = AccessibilityActions.collect(under: side == .reference ? reference.searchBar : clone.view)
        let accessibility = nodes.map { node -> AccessibilityNode in
            var node = node
            node.actions = AccessibilityActions.match(node, in: actions)
            return node
        }
        let capture: FieldCapture
        switch side {
        case .reference:
            reference.noteTokens()
            capture = FieldCapture(
                side: side, checkpoint: checkpoint, text: reference.text, tokens: reference.labels,
                selectedTokens: reference.selectedLabels, isEditing: reference.textField.isEditing,
                metrics: reference.metrics(in: view, slot: slot), accessibility: accessibility,
                caret: Self.caret(of: reference.textField, in: view, slot: slot),
                selectionHandles: reference.selectionHandles(in: view, slot: slot),
                eventCount: reference.events.count, keyPresses: ParityWindow.keyPressCount
            )
        case .clone:
            capture = FieldCapture(
                side: side, checkpoint: checkpoint, text: clone.text, tokens: clone.labels,
                selectedTokens: clone.selectedLabels, isEditing: clone.innerTextField?.isFirstResponder ?? false,
                metrics: clone.metrics(in: view, slot: slot), accessibility: accessibility,
                caret: clone.innerTextField.flatMap { Self.caret(of: $0, in: view, slot: slot) },
                selectionHandles: [],
                eventCount: clone.events.count, keyPresses: ParityWindow.keyPressCount
            )
        }
        return CapturedField(capture: capture, image: side == .reference ? pixels.reference : pixels.clone, scale: pixels.scale)
    }

    /// The caret of a text input that is editing, in slot coordinates: `nil` when the input
    /// shows none, because its selection is a range (a selected token, in the reference) or
    /// because it draws its caret in a clear tint (the clone, while a token is selected).
    static func caret(of field: UITextField, in stage: UIView, slot: CGRect) -> RectValue? {
        guard field.isFirstResponder, let range = field.selectedTextRange, range.isEmpty else { return nil }
        var alpha: CGFloat = 1
        guard field.tintColor.getRed(nil, green: nil, blue: nil, alpha: &alpha), alpha > 0 else { return nil }
        // Text-input rectangles are in the coordinates of the view that draws the text.
        let rect = field.caretRect(for: range.end)
        guard !rect.isNull, !rect.isInfinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return RectValue(field.textInputView.convert(rect, to: stage).offsetBy(dx: -slot.minX, dy: -slot.minY))
    }

    /// The first baseline of a view's text, in the stage's coordinates, as Auto Layout sees it.
    static func firstBaseline(of view: UIView, in stage: UIView) -> CGFloat? {
        guard view.window != nil else { return nil }
        let probe = UIView()
        probe.isHidden = true
        probe.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(probe)
        let constraints = [
            probe.topAnchor.constraint(equalTo: view.firstBaselineAnchor),
            probe.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            probe.widthAnchor.constraint(equalToConstant: 1),
            probe.heightAnchor.constraint(equalToConstant: 1),
        ]
        NSLayoutConstraint.activate(constraints)
        stage.layoutIfNeeded()
        let baseline = probe.frame.minY
        NSLayoutConstraint.deactivate(constraints)
        probe.removeFromSuperview()
        return baseline
    }
}

/// An error of the parity host, with a message meant for a result file.
public struct ParityError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// The custom accessibility actions of everything under a view, read in process.
@MainActor
enum AccessibilityActions {
    struct Entry {
        var frame: CGRect
        var label: String?
        var names: [String]
    }

    /// Every object under `root` that offers custom actions, with its screen frame.
    static func collect(under root: UIView) -> [Entry] {
        var entries: [Entry] = []
        var visited = Set<ObjectIdentifier>()
        visit(root, depth: 0, visited: &visited, into: &entries)
        return entries
    }

    private static func visit(_ object: NSObject, depth: Int, visited: inout Set<ObjectIdentifier>, into entries: inout [Entry]) {
        guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return }
        if let actions = object.accessibilityCustomActions, !actions.isEmpty {
            entries.append(Entry(frame: object.accessibilityFrame, label: object.accessibilityLabel, names: actions.map(\.name)))
        }
        var children: [NSObject] = []
        if let explicit = object.accessibilityElements {
            children += explicit.compactMap { $0 as? NSObject }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = object as? UIView { children += view.subviews }
        for child in children { visit(child, depth: depth + 1, visited: &visited, into: &entries) }
    }

    /// The custom actions of the object a node of the runtime's tree stands for: the one with
    /// the same label whose frame is the node's, to within a point.
    static func match(_ node: AccessibilityNode, in entries: [Entry]) -> [String] {
        let frame = node.frame.cgRect
        let candidates = entries.filter { entry in
            abs(entry.frame.minX - frame.minX) <= 1 && abs(entry.frame.minY - frame.minY) <= 1
                && abs(entry.frame.width - frame.width) <= 1 && abs(entry.frame.height - frame.height) <= 1
        }
        return (candidates.first { $0.label == node.label } ?? candidates.first)?.names ?? []
    }
}
