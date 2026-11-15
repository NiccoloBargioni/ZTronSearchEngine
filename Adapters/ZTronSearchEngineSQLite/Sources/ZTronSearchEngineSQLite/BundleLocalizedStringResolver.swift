import Foundation
import ZTronSearchEngine

/// Resolves localization keys from the strings tables of the host's bundles
/// (specification section 9.2: "`Bundle.localizedString(forKey:value:table:)` on the language
/// bundle, cached").
///
/// A field declared as `.localizedKey(table:bundle:)` names its bundle by a `SearchBundleID`.
/// The host registers the bundle behind each id here; `.main` is `Bundle.main` unless the host
/// registers another:
///
///     let resolver = BundleLocalizedStringResolver(bundles: ["catalog": catalogBundle])
///     let context = SearchContext<Schema>(id: "catalog", sources: sources, localizedStrings: resolver)
///
/// ## Languages
///
/// A language is one `.lproj` directory of a bundle, under the name of the directory (`en`,
/// `it`, `pt-BR`); `Base.lproj` is not a language. ``languages(bundle:table:)`` lists the
/// languages that have the table, the bundle's development localization first, because core
/// takes the first language as the base every other one falls back to.
///
/// ## Caching, and why the resolver holds no cache of its own
///
/// Everything the resolver knows is worked out once, in the initializer, and never changes:
/// the registered bundles, their languages and the `Bundle` of each language directory. That
/// makes it `Sendable` by construction, with no lock, no queue and no actor between a caller
/// and a string.
///
/// The strings themselves are cached by Foundation: a `Bundle` parses a strings table the
/// first time it is asked for one of its keys and keeps it for as long as the bundle lives,
/// and the resolver keeps the language bundles alive. A lookup after the first is a dictionary
/// lookup in memory (well under a microsecond), per bundle, table, language and key. Copying
/// the strings into a second cache would have to be guarded by a lock, which the iOS 15 floor
/// does not offer in checked form, and would hold every catalog string in memory twice.
public struct BundleLocalizedStringResolver: LocalizedStringResolving {
    private struct Catalog: Sendable {
        /// The development localization first, the others in alphabetical order.
        let languages: [String]
        /// The bundle of each language directory.
        let bundles: [String: Bundle]
    }

    /// What `Bundle` is told to return for a key it does not have. No strings table holds it.
    private static let missing = "\u{1}ZTronSearchEngineSQLite.missing\u{1}"

    private let catalogs: [SearchBundleID: Catalog]

    /// Registers the bundles the localized fields refer to.
    ///
    /// - Parameter bundles: The bundle behind each id. `.main` stands for `Bundle.main` unless
    ///   it is given here.
    public init(bundles: [SearchBundleID: Bundle] = [:]) {
        var registered: [SearchBundleID: Bundle] = [.main: .main]
        registered.merge(bundles) { _, host in host }
        catalogs = registered.mapValues(Self.catalog(of:))
    }

    /// The string of `key` in one language, or `nil` when that language has none. The key
    /// itself is never returned in place of a missing string.
    ///
    /// - Parameters:
    ///   - table: The strings table; `nil` is `Localizable`.
    ///   - language: A language as ``languages(bundle:table:)`` lists it.
    public func string(forKey key: String, table: String?, bundle: SearchBundleID, language: String) -> String? {
        guard let languageBundle = catalogs[bundle]?.bundles[language] else { return nil }
        let string = languageBundle.localizedString(forKey: key, value: Self.missing, table: table)
        return string == Self.missing ? nil : string
    }

    /// The languages of `bundle` that have `table`, the development localization first.
    ///
    /// - Parameter table: The strings table; `nil` is `Localizable`.
    public func languages(bundle: SearchBundleID, table: String?) -> [String] {
        guard let catalog = catalogs[bundle] else { return [] }
        let name = table ?? "Localizable"
        return catalog.languages.filter { language in
            guard let languageBundle = catalog.bundles[language] else { return false }
            return languageBundle.url(forResource: name, withExtension: "strings") != nil
                || languageBundle.url(forResource: name, withExtension: "stringsdict") != nil
        }
    }

    private static func catalog(of bundle: Bundle) -> Catalog {
        var bundles: [String: Bundle] = [:]
        for language in bundle.localizations where language != "Base" {
            guard let url = bundle.url(forResource: language, withExtension: "lproj"),
                  let languageBundle = Bundle(url: url) else { continue }
            bundles[language] = languageBundle
        }
        var languages = bundles.keys.sorted()
        if let development = developmentLanguage(of: bundle, among: languages), let index = languages.firstIndex(of: development) {
            languages.remove(at: index)
            languages.insert(development, at: 0)
        }
        return Catalog(languages: languages, bundles: bundles)
    }

    /// The language directory of the bundle's development localization: the one of that very
    /// name, or else the one that names the same language (`en` for a development region
    /// spelled `English` or `en_US`).
    private static func developmentLanguage(of bundle: Bundle, among languages: [String]) -> String? {
        guard let development = bundle.developmentLocalization else { return nil }
        if languages.contains(development) { return development }
        let canonical = Locale.canonicalLanguageIdentifier(from: development)
        if let match = languages.first(where: { Locale.canonicalLanguageIdentifier(from: $0) == canonical }) {
            return match
        }
        let language = canonical.split(separator: "-").first.map(String.init)
        return languages.first { Locale.canonicalLanguageIdentifier(from: $0).split(separator: "-").first.map(String.init) == language }
    }
}
