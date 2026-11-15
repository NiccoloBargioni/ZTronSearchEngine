import Foundation
import ZTronSearchEngine

// The host schema of the specification (section 4.1), as test fixtures: five kinds of items and
// a typed filter enum with a string escape hatch.

public enum CatalogKind: String, SearchItemKind, CaseIterable {
    case map
    case tip
    case tool
    case game
    case image
}

public enum Platform: String, Sendable, Hashable, Codable, CaseIterable {
    case ios
    case mac
    case tv
    case web
}

public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
    case maps
    case guides
    case calculators
    case trackers
    case galleries
}

/// An ISO 3166-1 alpha-2 country code.
public struct ISOCountry: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 2, rawValue.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        self.rawValue = rawValue.uppercased()
    }

    public static let italy = ISOCountry(rawValue: "IT")!
    public static let germany = ISOCountry(rawValue: "DE")!
    public static let japan = ISOCountry(rawValue: "JP")!
    public static let unitedStates = ISOCountry(rawValue: "US")!
}

public enum CatalogFilter: SearchFilter {
    case platform(Platform)
    case category(Category)
    case region(ISOCountry)
    /// Escape hatch for ad-hoc filters.
    case string(key: String, value: String)

    public var key: String {
        switch self {
        case .platform: return "platform"
        case .category: return "category"
        case .region: return "region"
        case .string(let key, _): return key
        }
    }

    public var value: String {
        switch self {
        case .platform(let platform): return platform.rawValue
        case .category(let category): return category.rawValue
        case .region(let country): return country.rawValue
        case .string(_, let value): return value
        }
    }

    public init?(key: String, value: String) {
        switch key {
        case "platform":
            guard let platform = Platform(rawValue: value) else { return nil }
            self = .platform(platform)
        case "category":
            guard let category = Category(rawValue: value) else { return nil }
            self = .category(category)
        case "region":
            guard let country = ISOCountry(rawValue: value) else { return nil }
            self = .region(country)
        default:
            self = .string(key: key, value: value)
        }
    }
}

public enum CatalogSchema: SearchSchema {
    public typealias Kind = CatalogKind
    public typealias Filter = CatalogFilter
}

// MARK: - Items (capability matrix of section 4)

/// Tool: Titled, Keyword, Filterable, Localized.
public struct Tool: Searchable, TitledSearchable, KeywordSearchable, FilterableSearchable, LocalizedSearchable {
    public var searchID: SearchableID
    public var searchKind: CatalogKind { .tool }
    public var searchText: String
    public var searchTitle: String
    public var searchKeywords: [String]
    public var searchFilters: Set<CatalogFilter>
    public var searchLanguage: String?
    public var searchLocalizations: [String: SearchLocalization]

    public init(
        id: String, title: String, text: String, keywords: [String] = [], filters: Set<CatalogFilter> = [],
        language: String? = "en", localizations: [String: SearchLocalization] = [:]
    ) {
        searchID = SearchableID(id)
        searchTitle = title
        searchText = text
        searchKeywords = keywords
        searchFilters = filters
        searchLanguage = language
        searchLocalizations = localizations
    }
}

/// Tip: Titled, Temporal, Embeddable, Localized.
public struct Tip: Searchable, TitledSearchable, TemporalSearchable, EmbeddableSearchable, LocalizedSearchable {
    public var searchID: SearchableID
    public var searchKind: CatalogKind { .tip }
    public var searchText: String
    public var searchTitle: String
    public var createdAt: Date
    public var updatedAt: Date
    public var embedding: [Float]?
    public var searchLanguage: String?
    public var searchLocalizations: [String: SearchLocalization]

    public var embeddingText: String { "tip \(searchTitle) \(searchText)" }

    public init(
        id: String, title: String, text: String, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date? = nil, embedding: [Float]? = nil, language: String? = "en",
        localizations: [String: SearchLocalization] = [:]
    ) {
        searchID = SearchableID(id)
        searchTitle = title
        searchText = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.embedding = embedding
        searchLanguage = language
        searchLocalizations = localizations
    }
}

/// Map: Titled, Filterable, Localized.
public struct MapItem: Searchable, TitledSearchable, FilterableSearchable, LocalizedSearchable {
    public var searchID: SearchableID
    public var searchKind: CatalogKind { .map }
    public var searchText: String
    public var searchTitle: String
    public var searchFilters: Set<CatalogFilter>
    public var searchLanguage: String?
    public var searchLocalizations: [String: SearchLocalization]

    public init(
        id: String, title: String, text: String, filters: Set<CatalogFilter> = [], language: String? = "en",
        localizations: [String: SearchLocalization] = [:]
    ) {
        searchID = SearchableID(id)
        searchTitle = title
        searchText = text
        searchFilters = filters
        searchLanguage = language
        searchLocalizations = localizations
    }
}

/// Game: Titled, Keyword, Filterable, Localized.
public struct Game: Searchable, TitledSearchable, KeywordSearchable, FilterableSearchable, LocalizedSearchable {
    public var searchID: SearchableID
    public var searchKind: CatalogKind { .game }
    public var searchText: String
    public var searchTitle: String
    public var searchKeywords: [String]
    public var searchFilters: Set<CatalogFilter>
    public var searchLanguage: String?
    public var searchLocalizations: [String: SearchLocalization]

    public init(
        id: String, title: String, text: String, keywords: [String] = [], filters: Set<CatalogFilter> = [],
        language: String? = "en", localizations: [String: SearchLocalization] = [:]
    ) {
        searchID = SearchableID(id)
        searchTitle = title
        searchText = text
        searchKeywords = keywords
        searchFilters = filters
        searchLanguage = language
        searchLocalizations = localizations
    }
}

/// Image: Titled, Keyword, Embeddable, Localized; searched through caption, alt text, tags and
/// optional OCR text, never through pixels.
public struct ImageItem: Searchable, TitledSearchable, KeywordSearchable, EmbeddableSearchable, LocalizedSearchable, CaptionedSearchable {
    public var searchID: SearchableID
    public var searchKind: CatalogKind { .image }
    /// Alt text.
    public var searchText: String
    public var searchTitle: String
    /// Tags.
    public var searchKeywords: [String]
    public var searchCaption: String?
    public var searchOCRText: String?
    public var embedding: [Float]?
    public var searchLanguage: String?
    public var searchLocalizations: [String: SearchLocalization]

    public var embeddingText: String {
        "image \(searchTitle) \(searchKeywords.joined(separator: " ")) \(searchCaption ?? "")"
    }

    public init(
        id: String, title: String, altText: String, tags: [String] = [], caption: String? = nil, ocrText: String? = nil,
        embedding: [Float]? = nil, language: String? = "en", localizations: [String: SearchLocalization] = [:]
    ) {
        searchID = SearchableID(id)
        searchTitle = title
        searchText = altText
        searchKeywords = tags
        searchCaption = caption
        searchOCRText = ocrText
        self.embedding = embedding
        searchLanguage = language
        searchLocalizations = localizations
    }
}

// MARK: - A second schema, for disjoint contexts

/// A settings picker context uses its own schema next to the catalog (section 9.1, rule 2).
public enum SettingsKind: String, SearchItemKind, CaseIterable {
    case setting
    case action
}

public enum SettingsFilter: SearchFilter {
    case section(String)

    public var key: String { "section" }

    public var value: String {
        switch self { case .section(let name): return name }
    }

    public init?(key: String, value: String) {
        guard key == "section" else { return nil }
        self = .section(value)
    }
}

public enum SettingsSchema: SearchSchema {
    public typealias Kind = SettingsKind
    public typealias Filter = SettingsFilter
}

public struct SettingEntry: Searchable, TitledSearchable, FilterableSearchable {
    public var searchID: SearchableID
    public var searchKind: SettingsKind
    public var searchText: String
    public var searchTitle: String
    public var searchFilters: Set<SettingsFilter>

    public init(id: String, kind: SettingsKind = .setting, title: String, text: String = "", section: String? = nil) {
        searchID = SearchableID(id)
        searchKind = kind
        searchTitle = title
        searchText = text
        searchFilters = section.map { [.section($0)] } ?? []
    }
}
