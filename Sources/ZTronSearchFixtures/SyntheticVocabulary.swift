import Foundation

/// A discrete distribution sampled in constant time: Walker's alias method, built with integer
/// arithmetic only so the table is identical on every platform.
struct AliasTable: Sendable {
    /// Per slot: keep the slot when the low 32 random bits are below this, else take the alias.
    let thresholds: [UInt32]
    let aliases: [UInt32]

    var count: Int { thresholds.count }

    /// Builds the table for non-negative integer weights. Their sum times their count must fit
    /// in 64 bits.
    init(weights: [UInt64]) {
        let count = weights.count
        precondition(count > 0 && count <= Int(UInt32.max))
        let total = weights.reduce(0, +)
        precondition(total > 0)
        // Scale so that the average weight is `total`.
        var scaled = weights.map { $0 * UInt64(count) }
        var thresholds = [UInt32](repeating: UInt32.max, count: count)
        var aliases = [UInt32](repeating: 0, count: count)
        var small: [Int] = []
        var large: [Int] = []
        for index in 0..<count {
            aliases[index] = UInt32(index)
            if scaled[index] < total { small.append(index) } else { large.append(index) }
        }
        while let low = small.popLast(), let high = large.popLast() {
            // scaled[low] / total, as a 32-bit fraction.
            let numerator = scaled[low]
            thresholds[low] = UInt32(truncatingIfNeeded: total.dividingFullWidth((numerator >> 32, numerator << 32)).quotient)
            aliases[low] = UInt32(high)
            scaled[high] -= total - scaled[low]
            if scaled[high] < total { small.append(high) } else { large.append(high) }
        }
        self.thresholds = thresholds
        self.aliases = aliases
    }

    /// Weights of a Zipf law with exponent 1, flattened at the head: rank `r` (0-based) weighs
    /// `1 / (r + 3)`.
    static func zipf(count: Int) -> AliasTable {
        AliasTable(weights: (0..<count).map { (1 << 40) / UInt64($0 + 3) })
    }
}

/// The pseudo-word vocabularies distractors are written with. Built once; the same in every
/// process and for every seed.
///
/// Latin pseudo-words are made of consonant-vowel syllables, two syllables for the most frequent
/// ranks and three for the rest, so frequent words are short, as in a real language. None of them
/// starts with the first three letters of a lexicon word in any language. That one rule keeps
/// the golden judgments valid among distractors: no pseudo-word is a lexicon word, completes a
/// prefix of one, or starts like one.
///
/// Japanese pseudo-words are three or four plain katakana. They never contain a voiced or small
/// kana or a long-vowel mark, so no reserved katakana word of the lexicon shares a pair of
/// characters with them.
struct SyntheticVocabulary: Sendable {
    static let shared = SyntheticVocabulary()

    static let latinCount = 200_000
    static let kanaCount = 20_000
    /// Ranks below this are two-syllable words.
    private static let shortWordCount = 12_000

    /// Latin pseudo-words, concatenated; word `r` is `latinOffsets[r]..<latinOffsets[r + 1]`.
    let latinBytes: [UInt8]
    let latinOffsets: [UInt32]
    let latinFrequencies: AliasTable

    /// Katakana pseudo-words as UTF-8, concatenated.
    let kanaBytes: [UInt8]
    let kanaOffsets: [UInt32]
    let kanaFrequencies: AliasTable

    /// Lexicon words mixed into bodies, as UTF-8, concatenated: English lemmas, and the Italian,
    /// German and Japanese forms of the concepts that are not reserved.
    let lexiconBytes: [UInt8]
    /// Offsets per language, in the order en, it, de, ja; each has one more entry than words.
    let lexiconOffsets: [[UInt32]]

    private static let onsets = [
        "b", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z", "w",
        "br", "dr", "gr", "kr", "tr", "st", "sk",
    ]
    private static let vowels = ["a", "e", "i", "o", "u", "ai"]
    private static let codas = ["", "n", "r", "s", "l", "k", "m", "t"]
    private static let kana = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワ")

    private init() {
        // Latin.
        var reserved = Set<UInt32>()
        for form in FixtureLexicon.latinForms {
            let bytes = Array(form.utf8)
            if bytes.count >= 3 { reserved.insert(Self.prefixKey(bytes[0], bytes[1], bytes[2])) }
        }
        let syllables: [[UInt8]] = Self.onsets.flatMap { onset in Self.vowels.map { Array((onset + $0).utf8) } }
        let codas = Self.codas.map { Array($0.utf8) }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.latinCount * 8)
        var offsets: [UInt32] = [0]
        offsets.reserveCapacity(Self.latinCount + 1)
        var word: [UInt8] = []

        // Each tier walks a permutation of its whole space, so no word is produced twice.
        func fill(syllableCount: Int, until target: Int, multiplier: Int) {
            var space = codas.count
            for _ in 0..<syllableCount { space *= syllables.count }
            precondition(space % multiplier != 0)
            var candidate = 0
            while offsets.count - 1 < target, candidate < space {
                var value = (candidate * multiplier) % space
                candidate += 1
                let coda = codas[value % codas.count]
                value /= codas.count
                word.removeAll(keepingCapacity: true)
                for _ in 0..<syllableCount {
                    word.append(contentsOf: syllables[value % syllables.count])
                    value /= syllables.count
                }
                word.append(contentsOf: coda)
                if reserved.contains(Self.prefixKey(word[0], word[1], word[2])) { continue }
                bytes.append(contentsOf: word)
                offsets.append(UInt32(bytes.count))
            }
        }
        fill(syllableCount: 2, until: Self.shortWordCount, multiplier: 104_729)
        fill(syllableCount: 3, until: Self.latinCount, multiplier: 15_485_863)
        precondition(offsets.count == Self.latinCount + 1, "the syllable space is too small")
        latinBytes = bytes
        latinOffsets = offsets
        latinFrequencies = .zipf(count: Self.latinCount)

        // Katakana: three kana for the frequent ranks, four for the rest.
        var kanaBytes: [UInt8] = []
        var kanaOffsets: [UInt32] = [0]
        let kana = Self.kana.map { Array(String($0).utf8) }
        let shortKana = kana.count * kana.count * kana.count
        for rank in 0..<Self.kanaCount {
            let length = rank < 4_000 ? 3 : 4
            // Affine walks of each space: every word is distinct, and neighbours in rank differ.
            var value = rank < 4_000
                ? (rank * 7_919 + 31_337) % shortKana
                : ((rank - 4_000) * 104_729 + 31_337) % (shortKana * kana.count)
            for _ in 0..<length {
                kanaBytes.append(contentsOf: kana[value % kana.count])
                value /= kana.count
            }
            kanaOffsets.append(UInt32(kanaBytes.count))
        }
        self.kanaBytes = kanaBytes
        self.kanaOffsets = kanaOffsets
        kanaFrequencies = .zipf(count: Self.kanaCount)

        // Lexicon words by language. Synonyms are left out on purpose: a paraphrase query must
        // find nothing lexically. So are the translations of reserved concepts.
        var lexiconBytes: [UInt8] = []
        var lexiconOffsets: [[UInt32]] = []
        for language in FixtureLexicon.languages {
            var offsets: [UInt32] = [UInt32(lexiconBytes.count)]
            for concept in FixtureLexicon.concepts where language == "en" || !concept.isReserved {
                lexiconBytes.append(contentsOf: Array(concept.form(in: language).utf8))
                offsets.append(UInt32(lexiconBytes.count))
            }
            lexiconOffsets.append(offsets)
        }
        self.lexiconBytes = lexiconBytes
        self.lexiconOffsets = lexiconOffsets
    }

    @inline(__always)
    private static func prefixKey(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt32 {
        (UInt32(a) << 16) | (UInt32(b) << 8) | UInt32(c)
    }

    /// The Latin pseudo-word of a frequency rank; rank 0 is the most frequent.
    func latinWord(rank: Int) -> String {
        String(decoding: latinBytes[Int(latinOffsets[rank])..<Int(latinOffsets[rank + 1])], as: UTF8.self)
    }

    /// The katakana pseudo-word of a frequency rank.
    func kanaWord(rank: Int) -> String {
        String(decoding: kanaBytes[Int(kanaOffsets[rank])..<Int(kanaOffsets[rank + 1])], as: UTF8.self)
    }
}
