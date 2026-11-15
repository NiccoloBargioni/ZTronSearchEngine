import Foundation

/// Parameters of an ``HNSWIndex``.
///
/// The defaults are the ones the specification fixes (section 7.3): `M = 16`,
/// `efSearch = 64`, top 50.
public struct HNSWConfiguration: Sendable, Hashable {
    /// `M`: links a node keeps on every layer above the bottom one. The bottom layer keeps
    /// twice as many. Clamped to 2...64.
    public var m: Int
    /// Candidates examined while a vector is linked into the graph. Higher values build a
    /// better graph more slowly: 400 instead of 200 costs 1.6 times the build time and, on
    /// 100,000 synthetic vectors, lifts recall@10 from 0.987 to 0.994. Clamped to `m`...4096.
    public var efConstruction: Int
    /// Candidates examined by a search. Higher values trade latency for recall. Clamped to
    /// 1...4096; a search never examines fewer candidates than the results it is asked for.
    public var efSearch: Int
    /// Candidates a search keeps on every layer above the bottom one, all of which become
    /// entry points of the layer below. Clamped to 1...4096.
    ///
    /// The classic algorithm keeps one, a greedy walk, and so enters the bottom layer at a
    /// single node. A query that lies between two topics has neighbours in both, and a search
    /// that enters in one of them seldom reaches the other: on 100,000 synthetic vectors such
    /// queries reach a recall@10 of 0.56 with one entry point and 0.93 with 64, while queries
    /// inside a topic go from 0.987 to 0.994. The upper layers hold one node in `m`, so the
    /// wider descent costs about a third more time per search. Set it to 1 for the classic
    /// behaviour.
    public var efEntry: Int
    /// Seed of the generator that assigns a layer to every node. Two indexes built from the
    /// same vectors, in the same order, with the same seed are identical.
    public var seed: UInt64
    /// When pruning a link list, refill it with the nearest discarded candidates instead of
    /// leaving it short. The graph gets denser, for 1.4 times the build time. On 100,000
    /// synthetic vectors that lifted the recall@10 of queries inside a topic by half a point;
    /// on a small corpus it lowered the recall of queries that belong to no topic, because a
    /// list that is always full sheds the long links such queries travel along. Off by
    /// default, as in the reference implementation.
    public var keepsPrunedConnections: Bool

    /// Creates a configuration; every value is clamped to its range.
    public init(
        m: Int = 16,
        efConstruction: Int = 200,
        efSearch: Int = 64,
        efEntry: Int = 64,
        seed: UInt64 = 0x5A54_726F_6E48_4E53,
        keepsPrunedConnections: Bool = false
    ) {
        self.m = min(max(2, m), 64)
        self.efConstruction = min(max(self.m, efConstruction), 4_096)
        self.efSearch = min(max(1, efSearch), 4_096)
        self.efEntry = min(max(1, efEntry), 4_096)
        self.seed = seed
        self.keepsPrunedConnections = keepsPrunedConnections
    }

    /// The specification's parameters, M = 16 and efSearch = 64, with efConstruction = 200 and
    /// efEntry = 64.
    public static let `default` = HNSWConfiguration()

    /// The number of neighbours a search returns unless told otherwise (specification section 10).
    public static let defaultNeighbourCount = 50
}
