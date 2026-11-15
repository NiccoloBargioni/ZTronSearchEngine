import Foundation
import ZTronSearchEngine

/// The golden set: judged queries over ``GoldenCorpus``, with graded judgments
/// (specification section 15.3: at least 300 queries, all five item types, at least three
/// languages, one of them non-Latin).
///
/// The queries are generated, not hand-written, and the generation is deterministic: the same
/// seed yields the same queries on every run and platform. ``queries`` is the set every gate
/// is measured on; ``generate(seed:)`` draws another sample of the same shape.
///
/// What each class guarantees, beyond its judgments:
/// - `paraphrase` and `crossLanguage` queries cannot be answered lexically. No word of the query
///   is a word, or the beginning of a word, of any golden item or distractor in any language,
///   and the source item has no word within typo distance of the query. Only the semantic
///   channel finds it.
/// - `typo` queries stay inside the edit budget of specification section 7.2, counted on the
///   word as written and on the word as typed.
/// - `filterAndKind` queries list every golden id that satisfies their hard constraints in
///   ``GoldenQuery/allowedIDs``, so precision 1.0 can be asserted.
public enum GoldenSet {
    /// Seed of ``queries``.
    public static let defaultSeed: UInt64 = 0x0060_1D5E_7000_0001
    /// The specification's floor for the whole set.
    public static let minimumQueryCount = 300
    /// Queries a class needs for its gate to mean something.
    public static let minimumQueriesPerClass = 30

    /// The golden set, generated once from ``defaultSeed``.
    public static let queries: [GoldenQuery] = generate(seed: defaultSeed)

    /// The queries of one class, in generation order.
    public static func queries(of queryClass: GoldenQueryClass) -> [GoldenQuery] {
        queries.filter { $0.queryClass == queryClass }
    }

    /// Queries per class.
    public static var countsByClass: [GoldenQueryClass: Int] {
        Dictionary(grouping: queries, by: \.queryClass).mapValues(\.count)
    }

    /// Queries per kind of the item they were derived from.
    public static var countsByKind: [CatalogKind: Int] {
        Dictionary(grouping: queries, by: \.kind).mapValues(\.count)
    }

    /// Queries per language of the query text.
    public static var countsByLanguage: [String: Int] {
        Dictionary(grouping: queries, by: \.language).mapValues(\.count)
    }

    /// Generates a golden set from a seed. The seed decides which items are sampled and how
    /// they are varied; the judging rules are the same for every seed.
    public static func generate(seed: UInt64) -> [GoldenQuery] {
        var builder = GoldenSetBuilder(seed: seed)
        return builder.build()
    }

    /// Checks ``queries``; see ``validate(_:)``.
    public static func validate() -> [String] {
        validate(queries)
    }

    /// Checks a golden set and returns one line per problem: duplicate ids, empty or malformed
    /// judgments, classes below 30 queries, fewer than 300 queries, missing kinds or languages,
    /// and judgments that violate a query's own hard constraints.
    public static func validate(_ queries: [GoldenQuery]) -> [String] {
        var problems: [String] = []
        if queries.count < minimumQueryCount {
            problems.append("only \(queries.count) queries; at least \(minimumQueryCount) are required")
        }

        var seen = Set<String>()
        for query in queries {
            if !seen.insert(query.id).inserted { problems.append("duplicate id \(query.id)") }
            if query.judgments.isEmpty { problems.append("\(query.id): no judgment") }
            for (id, grade) in query.judgments {
                if !(1...3).contains(grade) { problems.append("\(query.id): grade \(grade) for \(id) is outside 1...3") }
                if GoldenCorpus.entry(for: id) == nil { problems.append("\(query.id): judged id \(id) is not a golden item") }
            }
            if query.judgments[query.sourceID] == nil { problems.append("\(query.id): its source is not judged") }
            if query.text.trimmingCharacters(in: .whitespaces).isEmpty && query.tokens.isEmpty {
                problems.append("\(query.id): neither text nor tokens")
            }
            if query.hasHardConstraints {
                guard let allowed = query.allowedIDs else {
                    problems.append("\(query.id): hard constraints without the ids that satisfy them")
                    continue
                }
                for id in query.judgments.keys where !allowed.contains(id) {
                    problems.append("\(query.id): judged id \(id) violates the query's constraints")
                }
            } else if query.allowedIDs != nil {
                problems.append("\(query.id): allowed ids without any hard constraint")
            }
        }

        for queryClass in GoldenQueryClass.allCases {
            let ofClass = queries.filter { $0.queryClass == queryClass }
            if ofClass.count < minimumQueriesPerClass {
                problems.append("\(queryClass.rawValue): only \(ofClass.count) queries; at least \(minimumQueriesPerClass) are required")
            }
            let kinds = Set(ofClass.map(\.kind))
            for kind in expectedKinds(of: queryClass) where !kinds.contains(kind) {
                problems.append("\(queryClass.rawValue): no query for kind \(kind.rawValue)")
            }
        }

        let languages = Set(queries.map(\.language))
        if languages.count < 3 { problems.append("only \(languages.count) languages; at least three are required") }
        if !languages.contains("ja") { problems.append("no query in a non-Latin language") }
        return problems
    }

    /// The kinds a class must cover: all five, except that only tools, games and images have
    /// keywords.
    public static func expectedKinds(of queryClass: GoldenQueryClass) -> [CatalogKind] {
        queryClass == .keyword ? [.tool, .game, .image] : CatalogKind.allCases
    }
}

// MARK: - Generation

struct GoldenSetBuilder {
    private let seed: UInt64
    private let entries: [GoldenEntry]
    private let byKind: [CatalogKind: [GoldenEntry]]
    private let position: [SearchableID: Int]

    /// Folded Latin-script word to the entries that contain it, in any language.
    private let wordEntries: [String: Set<Int>]
    /// Every word an index may hold, sorted: the words of the golden corpus and the lexicon
    /// words a distractor may be written with.
    private let sortedWords: [String]
    private let wordsByLength: [Int: [(word: String, bytes: [UInt8], letters: UInt32)]]
    /// Folded words of the English surfaces of each entry.
    private let englishWords: [Set<String>]
    private let japaneseCharacters: Set<UInt32>
    private let japaneseBigrams: Set<UInt64>

    private var queries: [GoldenQuery] = []
    private var counters: [GoldenQueryClass: Int] = [:]
    private var neighbourCache: [String: Set<Int>] = [:]

    /// Entries a semantic query may reach by typo distance before its source is at risk of
    /// leaving the first ten results.
    private static let maximumFuzzyNeighbours = 6

    init(seed: UInt64) {
        self.seed = seed
        let entries = GoldenCorpus.entries
        self.entries = entries
        self.byKind = Dictionary(grouping: entries, by: \.kind)
        var position: [SearchableID: Int] = [:]
        var wordEntries: [String: Set<Int>] = [:]
        var englishWords: [Set<String>] = []
        var characters = Set<UInt32>()
        var bigrams = Set<UInt64>()
        for (index, entry) in entries.enumerated() {
            position[entry.id] = index
            for surface in entry.allSurfaces {
                for word in FixtureText.latinTokens(surface) {
                    wordEntries[word, default: []].insert(index)
                }
            }
            englishWords.append(Set(entry.surfaces(in: "en").flatMap(FixtureText.latinTokens)))
            for surface in entry.surfaces(in: "ja") {
                for run in FixtureText.japaneseRuns(surface) {
                    let scalars = run.unicodeScalars.map(\.value)
                    characters.formUnion(scalars)
                    for (first, second) in zip(scalars, scalars.dropFirst()) {
                        bigrams.insert((UInt64(first) << 32) | UInt64(second))
                    }
                }
            }
        }
        // Distractors bring lexicon words of their own: English lemmas, and the Italian, German
        // and Japanese forms of every concept that is not reserved. A query that must find
        // nothing lexically must not meet those either.
        var words = Set(wordEntries.keys)
        for concept in FixtureLexicon.concepts {
            words.insert(FixtureText.fold(concept.lemma))
            guard !concept.isReserved else { continue }
            for language in ["it", "de"] {
                for form in concept.surfaceForms(in: language) { words.insert(FixtureText.fold(form)) }
            }
            let scalars = concept.japanese.unicodeScalars.map(\.value)
            characters.formUnion(scalars)
            for (first, second) in zip(scalars, scalars.dropFirst()) {
                bigrams.insert((UInt64(first) << 32) | UInt64(second))
            }
        }
        self.position = position
        self.wordEntries = wordEntries
        self.sortedWords = words.sorted()
        var byLength: [Int: [(word: String, bytes: [UInt8], letters: UInt32)]] = [:]
        for word in wordEntries.keys.sorted() {
            let bytes = Array(word.utf8)
            byLength[bytes.count, default: []].append((word, bytes, Self.letters(of: bytes)))
        }
        self.wordsByLength = byLength
        self.englishWords = englishWords
        self.japaneseCharacters = characters
        self.japaneseBigrams = bigrams
    }

    mutating func build() -> [GoldenQuery] {
        exactTitles(perKind: 12)
        titlePrefixes(perKind: 12)
        typos(perKind: 12)
        keywords(limit: 45)
        paraphrases(perKind: 12)
        crossLanguage(perKindAndLanguage: 4)
        localizedTitles(perKindAndLanguage: 4)
        constrained()
        return queries
    }

    // MARK: Helpers

    private static func kindIndex(_ kind: CatalogKind) -> UInt64 {
        UInt64(CatalogKind.allCases.firstIndex(of: kind) ?? 0)
    }

    private func generator(_ salt: UInt64) -> SeededGenerator {
        SeededGenerator.stream(seed: seed, salt)
    }

    /// A seeded Fisher-Yates shuffle.
    private func shuffled<Element>(_ elements: [Element], salt: UInt64) -> [Element] {
        var result = elements
        var generator = generator(salt)
        var index = result.count - 1
        while index > 0 {
            result.swapAt(index, generator.index(below: index + 1))
            index -= 1
        }
        return result
    }

    private func entries(of kind: CatalogKind, salt: UInt64) -> [GoldenEntry] {
        shuffled(byKind[kind] ?? [], salt: salt &* 16 &+ Self.kindIndex(kind))
    }

    private mutating func add(
        _ queryClass: GoldenQueryClass,
        text: String,
        tokens: [SearchQueryToken<CatalogSchema>] = [],
        locale: String = "en",
        language: String = "en",
        judgments: [SearchableID: Int],
        source: GoldenEntry,
        variant: String,
        allowed: Set<SearchableID>? = nil
    ) {
        let number = (counters[queryClass] ?? 0) + 1
        counters[queryClass] = number
        let digits = String(number)
        queries.append(GoldenQuery(
            id: queryClass.rawValue + "-" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits,
            queryClass: queryClass, text: text, tokens: tokens, locale: locale, language: language,
            judgments: judgments, kind: source.kind, sourceID: source.id, variant: variant, allowedIDs: allowed
        ))
    }

    /// `true` when a word is a word an index may hold, or the beginning of one: the lexical
    /// channel, with its prefix expansion, would match it.
    private func hasLexicalPath(_ word: String) -> Bool {
        var low = 0
        var high = sortedWords.count
        while low < high {
            let middle = (low + high) / 2
            if sortedWords[middle] < word { low = middle + 1 } else { high = middle }
        }
        return low < sortedWords.count && sortedWords[low].hasPrefix(word)
    }

    /// The entries that contain a word within typo distance of `word`: what the fuzzy channel
    /// could bring in.
    private mutating func fuzzyNeighbours(of word: String) -> Set<Int> {
        if let cached = neighbourCache[word] { return cached }
        let bytes = Array(word.utf8)
        let budget = FixtureText.allowedEdits(forLength: word.unicodeScalars.count)
        var found = Set<Int>()
        if budget > 0 {
            let letters = Self.letters(of: bytes)
            for length in max(1, bytes.count - budget)...(bytes.count + budget) {
                // One edit changes which letters occur by two at most: a cheap way to skip
                // nearly every candidate before measuring the distance.
                for candidate in wordsByLength[length] ?? [] where (candidate.letters ^ letters).nonzeroBitCount <= 2 * budget {
                    if FixtureText.boundedEditDistance(bytes, candidate.bytes, maximum: budget) != nil {
                        found.formUnion(wordEntries[candidate.word] ?? [])
                    }
                }
            }
        }
        neighbourCache[word] = found
        return found
    }

    /// The set of letters `a` to `z` a word contains, as a bit mask.
    private static func letters(of bytes: [UInt8]) -> UInt32 {
        var mask: UInt32 = 0
        for byte in bytes where byte >= 0x61 && byte <= 0x7A {
            mask |= 1 << UInt32(byte - 0x61)
        }
        return mask
    }

    /// `true` when a query made of these words can only reach `source` through the semantic
    /// channel, and nothing lexical can crowd it out.
    private mutating func isSemanticOnly(_ words: [String], source: Int) -> Bool {
        var neighbours = Set<Int>()
        for word in words {
            if hasLexicalPath(word) { return false }
            neighbours.formUnion(fuzzyNeighbours(of: word))
        }
        return !neighbours.contains(source) && neighbours.count <= Self.maximumFuzzyNeighbours
    }

    /// The Japanese counterpart: no character of the word (no pair of characters, for a word in
    /// katakana) occurs in any Japanese surface of the corpus, so neither the word, nor a piece
    /// the tokenizer may cut it into, nor one of its bigrams is in a Japanese index.
    private func isSemanticOnlyJapanese(_ word: String) -> Bool {
        let scalars = word.unicodeScalars.map(\.value)
        guard !scalars.isEmpty else { return false }
        if scalars.count > 1, scalars.allSatisfy(FixtureText.isKatakana) {
            for (first, second) in zip(scalars, scalars.dropFirst())
            where japaneseBigrams.contains((UInt64(first) << 32) | UInt64(second)) {
                return false
            }
            return true
        }
        return scalars.allSatisfy { !japaneseCharacters.contains($0) }
    }

    /// Entries, other than the source, that are about at least two of the concepts: grade 2.
    private func related(to concepts: [Int], source: GoldenEntry) -> [SearchableID: Int] {
        var judgments = [source.id: 3]
        guard concepts.count >= 2 else { return judgments }
        for entry in entries where entry.id != source.id {
            let shared = concepts.filter(entry.conceptIDs.contains).count
            if shared >= 2 { judgments[entry.id] = 2 }
        }
        return judgments
    }

    // MARK: Exact title

    private mutating func exactTitles(perKind: Int) {
        for kind in CatalogKind.allCases {
            for (index, entry) in entries(of: kind, salt: 1).prefix(perKind).enumerated() {
                let text: String
                let variant: String
                switch index % 3 {
                case 0: (text, variant) = (entry.title, "title")
                case 1: (text, variant) = (entry.title.lowercased(), "lowercase")
                default: (text, variant) = (entry.title.uppercased(), "uppercase")
                }
                add(.exactTitle, text: text, judgments: [entry.id: 3], source: entry, variant: variant)
            }
        }
    }

    // MARK: Title prefix

    private mutating func titlePrefixes(perKind: Int) {
        // A prefix inside the first word is only fair when no later word of a title and no
        // keyword begins the same way: otherwise items that merely contain such a word tie with
        // the items whose title starts with the prefix.
        var laterWords = Set<String>()
        for entry in entries {
            for word in entry.title.lowercased().split(separator: " ").dropFirst() {
                laterWords.insert(String(word))
            }
            for keyword in entry.keywords {
                laterWords.formUnion(FixtureText.latinTokens(keyword))
            }
        }
        func isWord(_ string: String) -> Bool {
            string.allSatisfy(\.isLetter)
        }

        for kind in CatalogKind.allCases {
            var taken = 0
            for (index, entry) in entries(of: kind, salt: 2).enumerated() where taken < perKind {
                let words = entry.title.split(separator: " ").map(String.init)
                // Every option ends inside a word, three or more characters into it.
                var options: [(text: String, variant: String)] = []
                if words[0].count >= 5 {
                    let start = String(words[0].prefix(3 + index % 2))
                    let folded = start.lowercased()
                    if !laterWords.contains(where: { $0.hasPrefix(folded) }) { options.append((start, "firstWord")) }
                }
                if words.count >= 2, isWord(words[1]), words[1].count >= 4 {
                    options.append((words[0] + " " + words[1].prefix(min(3 + index % 3, words[1].count - 1)), "secondWord"))
                }
                if words.count >= 3, isWord(words[2]), words[2].count >= 4 {
                    options.append((
                        words[0] + " " + words[1] + " " + words[2].prefix(min(3 + index % 3, words[2].count - 1)), "thirdWord"
                    ))
                }
                guard !options.isEmpty else { continue }
                let option = options[index % options.count]
                var prefix = option.text
                if index % 2 == 1 { prefix = prefix.lowercased() }

                let folded = prefix.lowercased()
                var judgments = [entry.id: 3]
                for other in entries where other.id != entry.id && other.title.lowercased().hasPrefix(folded) {
                    judgments[other.id] = 2
                }
                add(.titlePrefix, text: prefix, judgments: judgments, source: entry, variant: option.variant)
                taken += 1
            }
        }
    }

    // MARK: Typos

    /// Applies `edits` random edits to a lowercase word and returns the result when it is a
    /// fair typo: different from the word, exactly `edits` away, inside the budget of both the
    /// word and the result, and not a word of the corpus or of the lexicon.
    private func corrupted(_ word: String, edits: Int, generator: inout SeededGenerator) -> String? {
        let original = Array(word.utf8)
        guard original.count >= 3, original.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return nil }
        let lexicon = FixtureLexicon.index.latin
        for _ in 0..<60 {
            var bytes = original
            for _ in 0..<edits {
                let letter = UInt8(0x61 + generator.index(below: 26))
                switch generator.index(below: 4) {
                case 0:
                    bytes.insert(letter, at: generator.index(below: bytes.count + 1))
                case 1:
                    if bytes.count > 1 { bytes.remove(at: generator.index(below: bytes.count)) }
                case 2:
                    bytes[generator.index(below: bytes.count)] = letter
                default:
                    if bytes.count > 1 {
                        let at = generator.index(below: bytes.count - 1)
                        bytes.swapAt(at, at + 1)
                    }
                }
            }
            let budget = min(FixtureText.allowedEdits(forLength: original.count), FixtureText.allowedEdits(forLength: bytes.count))
            guard edits <= budget, FixtureText.boundedEditDistance(original, bytes, maximum: edits) == edits else { continue }
            let result = String(decoding: bytes, as: UTF8.self)
            guard wordEntries[result] == nil, lexicon[result] == nil else { continue }
            return result
        }
        return nil
    }

    private mutating func typos(perKind: Int) {
        for kind in CatalogKind.allCases {
            var generator = generator(0x300 + Self.kindIndex(kind))
            var taken = 0
            for (index, entry) in entries(of: kind, salt: 3).enumerated() where taken < perKind {
                var words = entry.title.split(separator: " ").map(String.init)
                let eligible = words.indices.filter { words[$0].count >= 3 && words[$0].allSatisfy(\.isLetter) }
                let long = eligible.filter { words[$0].count >= 6 }
                let short = eligible.filter { words[$0].count < 6 }

                // Mostly a long word, with one or two edits; every fourth query a short word.
                let target: Int
                if let pick = (index % 4 == 3 ? short.first : nil) ?? long.max(by: { words[$0].count < words[$1].count }) ?? short.first {
                    target = pick
                } else {
                    continue
                }
                let edits = words[target].count >= 6 && index % 2 == 0 ? 2 : 1
                guard let typo = corrupted(words[target].lowercased(), edits: edits, generator: &generator) else { continue }
                words[target] = typo

                // Every fifth query carries a second typo, in another word.
                if index % 5 == 4, let second = eligible.first(where: { $0 != target }),
                   let typo = corrupted(words[second].lowercased(), edits: 1, generator: &generator) {
                    words[second] = typo
                }
                let text = words.joined(separator: " ")
                add(.typo, text: index % 2 == 0 ? text.lowercased() : text, judgments: [entry.id: 3], source: entry, variant: "title")
                taken += 1
            }
        }

        // Distinctive keywords: carried by one item and found nowhere else.
        var generator = generator(0x3FF)
        for entry in entries {
            for (keyword, concept) in zip(entry.keywords, entry.keywordConceptIDs)
            where FixtureLexicon.concept(concept).role == .rareObject && (wordEntries[keyword]?.count ?? 0) == 1 {
                let edits = keyword.count >= 6 ? 2 : 1
                guard let typo = corrupted(keyword, edits: edits, generator: &generator) else { continue }
                add(.typo, text: typo, judgments: [entry.id: 3], source: entry, variant: "keyword")
            }
        }
    }

    // MARK: Keywords

    private mutating func keywords(limit: Int) {
        var carriers: [String: [Int]] = [:]
        var order: [String] = []
        for (index, entry) in entries.enumerated() {
            for keyword in entry.keywords {
                if carriers[keyword] == nil { order.append(keyword) }
                carriers[keyword, default: []].append(index)
            }
        }
        let rotation: [CatalogKind] = [.tool, .game, .image]
        var taken = 0
        for keyword in shuffled(order, salt: 4) where taken < limit {
            guard let carrying = carriers[keyword] else { continue }
            let words = FixtureText.latinTokens(keyword)
            // Fair only when every item that mentions the keyword also carries it: a title or
            // a body that says the word without the tag would outrank the tagged items.
            let mentioning = entries.indices.filter { index in words.allSatisfy(englishWords[index].contains) }
            guard !words.isEmpty, Set(mentioning) == Set(carrying) else { continue }

            var judgments: [SearchableID: Int] = [:]
            for index in carrying {
                let title = Set(FixtureText.latinTokens(entries[index].title))
                judgments[entries[index].id] = words.allSatisfy(title.contains) ? 3 : 2
            }
            let wanted = rotation[taken % rotation.count]
            let source = carrying.first { entries[$0].kind == wanted } ?? carrying[0]
            add(.keyword, text: keyword, judgments: judgments, source: entries[source], variant: "keyword")
            taken += 1
        }
    }

    // MARK: Paraphrases

    private mutating func paraphrases(perKind: Int) {
        for kind in CatalogKind.allCases {
            var taken = 0
            for (index, entry) in entries(of: kind, salt: 5).enumerated() where taken < perKind {
                guard let source = position[entry.id] else { continue }
                var words: [String] = []
                for (slot, id) in entry.titleConceptIDs.enumerated() {
                    let synonyms = FixtureLexicon.concept(id).synonyms
                    // Start at a different synonym for each query, for variety.
                    let rotated = synonyms.indices.map { synonyms[($0 + index + slot) % synonyms.count] }
                    var best: (word: String, neighbours: Int)?
                    for synonym in rotated where !hasLexicalPath(synonym) {
                        let neighbours = fuzzyNeighbours(of: synonym)
                        if neighbours.contains(source) { continue }
                        if best == nil || neighbours.count < (best?.neighbours ?? 0) { best = (synonym, neighbours.count) }
                    }
                    guard let best else { break }
                    words.append(best.word)
                }
                guard words.count == entry.titleConceptIDs.count, Set(words).count == words.count,
                      isSemanticOnly(words, source: source) else { continue }

                let judgments = related(to: entry.titleConceptIDs, source: entry)
                // With more than ten relevant items Recall@10 could not reach 1.
                guard judgments.count <= 10 else { continue }
                add(.paraphrase, text: words.joined(separator: " "), judgments: judgments, source: entry, variant: "synonyms")
                taken += 1
            }
        }
    }

    // MARK: Cross-language

    private mutating func crossLanguage(perKindAndLanguage: Int) {
        for (languageIndex, language) in GoldenCorpus.languages.enumerated() {
            for kind in CatalogKind.allCases {
                var taken = 0
                for entry in entries(of: kind, salt: 0x60 + UInt64(languageIndex)) where taken < perKindAndLanguage {
                    guard !entry.isLocalized(in: language), let source = position[entry.id] else { continue }
                    // Reserved concepts only: their translations are in no index.
                    let reserved = entry.titleConceptIDs.map(FixtureLexicon.concept).filter(\.isReserved)
                    guard reserved.count >= 2 else { continue }
                    let modifier = reserved[0].form(in: language)
                    let head = reserved[1].form(in: language)

                    let text: String
                    switch language {
                    case "ja":
                        guard isSemanticOnlyJapanese(modifier), isSemanticOnlyJapanese(head) else { continue }
                        text = modifier + " " + head
                    case "it":
                        guard isSemanticOnly([FixtureText.fold(modifier), FixtureText.fold(head)], source: source) else { continue }
                        text = head + " " + modifier
                    default:
                        guard isSemanticOnly([FixtureText.fold(modifier), FixtureText.fold(head)], source: source) else { continue }
                        text = modifier + " " + head
                    }
                    let judgments = related(to: [reserved[0].id, reserved[1].id], source: entry)
                    guard judgments.count <= 10 else { continue }
                    add(
                        .crossLanguage, text: text, locale: language, language: language, judgments: judgments,
                        source: entry, variant: "reserved"
                    )
                    taken += 1
                }
            }
        }
    }

    // MARK: Localized titles

    private mutating func localizedTitles(perKindAndLanguage: Int) {
        for (languageIndex, language) in GoldenCorpus.languages.enumerated() {
            for kind in CatalogKind.allCases {
                var taken = 0
                for entry in entries(of: kind, salt: 0x70 + UInt64(languageIndex)) where taken < perKindAndLanguage {
                    guard let title = entry.title(in: language), entry.isLocalized(in: language) else { continue }
                    add(
                        .localizedTitle, text: title, locale: language, language: language, judgments: [entry.id: 3],
                        source: entry, variant: "title"
                    )
                    taken += 1
                }
            }
        }
    }

    // MARK: Filters, kinds and phrases

    /// Adds a constrained query. Judgments list only items that satisfy the constraints:
    /// grade 3 when the title is about everything the text says, 2 when the item is, 1 when it
    /// is about part of it or only satisfies the tokens.
    private mutating func addConstrained(
        text: String, tokens: [SearchQueryToken<CatalogSchema>], source: GoldenEntry, variant: String
    ) {
        let probe = GoldenQuery(
            id: "", queryClass: .filterAndKind, text: text, tokens: tokens, locale: "en", language: "en",
            judgments: [:], kind: source.kind, sourceID: source.id, variant: variant, allowedIDs: nil
        )
        let concepts = FixtureLexicon.conceptIDs(in: text)
        var phrases: [[String]] = []
        for case .phrase(let phrase) in tokens { phrases.append(FixtureText.words(phrase)) }

        var allowed = Set<SearchableID>()
        var judgments: [SearchableID: Int] = [:]
        for entry in entries where probe.satisfiesConstraints(entry.item) {
            allowed.insert(entry.id)
            if concepts.isEmpty {
                if phrases.isEmpty {
                    judgments[entry.id] = 1
                } else {
                    let title = FixtureText.words(entry.title)
                    judgments[entry.id] = phrases.allSatisfy { GoldenQuery.contains(title, phrase: $0) } ? 3 : 2
                }
            } else if concepts.allSatisfy(entry.titleConceptIDs.contains) {
                judgments[entry.id] = 3
            } else if concepts.allSatisfy(entry.conceptIDs.contains) {
                judgments[entry.id] = 2
            } else if concepts.contains(where: entry.conceptIDs.contains) || !phrases.isEmpty {
                judgments[entry.id] = 1
            }
        }
        guard judgments[source.id] != nil else { return }
        add(.filterAndKind, text: text, tokens: tokens, judgments: judgments, source: source, variant: variant, allowed: allowed)
    }

    private mutating func constrained() {
        func lemma(_ entry: GoldenEntry, _ slot: Int) -> String {
            FixtureLexicon.concept(entry.titleConceptIDs[min(slot, entry.titleConceptIDs.count - 1)]).lemma
        }
        func sortedFilters(_ entry: GoldenEntry) -> [CatalogFilter] {
            entry.filters.sorted { ($0.key, $0.value) < ($1.key, $1.value) }
        }
        func platform(_ entry: GoldenEntry) -> CatalogFilter? {
            sortedFilters(entry).first { $0.key == "platform" }
        }
        let filterable: [CatalogKind] = [.map, .tool, .game]

        // A word of the title, restricted to the kind of the item.
        for kind in CatalogKind.allCases {
            for (index, entry) in entries(of: kind, salt: 8).prefix(3).enumerated() {
                addConstrained(text: lemma(entry, index % 2), tokens: [.kind(kind)], source: entry, variant: "kind")
            }
        }
        // One filter: platform, category, region or the ad-hoc genre.
        for kind in filterable {
            for (index, entry) in entries(of: kind, salt: 9).prefix(6).enumerated() {
                let filters = sortedFilters(entry)
                guard !filters.isEmpty else { continue }
                addConstrained(text: lemma(entry, 1), tokens: [.filter(filters[index % filters.count])], source: entry, variant: "filter")
            }
        }
        // AND across keys: two filters of different keys.
        for kind in filterable {
            for entry in entries(of: kind, salt: 10).prefix(3) {
                let filters = sortedFilters(entry)
                guard let first = filters.first, let second = filters.last, first.key != second.key else { continue }
                addConstrained(text: lemma(entry, 0), tokens: [.filter(first), .filter(second)], source: entry, variant: "filters")
            }
        }
        // A kind and a filter together.
        for kind in filterable {
            for entry in entries(of: kind, salt: 11).prefix(2) {
                guard let platform = platform(entry) else { continue }
                addConstrained(text: lemma(entry, 1), tokens: [.kind(kind), .filter(platform)], source: entry, variant: "kindAndFilter")
            }
        }
        // OR inside a key: two platforms.
        for kind in filterable {
            for entry in entries(of: kind, salt: 12).prefix(2) {
                guard case .platform(let own)? = platform(entry),
                      let other = Platform.allCases.first(where: { $0 != own && !entry.filters.contains(.platform($0)) }) else { continue }
                addConstrained(
                    text: lemma(entry, 0), tokens: [.filter(.platform(own)), .filter(.platform(other))], source: entry,
                    variant: "sameKeyFilters"
                )
            }
        }
        // OR among kinds: a place that has a map, an image and a tip, without the tip.
        let families = (byKind[.map] ?? []).filter { $0.titleConceptIDs.count == 3 && !$0.isBaseOnly }
        for entry in shuffled(families, salt: 13).prefix(3) {
            addConstrained(
                text: lemma(entry, 0) + " " + lemma(entry, 1), tokens: [.kind(.map), .kind(.image)], source: entry, variant: "kinds"
            )
        }
        // Phrases: the name of a place, required word for word.
        for (index, entry) in shuffled(families, salt: 14).prefix(6).enumerated() {
            let phrase = lemma(entry, 0) + " " + lemma(entry, 1)
            switch index % 3 {
            case 0: addConstrained(text: "", tokens: [.phrase(phrase)], source: entry, variant: "phrase")
            case 1: addConstrained(text: "", tokens: [.phrase(phrase), .kind(.map)], source: entry, variant: "phrase")
            default: addConstrained(text: lemma(entry, 2), tokens: [.phrase(phrase)], source: entry, variant: "phrase")
            }
        }
        // Tokens only: no text at all.
        for kind in filterable {
            for entry in entries(of: kind, salt: 15).prefix(2) {
                let filters = sortedFilters(entry)
                guard let first = filters.first, let second = filters.last else { continue }
                var tokens: [SearchQueryToken<CatalogSchema>] = [.kind(kind), .filter(first)]
                if second.key != first.key { tokens.append(.filter(second)) }
                addConstrained(text: "", tokens: tokens, source: entry, variant: "tokensOnly")
            }
        }
    }
}
