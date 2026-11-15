import Foundation

/// A structured part of a query that is not free text.
public enum SearchQueryToken<Schema: SearchSchema>: Sendable, Hashable {
    /// Hard constraint; a case of the host's filter enum.
    case filter(Schema.Filter)
    /// Restricts results to one class of item.
    case kind(Schema.Kind)
    /// Required exact phrase; never fuzzed, never prefix-matched.
    case phrase(String)
}

/// Opaque position in a final snapshot's retained list.
public struct SearchCursor: Sendable, Hashable, Codable {
    /// Offset of the next hit in the retained list.
    public let offset: Int

    public init(offset: Int) {
        self.offset = offset
    }
}

/// What to search for (specification section 9).
public struct SearchQuery<Schema: SearchSchema>: Sendable, Hashable {
    public var text: String
    /// `.filter(Schema.Filter)`, `.kind(Schema.Kind)`, `.phrase(String)`.
    public var tokens: [SearchQueryToken<Schema>]
    /// Hard constraints; `.filter` tokens are merged in.
    public var filters: Set<Schema.Filter>
    /// `nil` = every kind; `.kind` tokens are merged in.
    public var kinds: Set<Schema.Kind>?
    /// `nil` = the engine's active locale.
    public var locale: Locale?
    public var limit: Int = 20
    public var cursor: SearchCursor?

    /// Token-to-query mapping is a pure function: `.filter` joins ``filters``, `.kind` joins
    /// ``kinds``, `.phrase` becomes a required exact phrase.
    public init(
        text: String,
        tokens: [SearchQueryToken<Schema>] = [],
        filters: Set<Schema.Filter> = [],
        kinds: Set<Schema.Kind>? = nil
    ) {
        self.text = text
        self.tokens = tokens
        var mergedFilters = filters
        var mergedKinds = kinds
        for token in tokens {
            switch token {
            case .filter(let filter):
                mergedFilters.insert(filter)
            case .kind(let kind):
                mergedKinds = (mergedKinds ?? []).union([kind])
            case .phrase:
                break
            }
        }
        self.filters = mergedFilters
        self.kinds = mergedKinds
    }
}

extension SearchQuery {
    /// Filters in force: ``filters`` plus every `.filter` token, so a query whose `tokens` were
    /// mutated after construction still constrains.
    public var resolvedFilters: Set<Schema.Filter> {
        var result = filters
        for case .filter(let filter) in tokens { result.insert(filter) }
        return result
    }

    /// Kinds in force: ``kinds`` plus every `.kind` token; `nil` = every kind.
    public var resolvedKinds: Set<Schema.Kind>? {
        var result = kinds
        for case .kind(let kind) in tokens { result = (result ?? []).union([kind]) }
        return result
    }

    /// Required exact phrases carried by `.phrase` tokens, in order.
    public var phrases: [String] {
        tokens.compactMap { token in
            if case .phrase(let phrase) = token { return phrase }
            return nil
        }
    }

    /// `true` when the query carries no free text, only tokens or filters.
    public var isTokensOnly: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// How a query reached the engine. It decides the throttling (specification section 10).
public enum SearchTrigger: Sendable, Hashable {
    /// A keystroke: lexical after the lexical debounce, semantic after the typing pause.
    case typing
    /// The search key: every phase runs immediately.
    case submit
}
