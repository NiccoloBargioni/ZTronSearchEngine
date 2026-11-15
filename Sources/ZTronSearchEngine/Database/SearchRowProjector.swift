import Foundation

/// A database row as a searchable item.
///
/// Every row becomes a `SearchDocument` through the same projector as a memory item
/// (specification section 9.2, rule 3): the row is first turned into this item, with its base
/// surfaces and its per-language localizations, and then projected like any other. That is what
/// makes a database row rank identically to the same item held in memory.
struct SearchRowItem<Schema: SearchSchema>: Searchable, TitledSearchable, KeywordSearchable, CaptionedSearchable,
    LocalizedSearchable, FilterableSearchable {
    typealias Kind = Schema.Kind
    typealias Filter = Schema.Filter

    var searchID: SearchableID
    var searchKind: Schema.Kind
    var searchText: String = ""
    var searchTitle: String = ""
    var searchKeywords: [String] = []
    var searchCaption: String?
    var searchOCRText: String?
    var searchLanguage: String?
    var searchLocalizations: [String: SearchLocalization] = [:]
    var searchFilters: Set<Schema.Filter> = []
}

/// A row that carries `updatedAt`: the same item with `TemporalSearchable` semantics.
struct SearchDatedRowItem<Schema: SearchSchema>: Searchable, TitledSearchable, KeywordSearchable, CaptionedSearchable,
    LocalizedSearchable, FilterableSearchable, TemporalSearchable {
    typealias Kind = Schema.Kind
    typealias Filter = Schema.Filter

    var row: SearchRowItem<Schema>
    var updatedAt: Date
    var createdAt: Date { updatedAt }

    var searchID: SearchableID { row.searchID }
    var searchKind: Schema.Kind { row.searchKind }
    var searchText: String { row.searchText }
    var searchTitle: String { row.searchTitle }
    var searchKeywords: [String] { row.searchKeywords }
    var searchCaption: String? { row.searchCaption }
    var searchOCRText: String? { row.searchOCRText }
    var searchLanguage: String? { row.searchLanguage }
    var searchLocalizations: [String: SearchLocalization] { row.searchLocalizations }
    var searchFilters: Set<Schema.Filter> { row.searchFilters }
}

/// Turns rows into items (section 9.2, rule 3).
struct SearchRowProjector<Schema: SearchSchema>: Sendable {
    let source: SearchTableSource<Schema>
    let languages: ResolvedLanguages
    let resolver: (any LocalizedStringResolving)?
    let reporter: DiagnosticReporter

    struct ProjectedRow {
        let item: AnySearchable<Schema.Kind>
        let rowID: Int64?
    }

    /// Caches what does not depend on the row: the languages a catalog offers.
    struct Session {
        var catalogLanguages: [CatalogKey: [String]] = [:]

        struct CatalogKey: Hashable {
            let bundle: SearchBundleID
            let table: String?
        }
    }

    func project(_ row: SearchRow, layout: SearchRowLayout, session: inout Session) -> ProjectedRow? {
        guard layout.id < row.values.count, let rawID = row.values[layout.id]?.stringValue, !rawID.isEmpty else { return nil }
        let id: SearchableID
        switch source.identity {
        case .tablePrefixed: id = SearchableID(source.name + "#" + rawID)
        case .verbatim: id = SearchableID(rawID)
        case .prefixed(let prefix): id = SearchableID(prefix + rawID)
        }
        var item = SearchRowItem<Schema>(searchID: id, searchKind: source.kind)
        var texts: [String] = []
        var localizedTexts: [String: [String]] = [:]
        var literalLanguages = Set<String>()
        var keyLanguages = Set<String>()
        var hasUntaggedLiteral = false

        for (index, field) in source.fields.enumerated() where index < layout.fields.count {
            let columns = layout.fields[index]
            guard columns.value < row.values.count, let value = row.values[columns.value]?.stringValue,
                  SearchProjector.nonEmpty(value) != nil else { continue }

            var catalog: (table: String?, bundle: SearchBundleID)?
            var literalLanguage: String?
            switch field.encoding {
            case .literal(let language):
                literalLanguage = language
            case .localizedKey(let table, let bundle):
                catalog = (table, bundle)
            case .perRow(_, let table, let bundle):
                if let flag = columns.isKey, flag < row.values.count, row.values[flag]?.isTruthy == true {
                    catalog = (table, bundle)
                }
            }

            guard let catalog else {
                // A literal: the value is the text.
                if let literalLanguage { literalLanguages.insert(LanguageTag.canonical(literalLanguage)) } else { hasUntaggedLiteral = true }
                assign(value, to: field, in: &item, texts: &texts)
                continue
            }

            // A localization key: resolved per language. The raw key never enters the index.
            guard let resolver else {
                reporter.debug(.unresolvedLocalizationKey(key: value, table: catalog.table, language: languages.active))
                continue
            }
            let key = Session.CatalogKey(bundle: catalog.bundle, table: catalog.table)
            let available: [String]
            if let cached = session.catalogLanguages[key] {
                available = cached
            } else {
                available = resolver.languages(bundle: catalog.bundle, table: catalog.table)
                session.catalogLanguages[key] = available
            }
            var resolvedAny = false
            for language in available {
                guard let string = resolver.string(forKey: value, table: catalog.table, bundle: catalog.bundle, language: language),
                      SearchProjector.nonEmpty(string) != nil, string != value else { continue }
                let tag = LanguageTag.canonical(language)
                // The catalog lists its base language first. Its string is the base surface every
                // other language falls back to, exactly like the base surface of a memory item;
                // when the base language has no string for the key, the first language that has
                // one stands in.
                if !resolvedAny {
                    keyLanguages.insert(tag)
                    assign(string, to: field, in: &item, texts: &texts)
                }
                resolvedAny = true
                var localization = item.searchLocalizations[tag] ?? SearchLocalization()
                switch field.role {
                case .title: localization.title = string
                case .text: localizedTexts[tag, default: []].append(string)
                case .keywords: localization.keywords.append(contentsOf: Self.split(string, separator: field.separator))
                case .caption: localization.caption = string
                // Recognized text is never localized.
                case .ocrText, .localizedAlt: break
                }
                item.searchLocalizations[tag] = localization
            }
            if !resolvedAny {
                reporter.debug(.unresolvedLocalizationKey(key: value, table: catalog.table, language: languages.active))
            }
        }

        item.searchText = texts.joined(separator: "\n")
        for (tag, strings) in localizedTexts {
            item.searchLocalizations[tag]?.text = strings.joined(separator: "\n")
        }
        // The base surface speaks one language only when every field that feeds it agrees.
        let baseLanguages = literalLanguages.union(keyLanguages)
        if !hasUntaggedLiteral, baseLanguages.count == 1 {
            item.searchLanguage = baseLanguages.first
        }

        for (index, column) in source.filters.enumerated() where index < layout.filters.count {
            guard layout.filters[index] < row.values.count, let value = row.values[layout.filters[index]]?.stringValue else { continue }
            for part in Self.split(value, separator: column.separator) {
                if let filter = Schema.Filter(key: column.key, value: part) {
                    item.searchFilters.insert(filter)
                } else {
                    reporter.report(.unknownFilter(id: id, record: FilterRecord(key: column.key, value: part)))
                }
            }
        }

        let rowID = layout.rowID.flatMap { $0 < row.values.count ? row.values[$0]?.integerValue : nil }
        if let column = layout.updatedAt, column < row.values.count, let date = row.values[column]?.dateValue {
            return ProjectedRow(item: AnySearchable(SearchDatedRowItem(row: item, updatedAt: date)), rowID: rowID)
        }
        return ProjectedRow(item: AnySearchable(item), rowID: rowID)
    }

    private func assign(_ value: String, to field: SearchStringField, in item: inout SearchRowItem<Schema>, texts: inout [String]) {
        switch field.role {
        case .title: item.searchTitle = value
        case .text: texts.append(value)
        case .keywords: item.searchKeywords.append(contentsOf: Self.split(value, separator: field.separator))
        case .caption: item.searchCaption = value
        case .ocrText: item.searchOCRText = value
        case .localizedAlt: break
        }
    }

    static func split(_ value: String, separator: String?) -> [String] {
        guard let separator, !separator.isEmpty else { return [value] }
        return value.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
