import Foundation

/// One row of model input: token ids padded to a fixed window, with the masks that go with it.
public struct TokenizedSequence: Sendable, Hashable {
    /// Token ids, special tokens included, padded to the window.
    public var inputIDs: [Int32]
    /// 1 for a token, 0 for padding.
    public var attentionMask: [Int32]
    /// The segment of each token: 0 for the first text, and whatever the tokenizer's template
    /// assigns to the second text of a pair.
    public var tokenTypeIDs: [Int32]
    /// Tokens before the padding.
    public var tokenCount: Int

    /// Creates a window from its parts.
    public init(inputIDs: [Int32], attentionMask: [Int32], tokenTypeIDs: [Int32], tokenCount: Int) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
        self.tokenTypeIDs = tokenTypeIDs
        self.tokenCount = tokenCount
    }
}

/// How a tokenizer wraps one text, or a pair of texts, in special tokens.
///
/// BERT-style models use `[CLS] A [SEP]` and `[CLS] A [SEP] B [SEP]`; XLM-R-style models use
/// `<s> A </s>` and `<s> A </s></s> B </s>`. Hugging Face `tokenizer.json` files spell the
/// template out and the tokenizers read it from there.
public struct SequenceTemplate: Sendable, Hashable {
    /// One element of a template.
    public enum Part: Sendable, Hashable {
        /// A special token.
        case special(id: Int32, typeID: Int32)
        /// The tokens of the first text.
        case first(typeID: Int32)
        /// The tokens of the second text.
        case second(typeID: Int32)
    }

    /// The layout of a single text.
    public var single: [Part]
    /// The layout of a pair of texts.
    public var pair: [Part]

    /// Creates a template from the layout of a single text and of a pair.
    public init(single: [Part], pair: [Part]) {
        self.single = single
        self.pair = pair
    }

    /// `[CLS] A [SEP]` and `[CLS] A [SEP] B [SEP]`, the second text and its separator in segment 1.
    public static func bert(cls: Int32, sep: Int32) -> SequenceTemplate {
        SequenceTemplate(
            single: [.special(id: cls, typeID: 0), .first(typeID: 0), .special(id: sep, typeID: 0)],
            pair: [
                .special(id: cls, typeID: 0), .first(typeID: 0), .special(id: sep, typeID: 0),
                .second(typeID: 1), .special(id: sep, typeID: 1),
            ]
        )
    }

    /// `<s> A </s>` and `<s> A </s></s> B </s>`, everything in segment 0.
    public static func roberta(bos: Int32, eos: Int32) -> SequenceTemplate {
        SequenceTemplate(
            single: [.special(id: bos, typeID: 0), .first(typeID: 0), .special(id: eos, typeID: 0)],
            pair: [
                .special(id: bos, typeID: 0), .first(typeID: 0), .special(id: eos, typeID: 0),
                .special(id: eos, typeID: 0), .second(typeID: 0), .special(id: eos, typeID: 0),
            ]
        )
    }

    /// The ids of every special token the template places.
    var specialIDs: Set<Int32> {
        var ids: Set<Int32> = []
        for case .special(let id, _) in single + pair {
            ids.insert(id)
        }
        return ids
    }

    func specialCount(in parts: [Part]) -> Int {
        parts.reduce(0) { count, part in
            if case .special = part { return count + 1 }
            return count
        }
    }
}

/// Splits text into the token ids a model was trained on.
///
/// Two implementations ship, in pure Swift: ``WordPieceTokenizer`` for BERT-style
/// vocabularies and ``UnigramTokenizer`` for SentencePiece models (XLM-R, multilingual-e5,
/// paraphrase-multilingual-MiniLM). ``TokenizerLoader`` picks one from the files next to a
/// model. Tokenizers are immutable values and safe to share.
public protocol TextTokenizing: Sendable {
    /// The token ids of `text`, without special tokens, padding or truncation.
    ///
    /// Text is always plain text: a special token spelled out in it (`[SEP]`, `</s>`) is
    /// tokenized like any other characters, so a query cannot inject one.
    func tokenize(_ text: String) -> [Int32]
    /// How texts are wrapped in special tokens.
    var template: SequenceTemplate { get }
    /// The id that fills the window after the last token.
    var padTokenID: Int32 { get }
    /// The id of a piece the vocabulary does not know.
    var unknownTokenID: Int32 { get }
    /// One more than the largest id the tokenizer can produce.
    var vocabularySize: Int { get }
}

extension TextTokenizing {
    /// Tokenizes one text into a window of `maxLength` ids: wrapped in special tokens,
    /// truncated at the end when it is too long, padded when it is short.
    public func encode(_ text: String, maxLength: Int = SemanticLimits.tokenWindow) -> TokenizedSequence {
        window(tokenize(text), maxLength: maxLength)
    }

    /// Tokenizes a pair of texts, a query and a passage, into one window of `maxLength` ids.
    ///
    /// When the pair is too long the longer text gives way first
    /// (``PairTruncation/lengths(first:second:budget:)``), so a short query is never cut to
    /// make room for a long passage.
    public func encode(pair first: String, _ second: String, maxLength: Int = SemanticLimits.tokenWindow) -> TokenizedSequence {
        window(pair: tokenize(first), tokenize(second), maxLength: maxLength)
    }

    /// The window for a text that is already tokenized.
    public func window(_ tokens: [Int32], maxLength: Int = SemanticLimits.tokenWindow) -> TokenizedSequence {
        let budget = max(0, maxLength - template.specialCount(in: template.single))
        return assemble(template.single, first: tokens.prefix(budget), second: [], maxLength: maxLength)
    }

    /// The window for a pair of texts that are already tokenized. Tokenizing the query once and
    /// pairing it with every passage is how a batch of pairs is assembled.
    public func window(pair first: [Int32], _ second: [Int32], maxLength: Int = SemanticLimits.tokenWindow) -> TokenizedSequence {
        let budget = max(0, maxLength - template.specialCount(in: template.pair))
        let kept = PairTruncation.lengths(first: first.count, second: second.count, budget: budget)
        return assemble(template.pair, first: first.prefix(kept.first), second: second.prefix(kept.second), maxLength: maxLength)
    }

    private func assemble(
        _ parts: [SequenceTemplate.Part],
        first: ArraySlice<Int32>,
        second: ArraySlice<Int32>,
        maxLength: Int
    ) -> TokenizedSequence {
        let window = max(0, maxLength)
        var ids: [Int32] = []
        var types: [Int32] = []
        ids.reserveCapacity(window)
        types.reserveCapacity(window)
        for part in parts {
            switch part {
            case .special(let id, let typeID):
                ids.append(id)
                types.append(typeID)
            case .first(let typeID):
                ids.append(contentsOf: first)
                types.append(contentsOf: repeatElement(typeID, count: first.count))
            case .second(let typeID):
                ids.append(contentsOf: second)
                types.append(contentsOf: repeatElement(typeID, count: second.count))
            }
        }
        // Only a window smaller than the template's own special tokens gets here over length.
        if ids.count > window {
            ids.removeSubrange(window...)
            types.removeSubrange(window...)
        }
        let tokenCount = ids.count
        var mask = [Int32](repeating: 1, count: tokenCount)
        let padding = window - tokenCount
        ids.append(contentsOf: repeatElement(padTokenID, count: padding))
        types.append(contentsOf: repeatElement(0, count: padding))
        mask.append(contentsOf: repeatElement(0, count: padding))
        return TokenizedSequence(inputIDs: ids, attentionMask: mask, tokenTypeIDs: types, tokenCount: tokenCount)
    }
}

/// How a pair of texts shares a token budget.
public enum PairTruncation: Sendable {
    /// The number of tokens each text keeps when together they may take `budget`.
    ///
    /// Tokens are taken from the longer text first, one at a time, until the pair fits; when
    /// both are equally long the second gives way. This is the "longest first" rule of the
    /// reference tokenizers, in closed form. A text no longer than half the budget is never
    /// truncated.
    public static func lengths(first: Int, second: Int, budget: Int) -> (first: Int, second: Int) {
        let first = max(0, first)
        let second = max(0, second)
        let budget = max(0, budget)
        guard first + second > budget else { return (first, second) }
        // When both texts are cut they end up level, the odd token going to the first.
        let secondShare = budget / 2
        let firstShare = budget - secondShare
        if first <= firstShare { return (first, budget - first) }
        if second <= secondShare { return (budget - second, second) }
        return (firstShare, secondShare)
    }
}
