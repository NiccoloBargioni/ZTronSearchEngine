import SwiftUI
import UIKit
import ZTronSearchEngine
@testable import ZTronSearchEngineUI

/// The state a SwiftUI host owns around a `ZTronSearchField`: the bindings, the focus state
/// and the handlers of every modifier, driven from outside by the scripts.
@MainActor
final class CloneModel: ObservableObject {
    @Published var text: String
    @Published var tokens: [ParityToken]
    @Published var selection: Set<UUID> = []
    /// What the host wants `.focused` to be; the screen writes it into its `@FocusState`.
    @Published var wantsFocus = false

    let setup: FieldSetup
    /// When the clear button shows: whatever mode the reference field is in.
    let clearButtonMode: ZTronClearButtonMode
    /// The parity log, as `onSearchFieldEvent` delivered it. Not published: logging must never
    /// invalidate the view under test.
    var events: [ParityEvent] = []
    var isFocused = false
    var submitCount = 0
    var cancelCount = 0
    var editingChanges: [Bool] = []
    /// The frames of the field's parts, in the hosting view's coordinates.
    var parts: [ZTronSearchFieldPart: CGRect] = [:]

    init(setup: FieldSetup, clearButtonMode: ZTronClearButtonMode) {
        self.setup = setup
        self.clearButtonMode = clearButtonMode
        text = setup.text
        tokens = setup.tokens.enumerated().map { $1.cloneToken(index: $0) }
    }
}

/// The resolved frames of the field's parts, lifted out of the field as a preference.
private struct ResolvedPartsKey: PreferenceKey {
    static var defaultValue: [ZTronSearchFieldPart: CGRect] { [:] }

    static func reduce(value: inout [ZTronSearchFieldPart: CGRect], nextValue: () -> [ZTronSearchFieldPart: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The clone as a host would write it (specification section 12.2, "Minimal host").
struct CloneScreen: View {
    @ObservedObject var model: CloneModel
    @FocusState private var focused: Bool

    var body: some View {
        let setup = model.setup
        ZTronSearchField<ParitySchema>(
            text: $model.text, tokens: $model.tokens, prompt: Text(verbatim: setup.prompt), tokenSelection: $model.selection
        )
        .focused($focused)
        .searchCancelButton(setup.cancelButton ? .automatic : .never)
        .clearButtonMode(model.clearButtonMode)
        .tokenDeletion(setup.allowsDeletingTokens ? .enabled : .disabled)
        .textToToken { (typed: String) -> ParityToken? in
            setup.tokenLabel(for: typed).map { ParityToken(kind: .phrase($0), text: $0) }
        }
        .onSearchFieldEvent { model.events.append(ParityEvent($0)) }
        .onEditingChanged { model.editingChanges.append($0) }
        .onSearchCancel { model.cancelCount += 1 }
        .onSubmit { model.submitCount += 1 }
        .onChange(of: model.wantsFocus) { wanted in
            if focused != wanted { focused = wanted }
        }
        .onChange(of: focused) { now in
            model.isFocused = now
            if model.wantsFocus != now { model.wantsFocus = now }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlayPreferenceValue(ZTronSearchFieldPartsKey.self) { anchors in
            GeometryReader { proxy in
                Color.clear.preference(key: ResolvedPartsKey.self, value: anchors.mapValues { proxy[$0] })
            }
        }
        .onPreferenceChange(ResolvedPartsKey.self) { parts in
            MainActor.assumeIsolated { model.parts = parts }
        }
        .ignoresSafeArea()
    }
}

/// The SwiftUI clone in a hosting controller, with the same surface as ``ReferenceField``.
@MainActor
public final class CloneField {
    let model: CloneModel
    public let controller: UIHostingController<AnyView>
    public var view: UIView { controller.view }
    public var setup: FieldSetup { model.setup }

    /// - Parameter clearButtonMode: the reference field's mode. A search bar shows its field's
    ///   clear button whenever the field holds something; the clone is put in the same mode
    ///   through its modifier, so the two are compared under one configuration.
    public init(setup: FieldSetup, clearButtonMode: UITextField.ViewMode) {
        let mode: ZTronClearButtonMode
        switch clearButtonMode {
        case .never: mode = .never
        case .whileEditing: mode = .whileEditing
        case .unlessEditing: mode = .unlessEditing
        case .always: mode = .always
        @unknown default: mode = .whileEditing
        }
        model = CloneModel(setup: setup, clearButtonMode: mode)
        controller = UIHostingController(rootView: AnyView(CloneScreen(model: model)))
        controller.view.backgroundColor = .clear
    }

    public var events: [ParityEvent] { model.events }
    public var text: String { model.text }
    public var labels: [String] { model.tokens.map(\.text) }
    public var selectedLabels: [String] { model.tokens.filter { model.selection.contains($0.id) }.map(\.text) }
    public var isFocused: Bool { model.isFocused }

    public func clearLog() {
        model.events.removeAll()
    }

    /// Host-driven focus: the round trip through `.focused`.
    public func setFocus(_ focused: Bool) {
        model.wantsFocus = focused
    }

    /// The text input SwiftUI built for the clone's `TextField`.
    public var innerTextField: UITextField? {
        ParityStageController.descendants(of: view, ofType: UITextField.self).first
    }

    /// The frame of one part of the clone, in the hosting view's coordinates.
    private func frame(of part: ZTronSearchFieldPart) -> CGRect? {
        model.parts[part]
    }

    var fieldFrame: CGRect? { frame(of: .field) }
    var clearButtonFrame: CGRect? { frame(of: .clearButton) }
    var cancelButtonFrame: CGRect? { frame(of: .cancelButton) }

    /// The frames of the tokens, by index.
    var tokenFrames: [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for (index, token) in model.tokens.enumerated() {
            if let frame = model.parts[.token(token.id)] { frames[index] = frame }
        }
        return frames
    }

    /// The layout of the clone, in the coordinates of its slot.
    func metrics(in stage: UIView, slot: CGRect) -> LayoutMetrics {
        var metrics = LayoutMetrics()
        func inSlot(_ rect: CGRect) -> RectValue {
            RectValue(view.convert(rect, to: stage).offsetBy(dx: -slot.minX, dy: -slot.minY))
        }
        if let field = frame(of: .field) { metrics.frames["field"] = inSlot(field) }
        if let glyph = frame(of: .glyph) { metrics.frames["glyph"] = inSlot(glyph) }
        for (index, frame) in tokenFrames { metrics.frames["token.\(index)"] = inSlot(frame) }
        if let clear = frame(of: .clearButton) { metrics.frames["clearButton"] = inSlot(clear) }
        if let cancel = frame(of: .cancelButton) { metrics.frames["cancelButton"] = inSlot(cancel) }
        if let input = innerTextField, let baseline = ParityStageController.firstBaseline(of: input, in: stage) {
            metrics.lengths["baseline"] = Double(baseline - slot.minY)
        }
        return metrics
    }
}
