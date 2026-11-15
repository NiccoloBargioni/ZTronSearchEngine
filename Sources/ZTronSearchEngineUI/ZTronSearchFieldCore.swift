import Foundation
import ZTronSearchEngine

/// The behavior of the search field, as a value: everything the view does in response to input
/// happens here, where it can be tested without rendering anything.
///
/// The field keeps a zero-width sentinel (U+200B) at the start of its private buffer. SwiftUI
/// exposes no software-keyboard key events on iOS 15, so a backspace at the start of the text is
/// recognized by the sentinel disappearing: the field restores it and acts on the tokens. The
/// sentinel never reaches the text binding, the accessibility tree or the event log.
///
/// The order and the payloads of the events are those of the UIKit reference, as the parity
/// host recorded them with real touches and keys (`ParityHost/Samples`, `behavior.eventProfile`).
struct ZTronSearchFieldCore<Schema: SearchSchema> {
    static var sentinel: String { "\u{200B}" }
    static var sentinelScalar: Unicode.Scalar { "\u{200B}" }

    /// What the UIKit reference does where the specification says "recorded, never assumed":
    /// the parity host records it per iOS version, and the view passes the record of the
    /// version it runs on.
    typealias Behavior = ZTronSearchFieldBehavior

    struct Policies {
        var deletion: ZTronTokenDeletionPolicy = .enabled
        var textInputPolicy: ((ZTronTextChange) -> Bool)?
        var editingPolicy: ((ZTronEditingRequest) -> Bool)?
        var onClear: (() -> Bool)?
        var onTokenDelete: ((ZTronSearchToken<Schema>) -> Bool)?
        var textToToken: ((String) -> ZTronSearchToken<Schema>?)?
        /// Defaults to the record of the newest sampled iOS version.
        var behavior: Behavior = .newestSampled
        /// Selection events carry the text range, and a move of the caret alone is an event:
        /// from iOS 18, where the text selection is observable. Before that only a change of
        /// the token selection is.
        var reportsTextSelection = false
    }

    /// What one input did, for the view to act on.
    struct Outcome: Equatable {
        var events: [ZTronSearchFieldEvent] = []
        /// The typed text became a token: animate the insertion.
        var insertedToken = false
        /// The inner input must give up focus.
        var resignsFocus = false
        /// The Cancel button ran: call the host's cancel actions.
        var cancelled = false
        /// The selection changed: tell the host.
        var selectionChanged = false
        /// The inner input must take focus: the clear button, tapped while the field was not
        /// editing, begins editing where the reference does.
        var takesFocus = false
    }

    /// Sentinel plus text: what the inner input edits.
    private(set) var buffer: String
    /// The textual portion: what the text binding holds.
    private(set) var text: String
    private(set) var tokens: [ZTronSearchToken<Schema>]
    private(set) var selection: Set<UUID>
    private(set) var isEditing = false
    /// The selected range of the text, in UTF-16 units; empty at the caret.
    private(set) var textSelection: Range<Int> = 0..<0

    /// The selection the log last reported, in the positions of the reference's document:
    /// the tokens first, one position each, then the text in UTF-16 units. The reference
    /// reports a selection when it changes in those terms, so removing a token that precedes
    /// the caret is a selection change although the caret stays where it is in the text.
    private var reportedSelection: Range<Int>
    private var reportedTokens: [String] = []

    init(text: String = "", tokens: [ZTronSearchToken<Schema>] = [], selection: Set<UUID> = []) {
        self.text = text
        self.tokens = tokens
        self.selection = selection
        buffer = Self.sentinel + text
        reportedSelection = 0..<0
        reportedSelection = documentSelection
        reportedTokens = selectedLabels
    }

    /// Removes every sentinel from a string that came out of the inner input.
    static func strip(_ raw: String) -> String {
        guard raw.unicodeScalars.contains(sentinelScalar) else { return raw }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar != sentinelScalar { scalars.append(scalar) }
        return String(scalars)
    }

    /// Smart quotes and smart dashes are off, so identifiers survive typing: whatever the
    /// keyboard substitutes is put back.
    static func plain(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x2013 && $0.value <= 0x201D }) else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{2018}", "\u{2019}": result.append("'")
            case "\u{201C}", "\u{201D}": result.append("\"")
            case "\u{2014}": result.append("--")
            case "\u{2013}": result.append("-")
            default: result.append(character)
            }
        }
        return result
    }

    private var labels: [String] { tokens.map(\.text) }

    // MARK: Selection

    private var selectedIndices: [Int] {
        tokens.indices.filter { selection.contains(tokens[$0].id) }
    }

    private var selectedLabels: [String] {
        selectedIndices.map { tokens[$0].text }
    }

    /// The part of the selection that is text. With tokens selected that is nothing, unless
    /// the selection runs on from the last token into the text, as it does when the clear
    /// button selects everything.
    private var selectedTextRange: Range<Int> {
        guard let last = tokens.last, !selection.isEmpty else { return textSelection }
        guard selection.contains(last.id), textSelection.lowerBound == 0 else { return 0..<0 }
        return textSelection
    }

    /// The selection in document positions: the selected tokens, and the text selected with
    /// them, when there are any; else the selected range of the text.
    private var documentSelection: Range<Int> {
        let text = selectedTextRange
        let selected = selectedIndices
        if let first = selected.first, let last = selected.last { return first..<(last + 1 + text.count) }
        return (tokens.count + text.lowerBound)..<(tokens.count + text.upperBound)
    }

    /// The location of a token in the coordinates of the text: tokens come before the text,
    /// one position each, so the last token is at -1.
    private func location(ofTokenAt index: Int) -> Int {
        index - tokens.count
    }

    private mutating func placeCaret(at offset: Int) {
        let clamped = min(max(offset, 0), text.utf16.count)
        textSelection = clamped..<clamped
    }

    /// Logs the selection if it is not the one last logged. The reference only reports while
    /// it edits; what changes in between is reported when editing begins.
    private mutating func reportSelection(policies: Policies, into outcome: inout Outcome) {
        guard isEditing else { return }
        let current = documentSelection
        let currentTokens = selectedLabels
        defer {
            reportedSelection = current
            reportedTokens = currentTokens
        }
        if policies.reportsTextSelection {
            guard current != reportedSelection else { return }
            let text = selectedTextRange
            outcome.selectionChanged = true
            outcome.events.append(.didChangeSelection(tokens: currentTokens, textLocation: text.lowerBound, textLength: text.count))
        } else {
            guard currentTokens != reportedTokens else { return }
            outcome.selectionChanged = true
            outcome.events.append(.didChangeSelection(tokens: currentTokens, textLocation: nil, textLength: nil))
        }
    }

    /// The selection as the host is told about it.
    func hostSelection(policies: Policies) -> ZTronSearchSelection {
        guard policies.reportsTextSelection else { return ZTronSearchSelection(tokens: selection) }
        let text = selectedTextRange
        return ZTronSearchSelection(tokens: selection, textLocation: text.lowerBound, textLength: text.count)
    }

    // MARK: Bindings

    /// The host changed the bindings from outside.
    mutating func adopt(text newText: String, tokens newTokens: [ZTronSearchToken<Schema>], selection newSelection: Set<UUID>? = nil) {
        var changed = false
        if newText != text {
            text = newText
            buffer = Self.sentinel + newText
            // Text set in code leaves the caret at its start until the field is edited.
            placeCaret(at: isEditing ? textSelection.lowerBound : 0)
            changed = true
        }
        if newTokens != tokens {
            tokens = newTokens
            selection = selection.intersection(Set(newTokens.map(\.id)))
            changed = true
        }
        if let newSelection {
            let restricted = newSelection.intersection(Set(tokens.map(\.id)))
            if restricted != selection {
                selection = restricted
                changed = true
            }
        }
        if changed, !isEditing {
            // Nothing is reported while the field is not editing, and what the host set is
            // where the field starts from.
            reportedSelection = documentSelection
            reportedTokens = selectedLabels
        }
    }

    /// The inner input reports the selected range of its text (from iOS 18), in UTF-16 units
    /// of the textual portion.
    mutating func textSelectionChanged(to range: Range<Int>, policies: Policies) -> Outcome {
        var outcome = Outcome()
        let length = text.utf16.count
        let clamped = min(max(range.lowerBound, 0), length)..<min(max(range.upperBound, 0), length)
        // A selected token is the selection; the caret behind it is not reported.
        guard isEditing, selection.isEmpty, clamped != textSelection else { return outcome }
        textSelection = clamped
        reportSelection(policies: policies, into: &outcome)
        return outcome
    }

    // MARK: Text input

    /// The inner input now holds `raw`.
    mutating func inputChanged(to raw: String, policies: Policies) -> Outcome {
        var outcome = Outcome()
        let hasSentinel = raw.unicodeScalars.contains(Self.sentinelScalar)
        var proposed = Self.plain(Self.strip(raw))

        // Only the sentinel went away: a backspace at the start of the text.
        if !hasSentinel && proposed == text {
            buffer = Self.sentinel + text
            return deleteBackwardAtStart(policies: policies)
        }
        guard proposed != text else {
            // The sentinel moved (the user typed in front of it) or nothing changed at all.
            buffer = Self.sentinel + text
            return outcome
        }

        var change = ZTronTextChange.between(text, proposed)
        // The delete key with a token selected deletes the token, not the character before
        // the caret: in the reference the selection is the token, and the caret is nowhere.
        if !selection.isEmpty, change.replacement.isEmpty {
            buffer = Self.sentinel + text
            removeSelectedTokens(policies: policies, outcome: &outcome)
            return outcome
        }
        // Typing with a token selected: the reference gives the selection up for a caret at
        // the end of the text and types there, wherever the inner input had its own caret.
        if !selection.isEmpty, change.range.isEmpty, change.range.lowerBound != text.endIndex {
            change = ZTronTextChange(text: text, range: text.endIndex..<text.endIndex, replacement: change.replacement)
            proposed = change.proposedText
        }
        let allowed = policies.textInputPolicy?(change) ?? true
        let range = change.utf16Range
        let selected = selectedIndices
        if let first = selected.first, let last = selected.last {
            // Typing with a token selected: the reference proposes to replace the token's
            // range, which lies before the text.
            outcome.events.append(.shouldChange(
                location: location(ofTokenAt: first), length: last - first + 1, replacement: change.replacement, allowed: allowed
            ))
        } else {
            outcome.events.append(.shouldChange(location: range.location, length: range.length, replacement: change.replacement, allowed: allowed))
        }
        guard allowed else {
            // A denied change is reverted.
            buffer = Self.sentinel + text
            return outcome
        }

        // Where the reference replaces the selected token with what is typed, so does the
        // field; either way the selection collapses to a caret at the end of the text, which
        // the reference reports before it reports where the typing left it.
        if !selection.isEmpty {
            if policies.behavior.typingReplacesSelectedTokens {
                removeSelectedTokens(policies: policies, outcome: &outcome, logsChange: false)
            }
            selection = []
            placeCaret(at: text.utf16.count)
            reportSelection(policies: policies, into: &outcome)
        }

        text = proposed
        buffer = Self.sentinel + proposed
        placeCaret(at: range.location + change.replacement.utf16.count)
        reportSelection(policies: policies, into: &outcome)
        outcome.events.append(.editingChanged(text: proposed))
        convertTextToToken(policies: policies, outcome: &outcome)
        return outcome
    }

    /// Backspace at the start of the text selects the last token; a second backspace deletes it.
    ///
    /// The reference asks its delegate about both: `shouldChangeCharactersIn` with the range
    /// of the token, which lies before the text and so has a negative location.
    mutating func deleteBackwardAtStart(policies: Policies) -> Outcome {
        var outcome = Outcome()
        buffer = Self.sentinel + text
        if !selection.isEmpty {
            removeSelectedTokens(policies: policies, outcome: &outcome)
        } else if let last = tokens.last {
            outcome.events.append(.shouldChange(location: -1, length: 1, replacement: "", allowed: true))
            selection = [last.id]
            placeCaret(at: 0)
            reportSelection(policies: policies, into: &outcome)
        }
        return outcome
    }

    /// The hardware delete key with a token selected.
    mutating func deleteSelection(policies: Policies) -> Outcome {
        var outcome = Outcome()
        removeSelectedTokens(policies: policies, outcome: &outcome)
        return outcome
    }

    /// - Parameter logsChange: the removal is a change of its own (the delete key), which the
    ///   reference announces and follows with a text notification; `false` when it is part of
    ///   another change that does both.
    private mutating func removeSelectedTokens(policies: Policies, outcome: inout Outcome, logsChange: Bool = true) {
        let selected = selectedIndices
        guard let first = selected.first, let last = selected.last else { return }
        if logsChange {
            outcome.events.append(.shouldChange(location: location(ofTokenAt: first), length: last - first + 1, replacement: "", allowed: true))
        }
        // With deletion off the reference still asks, and then leaves the token selected.
        guard policies.deletion == .enabled else { return }
        var removed = false
        tokens.removeAll { token in
            guard selection.contains(token.id), policies.onTokenDelete?(token) ?? true else { return false }
            removed = true
            return true
        }
        guard removed else { return }
        selection = selection.intersection(Set(tokens.map(\.id)))
        outcome.events.append(.tokensChanged(labels))
        if logsChange {
            // The caret is left where the token was: at the start of the text.
            if selection.isEmpty { placeCaret(at: 0) }
            reportSelection(policies: policies, into: &outcome)
            outcome.events.append(.editingChanged(text: text))
        }
    }

    /// A returned token replaces the textual portion. Where the reference leaves the new token
    /// selected, so does the field. The reference sends no text notification for it: the host
    /// replaced the text in code.
    private mutating func convertTextToToken(policies: Policies, outcome: inout Outcome) {
        guard !text.isEmpty, let token = policies.textToToken?(text) else { return }
        tokens.append(token)
        text = ""
        buffer = Self.sentinel
        placeCaret(at: 0)
        outcome.insertedToken = true
        outcome.events.append(.tokensChanged(labels))
        if policies.behavior.conversionSelectsToken { selection = [token.id] }
        reportSelection(policies: policies, into: &outcome)
    }

    // MARK: Tokens

    /// Tap selects a token.
    mutating func tapToken(_ id: UUID, policies: Policies = Policies()) -> Outcome {
        var outcome = Outcome()
        guard tokens.contains(where: { $0.id == id }), selection != [id] else { return outcome }
        selection = [id]
        placeCaret(at: 0)
        reportSelection(policies: policies, into: &outcome)
        if !isEditing { outcome.selectionChanged = true }
        return outcome
    }

    /// Tapping elsewhere deselects, and leaves the caret at the end of the text. With no
    /// token selected there is nothing to do: the inner input places its own caret.
    mutating func deselect(policies: Policies = Policies()) -> Outcome {
        var outcome = Outcome()
        guard !selection.isEmpty else { return outcome }
        selection = []
        if isEditing { placeCaret(at: text.utf16.count) }
        reportSelection(policies: policies, into: &outcome)
        if !isEditing { outcome.selectionChanged = true }
        return outcome
    }

    /// Removes one token at the host's request, under the same deletion rules as the delete key.
    mutating func delete(_ id: UUID, policies: Policies) -> Outcome {
        var outcome = Outcome()
        guard policies.deletion == .enabled, let token = tokens.first(where: { $0.id == id }),
              policies.onTokenDelete?(token) ?? true else { return outcome }
        tokens.removeAll { $0.id == id }
        outcome.events.append(.tokensChanged(labels))
        if selection.remove(id) != nil, !isEditing { outcome.selectionChanged = true }
        reportSelection(policies: policies, into: &outcome)
        return outcome
    }

    // MARK: Buttons and keys

    /// The clear button.
    ///
    /// The reference clears by selecting everything and deleting the selection, so its log
    /// shows the tokens selected, then gone; a token that was selected is deselected first;
    /// it always sends the text notification, even when there was no text; and, tapped while
    /// the field is not editing, the button begins editing.
    mutating func clear(policies: Policies) -> Outcome {
        var outcome = Outcome()
        let allowed = policies.onClear?() ?? true
        outcome.events.append(.shouldClear(allowed: allowed))
        guard allowed else { return outcome }
        let hadSelection = !selection.isEmpty
        if hadSelection {
            selection = []
            placeCaret(at: text.utf16.count)
            reportSelection(policies: policies, into: &outcome)
        }
        if policies.behavior.clearRemovesTokens {
            selection = Set(tokens.map(\.id))
            textSelection = 0..<text.utf16.count
            reportSelection(policies: policies, into: &outcome)
            if !tokens.isEmpty {
                tokens = []
                outcome.events.append(.tokensChanged([]))
            }
            selection = []
        } else {
            selection = []
            textSelection = 0..<text.utf16.count
            reportSelection(policies: policies, into: &outcome)
        }
        text = ""
        buffer = Self.sentinel
        placeCaret(at: 0)
        reportSelection(policies: policies, into: &outcome)
        if hadSelection, !isEditing { outcome.selectionChanged = true }
        outcome.events.append(.editingChanged(text: ""))
        outcome.takesFocus = !isEditing && policies.behavior.clearBeginsEditing
        return outcome
    }

    /// The Cancel button: clears text and tokens and drops focus. A host clears a search bar
    /// in code, which sends no text notification.
    mutating func cancel(policies: Policies = Policies()) -> Outcome {
        var outcome = Outcome()
        outcome.events.append(.cancelButtonClicked)
        let hadSelection = !selection.isEmpty
        selection = []
        if !tokens.isEmpty {
            tokens = []
            outcome.events.append(.tokensChanged([]))
            reportSelection(policies: policies, into: &outcome)
        }
        text = ""
        buffer = Self.sentinel
        placeCaret(at: 0)
        reportSelection(policies: policies, into: &outcome)
        if hadSelection { outcome.selectionChanged = true }
        outcome.resignsFocus = true
        outcome.cancelled = true
        return outcome
    }

    /// The search key.
    mutating func submit(policies: Policies) -> Outcome {
        var outcome = Outcome()
        outcome.events.append(.shouldReturn)
        convertTextToToken(policies: policies, outcome: &outcome)
        outcome.events.append(.editingDidEndOnExit)
        return outcome
    }

    // MARK: Editing

    /// Whether the field may begin editing. Asked before the inner input is enabled, so a
    /// denial shows no focus flicker.
    func mayBeginEditing(policies: Policies) -> (allowed: Bool, event: ZTronSearchFieldEvent) {
        let allowed = policies.editingPolicy?(.begin) ?? true
        return (allowed, .shouldBeginEditing(allowed: allowed))
    }

    /// Focus arrived at, or left, the inner input.
    mutating func focusChanged(to focused: Bool, policies: Policies) -> (outcome: Outcome, keepsFocus: Bool) {
        var outcome = Outcome()
        guard focused != isEditing else { return (outcome, false) }
        if focused {
            isEditing = true
            // Editing begins with the caret at the end of the text; the reference reports the
            // selection, if that moved it, before it reports that editing began.
            if selection.isEmpty { placeCaret(at: text.utf16.count) }
            reportSelection(policies: policies, into: &outcome)
            outcome.events.append(.didBeginEditing)
            return (outcome, false)
        }
        let allowed = policies.editingPolicy?(.end) ?? true
        outcome.events.append(.shouldEndEditing(allowed: allowed))
        guard allowed else { return (outcome, true) }
        isEditing = false
        if !selection.isEmpty {
            selection = []
            outcome.selectionChanged = true
        }
        outcome.events.append(.didEndEditing)
        return (outcome, false)
    }
}

/// The search field's built-in strings, localized in `Bundle.module`.
public enum ZTronSearchStrings {
    /// The default prompt.
    public static var search: String { localized("Search") }
    public static var cancel: String { localized("Cancel") }
    public static var clear: String { localized("Clear") }
    /// For the host's activity indicator.
    public static var searching: String { localized("Searching") }
    /// For the host's empty state.
    public static var noResults: String { localized("No results") }
    static var delete: String { localized("Delete") }
    static var copy: String { localized("Copy") }

    private static func localized(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }
}
