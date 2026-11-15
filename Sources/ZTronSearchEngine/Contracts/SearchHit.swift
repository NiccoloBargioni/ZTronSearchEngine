import Foundation

/// One result. Its `kind` is always a valid case: documents of unknown kinds never surface.
public struct SearchHit<Kind: SearchItemKind>: Sendable, Identifiable, Hashable {
    public let id: SearchableID
    public let kind: Kind
    public let score: Double
    /// Which channels contributed, `.rerank` included.
    public let channels: Set<SearchChannel>
    public let matchedField: SearchField?
    /// Tag of the localized surface that matched.
    public let matchedLanguage: String?
    /// Ranges into `SearchDocument.surface(for: matchedField)`: the original, un-normalized
    /// string of the surface that matched.
    public let highlights: [Range<String.Index>]

    public init(
        id: SearchableID,
        kind: Kind,
        score: Double,
        channels: Set<SearchChannel>,
        matchedField: SearchField? = nil,
        matchedLanguage: String? = nil,
        highlights: [Range<String.Index>] = []
    ) {
        self.id = id
        self.kind = kind
        self.score = score
        self.channels = channels
        self.matchedField = matchedField
        self.matchedLanguage = matchedLanguage
        self.highlights = highlights
    }
}

/// Identifies one search context (specification section 9.1).
public struct SearchContextID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    /// The context of a service built directly over a ``LexicalIndex``.
    public static let `default` = SearchContextID("default")
}

/// One published state of a query (specification section 9, "Snapshot semantics").
public struct SearchSnapshot<Schema: SearchSchema>: Sendable {
    public let query: SearchQuery<Schema>
    public let generation: UInt64
    public let phase: SearchPhase
    public let hits: [SearchHit<Schema.Kind>]
    public let nextCursor: SearchCursor?
    /// Channels skipped for budget or memory reasons.
    public let degraded: Set<SearchChannel>
    /// `true` on the last snapshot the device will produce for the query.
    public let isFinal: Bool
    /// The context that produced the snapshot.
    public let contextID: SearchContextID

    public init(
        query: SearchQuery<Schema>,
        generation: UInt64,
        phase: SearchPhase,
        hits: [SearchHit<Schema.Kind>],
        nextCursor: SearchCursor? = nil,
        degraded: Set<SearchChannel> = [],
        isFinal: Bool,
        contextID: SearchContextID = .default
    ) {
        self.query = query
        self.generation = generation
        self.phase = phase
        self.hits = hits
        self.nextCursor = nextCursor
        self.degraded = degraded
        self.isFinal = isFinal
        self.contextID = contextID
    }

    /// The same hits partitioned by class; the fused order is kept inside each kind.
    public var hitsByKind: [Schema.Kind: [SearchHit<Schema.Kind>]] {
        Dictionary(grouping: hits, by: \.kind)
    }
}

/// An autocomplete proposal for a typed prefix.
public struct SearchSuggestion: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        /// A title that starts with the typed words.
        case title
        /// A vocabulary term that completes the last typed word.
        case term
    }

    /// The proposed query text.
    public let text: String
    public let source: Source
    /// The item a `.title` suggestion came from.
    public let itemID: SearchableID?
    public let score: Double

    public var id: String { text }

    public init(text: String, source: Source, itemID: SearchableID? = nil, score: Double = 0) {
        self.text = text
        self.source = source
        self.itemID = itemID
        self.score = score
    }
}

/// Failures the engine reports to its callers.
public enum SearchError: Error, Sendable, Hashable {
    /// The cursor belongs to a query the engine has since replaced.
    case staleGeneration
    /// The cursor does not point into the retained list.
    case invalidCursor
    /// The persisted index was written by another projection, normalizer or model version.
    case versionMismatch(String)
    /// The persisted index is unreadable.
    case corruptIndex(String)
    /// Reading or writing the persisted index failed.
    case persistence(String)
    /// The database boundary reported a failure.
    case database(String)
    /// A field is declared as a localization key but the context has no resolver.
    case missingLocalizedStringResolver
    /// The operation needs a capability this service was built without.
    case unsupported(String)
}
