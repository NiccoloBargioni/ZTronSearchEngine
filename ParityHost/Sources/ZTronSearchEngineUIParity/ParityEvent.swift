import Foundation
import ZTronSearchEngineUI

/// One entry of a parity log: the codable mirror of `ZTronSearchFieldEvent`, case for case.
///
/// The clone reports `ZTronSearchFieldEvent` through `onSearchFieldEvent`; the reference's
/// delegate callbacks and control events are translated into the same cases
/// (specification section 12.3), so the two logs can be compared entry by entry.
public enum ParityEvent: Codable, Hashable, Sendable, CustomStringConvertible {
    case shouldBeginEditing(allowed: Bool)
    case didBeginEditing
    case shouldEndEditing(allowed: Bool)
    case didEndEditing
    case shouldChange(location: Int, length: Int, replacement: String, allowed: Bool)
    case editingChanged(text: String)
    case didChangeSelection(tokens: [String], textLocation: Int?, textLength: Int?)
    case shouldClear(allowed: Bool)
    case shouldReturn
    case editingDidEndOnExit
    case tokensChanged([String])
    case cancelButtonClicked

    public init(_ event: ZTronSearchFieldEvent) {
        switch event {
        case .shouldBeginEditing(let allowed): self = .shouldBeginEditing(allowed: allowed)
        case .didBeginEditing: self = .didBeginEditing
        case .shouldEndEditing(let allowed): self = .shouldEndEditing(allowed: allowed)
        case .didEndEditing: self = .didEndEditing
        case .shouldChange(let location, let length, let replacement, let allowed):
            self = .shouldChange(location: location, length: length, replacement: replacement, allowed: allowed)
        case .editingChanged(let text): self = .editingChanged(text: text)
        case .didChangeSelection(let tokens, let textLocation, let textLength):
            self = .didChangeSelection(tokens: tokens, textLocation: textLocation, textLength: textLength)
        case .shouldClear(let allowed): self = .shouldClear(allowed: allowed)
        case .shouldReturn: self = .shouldReturn
        case .editingDidEndOnExit: self = .editingDidEndOnExit
        case .tokensChanged(let labels): self = .tokensChanged(labels)
        case .cancelButtonClicked: self = .cancelButtonClicked
        }
    }

    /// One line per event, the form the result files and the failure messages use.
    public var description: String {
        switch self {
        case .shouldBeginEditing(let allowed): return "shouldBeginEditing(\(allowed))"
        case .didBeginEditing: return "didBeginEditing"
        case .shouldEndEditing(let allowed): return "shouldEndEditing(\(allowed))"
        case .didEndEditing: return "didEndEditing"
        case .shouldChange(let location, let length, let replacement, let allowed):
            return "shouldChange(\(location), \(length), \(Self.quoted(replacement)), \(allowed))"
        case .editingChanged(let text): return "editingChanged(\(Self.quoted(text)))"
        case .didChangeSelection(let tokens, let textLocation, let textLength):
            let text = textLocation.map { "\($0)+\(textLength ?? 0)" } ?? "-"
            return "didChangeSelection(tokens: \(tokens), text: \(text))"
        case .shouldClear(let allowed): return "shouldClear(\(allowed))"
        case .shouldReturn: return "shouldReturn"
        case .editingDidEndOnExit: return "editingDidEndOnExit"
        case .tokensChanged(let labels): return "tokensChanged(\(labels))"
        case .cancelButtonClicked: return "cancelButtonClicked"
        }
    }

    /// A string literal with every non-ASCII scalar escaped, so that an invisible character
    /// (the sentinel above all) shows up in a log.
    public static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            default:
                if scalar.isASCII, scalar.value >= 0x20 {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                }
            }
        }
        return result + "\""
    }

    /// Whether any payload of the event carries the clone's zero-width sentinel (U+200B).
    public var containsSentinel: Bool {
        func leaks(_ text: String) -> Bool { text.unicodeScalars.contains("\u{200B}") }
        switch self {
        case .shouldChange(_, _, let replacement, _): return leaks(replacement)
        case .editingChanged(let text): return leaks(text)
        case .didChangeSelection(let tokens, _, _): return tokens.contains(where: leaks)
        case .tokensChanged(let labels): return labels.contains(where: leaks)
        default: return false
        }
    }
}
