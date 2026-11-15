import Foundation

/// The two enums one engine instance speaks: the classes of items and the filters.
///
/// One schema per engine instance, fixed at construction (specification section 4.1).
public protocol SearchSchema: Sendable {
    associatedtype Kind: SearchItemKind
    associatedtype Filter: SearchFilter
}

/// A typed, equality-matched filter.
///
/// Only `key` and `value` are persisted, as a ``FilterRecord``. Both are canonical identifiers
/// (ASCII keys, ISO codes), never localized labels. Filters are never localized, never fuzzed
/// and never prefix-matched.
public protocol SearchFilter: Hashable, Sendable, Codable {
    /// Dimension; stable across app versions; persisted in the index.
    var key: String { get }
    /// Canonical, locale-independent value; persisted in the index.
    var value: String { get }
    /// Rebuilds a filter from an index record; `nil` = unknown to this build.
    init?(key: String, value: String)
}

/// The persisted form of a filter: key and value strings only.
public struct FilterRecord: Hashable, Sendable, Codable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

extension SearchFilter {
    /// The record the index stores for this filter.
    public var record: FilterRecord { FilterRecord(key: key, value: value) }
}

// MARK: - Fallback schema (the original string design)

/// Fallback kind: any string is a valid class.
public struct ZTronStringKind: SearchItemKind, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// Fallback filter. It carries both key and value because a single string would collapse every
/// ad-hoc filter into one dimension and lose the AND-across-keys, OR-within-a-key semantics.
public enum ZTronStringFilter: SearchFilter {
    case string(key: String, value: String)

    public var key: String {
        switch self { case .string(let key, _): return key }
    }

    public var value: String {
        switch self { case .string(_, let value): return value }
    }

    public init?(key: String, value: String) {
        self = .string(key: key, value: value)
    }
}

/// Fallback schema; equivalent to the original string design.
public enum ZTronStringSchema: SearchSchema {
    public typealias Kind = ZTronStringKind
    public typealias Filter = ZTronStringFilter
}

public typealias ZTronSearchService = SearchService<ZTronStringSchema>
