import Foundation

/// The word classes the fixtures compose titles and texts from.
public enum FixtureWordClass: String, Sendable, Hashable, CaseIterable {
    case adjective
    case noun
    case place
    case action
    case object
}

/// Grammatical gender of an Italian or German noun. Italian has no neuter.
public enum FixtureGender: String, Sendable, Hashable {
    case masculine
    case feminine
    case neuter
}

/// What a concept is used for when the golden corpus is composed.
///
/// A role is finer than a word class: `tag`, `toolNoun` and `theme` are all nouns, but they fill
/// different slots of a title.
public enum FixtureConceptRole: String, Sendable, Hashable, CaseIterable {
    /// An adjective that describes a place, an object or a theme.
    case descriptor
    case place
    /// An evocative noun for the title of a game.
    case theme
    case object
    /// An object used once, as the keyword of a single golden item.
    case rareObject
    /// An activity, as a verbal noun.
    case action
    /// What a map shows: route, overview, layout.
    case mapNoun
    /// What a tip is: guide, basics, tricks.
    case tipNoun
    /// What a tool is: calculator, journal, planner.
    case toolNoun
    /// What an image is: sunrise, screenshot, sketch.
    case viewNoun
    /// A genre or feature used as a keyword.
    case tag
    /// Reserved for items without localizations: a noun used as a modifier.
    case reservedModifier
    /// Reserved for items without localizations: a place.
    case reservedPlace
    /// Reserved for items without localizations: an object.
    case reservedObject
    /// Reserved for items without localizations: a theme.
    case reservedTheme

    /// The word class of every concept with this role.
    public var wordClass: FixtureWordClass {
        switch self {
        case .descriptor: return .adjective
        case .place, .reservedPlace: return .place
        case .object, .rareObject, .reservedObject: return .object
        case .action: return .action
        case .theme, .mapNoun, .tipNoun, .toolNoun, .viewNoun, .tag, .reservedModifier, .reservedTheme: return .noun
        }
    }

    /// `true` for the roles whose concepts only appear in golden items that carry no
    /// localization. Their Italian, German and Japanese forms never reach an index, so a query
    /// written with them can only be answered by the semantic channel.
    public var isReserved: Bool {
        switch self {
        case .reservedModifier, .reservedPlace, .reservedObject, .reservedTheme: return true
        default: return false
        }
    }
}

/// One meaning, with its words in four languages.
///
/// The English lemma, the English synonyms and every translation map to the same concept in the
/// fake embedding space, which is what lets a synonym or a foreign-language query find an item
/// that shares no token with it.
public struct FixtureConcept: Sendable, Hashable, Identifiable {
    /// Stable, dense identifier: the position of the concept in ``FixtureLexicon/concepts``.
    public let id: Int
    /// What the concept is used for when titles and texts are composed.
    public let role: FixtureConceptRole
    /// English lemma: one lowercase word. The only English form the golden corpus ever writes.
    public let lemma: String
    /// English synonyms, one lowercase word each. They never appear in the golden corpus.
    public let synonyms: [String]
    /// Italian citation form: a noun, or the masculine singular of an adjective.
    public let italian: String
    /// German citation form: a capitalized noun, or the uninflected stem of an adjective.
    public let german: String
    /// Japanese form: a noun, or the attributive form of an adjective, ready to precede a noun.
    public let japanese: String
    /// Gender of the Italian noun; `nil` for adjectives.
    public let italianGender: FixtureGender?
    /// Gender of the German noun; `nil` for adjectives.
    public let germanGender: FixtureGender?

    /// The word class of the concept.
    public var wordClass: FixtureWordClass { role.wordClass }
    /// `true` when the concept only appears in golden items that carry no localization.
    public var isReserved: Bool { role.isReserved }

    /// The citation form in a language: `"en"`, `"it"`, `"de"` or `"ja"`. Any other tag yields
    /// the English lemma.
    public func form(in language: String) -> String {
        switch language {
        case "it": return italian
        case "de": return german
        case "ja": return japanese
        default: return lemma
        }
    }

    /// The Italian form next to a noun of the given gender. Nouns are returned unchanged;
    /// adjectives in `-o` take `-a` in the feminine, every other adjective is invariable.
    public func italianForm(agreeingWith gender: FixtureGender) -> String {
        guard wordClass == .adjective, gender == .feminine, italian.hasSuffix("o") else { return italian }
        return String(italian.dropLast()) + "a"
    }

    /// The German form in front of a noun of the given gender, nominative singular without an
    /// article: `gefrorener Hafen`, `gefrorene Bucht`, `gefrorenes Tal`. Nouns are returned
    /// unchanged.
    public func germanForm(agreeingWith gender: FixtureGender) -> String {
        guard wordClass == .adjective else { return german }
        switch gender {
        case .masculine: return german + "er"
        case .feminine: return german + "e"
        case .neuter: return german + "es"
        }
    }

    /// Every form of the concept that a text in `language` may contain, inflections included.
    public func surfaceForms(in language: String) -> [String] {
        switch language {
        case "en":
            return [lemma] + synonyms
        case "it":
            let feminine = italianForm(agreeingWith: .feminine)
            return feminine == italian ? [italian] : [italian, feminine]
        case "de":
            guard wordClass == .adjective else { return [german] }
            return [german, german + "er", german + "e", german + "es", german + "en"]
        case "ja":
            return [japanese]
        default:
            return []
        }
    }
}

/// A curated multilingual lexicon of concepts.
///
/// Domain: a generic game-companion catalog. The content is invented and brand-neutral. The
/// golden corpus, the golden queries and the fake embedding space are all derived from it.
public enum FixtureLexicon {
    /// The languages every concept has a form in, as BCP 47 tags. English is the base language
    /// of the golden corpus; Japanese is the non-Latin one.
    public static let languages = ["en", "it", "de", "ja"]

    /// Every concept, in a fixed order. `concepts[id].id == id`.
    public static let concepts: [FixtureConcept] = makeConcepts()

    /// The concept with a given identifier.
    public static func concept(_ id: Int) -> FixtureConcept {
        concepts[id]
    }

    /// The concepts with a given role, in lexicon order.
    public static func concepts(in role: FixtureConceptRole) -> [FixtureConcept] {
        concepts.filter { $0.role == role }
    }

    /// The concepts of a word class, in lexicon order.
    public static func concepts(of wordClass: FixtureWordClass) -> [FixtureConcept] {
        concepts.filter { $0.wordClass == wordClass }
    }

    /// The concept a Latin-script word belongs to, in any of English, Italian and German.
    /// The word is folded first: case and diacritics do not matter.
    public static func conceptID(forWord word: String) -> Int? {
        index.latin[FixtureText.fold(word)]
    }

    /// The concepts a text mentions, in reading order, one entry per mention.
    ///
    /// Latin-script text is split into words and each word is looked up. Japanese text is
    /// matched against the lexicon's forms by substring, longest form first.
    public static func conceptIDs(in text: String) -> [Int] {
        var ids: [Int] = []
        let index = self.index
        FixtureText.scan(text) { piece in
            switch piece {
            case .latin(let bytes):
                if let id = index.table.lookup(bytes) { ids.append(id) }
            case .japanese(let scalars):
                index.matchJapanese(scalars, onConcept: { ids.append($0) }, onUnknown: { _ in })
            }
        }
        return ids
    }

    /// Every folded Latin-script form of the lexicon: lemmas, synonyms, Italian and German forms
    /// with their inflections.
    public static var latinForms: Set<String> {
        Set(index.latin.keys)
    }

    static let index = LexiconIndex(concepts: concepts)

    // MARK: Construction

    private static func makeConcepts() -> [FixtureConcept] {
        var result: [FixtureConcept] = []

        func add(_ rows: [AdjectiveRow], _ role: FixtureConceptRole) {
            for row in rows {
                result.append(FixtureConcept(
                    id: result.count, role: role, lemma: row.lemma, synonyms: words(row.synonyms),
                    italian: row.italian, german: row.german, japanese: row.japanese,
                    italianGender: nil, germanGender: nil
                ))
            }
        }
        func add(_ rows: [NounRow], _ role: FixtureConceptRole) {
            for row in rows {
                result.append(FixtureConcept(
                    id: result.count, role: role, lemma: row.lemma, synonyms: words(row.synonyms),
                    italian: row.italian, german: row.german, japanese: row.japanese,
                    italianGender: row.italianGender, germanGender: row.germanGender
                ))
            }
        }

        // The order is part of the fixture: identifiers, and with them the fake embedding
        // space, depend on it. New rows go at the end of their group; new groups at the end.
        add(descriptorRows, .descriptor)
        add(placeRows, .place)
        add(themeRows, .theme)
        add(objectRows, .object)
        add(actionRows, .action)
        add(mapNounRows, .mapNoun)
        add(tipNounRows, .tipNoun)
        add(toolNounRows, .toolNoun)
        add(viewNounRows, .viewNoun)
        add(tagRows, .tag)
        add(rareObjectRows, .rareObject)
        add(reservedModifierRows, .reservedModifier)
        add(reservedPlaceRows, .reservedPlace)
        add(reservedObjectRows, .reservedObject)
        add(reservedThemeRows, .reservedTheme)
        return result
    }

    private static func words(_ list: String) -> [String] {
        list.split(separator: " ").map(String.init)
    }

    // MARK: Validation

    /// Checks the rules the fixtures rely on and returns one line per problem; empty when the
    /// lexicon is sound.
    public static func validate() -> [String] {
        var problems: [String] = []
        if concepts.count < 160 {
            problems.append("only \(concepts.count) concepts; at least 160 are required")
        }
        for wordClass in FixtureWordClass.allCases where concepts(of: wordClass).isEmpty {
            problems.append("no concept of class \(wordClass.rawValue)")
        }

        var owners: [String: Int] = [:]
        var japaneseOwners: [String: Int] = [:]
        for (position, concept) in concepts.enumerated() {
            if concept.id != position {
                problems.append("\(concept.lemma): id \(concept.id) is not its position \(position)")
            }
            if concept.synonyms.isEmpty {
                problems.append("\(concept.lemma): no synonym")
            }
            var forms: [String] = []
            for language in ["en", "it", "de"] {
                for form in concept.surfaceForms(in: language) {
                    let tokens = FixtureText.latinTokens(form)
                    if tokens.count != 1 {
                        problems.append("\(concept.lemma): '\(form)' is not a single word")
                        continue
                    }
                    if tokens[0].count < 3 {
                        problems.append("\(concept.lemma): '\(form)' is shorter than three letters")
                    }
                    forms.append(tokens[0])
                }
            }
            let lemma = FixtureText.fold(concept.lemma)
            for synonym in concept.synonyms where FixtureText.fold(synonym) == lemma {
                problems.append("\(concept.lemma): synonym '\(synonym)' is the lemma")
            }
            if concept.lemma != concept.lemma.lowercased() || concept.synonyms.contains(where: { $0 != $0.lowercased() }) {
                problems.append("\(concept.lemma): English forms must be lowercase")
            }
            for form in Set(forms) {
                if let owner = owners[form], owner != concept.id {
                    problems.append("'\(form)' belongs to both \(concepts[owner].lemma) and \(concept.lemma)")
                } else {
                    owners[form] = concept.id
                }
            }

            if concept.japanese.isEmpty || !concept.japanese.unicodeScalars.allSatisfy({ FixtureText.isJapanese($0.value) }) {
                problems.append("\(concept.lemma): '\(concept.japanese)' is not Japanese text")
            }
            if let owner = japaneseOwners[concept.japanese] {
                problems.append("'\(concept.japanese)' belongs to both \(concepts[owner].lemma) and \(concept.lemma)")
            } else {
                japaneseOwners[concept.japanese] = concept.id
            }

            if concept.wordClass == .adjective {
                if !(concept.italian.hasSuffix("o") || concept.italian.hasSuffix("e") || concept.italian.hasSuffix("i")) {
                    problems.append("\(concept.lemma): Italian adjective '\(concept.italian)' has no regular feminine")
                }
                if concept.german.hasSuffix("e") || concept.german.hasSuffix("el") {
                    problems.append("\(concept.lemma): German adjective '\(concept.german)' does not inflect regularly")
                }
                if concept.german != concept.german.lowercased() {
                    problems.append("\(concept.lemma): German adjective '\(concept.german)' must be lowercase")
                }
            } else {
                if concept.italianGender == nil || concept.germanGender == nil {
                    problems.append("\(concept.lemma): noun without gender")
                }
                if concept.italianGender == .neuter {
                    problems.append("\(concept.lemma): Italian has no neuter")
                }
                if concept.german.first?.isUppercase != true {
                    problems.append("\(concept.lemma): German noun '\(concept.german)' must be capitalized")
                }
            }
        }
        return problems
    }
}

// MARK: - Lookup

/// The lookup structures of the lexicon, built once.
struct LexiconIndex: Sendable {
    /// Folded Latin-script form to concept.
    let latin: [String: Int]
    /// The same mapping keyed by the bytes of a folded token, for the embedding's hot path.
    let table: TokenTable
    /// Japanese forms as scalars, keyed by their first scalar, longest first.
    let japanese: [UInt32: [JapaneseForm]]
    /// Every folded Latin-script form, sorted by its bytes, with its concept and letter set.
    let forms: [LatinForm]

    struct LatinForm: Sendable {
        let bytes: [UInt8]
        let concept: Int
        /// The letters `a` to `z` the form contains, as a bit mask.
        let letters: UInt32
    }

    struct JapaneseForm: Sendable {
        let scalars: [UInt32]
        let concept: Int
    }

    init(concepts: [FixtureConcept]) {
        var latin: [String: Int] = [:]
        var japanese: [UInt32: [JapaneseForm]] = [:]
        for concept in concepts {
            for language in ["en", "it", "de"] {
                for form in concept.surfaceForms(in: language) {
                    let folded = FixtureText.fold(form)
                    // First owner wins; `FixtureLexicon.validate()` reports any second one.
                    if !folded.isEmpty, latin[folded] == nil { latin[folded] = concept.id }
                }
            }
            let scalars = concept.japanese.unicodeScalars.map(\.value)
            if let first = scalars.first {
                japanese[first, default: []].append(JapaneseForm(scalars: scalars, concept: concept.id))
            }
        }
        for key in japanese.keys {
            japanese[key]?.sort { lhs, rhs in
                lhs.scalars.count != rhs.scalars.count ? lhs.scalars.count > rhs.scalars.count : lhs.concept < rhs.concept
            }
        }
        self.latin = latin
        self.japanese = japanese
        self.table = TokenTable(latin)
        self.forms = latin.keys
            .map { key -> LatinForm in
                let bytes = Array(key.utf8)
                return LatinForm(bytes: bytes, concept: latin[key] ?? 0, letters: LexiconIndex.letters(of: bytes))
            }
            .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }

    /// The set of letters `a` to `z` among some bytes, as a bit mask.
    static func letters(of bytes: some Sequence<UInt8>) -> UInt32 {
        var mask: UInt32 = 0
        for byte in bytes where byte >= 0x61 && byte <= 0x7A {
            mask |= 1 << UInt32(byte - 0x61)
        }
        return mask
    }

    /// What a word the lexicon does not know may still mean, the way a subword model would
    /// guess: the concepts whose forms it begins (three letters or more), or else the concepts
    /// whose forms are nearest within the typo budget of its length. Weights add up to 1 for a
    /// beginning and to `1 / (1 + edits)` for a typo; empty when nothing is close.
    func partialMatches(_ token: UnsafeBufferPointer<UInt8>) -> [(concept: Int, weight: Float)] {
        guard token.count >= 3 else { return [] }
        let word = Array(token)

        // Forms the word begins: a contiguous range of the sorted list.
        var low = 0
        var high = forms.count
        while low < high {
            let middle = (low + high) / 2
            if forms[middle].bytes.lexicographicallyPrecedes(word) { low = middle + 1 } else { high = middle }
        }
        var concepts: [Int] = []
        var index = low
        while index < forms.count, forms[index].bytes.starts(with: word) {
            if !concepts.contains(forms[index].concept) { concepts.append(forms[index].concept) }
            index += 1
        }
        if !concepts.isEmpty {
            return concepts.sorted().map { ($0, 1 / Float(concepts.count)) }
        }

        // Nearest forms within the budget.
        let budget = FixtureText.allowedEdits(forLength: word.count)
        guard budget > 0 else { return [] }
        let letters = LexiconIndex.letters(of: word)
        var best = budget + 1
        for form in forms where abs(form.bytes.count - word.count) <= budget && (form.letters ^ letters).nonzeroBitCount <= 2 * budget {
            guard let distance = FixtureText.boundedEditDistance(word, form.bytes, maximum: min(best, budget)) else { continue }
            if distance < best {
                best = distance
                concepts = [form.concept]
            } else if distance == best, !concepts.contains(form.concept) {
                concepts.append(form.concept)
            }
        }
        guard !concepts.isEmpty else { return [] }
        let weight = 1 / (Float(1 + best) * Float(concepts.count))
        return concepts.sorted().map { ($0, weight) }
    }

    /// Walks a run of Japanese scalars, reporting each lexicon form it contains, leftmost and
    /// longest first, and the text between the forms.
    ///
    /// Unknown text is reported in pieces of one script each: a run of katakana, or a run of
    /// ideographs. Hiragana between forms is grammar (particles, endings) and is dropped.
    func matchJapanese(
        _ run: UnsafeBufferPointer<UInt32>,
        onConcept: (Int) -> Void,
        onUnknown: (UnsafeBufferPointer<UInt32>) -> Void
    ) {
        let count = run.count
        var index = 0
        var unknownStart = 0

        func flushUnknown(upTo end: Int) {
            var start = unknownStart
            while start < end {
                let value = run[start]
                if FixtureText.isHiragana(value) {
                    start += 1
                    continue
                }
                let katakana = FixtureText.isKatakana(value)
                var stop = start + 1
                while stop < end, !FixtureText.isHiragana(run[stop]), FixtureText.isKatakana(run[stop]) == katakana {
                    stop += 1
                }
                onUnknown(UnsafeBufferPointer(rebasing: run[start..<stop]))
                start = stop
            }
        }

        while index < count {
            var matched: JapaneseForm?
            if let candidates = japanese[run[index]] {
                for candidate in candidates where index + candidate.scalars.count <= count {
                    var equal = true
                    for offset in 1..<max(1, candidate.scalars.count) where run[index + offset] != candidate.scalars[offset] {
                        equal = false
                        break
                    }
                    if equal {
                        matched = candidate
                        break
                    }
                }
            }
            if let matched {
                flushUnknown(upTo: index)
                onConcept(matched.concept)
                index += matched.scalars.count
                unknownStart = index
            } else {
                index += 1
            }
        }
        flushUnknown(upTo: count)
    }
}

/// An open-addressing hash table from the bytes of a token to a concept identifier.
///
/// Looking a token up allocates nothing and never builds a `String`, which is what keeps
/// embedding a 100,000-item corpus fast. Hashing is FNV-1a, so the layout is the same in every
/// process.
struct TokenTable: Sendable {
    private let hashes: [UInt64]
    /// Concept per slot; -1 marks an empty slot.
    private let values: [Int32]
    /// Bytes of every key, concatenated; `offsets[slot]..<offsets[slot] + lengths[slot]`.
    private let bytes: [UInt8]
    private let offsets: [Int32]
    private let lengths: [Int32]
    private let mask: Int

    init(_ entries: [String: Int]) {
        var capacity = 16
        while capacity < entries.count * 3 { capacity <<= 1 }
        var hashes = [UInt64](repeating: 0, count: capacity)
        var values = [Int32](repeating: -1, count: capacity)
        var offsets = [Int32](repeating: 0, count: capacity)
        var lengths = [Int32](repeating: 0, count: capacity)
        var bytes: [UInt8] = []
        let mask = capacity - 1
        // Sorted, so the layout does not depend on dictionary iteration order.
        for key in entries.keys.sorted() {
            let utf8 = Array(key.utf8)
            let hash = utf8.withUnsafeBufferPointer { FixtureText.hash($0) }
            var slot = Int(truncatingIfNeeded: hash) & mask
            while values[slot] >= 0 { slot = (slot + 1) & mask }
            hashes[slot] = hash
            values[slot] = Int32(entries[key] ?? 0)
            offsets[slot] = Int32(bytes.count)
            lengths[slot] = Int32(utf8.count)
            bytes.append(contentsOf: utf8)
        }
        self.hashes = hashes
        self.values = values
        self.bytes = bytes
        self.offsets = offsets
        self.lengths = lengths
        self.mask = mask
    }

    /// The concept of a folded token, or `nil` when the token is not in the lexicon.
    @inline(__always)
    func lookup(_ token: UnsafeBufferPointer<UInt8>) -> Int? {
        let hash = FixtureText.hash(token)
        var slot = Int(truncatingIfNeeded: hash) & mask
        while values[slot] >= 0 {
            if hashes[slot] == hash, Int(lengths[slot]) == token.count {
                let offset = Int(offsets[slot])
                var equal = true
                for position in 0..<token.count where bytes[offset + position] != token[position] {
                    equal = false
                    break
                }
                if equal { return Int(values[slot]) }
            }
            slot = (slot + 1) & mask
        }
        return nil
    }
}
