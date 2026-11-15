import Foundation

/// The scan strategy as a value type: synchronous, for use straight from SwiftUI without an
/// actor hop (specification section 9.1).
///
/// The items are projected and tokenized once, at creation. Nothing touches disk, and releasing
/// the value frees everything, so an index can live in `@State` next to its context.
public struct ScanIndex<Schema: SearchSchema>: Sendable {
    let engine: ScanEngine
    let profile: RankingProfile
    let configuration: SearchEngineConfiguration
    let languages: ResolvedLanguages
    let reporter: DiagnosticReporter

    public init<Item: Searchable>(
        items: [Item],
        locale: Locale? = nil,
        profile: RankingProfile = .default
    ) where Item.Kind == Schema.Kind {
        self.init(erased: items.map(AnySearchable.init), locale: locale, profile: profile, configuration: .default)
    }

    /// The specification's spelling, where the runtime supports constrained existentials.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    @_disfavoredOverload
    public init(items: [any Searchable<Schema.Kind>], locale: Locale? = nil, profile: RankingProfile = .default) {
        self.init(erased: items.map { AnySearchable($0) }, locale: locale, profile: profile, configuration: .default)
    }

    /// An index with explicit engine settings: limits, minimum lengths, secondary languages.
    public init<Item: Searchable>(
        items: [Item],
        locale: Locale? = nil,
        profile: RankingProfile = .default,
        configuration: SearchEngineConfiguration
    ) where Item.Kind == Schema.Kind {
        self.init(erased: items.map(AnySearchable.init), locale: locale, profile: profile, configuration: configuration)
    }

    init(erased items: [AnySearchable<Schema.Kind>], locale: Locale?, profile: RankingProfile, configuration: SearchEngineConfiguration) {
        var configuration = configuration
        if let locale { configuration.locale = locale }
        let languages = ResolvedLanguages(locale: configuration.locale, configuration: configuration)
        let reporter = DiagnosticReporter(configuration)
        let projection = SearchService<Schema>.project(items, languages: languages, reporter: reporter)
        self.engine = ScanEngine(documents: projection.documents, embeddings: projection.embeddings)
        self.profile = profile
        self.configuration = configuration
        self.languages = languages
        self.reporter = reporter
    }

    /// Lexical, fuzzy and fusion in one pass.
    public func hits(for query: SearchQuery<Schema>) -> [SearchHit<Schema.Kind>] {
        snapshot(for: query).hits
    }

    public var count: Int { engine.count }

    /// The single final snapshot of a query, with its paging cursor.
    public func snapshot(for query: SearchQuery<Schema>, generation: UInt64 = 0, contextID: SearchContextID = .default) -> SearchSnapshot<Schema> {
        let session = TokenizerSession.threadLocal
        let prepared = SearchPipeline.prepare(query, configuration: configuration, languages: languages, session: session)
        var documents: [FusedDocument] = []
        var matchTerms: [String: Double] = [:]
        if !prepared.isEmpty,
           let lexical = try? engine.search(SearchPipeline.request(for: prepared, profile: profile, configuration: configuration), session: session) {
            matchTerms = lexical.matchTerms
            let ranked = SearchPipeline.droppingUnknownKinds(
                SearchPipeline.fuse(lexical: lexical, semantic: nil, profile: profile, signals: .none, configuration: configuration, reporter: reporter),
                as: Schema.Kind.self,
                reporter: reporter
            )
            documents = ResultRanker(profile: profile, signals: .none, now: configuration.now(), reporter: reporter).applyingPins(to: ranked)
        }
        let start = min(max(0, query.cursor?.offset ?? 0), documents.count)
        let end = min(documents.count, start + max(0, query.limit))
        let slice = documents[start..<end]
        let descriptions = engine.describe(
            slice.map(\.id), matchTerms: matchTerms, fieldWeights: SearchPipeline.fieldWeights(profile), session: session
        )
        return SearchSnapshot(
            query: query,
            generation: generation,
            phase: .lexical,
            hits: SearchPipeline.hits(slice, descriptions: descriptions, as: Schema.Kind.self),
            nextCursor: end < documents.count ? SearchCursor(offset: end) : nil,
            degraded: [],
            isFinal: true,
            contextID: contextID
        )
    }

    /// The stored projection of an item: the surfaces a hit's highlights index into.
    public func document(for id: SearchableID) -> SearchDocument? {
        engine.document(for: id)
    }
}
