import Foundation

/// The tokenizer of SentencePiece unigram models, read from a Hugging Face `tokenizer.json`:
/// XLM-R and the multilingual sentence-embedding and cross-encoder models distilled from it
/// (multilingual-e5, paraphrase-multilingual-MiniLM, mMiniLM rerankers).
///
/// Text is normalized, cut at whitespace, and every word, prefixed with the metaspace marker
/// `▁`, is segmented into the sequence of vocabulary pieces with the highest total score, by
/// Viterbi over the word. A character no piece covers becomes the unknown token, at a penalty
/// below the worst piece score, and consecutive unknowns merge into one.
public struct UnigramTokenizer: TextTokenizing {
    /// The marker SentencePiece puts in front of every word.
    public static let metaspace: Unicode.Scalar = "\u{2581}"
    /// How far below the worst piece an unknown character scores (SentencePiece's constant).
    static let unknownPenalty = 10.0

    /// How texts are wrapped in special tokens.
    public let template: SequenceTemplate
    /// The id that fills the window after the last token.
    public let padTokenID: Int32
    /// The id a character without a piece becomes.
    public let unknownTokenID: Int32
    /// One more than the largest id the tokenizer can produce.
    public let vocabularySize: Int

    private let normalizer: TextNormalizer
    private let preTokenizer: TextPreTokenizer
    private let pieces: PieceTable
    /// Score of each piece, by id.
    private let scores: [Double]
    private let unknownScore: Double

    /// A tokenizer over a unigram vocabulary with SentencePiece's default text handling:
    /// NFKC normalization, whitespace splitting, a metaspace in front of every word.
    ///
    /// - Parameters:
    ///   - pieces: The vocabulary; the id of a piece is its position.
    ///   - unknownTokenID: The id of the unknown piece.
    ///   - padTokenID: The id that fills the window after the last token.
    ///   - template: How texts are wrapped in special tokens.
    /// - Throws: ``SemanticError/tokenizerUnavailable(_:)`` when an id is outside the vocabulary.
    public init(
        pieces: [(piece: String, score: Double)],
        unknownTokenID: Int32,
        padTokenID: Int32,
        template: SequenceTemplate
    ) throws {
        try self.init(
            pieces: pieces,
            unknownTokenID: unknownTokenID,
            padTokenID: padTokenID,
            vocabularySize: pieces.count,
            normalizer: .sequence([.sentencePiece, .replaceRegex(" {2,}", with: " ")]),
            preTokenizer: .sequence([.whitespaceSplit, .metaspace(marker: Self.metaspace, prepend: .always, split: true)]),
            template: template,
            reservedIDs: []
        )
    }

    /// `tokenizer.json` files bring their own pipeline.
    init(
        pieces: [(piece: String, score: Double)],
        unknownTokenID: Int32,
        padTokenID: Int32,
        vocabularySize: Int,
        normalizer: TextNormalizer,
        preTokenizer: TextPreTokenizer,
        template: SequenceTemplate,
        reservedIDs: Set<Int32>
    ) throws {
        let reserved = Self.reserved(reservedIDs, template: template, unknownTokenID: unknownTokenID, padTokenID: padTokenID)
        try self.init(
            table: PieceTable(pieces.enumerated().compactMap { entry in
                reserved.contains(Int32(entry.offset)) ? nil : (piece: entry.element.piece, id: Int32(entry.offset))
            }),
            scores: pieces.map(\.score),
            unknownTokenID: unknownTokenID,
            padTokenID: padTokenID,
            vocabularySize: vocabularySize,
            normalizer: normalizer,
            preTokenizer: preTokenizer,
            template: template
        )
    }

    /// The ids text must never segment into.
    ///
    /// Control pieces (<s>, </s>, <pad>, <unk>, ...) sit in the vocabulary with the best score
    /// there is. They are placed by the template only, so a query that spells one out cannot
    /// forge it.
    static func reserved(_ ids: Set<Int32>, template: SequenceTemplate, unknownTokenID: Int32, padTokenID: Int32) -> Set<Int32> {
        ids.union(template.specialIDs).union([unknownTokenID, padTokenID])
    }

    /// The designated initializer.
    ///
    /// - Parameters:
    ///   - table: The pieces text may segment into, reserved ids left out.
    ///   - scores: The score of every piece of the vocabulary, by id.
    init(
        table: PieceTable,
        scores: [Double],
        unknownTokenID: Int32,
        padTokenID: Int32,
        vocabularySize: Int,
        normalizer: TextNormalizer,
        preTokenizer: TextPreTokenizer,
        template: SequenceTemplate
    ) throws {
        guard !scores.isEmpty, scores.indices.contains(Int(unknownTokenID)) else {
            throw SemanticError.tokenizerUnavailable("the unknown token is outside the unigram vocabulary")
        }
        guard padTokenID >= 0, Int(padTokenID) < max(vocabularySize, scores.count) else {
            throw SemanticError.tokenizerUnavailable("the padding token is outside the vocabulary")
        }
        var lowest = Double.infinity
        for score in scores {
            guard score.isFinite else {
                throw SemanticError.tokenizerUnavailable("the unigram vocabulary holds a score that is not finite")
            }
            lowest = min(lowest, score)
        }
        self.template = template
        self.padTokenID = padTokenID
        self.unknownTokenID = unknownTokenID
        self.vocabularySize = max(vocabularySize, scores.count)
        self.normalizer = normalizer
        self.preTokenizer = preTokenizer
        self.pieces = table
        self.scores = scores
        self.unknownScore = lowest - Self.unknownPenalty
    }

    /// The token ids of `text`, without special tokens: normalized, cut into words, and each word
    /// segmented into its best-scoring pieces.
    public func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for word in preTokenizer.apply([normalizer.apply(text)]) {
            segment(word, into: &ids)
        }
        return ids
    }

    /// Viterbi over the bytes of one word: the best-scoring way to spell it with pieces.
    private func segment(_ word: String, into ids: inout [Int32]) {
        var copy = word
        copy.withUTF8 { bytes in
            let count = bytes.count
            guard count > 0 else { return }
            // best[i]: the score of the best segmentation of bytes[0..<i]; previous[i] and
            // piece[i]: where its last piece starts and which piece it is.
            var best = [Double](repeating: -.infinity, count: count + 1)
            var previous = [Int](repeating: -1, count: count + 1)
            var piece = [Int32](repeating: unknownTokenID, count: count + 1)
            best[0] = 0

            var start = 0
            while start < count {
                // The character that starts here ends where the next one starts.
                var characterEnd = start + 1
                while characterEnd < count, bytes[characterEnd] & 0xC0 == 0x80 { characterEnd += 1 }
                guard best[start] > -.infinity else {
                    start = characterEnd
                    continue
                }

                var coversOneCharacter = false
                var end = characterEnd
                let limit = min(count, start + pieces.longestPiece)
                while end <= limit {
                    if let id = pieces.id(of: UnsafeBufferPointer(rebasing: bytes[start..<end])) {
                        let score = best[start] + scores[Int(id)]
                        if score > best[end] {
                            best[end] = score
                            previous[end] = start
                            piece[end] = id
                        }
                        if end == characterEnd { coversOneCharacter = true }
                    }
                    // Advance to the next character boundary.
                    end += 1
                    while end < count, bytes[end] & 0xC0 == 0x80 { end += 1 }
                }
                if !coversOneCharacter {
                    // Keeps the lattice connected: the character alone, as an unknown.
                    let score = best[start] + unknownScore
                    if score > best[characterEnd] {
                        best[characterEnd] = score
                        previous[characterEnd] = start
                        piece[characterEnd] = unknownTokenID
                    }
                }
                start = characterEnd
            }

            // Walk back from the end, then emit in order, merging runs of unknowns.
            var reversed: [Int32] = []
            var position = count
            while position > 0 {
                reversed.append(piece[position])
                position = previous[position]
            }
            let wordStart = ids.count
            for id in reversed.reversed() {
                if id == unknownTokenID, ids.count > wordStart, ids.last == unknownTokenID { continue }
                ids.append(id)
            }
        }
    }
}
