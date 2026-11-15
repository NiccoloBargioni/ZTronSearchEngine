import Foundation

/// The tokenizer of BERT-style models: basic tokenization, then greedy longest-match WordPiece
/// against a vocabulary (`vocab.txt`).
///
/// Basic tokenization cleans the text, puts every CJK ideograph and every punctuation mark in a
/// word of its own, and optionally lowercases and strips accents. Each word is then split into
/// the longest vocabulary pieces that spell it, continuation pieces carrying the `##` prefix;
/// a word that cannot be spelled becomes the unknown token.
public struct WordPieceTokenizer: TextTokenizing {
    /// Settings of a ``WordPieceTokenizer``; the defaults are those of `bert-base-uncased`.
    public struct Options: Sendable, Hashable {
        /// Lowercase the text. `false` for cased models, including the multilingual cased ones.
        public var lowercase: Bool
        /// Strip accents; `nil` follows ``lowercase``, as the reference tokenizer does.
        public var stripAccents: Bool?
        /// Make every CJK ideograph a word of its own.
        public var handleChineseCharacters: Bool
        /// The prefix of a piece that continues a word.
        public var continuationPrefix: String
        /// A longer word is not split: it becomes the unknown token.
        public var maxCharactersPerWord: Int
        /// The piece a word that cannot be spelled becomes.
        public var unknownToken: String
        /// The token that opens every sequence.
        public var classifierToken: String
        /// The token that closes a text.
        public var separatorToken: String
        /// The token that fills the window after the last token.
        public var padToken: String

        /// Creates options.
        public init(
            lowercase: Bool = true,
            stripAccents: Bool? = nil,
            handleChineseCharacters: Bool = true,
            continuationPrefix: String = "##",
            maxCharactersPerWord: Int = 100,
            unknownToken: String = "[UNK]",
            classifierToken: String = "[CLS]",
            separatorToken: String = "[SEP]",
            padToken: String = "[PAD]"
        ) {
            self.lowercase = lowercase
            self.stripAccents = stripAccents
            self.handleChineseCharacters = handleChineseCharacters
            self.continuationPrefix = continuationPrefix
            self.maxCharactersPerWord = max(1, maxCharactersPerWord)
            self.unknownToken = unknownToken
            self.classifierToken = classifierToken
            self.separatorToken = separatorToken
            self.padToken = padToken
        }
    }

    /// How texts are wrapped in special tokens.
    public let template: SequenceTemplate
    /// The id that fills the window after the last token.
    public let padTokenID: Int32
    /// The id a word that cannot be spelled becomes.
    public let unknownTokenID: Int32
    /// One more than the largest id the tokenizer can produce.
    public let vocabularySize: Int

    private let normalizer: TextNormalizer
    private let preTokenizer: TextPreTokenizer
    /// Pieces that start a word.
    private let initial: PieceTable
    /// Pieces that continue a word, without their prefix.
    private let continuation: PieceTable
    private let maxCharactersPerWord: Int

    /// A tokenizer over the lines of a `vocab.txt`: the id of a piece is its line number.
    ///
    /// - Throws: ``SemanticError/tokenizerUnavailable(_:)`` when the vocabulary lacks one of
    ///   the special tokens.
    public init(vocabulary: [String], options: Options = Options()) throws {
        let entries = vocabulary.enumerated().map { (piece: $0.element, id: Int32($0.offset)) }
        let stripAccents = options.stripAccents ?? options.lowercase
        try self.init(
            entries: entries,
            vocabularySize: vocabulary.count,
            normalizer: .bert(
                cleanText: true, handleChineseCharacters: options.handleChineseCharacters,
                stripAccents: stripAccents, lowercase: options.lowercase
            ),
            preTokenizer: .bert,
            template: nil,
            options: options
        )
    }

    /// The designated initializer: `tokenizer.json` files bring their own normalizer and
    /// template.
    init(
        entries: [(piece: String, id: Int32)],
        vocabularySize: Int,
        normalizer: TextNormalizer,
        preTokenizer: TextPreTokenizer,
        template: SequenceTemplate?,
        options: Options
    ) throws {
        // Special tokens are looked up by their full spelling, whatever they start with.
        let whole = PieceTable(entries)
        func id(of token: String) throws -> Int32 {
            guard let id = whole.id(of: token) else {
                throw SemanticError.tokenizerUnavailable("the vocabulary has no '\(token)' token")
            }
            return id
        }
        let unknown = try id(of: options.unknownToken)
        let pad = try id(of: options.padToken)
        let template = try template ?? .bert(cls: id(of: options.classifierToken), sep: id(of: options.separatorToken))

        // Special tokens are placed by the template only; text never spells one.
        let reserved = template.specialIDs.union([unknown, pad])
        let prefix = options.continuationPrefix
        var initial: [(piece: String, id: Int32)] = []
        var continuation: [(piece: String, id: Int32)] = []
        for entry in entries where !reserved.contains(entry.id) {
            if !prefix.isEmpty, entry.piece.hasPrefix(prefix) {
                continuation.append((String(entry.piece.dropFirst(prefix.count)), entry.id))
            } else {
                initial.append(entry)
            }
        }
        self.unknownTokenID = unknown
        self.padTokenID = pad
        self.template = template
        self.vocabularySize = vocabularySize
        self.normalizer = normalizer
        self.preTokenizer = preTokenizer
        self.initial = PieceTable(initial)
        self.continuation = PieceTable(continuation)
        self.maxCharactersPerWord = options.maxCharactersPerWord
    }

    /// The token ids of `text`, without special tokens: basic tokenization, then WordPiece.
    public func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for word in preTokenizer.apply([normalizer.apply(text)]) {
            split(word, into: &ids)
        }
        return ids
    }

    /// Greedy longest-match-first: at every position, the longest piece that spells what follows.
    private func split(_ word: String, into ids: inout [Int32]) {
        var copy = word
        copy.withUTF8 { bytes in
            // Byte offsets where a character starts, and the end of the word.
            var boundaries: [Int] = []
            for (offset, byte) in bytes.enumerated() where byte & 0xC0 != 0x80 {
                boundaries.append(offset)
            }
            boundaries.append(bytes.count)
            let characters = boundaries.count - 1
            guard characters > 0 else { return }
            guard characters <= maxCharactersPerWord else {
                ids.append(unknownTokenID)
                return
            }

            let first = ids.count
            var start = 0
            while start < characters {
                let table = start == 0 ? initial : continuation
                var end = characters
                var match: Int32?
                while end > start {
                    let slice = UnsafeBufferPointer(rebasing: bytes[boundaries[start]..<boundaries[end]])
                    if let id = table.id(of: slice) {
                        match = id
                        break
                    }
                    end -= 1
                }
                guard let match else {
                    // One part cannot be spelled: the whole word is unknown.
                    ids.removeSubrange(first...)
                    ids.append(unknownTokenID)
                    return
                }
                ids.append(match)
                start = end
            }
        }
    }
}
