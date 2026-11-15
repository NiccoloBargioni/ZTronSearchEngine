import Foundation

// MARK: - Identity

/// Stable identity of a searchable item.
///
/// Unique across every kind inside one engine (one search context); a collision is a
/// programmer error and is reported as a debug assertion (specification section 4).
public struct SearchableID: Hashable, Sendable, Identifiable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SearchableID: ExpressibleByStringLiteral, CustomStringConvertible, Comparable {
    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }

    public static func < (lhs: SearchableID, rhs: SearchableID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}

/// The class of an item (map, tip, tool, game, image, ...). Only `rawValue` is ever persisted.
public protocol SearchItemKind: Hashable, Sendable, Codable, RawRepresentable where RawValue == String {}

// MARK: - Required contract

/// A domain item the engine can index.
///
/// A `Searchable` provides evidence; the engine decides weight (specification section 3).
/// Three members are required. Everything else is an optional capability protocol that the
/// engine detects by conformance at projection time.
public protocol Searchable<Kind>: Sendable {
    associatedtype Kind: SearchItemKind

    /// Stable identity; unique across all kinds in one engine.
    var searchID: SearchableID { get }
    /// Which class the item is; every hit reports it. Required, never defaulted.
    var searchKind: Kind { get }
    /// Canonical text the engine tokenizes and indexes.
    var searchText: String { get }
}

// MARK: - Optional capabilities

public protocol TitledSearchable: Searchable {
    var searchTitle: String { get }
}

public protocol KeywordSearchable: Searchable {
    var searchKeywords: [String] { get }
}

public protocol TemporalSearchable: Searchable {
    var createdAt: Date { get }
    var updatedAt: Date { get }
}

public protocol FilterableSearchable<Kind, Filter>: Searchable {
    /// The host's filter enum (specification section 4.1).
    associatedtype Filter: SearchFilter
    var searchFilters: Set<Filter> { get }
}

public protocol EmbeddableSearchable: Searchable {
    /// Deterministic composition: type + title + tags + short description + caption (section 7.3).
    var embeddingText: String { get }
    /// `nil` when the vector ships in the vector store.
    var embedding: [Float]? { get }
}

public protocol LocalizedSearchable: Searchable {
    /// BCP 47 tag of the base surface; `nil` = unknown.
    var searchLanguage: String? { get }
    /// Keyed by BCP 47 tag, e.g. `"it"`, `"de-CH"`.
    var searchLocalizations: [String: SearchLocalization] { get }
}

/// Caption and recognized text of a visual item.
///
/// The specification's projection (`SearchDocument.caption`, `.ocrText`) and its BM25F field table
/// weigh both surfaces, and images are "searched through caption, alt text, tags and OCR text",
/// but section 4 lists no base-surface capability that supplies them. This protocol is that
/// source; it is additive and optional like every other capability.
public protocol CaptionedSearchable: Searchable {
    var searchCaption: String? { get }
    /// Text recognized inside the image. Never localized: it is whatever the pixels spell.
    var searchOCRText: String? { get }
}

extension CaptionedSearchable {
    public var searchOCRText: String? { nil }
}

/// Localized surfaces of an item for one language.
///
/// All values are resolved display strings: the engine never performs bundle lookups.
public struct SearchLocalization: Sendable, Hashable, Codable {
    public var title: String?
    public var text: String?
    public var keywords: [String]
    public var caption: String?

    public init(title: String? = nil, text: String? = nil, keywords: [String] = [], caption: String? = nil) {
        self.title = title
        self.text = text
        self.keywords = keywords
        self.caption = caption
    }
}

// MARK: - Type erasure for the iOS 15 floor

/// A searchable item of a known kind whose concrete type has been erased.
///
/// The specification spells heterogeneous collections as `[any Searchable<Schema.Kind>]`.
/// Constrained existentials inside generic arguments need runtime support that only exists from
/// iOS 16 / macOS 13, so on the iOS 15 deployment floor that spelling cannot be stored or passed
/// in an array. `AnySearchable` is the carrier that works everywhere while keeping the kind
/// checked at compile time: it can only be built from an item whose `Kind` matches.
///
/// Every API that takes `[any Searchable<Schema.Kind>]` in the specification exists here twice:
/// a generic overload available on the floor (it accepts `[AnySearchable<Kind>]` and any
/// homogeneous `[Item]`), and the verbatim overload gated on iOS 16.
public struct AnySearchable<Kind: SearchItemKind>: Searchable {
    /// The wrapped item. Optional capabilities are detected on this value.
    public let base: any Searchable
    public let searchKind: Kind

    public var searchID: SearchableID { base.searchID }
    public var searchText: String { base.searchText }

    public init<Item: Searchable>(_ item: Item) where Item.Kind == Kind {
        if let erased = item as? AnySearchable<Kind> {
            self = erased
        } else {
            self.base = item
            self.searchKind = item.searchKind
        }
    }
}

extension Array {
    /// Erases a homogeneous array of items: `tools.erased() + tips.erased()`.
    public func erased<Kind: SearchItemKind>() -> [AnySearchable<Kind>] where Element: Searchable, Element.Kind == Kind {
        map(AnySearchable.init)
    }
}
