import Foundation

/// A field of the search projection. The raw value is persisted in index files.
public enum SearchField: String, Sendable, Hashable, Codable, CaseIterable {
    case title
    case keywords
    case caption
    case text
    case localizedAlt
    case ocrText

    /// Position in the fixed scoring order. BM25F sums field contributions in this order in every
    /// strategy, which is what keeps scan and indexed scores bit-identical.
    @usableFromInline var ordinal: Int {
        switch self {
        case .title: return 0
        case .keywords: return 1
        case .caption: return 2
        case .text: return 3
        case .localizedAlt: return 4
        case .ocrText: return 5
        }
    }

    static let ordered: [SearchField] = [.title, .keywords, .caption, .text, .localizedAlt, .ocrText]
    static let count = 6
}

/// A retrieval or ranking stage that can contribute to a hit.
public enum SearchChannel: String, Sendable, Hashable, Codable, CaseIterable {
    case lexical
    case fuzzy
    case semantic
    case rerank
}

/// Which stage produced a snapshot.
public enum SearchPhase: Sendable, Hashable {
    case lexical
    case semantic
    case reranked
}

/// Language tags of each surface of a ``SearchDocument``.
///
/// Additive to the specification's document shape. Section 5 requires normalization and
/// tokenization per field language (rules 4 and 5) and hits that report the language of the
/// surface that matched (rule 11); a single document-level tag cannot express a title that
/// resolved to Italian next to a body that fell back to the base surface.
public struct SearchFieldLanguages: Sendable, Hashable, Codable {
    public var title: String?
    public var text: String?
    public var keywords: String?
    public var caption: String?
    public var ocrText: String?
    /// Parallel to ``SearchDocument/localizedAlt``.
    public var localizedAlt: [String?]

    public init(
        title: String? = nil,
        text: String? = nil,
        keywords: String? = nil,
        caption: String? = nil,
        ocrText: String? = nil,
        localizedAlt: [String?] = []
    ) {
        self.title = title
        self.text = text
        self.keywords = keywords
        self.caption = caption
        self.ocrText = ocrText
        self.localizedAlt = localizedAlt
    }

    /// One tag for every surface.
    public init(uniform language: String?, localizedAltCount: Int = 0) {
        self.init(
            title: language, text: language, keywords: language, caption: language, ocrText: language,
            localizedAlt: Array(repeating: language, count: localizedAltCount)
        )
    }
}

/// The engine-side read model of an item (specification section 6).
///
/// Built once at index time from a `Searchable` and the active locale; compact, denormalized
/// for retrieval, and versioned independently of the domain model. It is the only type the
/// index actors accept: domain objects never cross into the index.
public struct SearchDocument: Sendable, Codable, Identifiable, Hashable {
    public static let projectionVersion = 1

    public let id: SearchableID
    /// `Kind.rawValue` (section 4.1).
    public let kind: String
    /// Tag of the surface that won resolution (section 5).
    public let language: String?
    public let title: String?
    public let text: String
    public let keywords: [String]
    public let caption: String?
    public let ocrText: String?
    /// Secondary-language and shadowed base surfaces, low weight.
    public let localizedAlt: [String]
    /// Key and value strings only (section 4.1).
    public let filters: [FilterRecord]
    public let updatedAt: Date?
    /// Per-surface language tags; see ``SearchFieldLanguages``.
    public let languages: SearchFieldLanguages

    public init(
        id: SearchableID,
        kind: String,
        language: String? = nil,
        title: String? = nil,
        text: String,
        keywords: [String] = [],
        caption: String? = nil,
        ocrText: String? = nil,
        localizedAlt: [String] = [],
        filters: [FilterRecord] = [],
        updatedAt: Date? = nil,
        languages: SearchFieldLanguages? = nil
    ) {
        self.id = id
        self.kind = kind
        self.language = language
        self.title = title
        self.text = text
        self.keywords = keywords
        self.caption = caption
        self.ocrText = ocrText
        self.localizedAlt = localizedAlt
        self.filters = filters
        self.updatedAt = updatedAt
        var resolved = languages ?? SearchFieldLanguages(uniform: language, localizedAltCount: localizedAlt.count)
        if resolved.localizedAlt.count != localizedAlt.count {
            resolved.localizedAlt = Array(resolved.localizedAlt.prefix(localizedAlt.count))
                + Array(repeating: nil, count: max(0, localizedAlt.count - resolved.localizedAlt.count))
        }
        self.languages = resolved
    }

    /// Separator between the elements of a multi-valued surface in ``surface(for:)``.
    public static let surfaceSeparator = "\n"

    /// The string a hit's `highlights` index into for `field`.
    ///
    /// Single-valued fields return the value itself. Multi-valued fields (`keywords`,
    /// `localizedAlt`) return their elements joined by ``surfaceSeparator``.
    public func surface(for field: SearchField) -> String? {
        switch field {
        case .title: return title
        case .text: return text
        case .caption: return caption
        case .ocrText: return ocrText
        case .keywords: return keywords.isEmpty ? nil : keywords.joined(separator: Self.surfaceSeparator)
        case .localizedAlt: return localizedAlt.isEmpty ? nil : localizedAlt.joined(separator: Self.surfaceSeparator)
        }
    }
}
