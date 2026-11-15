import Foundation

/// Where a service keeps its documents.
enum SearchStorage: Sendable {
    /// BM25F inverted index, every channel.
    case indexed(LexicalIndex)
    /// Linear scan in memory.
    case scan(ScanEngine)

    var isScan: Bool {
        if case .scan = self { return true }
        return false
    }
}

/// A query after parsing: what every phase of the pipeline reads.
struct PreparedQuery: Sendable {
    let parsed: ParsedQuery
    let constraints: HardConstraints
    /// Trimmed free text.
    let text: String
    /// BCP 47 tag the query was normalized in.
    let language: String
    /// Nothing to search for: no text, no token, no filter; or text below the minimum length.
    let isEmpty: Bool
    /// Long enough, with free text that is not only identifiers: the semantic channel may run.
    let isSemanticEligible: Bool
}

/// The pure parts of the result pipeline, shared by the service and by ``ScanIndex``.
enum SearchPipeline {
    static func prepare<Schema: SearchSchema>(
        _ query: SearchQuery<Schema>,
        configuration: SearchEngineConfiguration,
        languages: ResolvedLanguages,
        session: TokenizerSession
    ) -> PreparedQuery {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var language = query.locale.map(LanguageTag.tag(for:)) ?? languages.active
        if configuration.queryLanguageHinting, query.locale == nil,
           let hinted = QueryParser.hintedLanguage(for: text, among: [languages.active] + languages.secondary) {
            language = hinted
        }
        let parsed = QueryParser.parse(
            text: query.text,
            phrases: query.phrases,
            language: language,
            minimumFuzzyLength: configuration.minimumFuzzyTokenLength,
            session: session
        )
        let constraints = HardConstraints(query)
        let hasStructure = !constraints.isEmpty || !parsed.phrases.isEmpty
        let tooShort = !hasStructure && parsed.characterCount < configuration.minimumQueryLength && !parsed.containsUnspacedScript
        let nothingToMatch = parsed.isMatchAll && constraints.isEmpty
        let hasFreeText = parsed.clauses.contains { !$0.isRequired }
        return PreparedQuery(
            parsed: parsed,
            constraints: constraints,
            text: text,
            language: language,
            isEmpty: tooShort || nothingToMatch,
            isSemanticEligible: hasFreeText && !parsed.isIdentifierOnly
                && (parsed.characterCount >= configuration.minimumSemanticQueryLength || parsed.containsUnspacedScript)
        )
    }

    static func request(
        for prepared: PreparedQuery,
        profile: RankingProfile,
        configuration: SearchEngineConfiguration
    ) -> LexicalRequest {
        LexicalRequest(
            parsed: prepared.parsed,
            constraints: prepared.constraints,
            profile: profile,
            limits: configuration.limits,
            fuzzyEnabled: true,
            minimumFuzzyLength: configuration.minimumFuzzyTokenLength
        )
    }

    /// Fuses the channel lists by weighted RRF, then applies everything the profile and the
    /// signal providers weigh. Pins are applied by the caller, after any rerank.
    static func fuse(
        lexical: LexicalResponse,
        semantic: [RankedDocument]?,
        profile: RankingProfile,
        signals: SignalProviders,
        configuration: SearchEngineConfiguration,
        reporter: DiagnosticReporter
    ) -> [FusedDocument] {
        var channels = [
            RankFusion.Channel(channel: .lexical, weight: profile.channelWeights[.lexical] ?? 0, documents: lexical.lexical),
        ]
        if lexical.fuzzyRan {
            channels.append(RankFusion.Channel(channel: .fuzzy, weight: profile.channelWeights[.fuzzy] ?? 0, documents: lexical.fuzzy))
        }
        if let semantic {
            channels.append(RankFusion.Channel(channel: .semantic, weight: profile.channelWeights[.semantic] ?? 0, documents: semantic))
        }
        let fused = RankFusion.fuse(channels, k: profile.rrfK, entriesPerChannel: configuration.limits.fusionEntriesPerChannel)
        let ranker = ResultRanker(profile: profile, signals: signals, now: configuration.now(), reporter: reporter)
        return ranker.rank(fused, limit: configuration.limits.retainedHits)
    }

    /// Drops documents whose stored kind is unknown to the running build. They never surface as
    /// hits; each is logged.
    static func droppingUnknownKinds<Kind: SearchItemKind>(
        _ documents: [FusedDocument],
        as _: Kind.Type,
        reporter: DiagnosticReporter
    ) -> [FusedDocument] {
        documents.filter { document in
            if Kind(rawValue: document.rawKind) != nil { return true }
            reporter.report(.unknownKind(id: document.id, rawKind: document.rawKind))
            return false
        }
    }

    static func hits<Kind: SearchItemKind>(
        _ documents: ArraySlice<FusedDocument>,
        descriptions: [MatchDescription],
        as _: Kind.Type
    ) -> [SearchHit<Kind>] {
        var hits: [SearchHit<Kind>] = []
        hits.reserveCapacity(documents.count)
        for (offset, document) in documents.enumerated() {
            guard let kind = Kind(rawValue: document.rawKind) else { continue }
            let description = offset < descriptions.count ? descriptions[offset] : .none
            hits.append(SearchHit(
                id: document.id,
                kind: kind,
                score: document.score,
                channels: document.channels.set,
                matchedField: description.field,
                matchedLanguage: description.language,
                highlights: description.highlights
            ))
        }
        return hits
    }

    /// Field weights in `SearchField.ordinal` order.
    static func fieldWeights(_ profile: RankingProfile) -> [Double] {
        SearchField.ordered.map { profile.fieldWeights[$0] ?? 0 }
    }

    // MARK: Rerank

    /// Blends cross-encoder scores into the head of a fused list (specification section 7.4).
    ///
    /// Final score = `blend` x normalized cross-encoder score + (1 - `blend`) x normalized RRF
    /// score, both normalized over the head, so one confident pass cannot push an exact-title
    /// hit out of the head. Only the head is reordered; everything below keeps its fused order.
    static func reranked(_ documents: [FusedDocument], scores: [Float], spec: RerankSpec) -> [FusedDocument] {
        let headCount = min(spec.topN, documents.count, scores.count)
        guard headCount > 1 else {
            var result = documents
            if headCount == 1 { result[0].channels.insert(.rerank) }
            return result
        }
        let head = Array(documents[..<headCount])
        let cross = normalize(scores.prefix(headCount).map(Double.init))
        let fused = normalize(head.map(\.score))
        let blended = (0..<headCount).map { spec.blend * cross[$0] + (1 - spec.blend) * fused[$0] }
        let order = (0..<headCount).sorted { blended[$0] == blended[$1] ? $0 < $1 : blended[$0] > blended[$1] }

        // Reported scores stay non-increasing down the list: the blended values are mapped onto
        // the span the head occupied.
        let top = head[0].score
        let floor = headCount < documents.count ? documents[headCount].score : head[headCount - 1].score
        let highest = blended[order[0]]
        let lowest = blended[order[headCount - 1]]
        var result: [FusedDocument] = []
        result.reserveCapacity(documents.count)
        for index in order {
            var document = head[index]
            document.channels.insert(.rerank)
            document.score = highest > lowest ? floor + (top - floor) * (blended[index] - lowest) / (highest - lowest) : top
            result.append(document)
        }
        result.append(contentsOf: documents[headCount...])
        return result
    }

    /// Min-max normalization to 0...1; a constant list maps to 0.5.
    private static func normalize(_ values: [Double]) -> [Double] {
        guard let minimum = values.min(), let maximum = values.max(), maximum > minimum else {
            return [Double](repeating: 0.5, count: values.count)
        }
        return values.map { ($0 - minimum) / (maximum - minimum) }
    }

    /// The text a cross-encoder reads for a hit: title plus caption, or the first 64 tokens of
    /// the text.
    static func passage(for document: SearchDocument) -> String {
        let headline = [document.title, document.caption].compactMap { SearchProjector.nonEmpty($0) }
        if !headline.isEmpty { return headline.joined(separator: "\n") }
        return document.text.split(whereSeparator: \.isWhitespace).prefix(64).joined(separator: " ")
    }
}
