import Foundation

/// One entry of a scenario script: a user action, or a point at which both fields are
/// captured and compared.
public enum ScriptAction: Codable, Hashable, Sendable {
    case step(ScriptStep)
    case checkpoint(String)
}

/// The scenario scripts of the parity matrix (specification section 12.5), shared by the UIKit
/// reference and the SwiftUI clone: the same setup and the same actions drive both.
public enum ParityScript: String, Codable, CaseIterable, Sendable {
    case type
    case backspaceSelect = "backspace-select"
    case backspaceDelete = "backspace-delete"
    case tapSelect = "tap-select"
    case clear
    case submit
    case cancel
    case textToToken = "text-to-token"
    case tokenOverflow = "token-overflow"
    case focusRoundTrip = "focus-round-trip"

    static let maps = ParityTokenSpec("Maps", symbol: "map")
    static let tips = ParityTokenSpec("Tips")
    /// More tokens than any phone-sized field shows at once.
    static let many: [ParityTokenSpec] = [
        ParityTokenSpec("Maps", symbol: "map"), ParityTokenSpec("Tips"), ParityTokenSpec("Tools", symbol: "wrench"),
        ParityTokenSpec("Guides"), ParityTokenSpec("Calculators", symbol: "function"), ParityTokenSpec("Trackers"),
        ParityTokenSpec("Galleries", symbol: "photo"), ParityTokenSpec("Harbor"), ParityTokenSpec("Outbreak", symbol: "flame"),
        ParityTokenSpec("Lanterns"), ParityTokenSpec("Shortcuts", symbol: "bolt"), ParityTokenSpec("Protocols"),
    ]

    /// The state both fields start in.
    public var setup: FieldSetup {
        switch self {
        case .type: return FieldSetup(tokens: [Self.maps])
        case .backspaceSelect, .backspaceDelete, .tapSelect: return FieldSetup(tokens: [Self.maps, Self.tips])
        case .clear: return FieldSetup(text: "harbor", tokens: [Self.maps])
        case .submit: return FieldSetup()
        case .cancel: return FieldSetup(tokens: [Self.maps], cancelButton: true)
        case .textToToken: return FieldSetup(tokenSuffix: " ")
        case .tokenOverflow: return FieldSetup(tokens: Self.many)
        case .focusRoundTrip: return FieldSetup()
        }
    }

    /// What the user does, and where the two fields are compared. Every script is also
    /// compared in its initial state, before the first action.
    public var actions: [ScriptAction] {
        switch self {
        case .type:
            return [.step(.tapField), .checkpoint("focused"), .step(.type("map")), .checkpoint("typed")]
        case .backspaceSelect:
            return [.step(.tapField), .step(.backspace), .checkpoint("selected")]
        case .backspaceDelete:
            return [.step(.tapField), .step(.backspace), .step(.backspace), .checkpoint("deleted")]
        case .tapSelect:
            return [
                .step(.tapField), .step(.tapToken(0)), .checkpoint("selected"),
                .step(.tapField), .checkpoint("deselected"),
            ]
        case .clear:
            return [.step(.tapField), .checkpoint("editing"), .step(.tapClear), .checkpoint("cleared")]
        case .submit:
            return [.step(.tapField), .step(.type("map")), .step(.submit), .checkpoint("submitted")]
        case .cancel:
            return [
                .step(.tapField), .step(.type("map")), .step(.settle(0.6)), .checkpoint("editing"),
                .step(.tapCancel), .step(.settle(0.6)), .checkpoint("cancelled"),
            ]
        case .textToToken:
            return [
                .step(.tapField), .step(.type("map")), .checkpoint("typed"),
                .step(.watchAnimation(3)), .step(.type(" ")), .step(.settle(0.6)), .checkpoint("converted"),
            ]
        case .tokenOverflow:
            return [
                .step(.setFocus(true)), .step(.settle(0.4)), .checkpoint("focused"),
                .step(.type("x")), .checkpoint("typed"),
            ]
        case .focusRoundTrip:
            return [
                .step(.setFocus(true)), .checkpoint("focused"),
                .step(.setFocus(false)), .checkpoint("blurred"),
            ]
        }
    }
}

/// How the keys of a script reach the field.
public enum ParityInput: String, Codable, CaseIterable, Sendable {
    /// Taps on the keys of the on-screen keyboard.
    case software
    /// Key events of a hardware keyboard.
    case hardware
}
