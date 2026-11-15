import Foundation

/// One elementary user action whose log the sampler records from the UIKit reference: a
/// starting state and the few steps that make up the action.
public struct ElementaryAction: Sendable {
    public var name: String
    public var setup: FieldSetup
    public var steps: [ScriptStep]

    public init(_ name: String, _ setup: FieldSetup, _ steps: [ScriptStep]) {
        self.name = name
        self.setup = setup
        self.steps = steps
    }
}

/// The elementary actions of the behavior profile (`behavior.eventProfile` in
/// `Samples/ios-<major>.json`): what the reference logs, and what state it is left in, for
/// each thing a user can do to the field. The clone's core is written against these records,
/// and the sampler records the clone's log of the same actions next to them.
public enum BehaviorProfile {
    static let maps = ParityTokenSpec("Maps", symbol: "map")
    static let tips = ParityTokenSpec("Tips")

    public static let actions: [ElementaryAction] = [
        ElementaryAction("focus-by-tap", FieldSetup(), [.tapField]),
        ElementaryAction("focus-by-tap-with-text", FieldSetup(text: "harbor"), [.tapField]),
        ElementaryAction("focus-again-with-text", FieldSetup(text: "harbor"), [.tapField, .setFocus(false), .tapField]),
        ElementaryAction("type", FieldSetup(tokens: [maps]), [.tapField, .type("ab")]),
        ElementaryAction("delete-text", FieldSetup(text: "ab"), [.tapField, .backspace]),
        ElementaryAction("backspace-in-empty-field", FieldSetup(), [.tapField, .backspace]),
        ElementaryAction("backspace-selects-last-token", FieldSetup(tokens: [maps, tips]), [.tapField, .backspace]),
        ElementaryAction("backspace-deletes-selected-token", FieldSetup(tokens: [maps, tips]), [.tapField, .backspace, .backspace]),
        ElementaryAction("backspace-with-deletion-disabled", FieldSetup(tokens: [maps], allowsDeletingTokens: false), [.tapField, .backspace, .backspace]),
        ElementaryAction("backspace-through-text-and-token", FieldSetup(text: "a", tokens: [maps]), [.tapField, .backspace, .backspace, .backspace]),
        ElementaryAction("tap-token-while-editing", FieldSetup(tokens: [maps, tips]), [.tapField, .tapToken(0)]),
        ElementaryAction("tap-token-while-not-editing", FieldSetup(tokens: [maps, tips]), [.tapToken(0)]),
        ElementaryAction("tap-token-after-typing", FieldSetup(tokens: [maps]), [.tapField, .type("ab"), .tapToken(0)]),
        ElementaryAction("tap-token-trailing-half", FieldSetup(tokens: [maps, tips]), [.tapField, .tapTokenTrailingHalf(0)]),
        ElementaryAction("tap-token-trailing-half-while-not-editing", FieldSetup(tokens: [maps, tips]), [.tapTokenTrailingHalf(0)]),
        ElementaryAction("tap-field-deselects", FieldSetup(tokens: [maps, tips]), [.tapField, .tapToken(0), .tapField]),
        ElementaryAction("tap-field-deselects-before-text", FieldSetup(text: "ab", tokens: [maps]), [.tapField, .tapToken(0), .tapField]),
        ElementaryAction("tap-text-deselects", FieldSetup(text: "harbor", tokens: [maps]), [.tapField, .tapToken(0), .tapText]),
        ElementaryAction("delete-tapped-first-token", FieldSetup(tokens: [maps, tips]), [.tapField, .tapToken(0), .backspace]),
        ElementaryAction("delete-tapped-token-before-text", FieldSetup(text: "ab", tokens: [maps]), [.tapField, .tapToken(0), .backspace]),
        ElementaryAction("type-over-selected-token", FieldSetup(tokens: [maps, tips]), [.tapField, .tapToken(0), .type("x")]),
        ElementaryAction("type-over-selected-token-before-text", FieldSetup(text: "ab", tokens: [maps]), [.tapField, .tapToken(0), .type("xy")]),
        ElementaryAction("clear-while-editing", FieldSetup(text: "harbor", tokens: [maps]), [.tapField, .tapClear]),
        ElementaryAction("clear-text-only", FieldSetup(text: "harbor"), [.tapField, .tapClear]),
        ElementaryAction("clear-while-not-editing", FieldSetup(text: "harbor", tokens: [maps]), [.tapClear]),
        ElementaryAction("clear-with-selected-token", FieldSetup(tokens: [maps, tips]), [.tapField, .tapToken(0), .tapClear]),
        ElementaryAction("submit", FieldSetup(text: "map"), [.tapField, .submit]),
        ElementaryAction("text-to-token", FieldSetup(tokenSuffix: " "), [.tapField, .type("ab ")]),
        ElementaryAction("type-after-conversion", FieldSetup(tokenSuffix: " "), [.tapField, .type("ab "), .type("x")]),
        ElementaryAction("backspace-after-conversion", FieldSetup(tokenSuffix: " "), [.tapField, .type("ab "), .backspace]),
        ElementaryAction("blur-with-selected-token", FieldSetup(tokens: [maps]), [.tapField, .tapToken(0), .setFocus(false)]),
        ElementaryAction("cancel", FieldSetup(text: "ab", tokens: [maps], cancelButton: true), [.tapField, .settle(0.5), .tapCancel, .settle(0.5)]),
    ]

    public static func action(named name: String) -> ElementaryAction? {
        actions.first { $0.name == name }
    }
}
