import UIKit

/// The UIKit reference: a real `UISearchTextField` with `UISearchToken`s, laid out by a real
/// `UISearchBar`, with a delegate that logs every callback.
///
/// The field is the search bar's own `searchTextField`, so its height at every content size,
/// its insets and the Cancel button next to it are whatever UIKit makes them. The bar draws no
/// background of its own, so a snapshot shows the field and nothing else.
///
/// The log is written in the vocabulary of the clone's parity log: one `ParityEvent` per
/// delegate callback or control event (specification section 12.3). UIKit has no callback for
/// token mutations, so the field's tokens are compared with the last known ones at every
/// callback and a `tokensChanged` entry is logged at the first callback that sees a change.
@MainActor
public final class ReferenceField: NSObject, UITextFieldDelegate, UISearchBarDelegate {
    public let searchBar = UISearchBar()
    public var textField: UISearchTextField { searchBar.searchTextField }
    public private(set) var setup: FieldSetup

    public private(set) var events: [ParityEvent] = []
    /// Every callback as UIKit made it, untranslated: for diagnosing a difference.
    public private(set) var trace: [String] = []

    /// Answers of the policies a script may install; `true` unless the script says otherwise.
    public var allowsBeginEditing = true
    public var allowsEndEditing = true
    public var allowsClear = true
    public var allowsChange: (_ location: Int, _ length: Int, _ replacement: String) -> Bool = { _, _, _ in true }
    /// Called when the Cancel button was clicked, after the bar was reset.
    public var onCancel: () -> Void = {}

    /// The delegate the search bar installed on its text field: every callback is forwarded to
    /// it, so the bar keeps behaving as it does without this log.
    private weak var forwarded: UITextFieldDelegate?
    private var knownTokens: [String] = []

    public init(setup: FieldSetup) {
        self.setup = setup
        super.init()
        searchBar.backgroundImage = UIImage()
        searchBar.placeholder = setup.prompt
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.spellCheckingType = .no
        searchBar.smartQuotesType = .no
        searchBar.smartDashesType = .no
        searchBar.returnKeyType = .search
        searchBar.delegate = self

        let field = textField
        field.allowsDeletingTokens = setup.allowsDeletingTokens
        for (index, spec) in setup.tokens.enumerated() {
            field.insertToken(Self.token(spec), at: index)
        }
        field.text = setup.text
        knownTokens = labels

        forwarded = field.delegate
        field.delegate = self
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(editingDidEndOnExit), for: .editingDidEndOnExit)
    }

    static func token(_ spec: ParityTokenSpec) -> UISearchToken {
        let token = UISearchToken(icon: spec.symbol.flatMap { UIImage(systemName: $0) }, text: spec.label)
        token.representedObject = spec.label
        return token
    }

    // MARK: State

    /// The labels of the tokens now in the field, in order.
    public var labels: [String] {
        textField.tokens.map { $0.representedObject as? String ?? "?" }
    }

    /// The textual portion: what the clone's text binding holds.
    public var text: String { textField.text ?? "" }

    /// The labels of the tokens inside the current selection.
    public var selectedLabels: [String] {
        guard let range = textField.selectedTextRange, !range.isEmpty else { return [] }
        return textField.tokens(in: range).map { $0.representedObject as? String ?? "?" }
    }

    /// The delegate is still this log: the search bar did not take its text field back.
    public var isObserving: Bool { textField.delegate === self }

    public func clearLog() {
        events.removeAll()
        trace.removeAll()
        knownTokens = labels
    }

    /// Logs a token mutation that no callback has seen yet.
    public func noteTokens() {
        let current = labels
        guard current != knownTokens else { return }
        knownTokens = current
        events.append(.tokensChanged(current))
        trace.append("tokens=\(current)")
    }

    private func log(_ event: ParityEvent, _ callback: String) {
        noteTokens()
        events.append(event)
        trace.append(callback)
    }

    private func selectionEvent() -> ParityEvent {
        let field = textField
        guard let range = field.selectedTextRange else {
            return .didChangeSelection(tokens: [], textLocation: nil, textLength: nil)
        }
        // Positions are document offsets: tokens come first, one position each, then the text.
        let textStart = field.offset(from: field.beginningOfDocument, to: field.textualRange.start)
        let start = field.offset(from: field.beginningOfDocument, to: range.start)
        let end = field.offset(from: field.beginningOfDocument, to: range.end)
        let location = max(start, textStart) - textStart
        let length = max(end, textStart) - max(start, textStart)
        return .didChangeSelection(tokens: selectedLabels, textLocation: location, textLength: length)
    }

    private func describeSelection() -> String {
        let field = textField
        guard let range = field.selectedTextRange else { return "nil" }
        let start = field.offset(from: field.beginningOfDocument, to: range.start)
        let end = field.offset(from: field.beginningOfDocument, to: range.end)
        return "\(start)..<\(end)"
    }

    // MARK: UITextFieldDelegate

    public func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        let allowed = allowsBeginEditing && (forwarded?.textFieldShouldBeginEditing?(textField) ?? true)
        log(.shouldBeginEditing(allowed: allowed), "textFieldShouldBeginEditing -> \(allowed)")
        return allowed
    }

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        log(.didBeginEditing, "textFieldDidBeginEditing")
        forwarded?.textFieldDidBeginEditing?(textField)
    }

    public func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        let allowed = allowsEndEditing && (forwarded?.textFieldShouldEndEditing?(textField) ?? true)
        log(.shouldEndEditing(allowed: allowed), "textFieldShouldEndEditing -> \(allowed)")
        return allowed
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        log(.didEndEditing, "textFieldDidEndEditing")
        forwarded?.textFieldDidEndEditing?(textField)
    }

    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let allowed = allowsChange(range.location, range.length, string)
            && (forwarded?.textField?(textField, shouldChangeCharactersIn: range, replacementString: string) ?? true)
        log(
            .shouldChange(location: range.location, length: range.length, replacement: string, allowed: allowed),
            "shouldChangeCharactersIn {\(range.location), \(range.length)} \(ParityEvent.quoted(string)) -> \(allowed)"
        )
        return allowed
    }

    public func textFieldDidChangeSelection(_ textField: UITextField) {
        log(selectionEvent(), "textFieldDidChangeSelection \(describeSelection())")
        forwarded?.textFieldDidChangeSelection?(textField)
    }

    public func textFieldShouldClear(_ textField: UITextField) -> Bool {
        let allowed = allowsClear && (forwarded?.textFieldShouldClear?(textField) ?? true)
        log(.shouldClear(allowed: allowed), "textFieldShouldClear -> \(allowed)")
        return allowed
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        log(.shouldReturn, "textFieldShouldReturn")
        // The host's submit handler converts the typed text, as the clone does on submit.
        convertTextToToken()
        return forwarded?.textFieldShouldReturn?(textField) ?? true
    }

    // MARK: Control events

    @objc private func editingChanged() {
        log(.editingChanged(text: text), "editingChanged \(ParityEvent.quoted(text))")
        convertTextToToken()
    }

    @objc private func editingDidEndOnExit() {
        log(.editingDidEndOnExit, "editingDidEndOnExit")
    }

    /// What a UIKit host does for text-to-token conversion: `replaceTextualPortion(of:with:at:)`.
    private func convertTextToToken() {
        guard let label = setup.tokenLabel(for: text) else { return }
        let field = textField
        field.replaceTextualPortion(of: field.textualRange, with: Self.token(ParityTokenSpec(label)), at: field.tokens.count)
        trace.append("replaceTextualPortion -> \(labels)")
        noteTokens()
    }

    // MARK: UISearchBarDelegate

    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        guard setup.cancelButton else { return }
        searchBar.setShowsCancelButton(true, animated: true)
    }

    public func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        guard setup.cancelButton else { return }
        searchBar.setShowsCancelButton(false, animated: true)
    }

    /// `UISearchBar` only reports the click; clearing the bar and dropping focus is the code
    /// every UIKit host writes, and what the specification asks of the clone (12.2, rule 6).
    public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        log(.cancelButtonClicked, "searchBarCancelButtonClicked")
        let field = textField
        field.tokens = []
        field.text = ""
        noteTokens()
        searchBar.resignFirstResponder()
        onCancel()
    }
}
