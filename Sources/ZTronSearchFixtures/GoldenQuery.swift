import Foundation
import ZTronSearchEngine

/// The classes of judged queries, one per relevance gate of specification section 15.3.
public enum GoldenQueryClass: String, Sendable, Hashable, CaseIterable {
    /// The full title, in any casing. Gate: rank 1 in at least 98% of queries.
    case exactTitle
    /// A prefix of the title of three or more characters that ends inside a word.
    /// Gate: MRR@10 at least 0.85.
    case titlePrefix
    /// The title or a distinctive keyword with typos inside the engine's edit budget.
    /// Gate: Recall@10 at least 0.90.
    case typo
    /// A keyword or tag. Gate: NDCG@10 at least 0.80.
    case keyword
    /// Synonyms of the item's concepts, sharing no token with the item. Gate: Recall@10 at
    /// least 0.75, through the semantic channel.
    case paraphrase
    /// A query in a language the item has no surface in. Gate: Recall@10 at least 0.70.
    case crossLanguage
    /// The localized title, with the engine built for that language. Gate: rank 1 in at least 95%.
    case localizedTitle
    /// Text plus filter, kind or phrase tokens. Gate: precision 1.0, no hit may violate a hard
    /// constraint.
    case filterAndKind
}

/// One judged query of the golden set.
public struct GoldenQuery: Sendable, Identifiable {
    /// Stable identifier: the class and a number, such as `typo-007`.
    public let id: String
    /// The class of the query: which gate it is measured against.
    public let queryClass: GoldenQueryClass
    /// The free text of the query. Empty only for queries made of tokens alone.
    public let text: String
    /// Filter, kind and phrase tokens. Empty for every class but ``GoldenQueryClass/filterAndKind``.
    public let tokens: [SearchQueryToken<CatalogSchema>]
    /// BCP 47 tag of the active locale the engine must be built with for this query: `"en"`,
    /// `"it"`, `"de"` or `"ja"`. For a cross-language query it is the language of the query:
    /// the engine runs in the user's locale, in which the source item has no surface.
    public let locale: String
    /// BCP 47 tag of the language the query text is written in.
    public let language: String
    /// Graded relevance, 1...3. Only relevant items are listed, and only golden ones.
    public let judgments: [SearchableID: Int]
    /// The kind the query is counted under: the kind of the item it was derived from.
    public let kind: CatalogKind
    /// The golden item the query was derived from. It is always judged.
    public let sourceID: SearchableID
    /// How the query was derived inside its class, for slicing a report: `title` or `keyword`
    /// for a typo, `firstWord` for a prefix that ends in the first word, `phrase` for a
    /// constrained query with a phrase token, and so on. Not part of the judgment.
    public let variant: String
    /// For queries with hard constraints: every golden id that satisfies them, judged or not.
    /// `nil` when the query has no kind, filter or phrase token.
    public let allowedIDs: Set<SearchableID>?

    /// The query as the engine takes it. The locale is left to the engine: build the engine
    /// with ``locale``.
    public var query: SearchQuery<CatalogSchema> {
        SearchQuery(text: text, tokens: tokens)
    }

    /// `true` when the query carries a kind, filter or phrase token.
    public var hasHardConstraints: Bool { !tokens.isEmpty }

    /// The judged ids, best grade first, then by id.
    public var relevantIDs: [SearchableID] {
        judgments.keys.sorted { lhs, rhs in
            let lhsGrade = judgments[lhs] ?? 0
            let rhsGrade = judgments[rhs] ?? 0
            return lhsGrade != rhsGrade ? lhsGrade > rhsGrade : lhs < rhs
        }
    }

    /// `true` when an item satisfies the hard constraints of the query, so it may appear among
    /// the hits. Works for any catalog item, golden or not: use it to assert precision 1.0 over
    /// a corpus that also holds distractors.
    ///
    /// Kinds: the item's kind is one of the kind tokens, when there are any. Filters: AND across
    /// keys, OR among the values of one key. Phrases: the words of every phrase appear, in
    /// order and next to each other, in one string of the item.
    public func satisfiesConstraints(_ item: AnySearchable<CatalogKind>) -> Bool {
        var kinds: Set<CatalogKind> = []
        var filters: [String: Set<String>] = [:]
        var phrases: [[String]] = []
        for token in tokens {
            switch token {
            case .kind(let kind): kinds.insert(kind)
            case .filter(let filter): filters[filter.key, default: []].insert(filter.value)
            case .phrase(let phrase): phrases.append(FixtureText.words(phrase))
            }
        }
        if !kinds.isEmpty, !kinds.contains(item.searchKind) { return false }
        if !filters.isEmpty {
            let records = GoldenQuery.filters(of: item.base)
            for (key, values) in filters where !records.contains(where: { $0.key == key && values.contains($0.value) }) {
                return false
            }
        }
        if !phrases.isEmpty {
            let surfaces = GoldenQuery.surfaces(of: item.base).map(FixtureText.words)
            for phrase in phrases where !surfaces.contains(where: { GoldenQuery.contains($0, phrase: phrase) }) {
                return false
            }
        }
        return true
    }

    /// The ids of the items that satisfy the hard constraints, out of any list of catalog items.
    public func allowedIDs(in items: [AnySearchable<CatalogKind>]) -> Set<SearchableID> {
        Set(items.filter(satisfiesConstraints).map(\.searchID))
    }

    // MARK: Reading items

    /// The filters of an item whose filter type is the catalog's; empty for any other item.
    static func filters(of item: any Searchable) -> Set<CatalogFilter> {
        func open<Item: FilterableSearchable>(_ item: Item) -> Set<CatalogFilter> {
            (item.searchFilters as? Set<CatalogFilter>) ?? []
        }
        guard let filterable = item as? any FilterableSearchable else { return [] }
        return open(filterable)
    }

    /// Every string of an item: base and localized title, text, keywords and caption, and
    /// recognized text.
    static func surfaces(of item: any Searchable) -> [String] {
        var surfaces = [item.searchText]
        if let titled = item as? any TitledSearchable { surfaces.append(titled.searchTitle) }
        if let keyworded = item as? any KeywordSearchable { surfaces.append(contentsOf: keyworded.searchKeywords) }
        if let captioned = item as? any CaptionedSearchable {
            if let caption = captioned.searchCaption { surfaces.append(caption) }
            if let recognized = captioned.searchOCRText { surfaces.append(recognized) }
        }
        if let localized = item as? any LocalizedSearchable {
            for language in localized.searchLocalizations.keys.sorted() {
                guard let localization = localized.searchLocalizations[language] else { continue }
                if let title = localization.title { surfaces.append(title) }
                if let text = localization.text { surfaces.append(text) }
                surfaces.append(contentsOf: localization.keywords)
                if let caption = localization.caption { surfaces.append(caption) }
            }
        }
        return surfaces
    }

    /// `true` when `words` contains `phrase` as consecutive words.
    static func contains(_ words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where words[start] == phrase[0] {
            var matches = true
            for offset in 1..<phrase.count where words[start + offset] != phrase[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }
}
