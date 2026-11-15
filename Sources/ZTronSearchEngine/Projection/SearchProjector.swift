import Foundation

/// Lets the projector reach the item inside an ``AnySearchable`` without knowing its kind.
protocol ErasedSearchable {
    var erasedBase: any Searchable { get }
}

extension AnySearchable: ErasedSearchable {
    var erasedBase: any Searchable { base }
}

/// Builds the engine-side read model of an item (specification section 6).
///
/// Projection is a pure function: the same item and languages always yield the same document.
/// Optional capabilities are detected by conformance here, at projection time.
public struct SearchProjector: Sendable {
    public let languages: ResolvedLanguages

    public init(languages: ResolvedLanguages) {
        self.languages = languages
    }

    /// Projects one item for a locale. `secondaryLanguages` are the BCP 47 tags whose surfaces
    /// feed `localizedAlt`; the engine passes the user's other preferred languages.
    public static func project(_ item: any Searchable, locale: Locale, secondaryLanguages: [String] = []) -> SearchDocument {
        let projector = SearchProjector(languages: ResolvedLanguages(active: LanguageTag.tag(for: locale), secondary: secondaryLanguages))
        return projector.project(item)
    }

    public func project(_ item: any Searchable) -> SearchDocument {
        var session = Session()
        return project(item, session: &session).document
    }

    // MARK: Batch projection

    /// Caches the fallback chains, which depend only on the set of localizations an item has;
    /// items of one catalog nearly always share that set.
    struct Session {
        var chains: [ChainKey: [String]] = [:]

        struct ChainKey: Hashable {
            let available: [String]
            let preference: String
        }

        mutating func chain(available: [String], preference: String) -> [String] {
            let key = ChainKey(available: available, preference: preference)
            if let cached = chains[key] { return cached }
            let chain = LanguageTag.chain(available: available, preference: preference)
            chains[key] = chain
            return chain
        }
    }

    struct Projection {
        var document: SearchDocument
        /// The item's filter type when it is `FilterableSearchable`, for the schema check.
        var filterType: Any.Type?
        /// A precomputed vector the item carries.
        var embedding: [Float]?
    }

    func project(_ item: any Searchable, session: inout Session) -> Projection {
        let base = (item as? any ErasedSearchable)?.erasedBase ?? item
        let localized = base as? any LocalizedSearchable
        let baseLanguage = localized?.searchLanguage.map(LanguageTag.canonical)
        let localizations = localized?.searchLocalizations ?? [:]
        let available = localizations.keys.sorted()

        let baseTitle = Self.nonEmpty((base as? any TitledSearchable)?.searchTitle)
        let baseText = base.searchText
        let baseKeywords = ((base as? any KeywordSearchable)?.searchKeywords ?? []).filter { Self.nonEmpty($0) != nil }
        let captioned = base as? any CaptionedSearchable
        let baseCaption = Self.nonEmpty(captioned?.searchCaption)
        let ocrText = Self.nonEmpty(captioned?.searchOCRText)

        // Field resolution: exact tag, language match, base surface (section 5, rule 2).
        let activeChain = available.isEmpty ? [] : session.chain(available: available, preference: languages.active)

        var title = baseTitle
        var titleLanguage = baseLanguage
        var text = baseText
        var textLanguage = baseLanguage
        var keywords = baseKeywords
        var keywordsLanguage = baseLanguage
        var caption = baseCaption
        var captionLanguage = baseLanguage
        var winner: String?
        var alt: [String] = []
        var altLanguages: [String?] = []

        func appendAlt(_ value: String?, _ language: String?) {
            guard let value = Self.nonEmpty(value), !alt.contains(value) else { return }
            alt.append(value)
            altLanguages.append(language)
        }

        for tag in activeChain.reversed() {
            guard let localization = localizations[tag] else { continue }
            let canonical = LanguageTag.canonical(tag)
            if let value = Self.nonEmpty(localization.title) { title = value; titleLanguage = canonical; winner = canonical }
            if let value = Self.nonEmpty(localization.text) { text = value; textLanguage = canonical; winner = canonical }
            let localizedKeywords = localization.keywords.filter { Self.nonEmpty($0) != nil }
            if !localizedKeywords.isEmpty { keywords = localizedKeywords; keywordsLanguage = canonical; winner = canonical }
            if let value = Self.nonEmpty(localization.caption) { caption = value; captionLanguage = canonical; winner = canonical }
        }

        // A base surface shadowed by a localization stays reachable at low weight.
        if title != baseTitle { appendAlt(baseTitle, baseLanguage) }
        if text != baseText { appendAlt(baseText, baseLanguage) }
        if keywords != baseKeywords, !baseKeywords.isEmpty { appendAlt(baseKeywords.joined(separator: ", "), baseLanguage) }
        if caption != baseCaption { appendAlt(baseCaption, baseLanguage) }

        // Secondary languages (section 5, rule 3).
        if !available.isEmpty {
            var consumed = Set(activeChain)
            var secondaryTags: [String] = []
            for preference in languages.secondary {
                for tag in session.chain(available: available, preference: preference) where consumed.insert(tag).inserted {
                    secondaryTags.append(tag)
                }
            }
            if languages.includesAllLanguages {
                for tag in available where consumed.insert(tag).inserted {
                    secondaryTags.append(tag)
                }
            }
            for tag in secondaryTags {
                guard let localization = localizations[tag] else { continue }
                let canonical = LanguageTag.canonical(tag)
                appendAlt(localization.title, canonical)
                appendAlt(localization.text, canonical)
                let localizedKeywords = localization.keywords.filter { Self.nonEmpty($0) != nil }
                if !localizedKeywords.isEmpty { appendAlt(localizedKeywords.joined(separator: ", "), canonical) }
                appendAlt(localization.caption, canonical)
            }
        }

        var filters: [FilterRecord] = []
        var filterType: Any.Type?
        if let filterable = base as? any FilterableSearchable {
            (filters, filterType) = Self.records(of: filterable)
        }

        let document = SearchDocument(
            id: base.searchID,
            kind: Self.rawKind(of: item),
            language: winner ?? baseLanguage,
            title: title,
            text: text,
            keywords: keywords,
            caption: caption,
            ocrText: ocrText,
            localizedAlt: alt,
            filters: filters,
            updatedAt: (base as? any TemporalSearchable)?.updatedAt,
            languages: SearchFieldLanguages(
                title: titleLanguage,
                text: textLanguage,
                keywords: keywordsLanguage,
                caption: captionLanguage,
                ocrText: baseLanguage,
                localizedAlt: altLanguages
            )
        )
        return Projection(
            document: document,
            filterType: filterType,
            embedding: (base as? any EmbeddableSearchable)?.embedding
        )
    }

    private static func rawKind(of item: any Searchable) -> String {
        func open<Item: Searchable>(_ item: Item) -> String { item.searchKind.rawValue }
        return open(item)
    }

    private static func records(of item: any FilterableSearchable) -> ([FilterRecord], Any.Type) {
        func open<Item: FilterableSearchable>(_ item: Item) -> ([FilterRecord], Any.Type) {
            var records: [FilterRecord] = []
            records.reserveCapacity(item.searchFilters.count)
            for filter in item.searchFilters {
                records.append(FilterRecord(key: filter.key, value: filter.value))
            }
            // A set has no order; the projection must be the same every time.
            records.sort { (lhs: FilterRecord, rhs: FilterRecord) -> Bool in
                if lhs.key == rhs.key { return lhs.value < rhs.value }
                return lhs.key < rhs.key
            }
            return (records, Item.Filter.self)
        }
        return open(item)
    }

    @inline(__always)
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.contains(where: { !$0.isWhitespace }) else { return nil }
        return value
    }
}
