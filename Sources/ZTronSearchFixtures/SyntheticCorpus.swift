import Foundation
import ZTronSearchEngine

/// A deterministic generator of distractors for scale tests: up to 100,000 items and beyond,
/// spread evenly over the five kinds.
///
/// Texts have realistic shapes: titles of 2 to 5 words, bodies of 20 to 80 words in sentences,
/// 0 to 6 keywords, captions and recognized text on images, filters on the kinds that have
/// them, and Italian, German or Japanese localizations on about one item in five. Words come
/// from a Zipf-distributed vocabulary of 200,000 pseudo-words, so a 100,000-item corpus holds
/// roughly 190,000 distinct terms, mixed with a share of real lexicon words in the bodies so
/// distractors compete with golden items on common words.
///
/// Distractors never become relevant to a golden query, which keeps the judgments complete:
/// - titles and keywords are pseudo-words only, so no distractor has a golden title, starts
///   with a golden prefix or carries a golden keyword;
/// - no pseudo-word starts like a lexicon word, so none is one, completes one or is expanded
///   from a prefix of one;
/// - bodies use English lemmas but never synonyms, and never the translations of reserved
///   concepts, so paraphrase and cross-language queries still find nothing lexically;
/// - lemmas only appear past the first 24 words of a body, which is where the description an
///   item is embedded from ends: a distractor can share words with a golden item, never a
///   meaning, so it is not near any golden query in the fake embedding space.
///
/// Item `n` depends only on the seed and on `n`: a corpus of 1,000 items is the beginning of
/// the corpus of 100,000 items with the same seed.
public struct SyntheticCorpus: Sendable {
    /// The seed the corpus was generated from.
    public let seed: UInt64
    /// Number of distractors.
    public let count: Int
    /// The distractors, in index order. Kinds rotate: map, tip, tool, game, image.
    public let items: [AnySearchable<CatalogKind>]

    /// Every synthetic id starts with this, and no golden id does.
    public static let idPrefix = "syn-"
    /// Distinct pseudo-words the generator draws from.
    public static var pseudoWordCount: Int { SyntheticVocabulary.latinCount }

    /// Generates `count` distractors from a seed. A negative count is treated as zero.
    public init(seed: UInt64, count: Int) {
        self.seed = seed
        self.count = max(0, count)
        self.items = SyntheticGenerator.items(seed: seed, range: 0..<max(0, count))
    }

    /// The golden corpus followed by `count` distractors.
    public static func combined(seed: UInt64, count: Int) -> [AnySearchable<CatalogKind>] {
        GoldenCorpus.items + SyntheticCorpus(seed: seed, count: count).items
    }

    /// The distractor at one index of the corpus generated from `seed`.
    public static func item(seed: UInt64, index: Int) -> AnySearchable<CatalogKind> {
        SyntheticGenerator.items(seed: seed, range: index..<(index + 1))[0]
    }

    /// `true` for the ids of distractors.
    public static func isSynthetic(_ id: SearchableID) -> Bool {
        id.rawValue.hasPrefix(idPrefix)
    }

    /// The pseudo-word of a frequency rank, `0..<pseudoWordCount`; rank 0 is the most frequent.
    public static func pseudoWord(rank: Int) -> String {
        SyntheticVocabulary.shared.latinWord(rank: rank)
    }

    /// The distractor maps, in index order. Computed from ``items`` on each access.
    public var maps: [MapItem] { items.compactMap { $0.base as? MapItem } }
    /// The distractor tips, in index order. Computed from ``items`` on each access.
    public var tips: [Tip] { items.compactMap { $0.base as? Tip } }
    /// The distractor tools, in index order. Computed from ``items`` on each access.
    public var tools: [Tool] { items.compactMap { $0.base as? Tool } }
    /// The distractor games, in index order. Computed from ``items`` on each access.
    public var games: [Game] { items.compactMap { $0.base as? Game } }
    /// The distractor images, in index order. Computed from ``items`` on each access.
    public var images: [ImageItem] { items.compactMap { $0.base as? ImageItem } }
}

// MARK: - Generation

/// Writes distractors. All text goes through one reusable byte buffer; the vocabularies are
/// read through unsafe pointers for the length of one generation, which is what keeps a
/// 100,000-item corpus well under a second in an optimized build.
enum SyntheticGenerator {
    /// One word in this many is a real lexicon word, where lexicon words are allowed.
    private static let lexiconShare = 10
    /// Words at the start of a base body that are never lexicon words: the stretch of a text
    /// that reaches an item's vector as its short description.
    private static let semanticWindow = 24
    /// One body word in this many is an identifier such as `kavo-4821`.
    private static let identifierShare = 100
    /// One item in this many carries localizations.
    private static let localizedShare = 5

    private static let platforms: [Platform] = Platform.allCases
    private static let categories: [ZTronSearchFixtures.Category] = ZTronSearchFixtures.Category.allCases
    private static let regions: [ISOCountry] = [.italy, .germany, .japan, .unitedStates]
    private static let genres: [String] = FixtureLexicon.concepts(in: .tag).map(\.lemma)
    private static let particles: [[UInt8]] = ["の", "と", "や", "、"].map { Array($0.utf8) }
    private static let sentenceEnd: [UInt8] = Array("。".utf8)
    private static let idPrefix: [UInt8] = Array(SyntheticCorpus.idPrefix.utf8)

    static func items(seed: UInt64, range: Range<Int>) -> [AnySearchable<CatalogKind>] {
        guard !range.isEmpty else { return [] }
        let vocabulary = SyntheticVocabulary.shared
        var result: [AnySearchable<CatalogKind>] = []
        result.reserveCapacity(range.count)

        vocabulary.latinBytes.withUnsafeBufferPointer { latinBytes in
        vocabulary.latinOffsets.withUnsafeBufferPointer { latinOffsets in
        vocabulary.latinFrequencies.thresholds.withUnsafeBufferPointer { latinThresholds in
        vocabulary.latinFrequencies.aliases.withUnsafeBufferPointer { latinAliases in
        vocabulary.kanaBytes.withUnsafeBufferPointer { kanaBytes in
        vocabulary.kanaOffsets.withUnsafeBufferPointer { kanaOffsets in
        vocabulary.kanaFrequencies.thresholds.withUnsafeBufferPointer { kanaThresholds in
        vocabulary.kanaFrequencies.aliases.withUnsafeBufferPointer { kanaAliases in
        vocabulary.lexiconBytes.withUnsafeBufferPointer { lexiconBytes in
            var writer = Writer(
                latin: Words(bytes: latinBytes, offsets: latinOffsets, thresholds: latinThresholds, aliases: latinAliases),
                kana: Words(bytes: kanaBytes, offsets: kanaOffsets, thresholds: kanaThresholds, aliases: kanaAliases),
                lexiconBytes: lexiconBytes,
                lexiconOffsets: vocabulary.lexiconOffsets
            )
            defer { writer.deallocate() }
            for index in range {
                result.append(writer.item(seed: seed, index: index))
            }
        }}}}}}}}}
        return result
    }

    /// A vocabulary seen through pointers: words by rank, and their Zipf sampler.
    private struct Words {
        let bytes: UnsafeBufferPointer<UInt8>
        let offsets: UnsafeBufferPointer<UInt32>
        let thresholds: UnsafeBufferPointer<UInt32>
        let aliases: UnsafeBufferPointer<UInt32>

        /// Draws a rank from the Zipf law.
        @inline(__always)
        func rank(_ generator: inout SeededGenerator) -> Int {
            let random = generator.next()
            let slot = Int(truncatingIfNeeded: (random >> 32).multipliedFullWidth(by: UInt64(thresholds.count)).low >> 32)
            return UInt32(truncatingIfNeeded: random) < thresholds[slot] ? slot : Int(aliases[slot])
        }
    }

    private struct Writer {
        let latin: Words
        let kana: Words
        let lexiconBytes: UnsafeBufferPointer<UInt8>
        let lexiconOffsets: [[UInt32]]

        private var buffer: UnsafeMutablePointer<UInt8>
        private var capacity: Int
        private var length = 0

        init(latin: Words, kana: Words, lexiconBytes: UnsafeBufferPointer<UInt8>, lexiconOffsets: [[UInt32]]) {
            self.latin = latin
            self.kana = kana
            self.lexiconBytes = lexiconBytes
            self.lexiconOffsets = lexiconOffsets
            capacity = 4_096
            buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        }

        func deallocate() {
            buffer.deallocate()
        }

        // MARK: Bytes

        @inline(__always)
        private mutating func reserve(_ extra: Int) {
            guard length + extra > capacity else { return }
            let grown = max(capacity * 2, length + extra)
            let replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: grown)
            replacement.update(from: buffer, count: length)
            buffer.deallocate()
            buffer = replacement
            capacity = grown
        }

        @inline(__always)
        private mutating func put(_ byte: UInt8) {
            reserve(1)
            buffer[length] = byte
            length += 1
        }

        @inline(__always)
        private mutating func put(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) {
            let count = end - start
            guard count > 0, let base = bytes.baseAddress else { return }
            reserve(count)
            memcpy(buffer + length, base + start, count)
            length += count
        }

        private mutating func put(_ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { put($0, from: 0, to: $0.count) }
        }

        /// The buffer as a string; the buffer is emptied.
        private mutating func take() -> String {
            let string = String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
            length = 0
            return string
        }

        /// Uppercases the ASCII letter at a position of the buffer.
        @inline(__always)
        private mutating func capitalize(at position: Int) {
            if position < length, buffer[position] >= 0x61, buffer[position] <= 0x7A {
                buffer[position] -= 0x20
            }
        }

        // MARK: Words

        @inline(__always)
        private mutating func putWord(_ words: Words, _ generator: inout SeededGenerator) {
            let rank = words.rank(&generator)
            put(words.bytes, from: Int(words.offsets[rank]), to: Int(words.offsets[rank + 1]))
        }

        /// A real word of the lexicon in a language: 0 en, 1 it, 2 de, 3 ja.
        private mutating func putLexiconWord(language: Int, _ generator: inout SeededGenerator) {
            let offsets = lexiconOffsets[language]
            let index = generator.index(below: offsets.count - 1)
            put(lexiconBytes, from: Int(offsets[index]), to: Int(offsets[index + 1]))
        }

        private mutating func putDigits(_ value: Int, count: Int) {
            var divisor = 1
            for _ in 1..<count { divisor *= 10 }
            var rest = value
            for _ in 0..<count {
                put(UInt8(0x30 + (rest / divisor) % 10))
                rest %= divisor
                divisor = max(1, divisor / 10)
            }
        }

        // MARK: Surfaces

        /// A title of 2 to 5 pseudo-words. `language` 3 writes katakana, anything else Latin.
        private mutating func title(language: Int, _ generator: inout SeededGenerator) -> String {
            let count = 2 + generator.index(below: 4)
            for position in 0..<count {
                if language == 3 {
                    putWord(kana, &generator)
                } else {
                    if position > 0 { put(0x20) }
                    let start = length
                    putWord(latin, &generator)
                    capitalize(at: start)
                }
            }
            return take()
        }

        /// A text of `count` words in sentences, with identifiers and, from word `lexiconFrom`
        /// on, a share of lexicon words.
        private mutating func text(language: Int, count: Int, lexiconFrom: Int, _ generator: inout SeededGenerator) -> String {
            var untilPeriod = 6 + generator.index(below: 9)
            var startsSentence = true
            for position in 0..<count {
                var draw = generator.index(below: SyntheticGenerator.lexiconShare * SyntheticGenerator.identifierShare)
                // Where lexicon words are not allowed yet, the draw becomes a pseudo-word.
                if position < lexiconFrom, draw % SyntheticGenerator.lexiconShare == 0 {
                    draw = SyntheticGenerator.lexiconShare * SyntheticGenerator.identifierShare - 1
                }
                if language == 3 {
                    if draw % SyntheticGenerator.lexiconShare == 0 {
                        putLexiconWord(language: 3, &generator)
                    } else {
                        putWord(kana, &generator)
                    }
                    untilPeriod -= 1
                    if untilPeriod == 0 || position == count - 1 {
                        put(SyntheticGenerator.sentenceEnd)
                        untilPeriod = 5 + generator.index(below: 5)
                    } else {
                        put(SyntheticGenerator.particles[generator.index(below: SyntheticGenerator.particles.count)])
                    }
                    continue
                }

                if position > 0 { put(0x20) }
                let start = length
                if draw % SyntheticGenerator.lexiconShare == 0 {
                    putLexiconWord(language: language, &generator)
                } else if draw < SyntheticGenerator.lexiconShare {
                    // An identifier: exact-match only, like a model number.
                    putWord(latin, &generator)
                    put(0x2D)
                    putDigits(100 + generator.index(below: 9_900), count: 4)
                } else {
                    putWord(latin, &generator)
                }
                if startsSentence { capitalize(at: start) }
                startsSentence = false
                untilPeriod -= 1
                if untilPeriod == 0 || position == count - 1 {
                    put(0x2E)
                    untilPeriod = 6 + generator.index(below: 9)
                    startsSentence = true
                }
            }
            return take()
        }

        /// 0 to 6 keywords, pseudo-words only.
        private mutating func keywords(language: Int, _ generator: inout SeededGenerator) -> [String] {
            let count = generator.index(below: 7)
            var keywords: [String] = []
            keywords.reserveCapacity(count)
            for _ in 0..<count {
                putWord(language == 3 ? kana : latin, &generator)
                keywords.append(take())
            }
            return keywords
        }

        /// Recognized text: a few uppercase pseudo-words and a number.
        private mutating func recognizedText(_ generator: inout SeededGenerator) -> String {
            let count = 2 + generator.index(below: 3)
            for position in 0..<count {
                if position > 0 { put(0x20) }
                let start = length
                putWord(latin, &generator)
                for offset in start..<length { capitalize(at: offset) }
            }
            put(0x20)
            putDigits(generator.index(below: 100), count: 2)
            return take()
        }

        /// 20 to 80 words, most often around 50.
        @inline(__always)
        private func bodyLength(_ generator: inout SeededGenerator) -> Int {
            20 + generator.index(below: 31) + generator.index(below: 31)
        }

        // MARK: Items

        mutating func item(seed: UInt64, index: Int) -> AnySearchable<CatalogKind> {
            var generator = SeededGenerator.stream(seed: seed, UInt64(index))
            let kind = CatalogKind.allCases[index % CatalogKind.allCases.count]

            put(SyntheticGenerator.idPrefix)
            putDigits(index % 10_000_000, count: 7)
            if index >= 10_000_000 {
                put(0x2D)
                putDigits(index / 10_000_000, count: 4)
            }
            let id = take()

            let title = self.title(language: 0, &generator)
            // Base surfaces: lexicon words only past the stretch that is embedded, and none in
            // captions, so a distractor shares words with golden items but never a meaning.
            let body = text(language: 0, count: bodyLength(&generator), lexiconFrom: SyntheticGenerator.semanticWindow, &generator)
            let hasKeywords = kind == .tool || kind == .game || kind == .image
            let keywords = hasKeywords ? self.keywords(language: 0, &generator) : []
            let caption = kind == .image
                ? text(language: 0, count: 6 + generator.index(below: 9), lexiconFrom: Int.max, &generator)
                : nil

            // About one item in five is localized: half of those in all three languages.
            var localizations: [String: SearchLocalization] = [:]
            if generator.index(below: SyntheticGenerator.localizedShare) == 0 {
                let languages: [Int]
                switch generator.index(below: 8) {
                case 0...3: languages = [1, 2, 3]
                case 4: languages = [1]
                case 5: languages = [2]
                case 6: languages = [3]
                default: languages = [1, 2]
                }
                for language in languages {
                    localizations[FixtureLexicon.languages[language]] = SearchLocalization(
                        title: self.title(language: language, &generator),
                        text: text(language: language, count: bodyLength(&generator), lexiconFrom: 0, &generator),
                        keywords: hasKeywords ? self.keywords(language: language, &generator) : [],
                        caption: kind == .image
                            ? text(language: language, count: 6 + generator.index(below: 9), lexiconFrom: 0, &generator)
                            : nil
                    )
                }
            }

            switch kind {
            case .map:
                var filters: Set<CatalogFilter> = [.category(.maps), .platform(SyntheticGenerator.platforms[generator.index(below: 4)])]
                if generator.index(below: 2) == 0 { filters.insert(.region(SyntheticGenerator.regions[generator.index(below: 4)])) }
                return AnySearchable(MapItem(id: id, title: title, text: body, filters: filters, language: "en", localizations: localizations))
            case .tip:
                let day: TimeInterval = 86_400
                let created = GoldenCorpus.referenceDate.addingTimeInterval(-day * Double(40 + generator.index(below: 700)))
                let updated = created.addingTimeInterval(day * Double(generator.index(below: 40)))
                return AnySearchable(Tip(
                    id: id, title: title, text: body, createdAt: created, updatedAt: updated,
                    language: "en", localizations: localizations
                ))
            case .tool:
                let filters: Set<CatalogFilter> = [
                    .category(SyntheticGenerator.categories[generator.index(below: SyntheticGenerator.categories.count)]),
                    .platform(SyntheticGenerator.platforms[generator.index(below: 4)]),
                ]
                return AnySearchable(Tool(
                    id: id, title: title, text: body, keywords: keywords, filters: filters,
                    language: "en", localizations: localizations
                ))
            case .game:
                let filters: Set<CatalogFilter> = [
                    .platform(SyntheticGenerator.platforms[generator.index(below: 4)]),
                    .region(SyntheticGenerator.regions[generator.index(below: 4)]),
                    .string(key: GoldenCorpus.genreFilterKey, value: SyntheticGenerator.genres[generator.index(below: SyntheticGenerator.genres.count)]),
                ]
                return AnySearchable(Game(
                    id: id, title: title, text: body, keywords: keywords, filters: filters,
                    language: "en", localizations: localizations
                ))
            case .image:
                let recognized = generator.index(below: 4) == 0 ? recognizedText(&generator) : nil
                return AnySearchable(ImageItem(
                    id: id, title: title, altText: body, tags: keywords, caption: caption, ocrText: recognized,
                    language: "en", localizations: localizations
                ))
            }
        }
    }
}
