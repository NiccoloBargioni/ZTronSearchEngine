import Foundation

public struct AccessibilityComparison: Codable, Sendable {
    /// The nodes that were compared, one line each.
    public var reference: [String]
    public var clone: [String]
    /// One line per difference: which node, which property, the two values.
    public var differences: [String]
    public var passes: Bool
}

/// Accessibility tree comparison: labels, values, traits and custom actions identical
/// (specification section 15.7).
///
/// The trees are the ones the accessibility runtime hands to a client, read through XCUITest:
/// what an assistive technology gets, not what either framework's objects say about
/// themselves in process. Traits are compared as that runtime resolves them: the element type
/// (search field, button, image, static text, other), selected, and enabled. Custom actions
/// are read in process and matched to the nodes by frame.
///
/// Nodes are compared in the order the runtime lists them. A container with no label, value,
/// placeholder or identifier says nothing to a user and is skipped on both sides; nesting
/// depth and frames are recorded in the result but not compared. Buttons, images, links and
/// static texts are leaves (the driver does not descend into them): an assistive technology
/// lands on the button, not on whatever a toolkit builds it from.
public enum AccessibilityComparator {
    public static func compare(reference: [AccessibilityNode], clone: [AccessibilityNode]) -> AccessibilityComparison {
        let first = reference.filter(\.hasContent)
        let second = clone.filter(\.hasContent)
        var differences: [String] = []
        if first.count != second.count {
            differences.append("node count: reference \(first.count), clone \(second.count)")
        }
        for index in 0..<min(first.count, second.count) {
            let a = first[index], b = second[index]
            func check(_ property: String, _ x: String, _ y: String) {
                if x != y { differences.append("node \(index) \(property): reference \(x), clone \(y)") }
            }
            check("type", a.type, b.type)
            check("label", ParityEvent.quoted(a.label), ParityEvent.quoted(b.label))
            check("value", a.value.map(ParityEvent.quoted) ?? "nil", b.value.map(ParityEvent.quoted) ?? "nil")
            check("placeholder", a.placeholder.map(ParityEvent.quoted) ?? "nil", b.placeholder.map(ParityEvent.quoted) ?? "nil")
            check("identifier", ParityEvent.quoted(a.identifier), ParityEvent.quoted(b.identifier))
            check("selected", "\(a.isSelected)", "\(b.isSelected)")
            check("enabled", "\(a.isEnabled)", "\(b.isEnabled)")
            check("custom actions", "\(a.actions)", "\(b.actions)")
        }
        for extra in first.dropFirst(second.count) { differences.append("reference only: \(describe(extra))") }
        for extra in second.dropFirst(first.count) { differences.append("clone only: \(describe(extra))") }
        return AccessibilityComparison(
            reference: first.map(describe), clone: second.map(describe), differences: differences, passes: differences.isEmpty
        )
    }

    static func describe(_ node: AccessibilityNode) -> String {
        var parts = ["\(node.type) label=\(ParityEvent.quoted(node.label))"]
        if let value = node.value { parts.append("value=\(ParityEvent.quoted(value))") }
        if let placeholder = node.placeholder { parts.append("placeholder=\(ParityEvent.quoted(placeholder))") }
        if !node.identifier.isEmpty { parts.append("identifier=\(ParityEvent.quoted(node.identifier))") }
        if node.isSelected { parts.append("selected") }
        if !node.isEnabled { parts.append("disabled") }
        if !node.actions.isEmpty { parts.append("actions=\(node.actions)") }
        return parts.joined(separator: " ")
    }
}
