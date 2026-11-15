import Foundation

/// What a script asks both fields to be before its first step: the same state and the same
/// configuration, expressed once and applied to the UIKit reference and to the SwiftUI clone.
public struct FieldSetup: Codable, Hashable, Sendable {
    /// The placeholder. Both fields get the same string, so the comparison never depends on
    /// either side's localization of a default.
    public var prompt: String = "Search"
    public var text: String = ""
    public var tokens: [ParityTokenSpec] = []
    /// The Cancel button shows while editing: `UISearchBar` with the usual delegate code on the
    /// reference, `.searchCancelButton(.automatic)` on the clone. Off for every script but the
    /// cancel one, so that a difference in the button never hides a difference in the field.
    public var cancelButton = false
    /// Typed text that ends with this suffix becomes a token labelled with what precedes it
    /// (`replaceTextualPortion(of:with:at:)` on the reference, `.textToToken` on the clone).
    public var tokenSuffix: String?
    /// `allowsDeletingTokens` / `.tokenDeletion`.
    public var allowsDeletingTokens = true

    public init(
        prompt: String = "Search", text: String = "", tokens: [ParityTokenSpec] = [], cancelButton: Bool = false,
        tokenSuffix: String? = nil, allowsDeletingTokens: Bool = true
    ) {
        self.prompt = prompt
        self.text = text
        self.tokens = tokens
        self.cancelButton = cancelButton
        self.tokenSuffix = tokenSuffix
        self.allowsDeletingTokens = allowsDeletingTokens
    }

    /// The label of the token `typed` turns into, if the rule applies.
    public func tokenLabel(for typed: String) -> String? {
        guard let tokenSuffix, typed.hasSuffix(tokenSuffix), typed.count > tokenSuffix.count else { return nil }
        return String(typed.dropLast(tokenSuffix.count))
    }
}
