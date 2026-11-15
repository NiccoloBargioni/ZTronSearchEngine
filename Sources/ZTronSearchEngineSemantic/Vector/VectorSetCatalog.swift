import Foundation
import os

/// The vector sets a build or sync pipeline ships: one for the base language and, optionally,
/// one per locale.
///
/// Specification section 5, rule 8: item vectors are computed from the base-language
/// composition and the multilingual model carries cross-language matching; a pipeline may also
/// ship per-locale sets, in which case the engine loads the set of the active locale and falls
/// back to the base set. Items are never re-embedded on device.
///
/// A set is a vector file (``QuantizedVectorStore``) and, next to it, the graph file
/// (``HNSWIndex``) built over it.
public struct VectorSetCatalog: Sendable, Hashable {
    /// The files of one vector set.
    public struct Files: Sendable, Hashable {
        /// The vector file.
        public var vectors: URL
        /// The graph file built over `vectors`; `nil` when the graph is built on device.
        public var graph: URL?

        /// Creates the files of a set.
        public init(vectors: URL, graph: URL? = nil) {
            self.vectors = vectors
            self.graph = graph
        }
    }

    /// The outcome of resolving a locale against the catalog.
    public struct Resolution: Sendable, Hashable {
        /// The key of the per-locale set that was chosen; `nil` when the base set was.
        public let languageTag: String?
        /// The files of the chosen set.
        public let files: Files
    }

    /// The set computed from the base-language composition. Every catalog has one.
    public var base: Files
    /// Per-locale sets, keyed by BCP 47 tag (`"it"`, `"de-CH"`, `"zh-Hans"`).
    public var localized: [String: Files]

    /// Creates a catalog from a base set and the per-locale sets.
    public init(base: Files, localized: [String: Files] = [:]) {
        self.base = base
        self.localized = localized
    }

    /// The set to load for a locale.
    ///
    /// The chain is the one the engine uses for localized fields (section 5, rule 2): the exact
    /// tag, then the match `Bundle.preferredLocalizations(from:forPreferences:)` picks among the
    /// sets of the same language, then the bare language, then the base set.
    public func resolve(_ languageTag: String?) -> Resolution {
        guard let languageTag, !languageTag.isEmpty, !localized.isEmpty else {
            return Resolution(languageTag: nil, files: base)
        }
        let available = localized.keys.sorted()
        let wanted = Self.canonical(languageTag)
        let wantedLanguage = Self.language(of: wanted)

        if let exact = available.first(where: { Self.canonical($0).caseInsensitiveCompare(wanted) == .orderedSame }),
           let files = localized[exact] {
            return Resolution(languageTag: exact, files: files)
        }
        // Apple's matcher answers with an arbitrary available localization when nothing
        // matches, so its answer only counts when the language agrees.
        for match in Bundle.preferredLocalizations(from: available, forPreferences: [wanted])
        where Self.language(of: Self.canonical(match)) == wantedLanguage {
            if let files = localized[match] {
                return Resolution(languageTag: match, files: files)
            }
        }
        if let bare = available.first(where: { Self.canonical($0).lowercased() == wantedLanguage }),
           let files = localized[bare] {
            return Resolution(languageTag: bare, files: files)
        }
        return Resolution(languageTag: nil, files: base)
    }

    /// Opens the vector file of the set for a locale, memory-mapped.
    ///
    /// When the per-locale file cannot be used (missing, unreadable, written for another
    /// model), the base file is opened instead; only a failure of the base file is thrown.
    public func openStore(
        for languageTag: String?,
        expecting expectation: QuantizedVectorStore.Expectation? = nil
    ) throws -> (store: QuantizedVectorStore, resolution: Resolution) {
        let resolution = resolve(languageTag)
        if resolution.languageTag != nil {
            do {
                return (try QuantizedVectorStore.open(resolution.files.vectors, expecting: expectation), resolution)
            } catch {
                Logger.semantic.error(
                    "vector set '\(resolution.languageTag ?? "", privacy: .public)' is unusable, falling back to the base set: \(String(describing: error), privacy: .public)"
                )
            }
        }
        let fallback = Resolution(languageTag: nil, files: base)
        return (try QuantizedVectorStore.open(base.vectors, expecting: expectation), fallback)
    }

    // MARK: Discovery

    /// The extension graph files are written with.
    public static let graphFileExtension = "zthnsw"

    /// Builds a catalog from the files of a directory that follow the naming convention
    ///
    ///     <name>.ztvec          <name>.zthnsw            base set
    ///     <name>.<tag>.ztvec    <name>.<tag>.zthnsw      per-locale set, e.g. vectors.it.ztvec
    ///
    /// - Returns: `nil` when the directory holds no base vector file.
    public static func discover(in directory: URL, name: String = "vectors") async throws -> VectorSetCatalog? {
        let names = Set(try await FileAccess.fileNames(in: directory))
        let vectorSuffix = "." + QuantizedVectorStore.fileExtension
        let graphSuffix = "." + graphFileExtension

        func files(stem: String) -> Files? {
            guard names.contains(stem + vectorSuffix) else { return nil }
            let graphName = stem + graphSuffix
            return Files(
                vectors: directory.appendingPathComponent(stem + vectorSuffix),
                graph: names.contains(graphName) ? directory.appendingPathComponent(graphName) : nil
            )
        }

        guard let base = files(stem: name) else { return nil }
        var localized: [String: Files] = [:]
        let prefix = name + "."
        for fileName in names where fileName.hasPrefix(prefix) && fileName.hasSuffix(vectorSuffix) {
            let tag = String(fileName.dropFirst(prefix.count).dropLast(vectorSuffix.count))
            guard !tag.isEmpty, fileName.count > prefix.count + vectorSuffix.count,
                  let set = files(stem: prefix + tag) else { continue }
            localized[tag] = set
        }
        return VectorSetCatalog(base: base, localized: localized)
    }

    // MARK: Tags

    /// Canonical BCP 47 spelling of a tag or locale identifier: `it_IT` becomes `it-IT`,
    /// keywords are dropped.
    static func canonical(_ identifier: String) -> String {
        var trimmed = identifier
        if let at = trimmed.firstIndex(of: "@") {
            trimmed = String(trimmed[..<at])
        }
        let canonical = Locale.canonicalLanguageIdentifier(from: trimmed)
        return canonical.isEmpty ? trimmed.replacingOccurrences(of: "_", with: "-") : canonical
    }

    /// The primary language subtag, lowercased: `it` for `it-IT`.
    static func language(of tag: String) -> String {
        let end = tag.firstIndex(where: { $0 == "-" || $0 == "_" }) ?? tag.endIndex
        return tag[..<end].lowercased()
    }
}

extension Logger {
    /// The unified log category of the semantic channel.
    static let semantic = Logger(subsystem: "com.ztron.searchengine", category: "semantic")
}
