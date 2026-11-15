import Foundation

/// BCP 47 helpers and the localization fallback chain of specification section 5.
enum LanguageTag {
    /// The BCP 47 tag of a locale: `it_IT` becomes `it-IT`, keywords are dropped.
    static func tag(for locale: Locale) -> String {
        canonical(locale.identifier)
    }

    /// Canonical BCP 47 spelling of a tag or locale identifier.
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

    /// The localizations to try for `preference`, best first: the exact tag, then the language
    /// match Apple's rules pick. The base surface follows the chain and is not part of it.
    ///
    /// `Bundle.preferredLocalizations(from:forPreferences:)` does the matching so fallbacks
    /// follow Apple's rules. It answers with an arbitrary available localization when nothing
    /// matches, so its answer only counts when the language agrees.
    static func chain(available: [String], preference: String) -> [String] {
        guard !available.isEmpty else { return [] }
        let wanted = canonical(preference)
        let wantedLanguage = language(of: wanted)
        var chain: [String] = []

        if let exact = available.first(where: { canonical($0).caseInsensitiveCompare(wanted) == .orderedSame }) {
            chain.append(exact)
        }
        for match in Bundle.preferredLocalizations(from: available, forPreferences: [wanted])
        where language(of: canonical(match)) == wantedLanguage && !chain.contains(match) {
            chain.append(match)
        }
        // The bare language entry is a legitimate fallback even when Apple's matcher preferred a
        // regional variant.
        if let bare = available.first(where: { canonical($0).lowercased() == wantedLanguage }), !chain.contains(bare) {
            chain.append(bare)
        }
        return chain
    }

    /// `true` when two tags name the same language, whatever their region or script.
    static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        language(of: canonical(lhs)) == language(of: canonical(rhs))
    }
}

/// The languages one index generation is built for. Resolved once per generation.
public struct ResolvedLanguages: Sendable, Hashable {
    /// BCP 47 tag of the active locale.
    public let active: String
    /// BCP 47 tags whose surfaces feed `localizedAlt`, in preference order, without `active`.
    public let secondary: [String]
    /// `true` when every language an item is localized in feeds `localizedAlt`.
    public let includesAllLanguages: Bool

    public init(active: String, secondary: [String] = [], includesAllLanguages: Bool = false) {
        self.active = LanguageTag.canonical(active)
        var seen: Set<String> = [LanguageTag.language(of: self.active)]
        var unique: [String] = []
        for tag in secondary {
            let canonical = LanguageTag.canonical(tag)
            // A regional variant of the active language is the active language for this purpose.
            if seen.insert(LanguageTag.language(of: canonical)).inserted {
                unique.append(canonical)
            }
        }
        self.secondary = unique
        self.includesAllLanguages = includesAllLanguages
    }

    /// Resolves the policy of a configuration for a locale.
    public init(locale: Locale, configuration: SearchEngineConfiguration) {
        let active = LanguageTag.tag(for: locale)
        switch configuration.secondaryLanguages {
        case .preferredLanguages:
            self.init(active: active, secondary: configuration.preferredLanguages())
        case .explicit(let tags):
            self.init(active: active, secondary: tags)
        case .all:
            self.init(active: active, secondary: configuration.preferredLanguages(), includesAllLanguages: true)
        case .none:
            self.init(active: active)
        }
    }
}
