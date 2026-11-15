import Foundation

public struct EventLogComparison: Codable, Sendable {
    /// The two logs as recorded.
    public var reference: [ParityEvent]
    public var clone: [ParityEvent]
    /// The two logs as compared, after the tolerated deviations were applied.
    public var comparedReference: [ParityEvent]
    public var comparedClone: [ParityEvent]
    /// Index of the first entry at which the compared logs part; `nil` when they are identical.
    public var firstDifference: Int?
    /// Which tolerated deviations of specification 12.5 changed either log, and by how much.
    public var appliedDeviations: [String]
    /// The clone's log carries the zero-width sentinel somewhere.
    public var sentinelLeaked: Bool
    public var passes: Bool
}

/// Event log comparison: identical order and payloads (specification section 15.7), after the
/// only two adjustments section 12.5 allows.
///
/// 1. **Text selection.** UIKit reports every move of the caret through
///    `textFieldDidChangeSelection`; the clone can observe text selection only from iOS 18.
///    Below iOS 18 both logs are therefore reduced to changes of the *token* selection: the
///    text range is dropped from every selection entry, and an entry that leaves the set of
///    selected tokens as it was is removed.
/// 2. **The reverted change.** The clone enforces `textInputPolicy` by reverting a denied
///    change, which costs one extra text notification: an `editingChanged` directly after a
///    denied `shouldChange` in the clone's log is dropped.
///
/// Nothing else is filtered, reordered or rewritten.
public enum EventLogComparator {
    /// - Parameter comparesTextSelection: `true` from iOS 18, where the clone must report the
    ///   text range of a selection as the reference does.
    public static func compare(reference: [ParityEvent], clone: [ParityEvent], comparesTextSelection: Bool) -> EventLogComparison {
        var applied: [String] = []
        var comparedReference = reference
        var comparedClone = clone

        let withoutRevert = droppingRevertNotifications(comparedClone)
        if withoutRevert.count != comparedClone.count {
            applied.append("12.5 textInputPolicy: dropped \(comparedClone.count - withoutRevert.count) extra text notification(s) from the clone's log")
            comparedClone = withoutRevert
        }
        if !comparesTextSelection {
            let reducedReference = reducedToTokenSelection(comparedReference)
            let reducedClone = reducedToTokenSelection(comparedClone)
            if reducedReference != comparedReference || reducedClone != comparedClone {
                applied.append(
                    "12.5 text selection: reduced selection entries to token-selection changes "
                        + "(reference \(comparedReference.count) -> \(reducedReference.count) entries, "
                        + "clone \(comparedClone.count) -> \(reducedClone.count))"
                )
            }
            comparedReference = reducedReference
            comparedClone = reducedClone
        }

        var firstDifference: Int?
        if comparedReference != comparedClone {
            let common = min(comparedReference.count, comparedClone.count)
            firstDifference = (0..<common).first { comparedReference[$0] != comparedClone[$0] } ?? common
        }
        let leaked = clone.contains(where: \.containsSentinel)
        return EventLogComparison(
            reference: reference, clone: clone, comparedReference: comparedReference, comparedClone: comparedClone,
            firstDifference: firstDifference, appliedDeviations: applied, sentinelLeaked: leaked,
            passes: firstDifference == nil && !leaked
        )
    }

    /// Selection entries without their text range, and only where the token selection changes.
    static func reducedToTokenSelection(_ log: [ParityEvent]) -> [ParityEvent] {
        var result: [ParityEvent] = []
        var selected: [String] = []
        for event in log {
            guard case .didChangeSelection(let tokens, _, _) = event else {
                result.append(event)
                continue
            }
            guard tokens != selected else { continue }
            selected = tokens
            result.append(.didChangeSelection(tokens: tokens, textLocation: nil, textLength: nil))
        }
        return result
    }

    /// The clone's log without the notification a reverted change costs.
    static func droppingRevertNotifications(_ log: [ParityEvent]) -> [ParityEvent] {
        var result: [ParityEvent] = []
        var afterDenial = false
        for event in log {
            if afterDenial, case .editingChanged = event {
                afterDenial = false
                continue
            }
            if case .shouldChange(_, _, _, let allowed) = event {
                afterDenial = !allowed
            } else {
                afterDenial = false
            }
            result.append(event)
        }
        return result
    }
}
