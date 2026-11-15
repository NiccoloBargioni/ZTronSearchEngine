import Foundation

/// BM25F parameters (specification section 7.1).
public struct BM25Parameters: Sendable, Hashable {
    /// Term-frequency saturation.
    public var k1: Double
    /// Length normalization per field.
    public var b: [SearchField: Double]
    /// Weight of a vocabulary term reached only by completing the final token, relative to an
    /// exact token match (1.0). Below 1 so "box" outranks "boxes" for the query `box`.
    ///
    /// Additive to the specification, which caps prefix expansion at 32 terms but does not say
    /// how an expansion scores against the exact term. Tuned against the golden set.
    public var prefixWeight: Double

    public init(k1: Double = 1.2, b: [SearchField: Double] = BM25Parameters.defaultB, prefixWeight: Double = 0.7) {
        self.k1 = k1
        self.b = b
        self.prefixWeight = prefixWeight
    }

    public static let defaultB: [SearchField: Double] = [
        .title: 0.5,
        .keywords: 0.3,
        .caption: 0.75,
        .text: 0.75,
        .localizedAlt: 0.75,
        .ocrText: 0.75,
    ]
}

/// How an injected signal is weighed.
public struct SignalSpec: Sendable, Hashable {
    /// Largest boost the signal may add, as a fraction of the top fused score.
    public var weight: Double
    /// Freshness only: the age, in days, at which the boost halves.
    public var halfLifeDays: Double?

    public init(weight: Double, halfLifeDays: Double? = nil) {
        self.weight = weight
        self.halfLifeDays = halfLifeDays
    }

    /// log1p-scaled popularity at the tuned weight (``tunedWeight``).
    public static let popularity = SignalSpec(weight: tunedWeight)

    /// Exponential decay with the given half-life, at the tuned weight unless another is given.
    public static func freshness(halfLifeDays: Double, weight: Double = tunedWeight) -> SignalSpec {
        SignalSpec(weight: weight, halfLifeDays: halfLifeDays)
    }

    /// The ceiling the specification puts on the popularity boost: 15% of the top fused score.
    public static let maximumPopularityWeight = 0.15

    /// The weight popularity and freshness carry unless the host says otherwise, as a fraction
    /// of the top fused score.
    ///
    /// It is tuned from the relevance judgments of the golden set, against signals that know
    /// nothing about relevance: the largest weight at which, with both signals on, no
    /// exact-title or localized-title query loses the first place and no class of specification
    /// section 15.3 moves by a tenth of a percent, among 5,000 and among 100,000 distractors.
    /// Reciprocal rank fusion leaves little room at the head of a list: one rank in every
    /// channel is 1.6% of the top score, and a title that wins one channel and comes second in
    /// another leads by a fraction of that. At this weight a signal breaks ties and reorders
    /// near-ties; it does not move an exact-title hit.
    ///
    /// A signal that agrees with relevance can carry more, up to the ceiling. Measure it against
    /// judged queries first, the way `SignalTuningTests` does.
    public static let tunedWeight = 0.005
}

/// What the curation system may do to a result list.
public struct EditorialPolicy: Sendable, Hashable {
    /// Pins are limited per query so they cannot hide organic results. At most 3.
    public var maximumPins: Int
    public var appliesSuppressions: Bool

    public init(maximumPins: Int = 3, appliesSuppressions: Bool = true) {
        self.maximumPins = min(max(0, maximumPins), EditorialPolicy.pinCeiling)
        self.appliesSuppressions = appliesSuppressions
    }

    public static let pinCeiling = 3
    public static let `default` = EditorialPolicy()
}

/// The cross-encoder stage (specification section 7.4).
public struct RerankSpec: Sendable, Hashable {
    /// Hits reranked from the head of the semantic snapshot; at most 32.
    public var topN: Int
    /// Final score = `blend` x normalized cross-encoder score + (1 - `blend`) x normalized RRF score.
    public var blend: Double

    public init(topN: Int = 16, blend: Double = 0.7) {
        self.topN = min(max(1, topN), RerankSpec.topNCeiling)
        self.blend = min(max(0, blend), 1)
    }

    public static let topNCeiling = 32
    public static let `default` = RerankSpec()
}

/// Everything the engine is allowed to weigh (specification section 8).
///
/// Ranking can be retuned by swapping a profile without touching a single domain type.
public struct RankingProfile: Sendable, Hashable {
    public var fieldWeights: [SearchField: Double]
    /// k1, b per field.
    public var bm25: BM25Parameters
    public var channelWeights: [SearchChannel: Double]
    public var rrfK: Double = 60
    /// Keyed by `Kind.rawValue`; multiplicative, 1.0 neutral, clamped to 0.5...1.5.
    public var kindBoosts: [String: Double]
    /// log1p-scaled, adds at most 15% of the top fused score.
    public var popularity: SignalSpec?
    /// Exponential decay, half-life in days.
    public var freshness: SignalSpec?
    /// Pins to the top, suppressions.
    public var editorial: EditorialPolicy
    /// topN = 16, blend = 0.7; applied only past the calibration gate.
    public var rerank: RerankSpec?

    public init(
        fieldWeights: [SearchField: Double] = RankingProfile.defaultFieldWeights,
        bm25: BM25Parameters = BM25Parameters(),
        channelWeights: [SearchChannel: Double] = RankingProfile.defaultChannelWeights,
        rrfK: Double = 60,
        kindBoosts: [String: Double] = [:],
        popularity: SignalSpec? = .popularity,
        freshness: SignalSpec? = nil,
        editorial: EditorialPolicy = .default,
        rerank: RerankSpec? = .default
    ) {
        self.fieldWeights = fieldWeights
        self.bm25 = bm25
        self.channelWeights = channelWeights
        self.rrfK = rrfK
        self.kindBoosts = kindBoosts
        self.popularity = popularity
        self.freshness = freshness
        self.editorial = editorial
        self.rerank = rerank
    }

    public static let defaultFieldWeights: [SearchField: Double] = [
        .title: 8.0,
        .keywords: 4.0,
        .caption: 2.5,
        .text: 1.0,
        .localizedAlt: 0.5,
        .ocrText: 0.5,
    ]

    public static let defaultChannelWeights: [SearchChannel: Double] = [
        .lexical: 1.0,
        .fuzzy: 0.6,
        .semantic: 0.8,
    ]

    public static let `default` = RankingProfile()

    /// The range every multiplicative boost is clamped to.
    public static let boostRange: ClosedRange<Double> = 0.5...1.5

    /// The clamped boost for a kind; 1.0 when none is declared.
    public func kindBoost(for rawKind: String) -> Double {
        guard let boost = kindBoosts[rawKind], boost.isFinite else { return 1 }
        return min(max(boost, Self.boostRange.lowerBound), Self.boostRange.upperBound)
    }
}

// MARK: - Signal providers

/// Popularity from the analytics or behavior pipeline.
///
/// Providers are optional, `Sendable`, synchronous, O(1) lookups by ``SearchableID``, and must
/// never block. A provider that throws is treated as absent for that query.
public protocol PopularityProvider: Sendable {
    /// A non-negative raw count (views, opens, ...); `nil` = unknown.
    func popularity(for id: SearchableID) throws -> Double?
}

/// What the curation system decided for one item.
public enum EditorialDecision: Sendable, Hashable {
    /// Pin to the top; lower `rank` first.
    case pin(rank: Int)
    /// Never show.
    case suppress
}

/// Editorial boost or suppression from the curation system.
public protocol EditorialProvider: Sendable {
    func decision(for id: SearchableID) throws -> EditorialDecision?
}

/// User affinity from the personalization layer. The engine exposes the hook only.
public protocol PersonalizationProvider: Sendable {
    /// A multiplicative boost, 1.0 neutral, clamped to 0.5...1.5; `nil` = neutral.
    func affinity(for id: SearchableID) throws -> Double?
}

/// The signal providers the host injects.
public struct SignalProviders: Sendable {
    public var popularity: (any PopularityProvider)?
    public var editorial: (any EditorialProvider)?
    public var personalization: (any PersonalizationProvider)?

    public init(
        popularity: (any PopularityProvider)? = nil,
        editorial: (any EditorialProvider)? = nil,
        personalization: (any PersonalizationProvider)? = nil
    ) {
        self.popularity = popularity
        self.editorial = editorial
        self.personalization = personalization
    }

    public static let none = SignalProviders()
}
