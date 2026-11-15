import Foundation

/// How a context retrieves (specification section 9.1).
public enum SearchStrategy: Sendable, Hashable {
    /// Scan up to 500 documents, indexed above.
    case automatic
    /// Linear, in memory, synchronous, no disk.
    case scan
    /// BM25F inverted index, optional persistence, every channel.
    case indexed
}

/// Where an indexed context persists its index.
public enum SearchIndexStorage: Sendable, Hashable {
    /// A directory. The context writes one file there, keyed by its id and `projectionVersion`.
    case files(URL)
    /// Inside the host database: `<prefix>_meta`, `_docs`, `_terms`, `_postings`, written through
    /// the boundary's write transaction with an atomic generation swap.
    case database(tablePrefix: String)
    /// Never persisted.
    case inMemory

    /// `.files` in the caches directory.
    public static var `default`: SearchIndexStorage {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return .files(base.appendingPathComponent("ZTronSearchEngine", isDirectory: true))
    }
}

/// Where a context's searchables come from.
public enum SearchSource<Schema: SearchSchema>: Sendable {
    case memory([AnySearchable<Schema.Kind>])
    case database(any SearchDatabaseConnection, [SearchTableSource<Schema>])
}

extension SearchSource {
    /// A memory source from any homogeneous array of items: `.items(tools)`.
    public static func items<Item: Searchable>(_ items: [Item]) -> SearchSource where Item.Kind == Schema.Kind {
        let erased: [AnySearchable<Schema.Kind>] = items.map(AnySearchable.init)
        return SearchSource.memory(erased)
    }

    /// The specification's spelling, where the runtime supports constrained existentials.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    @_disfavoredOverload
    public static func memory(_ items: [any Searchable<Schema.Kind>]) -> SearchSource {
        let erased: [AnySearchable<Schema.Kind>] = items.map { AnySearchable($0) }
        return SearchSource.memory(erased)
    }
}

/// An independent, disjoint set of searchables with its own schema, index, ranking state and
/// lifecycle (specification section 9.1).
///
/// A context is a value: cheap to create and discard, and it can live in `@State`.
public struct SearchContext<Schema: SearchSchema>: Sendable {
    public var id: SearchContextID
    /// Sources generalize items; `items` stays as the one-source convenience.
    public var sources: [SearchSource<Schema>]
    /// `nil` = engine default; a context may search in its own locale.
    public var locale: Locale?
    public var strategy: SearchStrategy = .automatic
    /// Required when any field is a localized key.
    public var localizedStrings: (any LocalizedStringResolving)?
    /// `.files(URL)`, the default, or `.database(tablePrefix:)` through the write transaction.
    public var indexStorage: SearchIndexStorage

    public init(
        id: SearchContextID,
        sources: [SearchSource<Schema>],
        locale: Locale? = nil,
        strategy: SearchStrategy = .automatic,
        localizedStrings: (any LocalizedStringResolving)? = nil,
        indexStorage: SearchIndexStorage = .default
    ) {
        self.id = id
        self.sources = sources
        self.locale = locale
        self.strategy = strategy
        self.localizedStrings = localizedStrings
        self.indexStorage = indexStorage
    }

    public init<Item: Searchable>(
        id: SearchContextID,
        items: [Item],
        locale: Locale? = nil,
        strategy: SearchStrategy = .automatic
    ) where Item.Kind == Schema.Kind {
        let erased: [AnySearchable<Schema.Kind>] = items.map(AnySearchable.init)
        self.init(id: id, sources: [SearchSource.memory(erased)], locale: locale, strategy: strategy)
    }

    /// The specification's spelling, where the runtime supports constrained existentials.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    @_disfavoredOverload
    public init(
        id: SearchContextID,
        items: [any Searchable<Schema.Kind>],
        locale: Locale? = nil,
        strategy: SearchStrategy = .automatic
    ) {
        let erased: [AnySearchable<Schema.Kind>] = items.map { AnySearchable($0) }
        self.init(id: id, sources: [SearchSource.memory(erased)], locale: locale, strategy: strategy)
    }

    /// Every item held in memory, across the memory sources. Setting it replaces the memory
    /// sources with one source and leaves database sources in place.
    public var memoryItems: [AnySearchable<Schema.Kind>] {
        get {
            sources.flatMap { source -> [AnySearchable<Schema.Kind>] in
                if case .memory(let items) = source { return items }
                return []
            }
        }
        set {
            var kept = sources.filter { source in
                if case .memory = source { return false }
                return true
            }
            let source: SearchSource<Schema> = .memory(newValue)
            kept.insert(source, at: 0)
            sources = kept
        }
    }

    /// The specification's `items`: the one-source convenience over ``memoryItems``.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    public var items: [any Searchable<Schema.Kind>] {
        get {
            var result: [any Searchable<Schema.Kind>] = []
            for item in memoryItems { result.append(item) }
            return result
        }
        set {
            let erased: [AnySearchable<Schema.Kind>] = newValue.map { AnySearchable($0) }
            memoryItems = erased
        }
    }

    /// `true` when at least one source is a database.
    public var hasDatabaseSources: Bool {
        sources.contains { source in
            if case .database = source { return true }
            return false
        }
    }
}
