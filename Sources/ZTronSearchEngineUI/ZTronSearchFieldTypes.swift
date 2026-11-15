import SwiftUI
import ZTronSearchEngine

// Value types of the search field's modifiers (specification sections 12.1 and 12.3). Package
// enums wrap the SwiftUI modifiers whose parameters are platform enums, so hosts never see one.

public enum ZTronSearchFieldStyle: Sendable, Hashable {
    /// The rounded, filled field of the system search bar. The default.
    case native
    /// No background and no insets: the host draws the chrome.
    case plain
}

/// When the clear button shows.
public enum ZTronClearButtonMode: Sendable, Hashable {
    case never
    /// The default.
    case whileEditing
    case unlessEditing
    case always
}

public enum ZTronCancelButtonMode: Sendable, Hashable {
    /// While editing, as the system search bar does.
    case automatic
    case never
}

/// Whether the user may delete tokens.
public enum ZTronTokenDeletionPolicy: Sendable, Hashable {
    /// The default.
    case enabled
    case disabled
}

/// Whether tokens may be copied.
public enum ZTronTokenCopyingPolicy: Sendable, Hashable {
    /// The default.
    case disabled
    case enabled
}

/// The keyboard the field asks for.
public enum ZTronKeyboard: Sendable, Hashable {
    case `default`
    case asciiCapable
    case numbersAndPunctuation
    case url
    case numberPad
    case phonePad
    case namePhonePad
    case emailAddress
    case decimalPad
    case twitter
    case webSearch
    case asciiCapableNumberPad
}

/// What the field is used for, so the system can offer the right suggestions.
public enum ZTronTextContent: Sendable, Hashable {
    case none
    case name
    case emailAddress
    case url
    case location
    case organizationName
}

public enum ZTronEditingRequest: Sendable, Hashable {
    case begin
    case end
}

/// A proposed change of the textual portion, before it is applied.
public struct ZTronTextChange: Sendable, Hashable {
    /// The text before the change.
    public let text: String
    /// The part of `text` being replaced.
    public let range: Range<String.Index>
    /// What replaces it.
    public let replacement: String

    public init(text: String, range: Range<String.Index>, replacement: String) {
        self.text = text
        self.range = range
        self.replacement = replacement
    }

    /// The text after the change.
    public var proposedText: String {
        text.replacingCharacters(in: range, with: replacement)
    }

    /// UTF-16 location and length of ``range``: the numbers a text-field delegate reports.
    public var utf16Range: (location: Int, length: Int) {
        let location = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
        return (location, text.utf16.distance(from: range.lowerBound, to: range.upperBound))
    }

    /// The smallest change that turns `old` into `new`: what was typed, pasted or deleted.
    public static func between(_ old: String, _ new: String) -> ZTronTextChange {
        let before = Array(old)
        let after = Array(new)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let lower = old.index(old.startIndex, offsetBy: prefix)
        let upper = old.index(old.endIndex, offsetBy: -suffix)
        return ZTronTextChange(text: old, range: lower..<upper, replacement: String(after[prefix..<(after.count - suffix)]))
    }
}

/// What is selected in the field.
///
/// Token selection is reported on every iOS; text selection only from iOS 18.
public struct ZTronSearchSelection: Sendable, Hashable {
    /// Ids of the selected tokens.
    public var tokens: Set<UUID>
    /// UTF-16 location and length of the selected text; `nil` where the system does not report it.
    public var textLocation: Int?
    public var textLength: Int?

    public init(tokens: Set<UUID> = [], textLocation: Int? = nil, textLength: Int? = nil) {
        self.tokens = tokens
        self.textLocation = textLocation
        self.textLength = textLength
    }
}

/// Every event of the field, in order: the parity log (section 12.3).
///
/// One case per UIKit delegate callback or control event, with the same payloads, so the log of
/// the clone can be compared with the delegate log of the reference.
public enum ZTronSearchFieldEvent: Sendable, Hashable {
    /// `textFieldShouldBeginEditing`.
    case shouldBeginEditing(allowed: Bool)
    /// `textFieldDidBeginEditing`.
    case didBeginEditing
    /// `textFieldShouldEndEditing`.
    case shouldEndEditing(allowed: Bool)
    /// `textFieldDidEndEditing`.
    case didEndEditing
    /// `textField(_:shouldChangeCharactersIn:replacementString:)`, with a UTF-16 range.
    case shouldChange(location: Int, length: Int, replacement: String, allowed: Bool)
    /// The `editingChanged` control event and `textDidChangeNotification`.
    case editingChanged(text: String)
    /// `textFieldDidChangeSelection`: the labels of the selected tokens, and the text range when known.
    case didChangeSelection(tokens: [String], textLocation: Int?, textLength: Int?)
    /// `textFieldShouldClear`.
    case shouldClear(allowed: Bool)
    /// `textFieldShouldReturn`.
    case shouldReturn
    /// The `editingDidEndOnExit` control event.
    case editingDidEndOnExit
    /// A mutation of `tokens` by the user: the labels now in the field, in order.
    case tokensChanged([String])
    /// The search bar's Cancel button.
    case cancelButtonClicked
}
