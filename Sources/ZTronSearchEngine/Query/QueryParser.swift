import Foundation
import NaturalLanguage

/// One term of a parsed query, before the vocabulary is consulted.
struct QueryClause: Sendable, Hashable {
    /// Normalized term.
    var term: String
    /// The final token of the free text: expanded to vocabulary terms that start with it.
    var allowsPrefix: Bool
    /// Eligible for correction by the fuzzy channel.
    var allowsFuzzy: Bool
    /// Member of a required exact phrase.
    var isRequired: Bool
    /// For a word in a script without word spacing: its character bigrams, used when the word
    /// itself is not in the vocabulary because the indexer segmented the text differently.
    var bigramFallback: [String]
}

/// A query reduced to terms and phrases: the strategy-independent half of planning.
struct ParsedQuery: Sendable, Hashable {
    /// Clauses in query order: the order clause scores are summed in.
    var clauses: [QueryClause] = []
    /// Required exact phrases as sequences of normalized words.
    var phrases: [[String]] = []
    /// Longest fuzzy-eligible token, in normalized scalars. The fuzzy channel runs from 3.
    var longestTokenLength = 0
    /// Characters of free text, whitespace trimmed.
    var characterCount = 0
    /// The free text holds a character of a script without word spacing.
    var containsUnspacedScript = false
    /// Every free-text token is an identifier (digits, `-`, `_`, `.`): exact matching only.
    var isIdentifierOnly = false
    /// No free text and no phrase: only filters and kinds constrain.
    var isMatchAll: Bool { clauses.isEmpty && phrases.isEmpty }

    /// At most this many clauses are scored; a query is not a document.
    static let maximumClauses = 64
}

enum QueryParser {
    private static let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}"]

    /// Parses free text and phrase tokens.
    ///
    /// Quoted spans in the text are phrases too. The final free-text token is prefix-expandable
    /// unless whitespace follows it, which says the word is complete. Phrases, identifiers and
    /// token chips never take part in fuzzy expansion or prefix matching.
    static func parse(
        text: String,
        phrases phraseTokens: [String],
        language: String?,
        minimumFuzzyLength: Int,
        session: TokenizerSession
    ) -> ParsedQuery {
        var parsed = ParsedQuery()
        let (freeText, quoted) = splitQuotedPhrases(text)
        let trimmed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        parsed.characterCount = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        parsed.containsUnspacedScript = text.contains(where: ScriptClass.isUnspaced)

        var seen = Set<QueryClause>()
        func append(_ clause: QueryClause) {
            guard parsed.clauses.count < ParsedQuery.maximumClauses, seen.insert(clause).inserted else { return }
            parsed.clauses.append(clause)
        }

        // Free text.
        if !trimmed.isEmpty {
            let endsWithSpace = freeText.last.map(\.isWhitespace) ?? false
            let tokens = session.tokenize(freeText, language: language)
            let words = tokens.filter { $0.kind == .word }
            let lastWord = words.last
            var allIdentifiers = !words.isEmpty
            for token in tokens {
                switch token.kind {
                case .bigram:
                    continue
                case .compound:
                    append(QueryClause(term: token.term, allowsPrefix: false, allowsFuzzy: false, isRequired: false, bigramFallback: []))
                case .word:
                    // An identifier matches exactly only, as a whole: `m1912-a1` must not find
                    // `m1911-a1` through the part they share. The compound clause stands for it.
                    if token.isCompoundPart { continue }
                    let length = token.term.unicodeScalars.count
                    let isLast = lastWord.map { $0.range == token.range } ?? false
                    let isExact = token.isExactOnly
                    if !isExact { allIdentifiers = false }
                    let allowsFuzzy = !isExact && length >= minimumFuzzyLength
                    if allowsFuzzy { parsed.longestTokenLength = max(parsed.longestTokenLength, length) }
                    append(QueryClause(
                        term: token.term,
                        allowsPrefix: isLast && !endsWithSpace && !isExact,
                        allowsFuzzy: allowsFuzzy,
                        isRequired: false,
                        bigramFallback: bigrams(of: freeText[token.range], language: language, session: session)
                    ))
                }
            }
            parsed.isIdentifierOnly = allIdentifiers
        }

        // Phrases: quoted spans of the text, then phrase tokens.
        for phrase in quoted + phraseTokens {
            let words = session.words(phrase, language: language)
            guard !words.isEmpty else { continue }
            parsed.phrases.append(words)
            for word in words {
                append(QueryClause(term: word, allowsPrefix: false, allowsFuzzy: false, isRequired: true, bigramFallback: []))
            }
        }
        return parsed
    }

    /// Splits `"..."` spans out of the text. An opening quote without its partner is still
    /// being typed and stays ordinary text.
    static func splitQuotedPhrases(_ text: String) -> (free: String, phrases: [String]) {
        guard text.contains(where: quotes.contains) else { return (text, []) }
        var free = ""
        var phrases: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quotes.contains(character) {
                let after = text.index(after: index)
                if let close = text[after...].firstIndex(where: quotes.contains) {
                    let phrase = String(text[after..<close])
                    if phrase.contains(where: { !$0.isWhitespace }) { phrases.append(phrase) }
                    free.append(" ")
                    index = text.index(after: close)
                    continue
                }
                free.append(" ")
                index = after
                continue
            }
            free.append(character)
            index = text.index(after: index)
        }
        return (free, phrases)
    }

    /// The character bigrams of a word in a script without word spacing; empty for other words
    /// and for words of fewer than three characters, which need no decomposition.
    private static func bigrams(of word: Substring, language: String?, session: TokenizerSession) -> [String] {
        guard word.count >= 3, word.allSatisfy(ScriptClass.isUnspaced) else { return [] }
        var result: [String] = []
        var previous: Character?
        for character in word {
            if let before = previous {
                let term = SearchNormalizer.normalize(String([before, character]), language: language)
                if !term.isEmpty { result.append(term) }
            }
            previous = character
        }
        return result
    }

    /// The language `NLLanguageRecognizer` hints for a query of 8 or more characters, when it is
    /// confident and the language is one the index was built for (section 5, rule 10).
    static func hintedLanguage(for text: String, among indexed: [String]) -> String? {
        guard text.count >= 8, !indexed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.9 else {
            return nil
        }
        return indexed.first { LanguageTag.sameLanguage($0, language.rawValue) }
    }
}
