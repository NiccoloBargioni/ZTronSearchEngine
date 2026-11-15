import Foundation
import ZTronSearchFixtures
@testable import ZTronSearchEngine

extension GoldenQueryClass {
    /// The target specification section 15.3 sets for the class.
    var gate: Double {
        switch self {
        case .exactTitle: return 0.98        // rank 1
        case .titlePrefix: return 0.85       // MRR@10
        case .typo: return 0.90              // recall@10
        case .keyword: return 0.80           // NDCG@10
        case .paraphrase: return 0.75        // recall@10
        case .crossLanguage: return 0.70     // recall@10
        case .localizedTitle: return 0.95    // rank 1
        case .filterAndKind: return 1.0      // precision
        }
    }

    /// How far a class may sit below its value without signals and still count as unchanged:
    /// a tenth of a percent, a tenth of the precision the specification states its targets
    /// with. Less than one query losing the first place in any class of the golden set.
    static let regressionTolerance = 0.001
}

extension GoldenQuery {
    /// The metric the query's class is gated on, for one ranked list.
    func gatedValue(ranked: [SearchableID], allowed: @autoclosure () -> Set<SearchableID>) -> Double {
        switch queryClass {
        case .exactTitle, .localizedTitle:
            return RelevanceMetrics.isRankOne(ranked, judgments: judgments) ? 1 : 0
        case .titlePrefix:
            return RelevanceMetrics.reciprocalRank(ranked, judgments: judgments, at: 10)
        case .typo, .paraphrase, .crossLanguage:
            return RelevanceMetrics.recall(ranked, judgments: judgments, at: 10)
        case .keyword:
            return RelevanceMetrics.ndcg(ranked, judgments: judgments, at: 10)
        case .filterAndKind:
            return RelevanceMetrics.precision(ranked, allowed: allowed())
        }
    }
}

/// Signals that know nothing about relevance: what a hash of the id says, whatever the query.
///
/// This is the pessimistic case for a ranking: real popularity and real affinity tend to agree
/// with relevance, and a signal that agrees with it cannot cost a class anything. Weights that
/// hold every gate against these hold it against signals that carry information.
final class RelevanceBlindSignals: PopularityProvider, PersonalizationProvider, EditorialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seed: UInt64
    private var affinitySpread: Double
    private var pinned: [SearchableID: Int] = [:]
    private var suppressedShare: Double = 0

    init(seed: UInt64 = 1, affinitySpread: Double = 0) {
        self.seed = seed
        self.affinitySpread = affinitySpread
    }

    func configure(seed: UInt64, affinitySpread: Double) {
        lock.lock(); defer { lock.unlock() }
        self.seed = seed
        self.affinitySpread = affinitySpread
    }

    /// Pins the given ids, in order, and suppresses a share of every other id.
    func curate(pinning ids: [SearchableID], suppressing share: Double) {
        lock.lock(); defer { lock.unlock() }
        pinned = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        suppressedShare = share
    }

    /// Uniform in 0..<1, a different draw per id, seed and purpose.
    static func unit(_ id: SearchableID, seed: UInt64, purpose: UInt64) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ (seed &* 0x9E37_79B9_7F4A_7C15) ^ (purpose &* 0xC2B2_AE3D_27D4_EB4F)
        for byte in id.rawValue.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        hash ^= hash >> 29
        hash = hash &* 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 32
        return Double(hash >> 11) / Double(1 << 53)
    }

    /// View counts spread evenly over nearly five orders of magnitude, a tenth of the items
    /// never viewed. After the engine's log1p scaling this is the widest spread a popularity
    /// can have, so it is the hardest on the ranking.
    func popularity(for id: SearchableID) throws -> Double? {
        let seed = lock.withLock { self.seed }
        let draw = Self.unit(id, seed: seed, purpose: 1)
        guard draw >= 0.1 else { return nil }
        return exp(draw * log(50_000)) - 1
    }

    func affinity(for id: SearchableID) throws -> Double? {
        let (seed, spread) = lock.withLock { (self.seed, self.affinitySpread) }
        guard spread > 0 else { return nil }
        return 1 + (Self.unit(id, seed: seed, purpose: 2) * 2 - 1) * spread
    }

    func decision(for id: SearchableID) throws -> EditorialDecision? {
        let (seed, pinned, share) = lock.withLock { (self.seed, self.pinned, self.suppressedShare) }
        if let rank = pinned[id] { return .pin(rank: rank) }
        if share > 0, Self.unit(id, seed: seed, purpose: 3) < share { return .suppress }
        return nil
    }
}
