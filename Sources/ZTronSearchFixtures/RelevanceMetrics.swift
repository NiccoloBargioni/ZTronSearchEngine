import Foundation
import ZTronSearchEngine

/// Relevance metrics over a ranked list of ids and graded judgments (specification section 15.3).
///
/// Judgments list only relevant items, with a grade of 1 or more; an id that is not listed is
/// not relevant. Every function is pure. An id that appears twice in a ranked list counts once,
/// at its first position: a result list cannot earn credit for the same item twice.
public enum RelevanceMetrics {
    /// Discounted cumulative gain of the first `k` results.
    ///
    /// The gain of a result is `2^grade - 1`; the result at 1-based rank `i` is discounted by
    /// `log2(i + 1)`.
    public static func dcg(_ ranked: [SearchableID], judgments: [SearchableID: Int], at k: Int) -> Double {
        var total = 0.0
        var seen = Set<SearchableID>()
        for (index, id) in ranked.prefix(max(0, k)).enumerated() {
            guard seen.insert(id).inserted, let grade = judgments[id], grade > 0 else { continue }
            total += gain(grade) / discount(rank: index + 1)
        }
        return total
    }

    /// The best DCG any list of `k` results could reach: the judged items, best grade first.
    public static func idealDCG(judgments: [SearchableID: Int], at k: Int) -> Double {
        var total = 0.0
        for (index, grade) in judgments.values.filter({ $0 > 0 }).sorted(by: >).prefix(max(0, k)).enumerated() {
            total += gain(grade) / discount(rank: index + 1)
        }
        return total
    }

    /// Normalized DCG of the first `k` results, in `0...1`: ``dcg(_:judgments:at:)`` divided by
    /// ``idealDCG(judgments:at:)``. `0` when nothing is relevant.
    public static func ndcg(_ ranked: [SearchableID], judgments: [SearchableID: Int], at k: Int) -> Double {
        let ideal = idealDCG(judgments: judgments, at: k)
        guard ideal > 0 else { return 0 }
        return dcg(ranked, judgments: judgments, at: k) / ideal
    }

    /// `1 / rank` of the first relevant result among the first `k`; `0` when there is none.
    /// Averaged over queries it is MRR@k.
    public static func reciprocalRank(_ ranked: [SearchableID], judgments: [SearchableID: Int], at k: Int) -> Double {
        for (index, id) in ranked.prefix(max(0, k)).enumerated() {
            if let grade = judgments[id], grade > 0 { return 1 / Double(index + 1) }
        }
        return 0
    }

    /// The share of the relevant items that the first `k` results contain, in `0...1`.
    ///
    /// The denominator is the number of relevant items, not `k`: a query with more than `k`
    /// relevant items cannot reach 1. `0` when nothing is relevant.
    public static func recall(_ ranked: [SearchableID], judgments: [SearchableID: Int], at k: Int) -> Double {
        let relevant = judgments.filter { $0.value > 0 }
        guard !relevant.isEmpty else { return 0 }
        let found = Set(ranked.prefix(max(0, k))).filter { relevant[$0] != nil }
        return Double(found.count) / Double(relevant.count)
    }

    /// `true` when the first result is judged with at least `minimumGrade`.
    public static func isRankOne(_ ranked: [SearchableID], judgments: [SearchableID: Int], minimumGrade: Int = 3) -> Bool {
        guard let first = ranked.first, let grade = judgments[first] else { return false }
        return grade >= minimumGrade
    }

    /// The share of results that satisfy the hard constraints of a query, in `0...1`: the gate
    /// for filter and kind tokens is exactly `1`. An empty list violates nothing and scores `1`.
    public static func precision(_ ranked: [SearchableID], allowed: Set<SearchableID>) -> Double {
        guard !ranked.isEmpty else { return 1 }
        return Double(ranked.filter(allowed.contains).count) / Double(ranked.count)
    }

    /// The mean of per-query values; `0` for no query.
    public static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    @inline(__always)
    private static func gain(_ grade: Int) -> Double {
        Double((1 << min(grade, 62)) - 1)
    }

    @inline(__always)
    private static func discount(rank: Int) -> Double {
        log2(Double(rank + 1))
    }
}
