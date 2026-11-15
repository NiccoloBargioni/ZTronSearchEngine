import Accelerate
import Foundation

/// The scan strategy (specification section 9.1, rule 3).
///
/// Documents are projected and tokenized once, at creation; each keeps its normalized field
/// tokens as (term, field, frequency) entries. A query scores every document with the same
/// BM25F formula, field weights, fuzzy limits and fusion as the indexed strategy. Fuzzy is a
/// direct Damerau-Levenshtein against each vocabulary term, after a length pre-check and a
/// look at which letters the term holds; prefix matching is a direct prefix test, and nothing
/// is built that a 40-item context would never use: no inverted index, no sorted vocabulary,
/// no trigram index, no file.
struct ScanEngine: Sendable {
    private let batch: TokenizedBatch
    private let termIDs: [String: Int]
    private let exactOnly: [Bool]
    /// Scalars in every term, for the length pre-check of the fuzzy channel.
    private let scalarCounts: [Int32]
    /// Which scalars every term holds (`TermSignature`): one word, compared before any distance.
    private let signatures: [UInt64]
    private let positions: [SearchableID: Int]
    /// Precomputed item vectors, row-major, for the documents listed in `vectorDocuments`.
    private let vectors: [Float]
    private let vectorDocuments: [Int]
    let vectorDimensions: Int
    let statistics: CorpusStatistics

    var documents: [SearchDocument] { batch.documents }
    var count: Int { batch.documents.count }
    var hasVectors: Bool { !vectorDocuments.isEmpty }

    init(documents: [SearchDocument], embeddings: [SearchableID: [Float]] = [:], session: TokenizerSession = .threadLocal) {
        // Later duplicates replace earlier ones, as an upsert would.
        var unique: [SearchDocument] = []
        var seen: [SearchableID: Int] = [:]
        unique.reserveCapacity(documents.count)
        for document in documents {
            if let position = seen[document.id] {
                unique[position] = document
            } else {
                seen[document.id] = unique.count
                unique.append(document)
            }
        }
        positions = seen
        // Token positions are kept: a context this small is read straight from the view, and a
        // hit is then highlighted from what tokenizing it once already found.
        batch = DocumentTokenizer.tokenize(unique, session: session, recordingSpans: true)

        var ids: [String: Int] = [:]
        ids.reserveCapacity(batch.terms.count)
        var counts: [Int32] = []
        counts.reserveCapacity(batch.terms.count)
        var marks: [UInt64] = []
        marks.reserveCapacity(batch.terms.count)
        var exact: [Bool] = []
        exact.reserveCapacity(batch.terms.count)
        for (index, term) in batch.terms.enumerated() {
            ids[term] = index
            var count: Int32 = 0
            var signature: UInt64 = 0
            for scalar in term.unicodeScalars {
                count += 1
                signature |= TermSignature.bit(scalar.value)
            }
            counts.append(count)
            marks.append(signature)
            exact.append(ScriptClass.isExactOnly(term))
        }
        termIDs = ids
        scalarCounts = counts
        signatures = marks
        exactOnly = exact

        var totals = [UInt64](repeating: 0, count: SearchField.count)
        for (index, length) in batch.fieldLengths.enumerated() {
            totals[index % SearchField.count] += UInt64(length)
        }
        statistics = CorpusStatistics(documentCount: unique.count, totalFieldLengths: totals)

        var dimensions = 0
        var rows: [Float] = []
        var rowDocuments: [Int] = []
        for (position, document) in unique.enumerated() {
            guard let vector = embeddings[document.id], !vector.isEmpty else { continue }
            if dimensions == 0 { dimensions = vector.count }
            guard vector.count == dimensions else { continue }
            rows.append(contentsOf: Self.normalized(vector))
            rowDocuments.append(position)
        }
        vectors = rows
        vectorDocuments = rowDocuments
        vectorDimensions = dimensions
    }

    // MARK: Lexical and fuzzy, one pass

    func search(_ request: LexicalRequest, session: TokenizerSession = .threadLocal) throws -> LexicalResponse {
        var response = LexicalResponse()
        response.phrases = request.parsed.phrases
        let documentCount = count
        guard documentCount > 0 else { return response }

        let parameters = ScoringParameters(profile: request.profile, statistics: statistics)
        let plan = QueryPlanner.plan(
            request.parsed, source: Source(engine: self), parameters: parameters, limits: request.limits,
            fuzzyEnabled: request.fuzzyEnabled, minimumFuzzyLength: request.minimumFuzzyLength
        )
        response.matchTerms = plan.matchTerms
        response.fuzzyRan = plan.fuzzyActive
        guard !plan.isUnsatisfiable else { return response }

        var lexical = [Double](repeating: 0, count: documentCount)
        var fuzzy = [Double](repeating: 0, count: documentCount)
        var matchedLexical = [UInt64](repeating: 0, count: documentCount)
        var matchedFuzzy = [UInt64](repeating: 0, count: documentCount)
        let constrained = !request.constraints.isEmpty

        if plan.isMatchAll {
            for document in 0..<documentCount where !constrained || allows(document, request.constraints) {
                lexical[document] = 1
                matchedLexical[document] = 1
            }
        } else {
            // Every (clause, alternative) pair that a term can feed. A term may serve several
            // clauses, so the pairs of one term are chained.
            struct Link {
                let clause: Int
                let weight: Double
                let isFuzzy: Bool
                let next: Int
            }
            var links: [Link] = []
            var head = [Int](repeating: -1, count: batch.terms.count)
            for (clauseIndex, clause) in plan.clauses.enumerated() {
                for alternative in clause.alternatives {
                    links.append(Link(clause: clauseIndex, weight: alternative.weight, isFuzzy: alternative.isFuzzy, next: head[alternative.reference.handle]))
                    head[alternative.reference.handle] = links.count - 1
                }
            }
            var termFrequency = [Double](repeating: 0, count: links.count)
            var touched: [Int] = []
            var clauseLexical = [Double](repeating: 0, count: plan.clauses.count)
            var clauseFuzzy = [Double](repeating: 0, count: plan.clauses.count)

            var entry = 0
            for document in 0..<documentCount {
                let end = Int(batch.documentEnds[document])
                if document % 256 == 0 { try Task.checkCancellation() }
                if constrained && !allows(document, request.constraints) {
                    entry = end
                    continue
                }
                // Entries are sorted by term, then field: each alternative sums its fields in
                // field order, exactly like the indexed strategy.
                while entry < end {
                    let packed = batch.entries[entry]
                    entry += 1
                    var link = head[Int(TokenizedBatch.term(of: packed))]
                    guard link >= 0 else { continue }
                    let field = TokenizedBatch.field(of: packed)
                    let contribution = parameters.contribution(
                        field: field,
                        frequency: TokenizedBatch.frequency(of: packed),
                        length: batch.fieldLengths[document * SearchField.count + field]
                    )
                    while link >= 0 {
                        if termFrequency[link] == 0 { touched.append(link) }
                        termFrequency[link] += contribution
                        link = links[link].next
                    }
                }
                guard !touched.isEmpty else { continue }
                for link in touched {
                    let clause = links[link].clause
                    let frequency = termFrequency[link]
                    termFrequency[link] = 0
                    guard frequency > 0 else { continue }
                    if !links[link].isFuzzy {
                        let value = parameters.score(weight: links[link].weight, idf: plan.clauses[clause].idfLexical, tf: frequency)
                        if value > clauseLexical[clause] { clauseLexical[clause] = value }
                    }
                    let value = parameters.score(weight: links[link].weight, idf: plan.clauses[clause].idfFuzzy, tf: frequency)
                    if value > clauseFuzzy[clause] { clauseFuzzy[clause] = value }
                }
                touched.removeAll(keepingCapacity: true)
                // Clause scores are added in query order.
                for clause in 0..<plan.clauses.count {
                    let bit: UInt64 = clause < 64 ? 1 << UInt64(clause) : 0
                    if clauseLexical[clause] > 0 {
                        lexical[document] += clauseLexical[clause]
                        matchedLexical[document] |= bit
                        clauseLexical[clause] = 0
                    }
                    if clauseFuzzy[clause] > 0 {
                        fuzzy[document] += clauseFuzzy[clause]
                        matchedFuzzy[document] |= bit
                        clauseFuzzy[clause] = 0
                    }
                }
            }
        }

        var phraseState = [UInt8](repeating: 0, count: plan.phrases.isEmpty ? 0 : documentCount)
        let limit = request.limits.fusionEntriesPerChannel
        response.lexical = rankedList(
            scores: lexical, matched: matchedLexical, plan: plan, limit: limit, phraseState: &phraseState, session: session
        )
        if plan.fuzzyActive {
            response.fuzzy = rankedList(
                scores: fuzzy, matched: matchedFuzzy, plan: plan, limit: limit, phraseState: &phraseState, session: session
            )
        }
        return response
    }

    private func allows(_ document: Int, _ constraints: HardConstraints) -> Bool {
        constraints.allows(kind: batch.documents[document].kind, filters: batch.documents[document].filters)
    }

    private func rankedList(
        scores: [Double],
        matched: [UInt64],
        plan: QueryPlan<Int>,
        limit: Int,
        phraseState: inout [UInt8],
        session: TokenizerSession
    ) -> [RankedDocument] {
        let required = plan.requiredMask
        var order: [Int] = []
        for document in 0..<scores.count where matched[document] != 0 && matched[document] & required == required {
            order.append(document)
        }
        order.sort { lhs, rhs in
            RankFusion.precedes(scores[lhs], batch.documents[lhs].id, scores[rhs], batch.documents[rhs].id)
        }
        var result: [RankedDocument] = []
        result.reserveCapacity(min(limit, order.count))
        for document in order {
            if result.count >= limit { break }
            if !plan.phrases.isEmpty {
                if phraseState[document] == 0 {
                    phraseState[document] = Highlighter.containsPhrases(plan.phrases, in: batch.documents[document], session: session) ? 1 : 2
                }
                if phraseState[document] != 1 { continue }
            }
            let stored = batch.documents[document]
            result.append(RankedDocument(id: stored.id, rawKind: stored.kind, updatedAt: stored.updatedAt, score: scores[document]))
        }
        return result
    }

    // MARK: Lookups

    func document(for id: SearchableID) -> SearchDocument? {
        positions[id].map { batch.documents[$0] }
    }

    /// Where each hit matched, from the token positions kept at creation: nothing is tokenized.
    func describe(_ ids: [SearchableID], matchTerms: [String: Double], fieldWeights: [Double], session: TokenizerSession = .threadLocal) -> [MatchDescription] {
        guard !matchTerms.isEmpty else { return ids.map { _ in .none } }
        // The terms of the query this context's vocabulary holds.
        var weights: [UInt32: Double] = [:]
        weights.reserveCapacity(matchTerms.count)
        for (term, weight) in matchTerms {
            if let id = termIDs[term] { weights[UInt32(id)] = weight }
        }
        return ids.map { id in
            guard let position = positions[id], !weights.isEmpty else { return .none }
            let first = position == 0 ? 0 : Int(batch.spanEnds[position - 1])
            let last = Int(batch.spanEnds[position])
            // Matching tokens by surface. Spans of one surface are contiguous.
            var matched: [(piece: Int, spans: [(start: Int, length: Int)], weight: Double)] = []
            for index in first..<last {
                let span = batch.spans[index]
                guard let weight = weights[span.term] else { continue }
                if let current = matched.indices.last, matched[current].piece == Int(span.piece) {
                    matched[current].spans.append((Int(span.start), Int(span.length)))
                    matched[current].weight += weight
                } else {
                    matched.append((Int(span.piece), [(Int(span.start), Int(span.length))], weight))
                }
            }
            guard !matched.isEmpty else { return .none }
            let document = batch.documents[position]
            var surfaces: [DocumentSurface] = []
            document.forEachSurface { surfaces.append($0) }
            let pieces = matched.compactMap { entry -> Highlighter.MatchedPiece? in
                guard entry.piece < surfaces.count else { return nil }
                return Highlighter.MatchedPiece(surface: surfaces[entry.piece], spans: entry.spans, weight: entry.weight)
            }
            return Highlighter.summarize(document, pieces: pieces, fieldWeights: fieldWeights)
        }
    }

    /// Semantic neighbours as ranked documents, at most `limit`, without the ones that violate
    /// a hard constraint: a kind, a filter, or a phrase the query requires.
    func resolve(
        _ matches: [SemanticMatch],
        constraints: HardConstraints,
        phrases: [[String]] = [],
        limit: Int = .max,
        session: TokenizerSession = .threadLocal
    ) -> [RankedDocument] {
        var resolved: [RankedDocument] = []
        for match in matches {
            if resolved.count >= limit { break }
            guard let document = document(for: match.id), allows(document, constraints: constraints, phrases: phrases, session: session) else { continue }
            resolved.append(RankedDocument(id: document.id, rawKind: document.kind, updatedAt: document.updatedAt, score: Double(match.similarity)))
        }
        return resolved
    }

    private func allows(_ document: SearchDocument, constraints: HardConstraints, phrases: [[String]], session: TokenizerSession) -> Bool {
        guard constraints.allows(kind: document.kind, filters: document.filters) else { return false }
        return phrases.isEmpty || Highlighter.containsPhrases(phrases, in: document, session: session)
    }

    func completions(of prefix: String, limit: Int) -> [(term: String, documentFrequency: Int)] {
        let source = Source(engine: self)
        var result: [(String, Int)] = []
        if let exact = source.exact(prefix), !ScriptClass.isExactOnly(prefix) {
            result.append((exact.term, exact.documentFrequency))
        }
        for expansion in source.prefixExpansions(of: prefix, limit: limit) {
            result.append((expansion.term, expansion.documentFrequency))
        }
        return Array(result.prefix(limit))
    }

    // MARK: Semantic, brute force

    /// The nearest documents to a query vector by brute-force dot product over the vectors the
    /// items carry; never HNSW (section 9.1, rule 4).
    func nearest(
        to query: [Float],
        limit: Int,
        constraints: HardConstraints,
        phrases: [[String]] = [],
        session: TokenizerSession = .threadLocal
    ) -> [RankedDocument] {
        guard hasVectors, query.count == vectorDimensions, limit > 0 else { return [] }
        let unit = Self.normalized(query)
        var similarities = [Float](repeating: 0, count: vectorDocuments.count)
        vDSP_mmul(vectors, 1, unit, 1, &similarities, 1, vDSP_Length(vectorDocuments.count), 1, vDSP_Length(vectorDimensions))
        var order = Array(vectorDocuments.indices)
        order.sort { lhs, rhs in
            RankFusion.precedes(
                Double(similarities[lhs]), batch.documents[vectorDocuments[lhs]].id,
                Double(similarities[rhs]), batch.documents[vectorDocuments[rhs]].id
            )
        }
        var result: [RankedDocument] = []
        for row in order {
            if result.count >= limit { break }
            let document = batch.documents[vectorDocuments[row]]
            guard allows(document, constraints: constraints, phrases: phrases, session: session) else { continue }
            result.append(RankedDocument(id: document.id, rawKind: document.kind, updatedAt: document.updatedAt, score: Double(similarities[row])))
        }
        return result
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        guard sumOfSquares > 0 else { return vector }
        var divisor = sqrt(sumOfSquares)
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    // MARK: Vocabulary

    /// The vocabulary of the scan strategy: a linear pass over the distinct terms.
    private struct Source: TermSource {
        typealias Handle = Int
        let engine: ScanEngine

        func exact(_ term: String) -> TermReference<Int>? {
            guard let id = engine.termIDs[term] else { return nil }
            let frequency = Int(engine.batch.documentFrequency[id])
            return frequency > 0 ? TermReference(term: term, documentFrequency: frequency, handle: id) : nil
        }

        func prefixExpansions(of prefix: String, limit: Int) -> [TermReference<Int>] {
            let prefixBytes = prefix.utf8
            let prefixLength = prefixBytes.count
            var matches: [Int] = []
            for (id, term) in engine.batch.terms.enumerated() where !engine.exactOnly[id] {
                let bytes = term.utf8
                if bytes.count > prefixLength && bytes.starts(with: prefixBytes) && engine.batch.documentFrequency[id] > 0 {
                    matches.append(id)
                }
            }
            matches.sort { lhs, rhs in
                let left = engine.batch.documentFrequency[lhs]
                let right = engine.batch.documentFrequency[rhs]
                if left != right { return left > right }
                return engine.batch.terms[lhs].utf8.lexicographicallyPrecedes(engine.batch.terms[rhs].utf8)
            }
            return matches.prefix(limit).map {
                TermReference(term: engine.batch.terms[$0], documentFrequency: Int(engine.batch.documentFrequency[$0]), handle: $0)
            }
        }

        func fuzzyCandidates(for term: String, maximumEdits: Int, limit: Int) -> [(reference: TermReference<Int>, edits: Int)] {
            let query = EditDistance.scalars(term)
            guard maximumEdits > 0, query.count >= 2 else { return [] }
            let signature = TermSignature.of(query)
            // One machine word per candidate; the table is for tokens too long for it.
            let pattern = EditPattern(query)
            var scratch = EditDistance.Scratch()
            var found: [(id: Int, edits: Int)] = []
            for id in 0..<engine.batch.terms.count {
                // Length pre-check, then the letters, before any distance is computed.
                if engine.exactOnly[id] || abs(Int(engine.scalarCounts[id]) - query.count) > maximumEdits
                    || engine.batch.documentFrequency[id] == 0
                    || !TermSignature.mayBeWithin(maximumEdits, signature, engine.signatures[id]) { continue }
                let edits: Int?
                if let pattern {
                    edits = pattern.distance(to: engine.batch.terms[id], maximum: maximumEdits)
                } else {
                    edits = EditDistance.bounded(query, EditDistance.scalars(engine.batch.terms[id]), maximum: maximumEdits, scratch: &scratch)
                }
                if let edits, edits > 0 {
                    found.append((id, edits))
                }
            }
            found.sort { lhs, rhs in
                if lhs.edits != rhs.edits { return lhs.edits < rhs.edits }
                let left = engine.batch.documentFrequency[lhs.id]
                let right = engine.batch.documentFrequency[rhs.id]
                if left != right { return left > right }
                return engine.batch.terms[lhs.id].utf8.lexicographicallyPrecedes(engine.batch.terms[rhs.id].utf8)
            }
            return found.prefix(limit).map { element in
                (TermReference(term: engine.batch.terms[element.id], documentFrequency: Int(engine.batch.documentFrequency[element.id]), handle: element.id), element.edits)
            }
        }
    }
}
