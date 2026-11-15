import Foundation

/// A vocabulary term as one strategy sees it.
struct TermReference<Handle> {
    let term: String
    /// Live documents that contain the term in any field.
    let documentFrequency: Int
    /// How the strategy finds the term's postings.
    let handle: Handle
}

/// The vocabulary of one strategy. The scan and the indexed strategies implement it differently
/// (a linear pass against a sorted vocabulary with a trigram index) but must answer identically:
/// that, plus the shared BM25F arithmetic, is what makes them rank identically.
protocol TermSource {
    associatedtype Handle

    func exact(_ term: String) -> TermReference<Handle>?

    /// Terms that start with `prefix`, best first by document frequency, then by term. The
    /// prefix itself and exact-only terms are excluded. At most `limit` terms.
    func prefixExpansions(of prefix: String, limit: Int) -> [TermReference<Handle>]

    /// Terms within `maximumEdits` of `term`, best first by edit distance, then document
    /// frequency, then term. The term itself and exact-only terms are excluded. At most `limit`.
    func fuzzyCandidates(for term: String, maximumEdits: Int, limit: Int) -> [(reference: TermReference<Handle>, edits: Int)]
}

struct PlannedAlternative<Handle> {
    let reference: TermReference<Handle>
    /// 1 for the exact term, the profile's prefix weight for a completion, 1 / (1 + edits) for a
    /// correction.
    let weight: Double
    /// Reached only through the fuzzy channel.
    let isFuzzy: Bool
}

struct PlannedClause<Handle> {
    var alternatives: [PlannedAlternative<Handle>]
    /// Blended over the lexical alternatives: one inverse document frequency for the clause, so
    /// a rare completion does not outrank the word that was typed.
    var idfLexical: Double
    /// Blended over every alternative.
    var idfFuzzy: Double
    var isRequired: Bool
    /// Largest document frequency among the alternatives; orders candidate admission.
    var maximumDocumentFrequency: Int
}

/// A query resolved against a vocabulary.
struct QueryPlan<Handle> {
    var clauses: [PlannedClause<Handle>] = []
    var phrases: [[String]] = []
    /// The fuzzy channel runs for this query.
    var fuzzyActive = false
    /// Bit `i` set when clause `i` belongs to a required phrase.
    var requiredMask: UInt64 = 0
    /// No text and no phrase: every document that survives the hard constraints matches.
    var isMatchAll = false
    /// A required term is absent from the vocabulary: nothing can match.
    var isUnsatisfiable = false
    /// Every term that can match, with its weight; what highlighting looks for.
    var matchTerms: [String: Double] = [:]

    /// Sum of the alternatives' document frequencies: an upper bound on the candidates.
    var candidateUpperBound: Int {
        clauses.reduce(0) { total, clause in
            total + clause.alternatives.reduce(0) { $0 + $1.reference.documentFrequency }
        }
    }
}

/// Time spent resolving a query against a vocabulary, in seconds.
struct PlanTimings {
    /// Exact lookups and prefix expansion.
    var lookup: TimeInterval = 0
    /// Fuzzy candidate generation and verification.
    var fuzzy: TimeInterval = 0
}

enum QueryPlanner {
    static func plan<Source: TermSource>(
        _ parsed: ParsedQuery,
        source: Source,
        parameters: ScoringParameters,
        limits: SearchLimits,
        fuzzyEnabled: Bool,
        minimumFuzzyLength: Int
    ) -> QueryPlan<Source.Handle> {
        var timings = PlanTimings()
        return plan(
            parsed, source: source, parameters: parameters, limits: limits,
            fuzzyEnabled: fuzzyEnabled, minimumFuzzyLength: minimumFuzzyLength, timings: &timings
        )
    }

    static func plan<Source: TermSource>(
        _ parsed: ParsedQuery,
        source: Source,
        parameters: ScoringParameters,
        limits: SearchLimits,
        fuzzyEnabled: Bool,
        minimumFuzzyLength: Int,
        timings: inout PlanTimings
    ) -> QueryPlan<Source.Handle> {
        var plan = QueryPlan<Source.Handle>()
        plan.phrases = parsed.phrases
        plan.isMatchAll = parsed.isMatchAll
        plan.fuzzyActive = fuzzyEnabled && limits.fuzzyCandidatesPerToken > 0
            && parsed.longestTokenLength >= minimumFuzzyLength

        func add(_ alternatives: [PlannedAlternative<Source.Handle>], isRequired: Bool) {
            var lexicalMaximum = 0
            var overallMaximum = 0
            for alternative in alternatives {
                overallMaximum = max(overallMaximum, alternative.reference.documentFrequency)
                if !alternative.isFuzzy { lexicalMaximum = max(lexicalMaximum, alternative.reference.documentFrequency) }
                plan.matchTerms[alternative.reference.term] = max(plan.matchTerms[alternative.reference.term] ?? 0, alternative.weight)
            }
            if isRequired {
                if lexicalMaximum == 0 { plan.isUnsatisfiable = true }
                if plan.clauses.count < 64 { plan.requiredMask |= 1 << UInt64(plan.clauses.count) }
            }
            plan.clauses.append(PlannedClause(
                alternatives: alternatives,
                idfLexical: lexicalMaximum > 0 ? parameters.idf(documentFrequency: lexicalMaximum) : 0,
                idfFuzzy: overallMaximum > 0 ? parameters.idf(documentFrequency: overallMaximum) : 0,
                isRequired: isRequired,
                maximumDocumentFrequency: overallMaximum
            ))
        }

        for clause in parsed.clauses {
            var alternatives: [PlannedAlternative<Source.Handle>] = []
            var taken = Set<String>()
            let lookupStart = DispatchTime.now().uptimeNanoseconds
            if let exact = source.exact(clause.term) {
                alternatives.append(PlannedAlternative(reference: exact, weight: 1, isFuzzy: false))
                taken.insert(exact.term)
            }
            if clause.allowsPrefix {
                for expansion in source.prefixExpansions(of: clause.term, limit: limits.prefixExpansions)
                where taken.insert(expansion.term).inserted {
                    alternatives.append(PlannedAlternative(reference: expansion, weight: parameters.prefixWeight, isFuzzy: false))
                }
            }

            // A word in a script without word spacing that the indexer segmented differently:
            // fall back to its character bigrams, which the index always carries.
            if alternatives.isEmpty && !clause.bigramFallback.isEmpty {
                var matchedAny = false
                for bigram in clause.bigramFallback {
                    if let exact = source.exact(bigram) {
                        matchedAny = true
                        add([PlannedAlternative(reference: exact, weight: 1, isFuzzy: false)], isRequired: false)
                    }
                }
                if matchedAny { continue }
            }

            let fuzzyStart = DispatchTime.now().uptimeNanoseconds
            timings.lookup += Double(fuzzyStart - lookupStart) / 1_000_000_000
            defer { timings.fuzzy += Double(DispatchTime.now().uptimeNanoseconds - fuzzyStart) / 1_000_000_000 }
            if plan.fuzzyActive && clause.allowsFuzzy {
                let length = clause.term.unicodeScalars.count
                let edits = EditDistance.allowedEdits(forLength: length)
                if edits > 0 {
                    for candidate in source.fuzzyCandidates(for: clause.term, maximumEdits: edits, limit: limits.fuzzyCandidatesPerToken)
                    where taken.insert(candidate.reference.term).inserted {
                        alternatives.append(PlannedAlternative(
                            reference: candidate.reference,
                            weight: 1 / (1 + Double(candidate.edits)),
                            isFuzzy: true
                        ))
                    }
                }
            }
            add(alternatives, isRequired: clause.isRequired)
        }
        return plan
    }
}

/// Keeps the best `limit` elements seen so far under a strict "is better" order.
struct TopSelector<Element> {
    private(set) var elements: [Element] = []
    let limit: Int
    let isBetter: (Element, Element) -> Bool

    init(limit: Int, isBetter: @escaping (Element, Element) -> Bool) {
        self.limit = limit
        self.isBetter = isBetter
        elements.reserveCapacity(limit + 1)
    }

    /// `true` when `element` would be kept.
    @inline(__always)
    func accepts(_ element: Element) -> Bool {
        elements.count < limit || isBetter(element, elements[elements.count - 1])
    }

    mutating func insert(_ element: Element) {
        guard limit > 0, accepts(element) else { return }
        var low = 0
        var high = elements.count
        while low < high {
            let middle = (low + high) / 2
            if isBetter(element, elements[middle]) { high = middle } else { low = middle + 1 }
        }
        elements.insert(element, at: low)
        if elements.count > limit { elements.removeLast() }
    }
}
