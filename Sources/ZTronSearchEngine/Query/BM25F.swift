import Foundation

/// Corpus-wide numbers BM25F needs: live documents and the total length of each field.
struct CorpusStatistics: Sendable, Hashable {
    var documentCount: Int
    /// Total primary-word count per field, in `SearchField.ordinal` order.
    var totalFieldLengths: [UInt64]

    init(documentCount: Int = 0, totalFieldLengths: [UInt64] = [UInt64](repeating: 0, count: SearchField.count)) {
        self.documentCount = documentCount
        self.totalFieldLengths = totalFieldLengths
    }
}

/// The BM25F formula of specification section 7.1, shared verbatim by the scan and the indexed
/// strategies.
///
/// For a term `t` and a document `d`:
///
///     tf~(t, d) = sum over fields f of  w_f * tf(t, d, f) / (1 - b_f + b_f * len(d, f) / avglen(f))
///     score(t, d) = idf(t) * tf~ / (k1 + tf~)
///     idf(t) = ln(1 + (N - df + 0.5) / (df + 0.5))
///
/// Field contributions are always added in `SearchField.ordinal` order and clause scores in
/// query order. Both strategies call these exact functions, so their scores are bit-identical
/// and they rank the same documents identically (section 9.1, rule 3).
struct ScoringParameters: Sendable {
    let k1: Double
    let prefixWeight: Double
    let documentCount: Int
    /// `w_f`.
    let weight: [Double]
    /// `1 - b_f`.
    let oneMinusB: [Double]
    /// `b_f / avglen(f)`.
    let bOverAverage: [Double]

    init(profile: RankingProfile, statistics: CorpusStatistics) {
        k1 = profile.bm25.k1
        prefixWeight = profile.bm25.prefixWeight
        documentCount = statistics.documentCount
        var weight = [Double](repeating: 0, count: SearchField.count)
        var oneMinusB = [Double](repeating: 1, count: SearchField.count)
        var bOverAverage = [Double](repeating: 0, count: SearchField.count)
        for field in SearchField.ordered {
            let ordinal = field.ordinal
            let b = min(max(profile.bm25.b[field] ?? 0.75, 0), 1)
            weight[ordinal] = max(profile.fieldWeights[field] ?? 0, 0)
            oneMinusB[ordinal] = 1 - b
            let total = Double(statistics.totalFieldLengths[ordinal])
            let average = statistics.documentCount > 0 && total > 0 ? total / Double(statistics.documentCount) : 1
            bOverAverage[ordinal] = b / average
        }
        self.weight = weight
        self.oneMinusB = oneMinusB
        self.bOverAverage = bOverAverage
    }

    /// One field's share of `tf~`.
    @inline(__always)
    func contribution(field: Int, frequency: UInt32, length: UInt32) -> Double {
        weight[field] * Double(frequency) / (oneMinusB[field] + bOverAverage[field] * Double(length))
    }

    /// The score one alternative of a clause gives a document.
    @inline(__always)
    func score(weight alternativeWeight: Double, idf: Double, tf: Double) -> Double {
        alternativeWeight * idf * (tf / (k1 + tf))
    }

    /// Non-negative inverse document frequency.
    @inline(__always)
    func idf(documentFrequency: Int) -> Double {
        let n = Double(documentCount)
        let df = Double(min(max(documentFrequency, 0), documentCount))
        return log(1 + (n - df + 0.5) / (df + 0.5))
    }
}

/// Hard constraints of a query: applied before retrieval, never scored
/// (specification sections 4.1 and 8).
struct HardConstraints: Sendable, Hashable {
    /// Allowed `Kind.rawValue`s; `nil` = every kind.
    var kinds: Set<String>?
    /// Filter key to allowed values: AND across keys, OR among the values of one key.
    var filters: [String: Set<String>]

    init(kinds: Set<String>? = nil, filters: [String: Set<String>] = [:]) {
        self.kinds = kinds
        self.filters = filters
    }

    init<Schema: SearchSchema>(_ query: SearchQuery<Schema>) {
        kinds = query.resolvedKinds.map { Set($0.map(\.rawValue)) }
        var groups: [String: Set<String>] = [:]
        for filter in query.resolvedFilters {
            groups[filter.key, default: []].insert(filter.value)
        }
        filters = groups
    }

    var isEmpty: Bool { kinds == nil && filters.isEmpty }

    /// Equality on the record: every key must be satisfied by at least one of its values.
    func allows(kind: String, filters records: [FilterRecord]) -> Bool {
        if let kinds, !kinds.contains(kind) { return false }
        for (key, values) in filters {
            var satisfied = false
            for record in records where record.key == key && values.contains(record.value) {
                satisfied = true
                break
            }
            if !satisfied { return false }
        }
        return true
    }
}
