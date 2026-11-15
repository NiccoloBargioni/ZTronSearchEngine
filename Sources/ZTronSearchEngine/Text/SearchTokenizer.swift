import Foundation
import NaturalLanguage

/// One token of a field or of a query.
struct SearchToken {
    enum Kind: UInt8 {
        /// A word found by `NLTokenizer`. Words form the primary sequence of a field: they count
        /// toward its length and they are what phrases are verified against.
        case word
        /// Words joined by `-`, `_` or `.` with nothing else between them (`m1911-a1`,
        /// `ray_gun`, `example.com`), indexed whole next to their parts.
        case compound
        /// Two adjacent characters of a script written without word spacing.
        case bigram
    }

    /// Normalized text (specification section 5, rule 4).
    var term: String
    /// Where the token sits in the original, un-normalized string.
    var range: Range<String.Index>
    var kind: Kind
    /// Contains a digit or one of `-`, `_`, `.`: matches exactly only.
    var isExactOnly: Bool
    /// A word that is one part of a compound. In a query the whole identifier matches exactly
    /// only, so its parts are neither fuzzed nor completed either.
    var isCompoundPart = false
}

/// Tokenization (specification section 5, rule 5): `NLTokenizer(unit: .word)` with the field's
/// language when known, plus character bigrams for scripts without word spacing.
///
/// A session owns its `NLTokenizer` instances and a cache of normalized tokens, neither of which
/// is thread-safe, so a session is confined to one actor, one task or one thread. Synchronous
/// callers that have no session of their own use ``threadLocal``.
final class TokenizerSession {
    /// Tokens longer than this many UTF-8 bytes are not indexed: they are blobs, not words.
    static let maximumTermBytes = 80
    private static let cacheLimit = 50_000
    private static let threadKey = "com.ztron.searchengine.tokenizer"

    private var tokenizers: [String: NLTokenizer] = [:]
    private var normalizedCache: [String: [String: String]] = [:]
    private var wordRanges: [Range<String.Index>] = []

    init() {}

    /// The session of the calling thread. Only for synchronous code paths.
    static var threadLocal: TokenizerSession {
        let dictionary = Thread.current.threadDictionary
        if let existing = dictionary[threadKey] as? TokenizerSession {
            return existing
        }
        let created = TokenizerSession()
        dictionary[threadKey] = created
        return created
    }

    // MARK: Tokenizing

    /// Tokenizes `text`, appending to `tokens`: words and compounds in reading order, then bigrams.
    func tokenize(_ text: String, language: String?, into tokens: inout [SearchToken]) {
        guard !text.isEmpty else { return }
        let languageKey = Self.languageKey(for: language)
        let tokenizer = tokenizer(forKey: languageKey)
        tokenizer.string = text
        wordRanges.removeAll(keepingCapacity: true)
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            self.appendWord(text, range)
            return true
        }
        tokenizer.string = nil

        var index = 0
        while index < wordRanges.count {
            // A chain of words separated by exactly one connector character is one identifier.
            var last = index
            while last + 1 < wordRanges.count,
                  Self.isSingleConnector(text, from: wordRanges[last].upperBound, to: wordRanges[last + 1].lowerBound) {
                last += 1
            }
            for position in index...last {
                appendToken(text, wordRanges[position], kind: .word, languageKey: languageKey, isCompoundPart: last > index, into: &tokens)
            }
            if last > index {
                let whole = wordRanges[index].lowerBound..<wordRanges[last].upperBound
                appendToken(text, whole, kind: .compound, languageKey: languageKey, into: &tokens)
            }
            index = last + 1
        }

        if Self.mayContainUnspacedScript(text) {
            appendBigrams(text, languageKey: languageKey, into: &tokens)
        }
    }

    func tokenize(_ text: String, language: String?) -> [SearchToken] {
        var tokens: [SearchToken] = []
        tokenize(text, language: language, into: &tokens)
        return tokens
    }

    /// The normalized words of `text`, in order: the primary sequence phrases are verified against.
    func words(_ text: String, language: String?) -> [String] {
        tokenize(text, language: language).compactMap { $0.kind == .word ? $0.term : nil }
    }

    // MARK: Pieces

    /// Records a word the tokenizer found. A word it kept whole across an apostrophe
    /// (`dell'isola`, `l’eau`, `harbor's`) is recorded as its parts: the noun has to be findable
    /// without its article, and a typed `l'isola` has to find `dell'isola`.
    private func appendWord(_ text: String, _ range: Range<String.Index>) {
        var mayHoldApostrophe = false
        for byte in text.utf8[range] where byte == 0x27 || byte == 0xE2 || byte == 0xCA {
            mayHoldApostrophe = true
            break
        }
        guard mayHoldApostrophe else {
            wordRanges.append(range)
            return
        }
        let scalars = text.unicodeScalars
        var start = range.lowerBound
        var index = range.lowerBound
        while index < range.upperBound {
            let next = scalars.index(after: index)
            // The typewriter apostrophe, the typographic one and the modifier letter.
            if scalars[index].value == 0x27 || scalars[index].value == 0x2019 || scalars[index].value == 0x02BC {
                if start < index { wordRanges.append(start..<index) }
                start = next
            }
            index = next
        }
        if start < range.upperBound { wordRanges.append(start..<range.upperBound) }
    }

    private func appendToken(
        _ text: String,
        _ range: Range<String.Index>,
        kind: SearchToken.Kind,
        languageKey: String,
        isCompoundPart: Bool = false,
        into tokens: inout [SearchToken]
    ) {
        let (term, isExactOnly) = normalizedTerm(text[range], languageKey: languageKey)
        guard !term.isEmpty, term.utf8.count <= Self.maximumTermBytes else { return }
        tokens.append(SearchToken(
            term: term, range: range, kind: kind, isExactOnly: isExactOnly, isCompoundPart: isCompoundPart
        ))
    }

    private func appendBigrams(_ text: String, languageKey: String, into tokens: inout [SearchToken]) {
        let existing = Set(wordRanges)
        var previous: (start: String.Index, end: String.Index)?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ScriptClass.isUnspaced(text[index]) {
                if let before = previous {
                    let range = before.start..<next
                    if !existing.contains(range) {
                        appendToken(text, range, kind: .bigram, languageKey: languageKey, into: &tokens)
                    }
                }
                previous = (index, next)
            } else {
                previous = nil
            }
            index = next
        }
    }

    /// `true` when the text between two words is exactly one connector character: `-`, `_`,
    /// `.`, or one of the two Unicode hyphens (U+2010, U+2011).
    private static func isSingleConnector(_ text: String, from: String.Index, to: String.Index) -> Bool {
        guard from < to else { return false }
        let utf8 = text.utf8
        switch utf8.distance(from: from, to: to) {
        case 1:
            let byte = utf8[from]
            return byte == 0x2D || byte == 0x5F || byte == 0x2E
        case 3:
            let second = utf8.index(after: from)
            let third = utf8.index(after: second)
            return utf8[from] == 0xE2 && utf8[second] == 0x80 && (utf8[third] == 0x90 || utf8[third] == 0x91)
        default:
            return false
        }
    }

    /// Every unspaced script starts at U+0E00 or later, so its UTF-8 lead bytes are 0xE0 or more.
    private static func mayContainUnspacedScript(_ text: String) -> Bool {
        text.utf8.contains { $0 >= 0xE0 }
    }

    /// The normalized form of a token and whether it matches exactly only.
    ///
    /// ASCII, the common case, takes one pass: its normalization is lower-casing, and it is
    /// exact-only when it holds a digit or one of `-`, `_`, `.`.
    private func normalizedTerm(_ raw: Substring, languageKey: String) -> (term: String, isExactOnly: Bool) {
        var isASCII = true
        var hasUppercase = false
        var isExactOnly = false
        for byte in raw.utf8 {
            if byte >= 0x80 { isASCII = false; break }
            if byte >= 0x41 && byte <= 0x5A {
                hasUppercase = true
            } else if (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F || byte == 0x2E {
                isExactOnly = true
            }
        }
        if isASCII {
            guard hasUppercase else { return (String(raw), isExactOnly) }
            let lowered = raw.utf8.withContiguousStorageIfAvailable { bytes in
                String(unsafeUninitializedCapacity: bytes.count) { buffer in
                    for index in 0..<bytes.count {
                        let byte = bytes[index]
                        buffer[index] = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
                    }
                    return bytes.count
                }
            }
            return (lowered ?? String(raw).lowercased(), isExactOnly)
        }
        let key = String(raw)
        if let cached = normalizedCache[languageKey]?[key] {
            return (cached, ScriptClass.isExactOnly(cached))
        }
        let locale: Locale? = languageKey.isEmpty ? nil : Locale(identifier: languageKey)
        let normalized = SearchNormalizer.normalize(key, locale: locale)
        if (normalizedCache[languageKey]?.count ?? 0) >= Self.cacheLimit {
            normalizedCache[languageKey] = [:]
        }
        normalizedCache[languageKey, default: [:]][key] = normalized
        return (normalized, ScriptClass.isExactOnly(normalized))
    }

    private func tokenizer(forKey languageKey: String) -> NLTokenizer {
        if let existing = tokenizers[languageKey] {
            return existing
        }
        let created = NLTokenizer(unit: .word)
        if !languageKey.isEmpty {
            created.setLanguage(NLLanguage(rawValue: languageKey))
        }
        tokenizers[languageKey] = created
        return created
    }

    /// The `NLLanguage` code of a BCP 47 tag: the language subtag, or the script-qualified
    /// Chinese codes Natural Language expects.
    static func languageKey(for tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return "" }
        let canonical = LanguageTag.canonical(tag)
        let language = LanguageTag.language(of: canonical)
        guard language == "zh" else { return language }
        let lowered = canonical.lowercased()
        if lowered.contains("hant") || lowered.hasSuffix("-tw") || lowered.hasSuffix("-hk") || lowered.hasSuffix("-mo") {
            return "zh-Hant"
        }
        return "zh-Hans"
    }
}
