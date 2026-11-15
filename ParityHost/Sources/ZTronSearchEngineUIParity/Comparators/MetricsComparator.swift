import Foundation

/// The layout of one field at one moment: named frames and named lengths, in points, in the
/// coordinate space of the field's slot.
///
/// Frames: `field` (the rounded background), `glyph`, `token.<n>`, `clearButton`,
/// `cancelButton`. Lengths: `baseline` (the first baseline of the text, from the top of the
/// slot).
public struct LayoutMetrics: Codable, Hashable, Sendable {
    public var frames: [String: RectValue]
    public var lengths: [String: Double]

    public init(frames: [String: RectValue] = [:], lengths: [String: Double] = [:]) {
        self.frames = frames
        self.lengths = lengths
    }
}

/// One measured difference between the reference's layout and the clone's.
public struct MetricDeviation: Codable, Hashable, Sendable {
    /// `glyph.x`, `token.0.width`, `baseline`, ...
    public var name: String
    public var reference: Double?
    public var clone: Double?
    /// Absolute difference in points; `nil` when one side has no such element at all.
    public var deviation: Double?
}

public struct MetricsComparison: Codable, Sendable {
    /// The largest deviation, in points; 0 when the layouts hold the same elements at the
    /// same places.
    public var worstDeviation: Double
    public var worstName: String?
    /// Elements that only one of the two fields has.
    public var missing: [String]
    /// Every value that deviates by more than the tolerance, worst first.
    public var failures: [MetricDeviation]
    public var comparedValues: Int
    public var passes: Bool
}

/// Layout metrics comparison: field height, baseline, glyph, token and clear-button frames
/// within 0.5 pt (specification section 15.7).
public enum MetricsComparator {
    public static let tolerance = 0.5

    public static func compare(reference: LayoutMetrics, clone: LayoutMetrics) -> MetricsComparison {
        var deviations: [MetricDeviation] = []
        var missing: [String] = []
        var compared = 0

        for name in Set(reference.frames.keys).union(clone.frames.keys).sorted() {
            guard let first = reference.frames[name], let second = clone.frames[name] else {
                missing.append(name + (reference.frames[name] == nil ? " (clone only)" : " (reference only)"))
                continue
            }
            let parts: [(String, Double, Double)] = [
                ("x", first.x, second.x), ("y", first.y, second.y),
                ("width", first.width, second.width), ("height", first.height, second.height),
            ]
            for (part, a, b) in parts {
                compared += 1
                deviations.append(MetricDeviation(name: "\(name).\(part)", reference: a, clone: b, deviation: abs(a - b)))
            }
        }
        for name in Set(reference.lengths.keys).union(clone.lengths.keys).sorted() {
            guard let first = reference.lengths[name], let second = clone.lengths[name] else {
                missing.append(name + (reference.lengths[name] == nil ? " (clone only)" : " (reference only)"))
                continue
            }
            compared += 1
            deviations.append(MetricDeviation(name: name, reference: first, clone: second, deviation: abs(first - second)))
        }

        let sorted = deviations.sorted { ($0.deviation ?? 0) > ($1.deviation ?? 0) }
        let worst = sorted.first
        // Frames are sums of binary fractions: exactly 0.5 pt can come out as 0.5000000000001.
        let failures = sorted.filter { ($0.deviation ?? 0) > tolerance + 1e-9 }
        return MetricsComparison(
            worstDeviation: worst?.deviation ?? 0, worstName: worst?.name, missing: missing, failures: failures,
            comparedValues: compared, passes: failures.isEmpty && missing.isEmpty
        )
    }
}
