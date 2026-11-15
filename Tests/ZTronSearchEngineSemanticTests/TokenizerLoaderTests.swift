import XCTest
@testable import ZTronSearchEngineSemantic

/// Tokenizers are selected by the files found next to the model.
final class TokenizerLoaderTests: XCTestCase {
    /// A `tokenizer.json` in the layout Hugging Face writes for XLM-R models, over the
    /// hand-made vocabulary of ``UnigramTokenizerTests``.
    static func unigramTokenizerJSON(
        normalizer: String = #"{"type":"Sequence","normalizers":[{"type":"Precompiled","precompiled_charsmap":"AAAA"},{"type":"Replace","pattern":{"Regex":" {2,}"},"content":" "}]}"#,
        modelType: String = "Unigram"
    ) -> Data {
        let vocabulary = UnigramTokenizerTests.pieces
            .map { #"["\#($0.piece)", \#($0.score)]"# }
            .joined(separator: ",")
        let json = #"""
        {
          "version": "1.0",
          "truncation": null,
          "padding": null,
          "added_tokens": [
            {"id": 0, "content": "<s>", "single_word": false, "lstrip": false, "rstrip": false, "normalized": false, "special": true},
            {"id": 1, "content": "<pad>", "single_word": false, "lstrip": false, "rstrip": false, "normalized": false, "special": true},
            {"id": 2, "content": "</s>", "single_word": false, "lstrip": false, "rstrip": false, "normalized": false, "special": true},
            {"id": 3, "content": "<unk>", "single_word": false, "lstrip": false, "rstrip": false, "normalized": false, "special": true},
            {"id": 29, "content": "<mask>", "single_word": false, "lstrip": true, "rstrip": false, "normalized": false, "special": true}
          ],
          "normalizer": \#(normalizer),
          "pre_tokenizer": {"type": "Sequence", "pretokenizers": [
            {"type": "WhitespaceSplit"},
            {"type": "Metaspace", "replacement": "▁", "prepend_scheme": "always", "split": true}
          ]},
          "post_processor": {
            "type": "TemplateProcessing",
            "single": [
              {"SpecialToken": {"id": "<s>", "type_id": 0}},
              {"Sequence": {"id": "A", "type_id": 0}},
              {"SpecialToken": {"id": "</s>", "type_id": 0}}
            ],
            "pair": [
              {"SpecialToken": {"id": "<s>", "type_id": 0}},
              {"Sequence": {"id": "A", "type_id": 0}},
              {"SpecialToken": {"id": "</s>", "type_id": 0}},
              {"SpecialToken": {"id": "</s>", "type_id": 0}},
              {"Sequence": {"id": "B", "type_id": 0}},
              {"SpecialToken": {"id": "</s>", "type_id": 0}}
            ],
            "special_tokens": {
              "<s>": {"id": "<s>", "ids": [0], "tokens": ["<s>"]},
              "</s>": {"id": "</s>", "ids": [2], "tokens": ["</s>"]}
            }
          },
          "decoder": {"type": "Metaspace", "replacement": "▁", "prepend_scheme": "always", "split": true},
          "model": {"type": "\#(modelType)", "unk_id": 3, "vocab": [\#(vocabulary)], "byte_fallback": false}
        }
        """#
        return Data(json.utf8)
    }

    /// A `tokenizer.json` for a BERT model, over the vocabulary of ``WordPieceTokenizerTests``.
    static func wordPieceTokenizerJSON(lowercase: Bool = true) -> Data {
        let vocabulary = WordPieceTokenizerTests.vocabulary.enumerated()
            .map { #""\#($0.element)": \#($0.offset)"# }
            .joined(separator: ",")
        let json = #"""
        {
          "version": "1.0",
          "added_tokens": [
            {"id": 0, "content": "[PAD]", "special": true}, {"id": 1, "content": "[UNK]", "special": true},
            {"id": 2, "content": "[CLS]", "special": true}, {"id": 3, "content": "[SEP]", "special": true},
            {"id": 4, "content": "[MASK]", "special": true}
          ],
          "normalizer": {"type": "BertNormalizer", "clean_text": true, "handle_chinese_chars": true, "strip_accents": null, "lowercase": \#(lowercase)},
          "pre_tokenizer": {"type": "BertPreTokenizer"},
          "post_processor": {
            "type": "TemplateProcessing",
            "single": [{"SpecialToken": {"id": "[CLS]", "type_id": 0}}, {"Sequence": {"id": "A", "type_id": 0}}, {"SpecialToken": {"id": "[SEP]", "type_id": 0}}],
            "pair": [
              {"SpecialToken": {"id": "[CLS]", "type_id": 0}}, {"Sequence": {"id": "A", "type_id": 0}}, {"SpecialToken": {"id": "[SEP]", "type_id": 0}},
              {"Sequence": {"id": "B", "type_id": 1}}, {"SpecialToken": {"id": "[SEP]", "type_id": 1}}
            ],
            "special_tokens": {"[CLS]": {"id": "[CLS]", "ids": [2], "tokens": ["[CLS]"]}, "[SEP]": {"id": "[SEP]", "ids": [3], "tokens": ["[SEP]"]}}
          },
          "decoder": {"type": "WordPiece", "prefix": "##", "cleanup": true},
          "model": {"type": "WordPiece", "unk_token": "[UNK]", "continuing_subword_prefix": "##", "max_input_chars_per_word": 100, "vocab": {\#(vocabulary)}}
        }
        """#
        return Data(json.utf8)
    }

    // MARK: tokenizer.json

    func testAUnigramTokenizerJSONBehavesLikeTheVocabularyItDescribes() throws {
        let loaded = try TokenizerLoader.tokenizer(fromTokenizerJSON: Self.unigramTokenizerJSON())
        XCTAssertTrue(loaded is UnigramTokenizer)
        let direct = try UnigramTokenizer(
            pieces: UnigramTokenizerTests.pieces, unknownTokenID: 3, padTokenID: 1, template: .roberta(bos: 0, eos: 2)
        )
        for text in ["hello world", "newyork", "Hello ☃☃ cat", "  ｈｅｌｌｏ \t world ", "citta\u{300} gatto", "hello </s> world", ""] {
            XCTAssertEqual(loaded.tokenize(text), direct.tokenize(text), "text '\(text)'")
            XCTAssertEqual(loaded.encode(text, maxLength: 16), direct.encode(text, maxLength: 16))
            XCTAssertEqual(loaded.encode(pair: text, "world", maxLength: 16), direct.encode(pair: text, "world", maxLength: 16))
        }
        XCTAssertEqual(loaded.template, .roberta(bos: 0, eos: 2))
        XCTAssertEqual(loaded.padTokenID, 1, "<pad> is found by name when the file declares no padding")
        XCTAssertEqual(loaded.unknownTokenID, 3)
        XCTAssertEqual(loaded.vocabularySize, 30, "added tokens beyond the model vocabulary count")
        XCTAssertEqual(loaded.encode("hello world", maxLength: 6).inputIDs, [0, 5, 6, 2, 1, 1])
    }

    func testPiecesOfAnyLengthAndScriptSurviveLoading() throws {
        // Pieces around and beyond the loader's 512-byte conversion buffer, in one- and
        // two-byte characters, and one outside the Basic Multilingual Plane.
        let long = String(repeating: "a", count: 600)
        let accented = String(repeating: "é", count: 300)
        let edge = String(repeating: "é", count: 255) + "a"
        let pieces = ["<s>", "<pad>", "</s>", "<unk>", "▁", "▁" + long, "▁" + accented, "▁" + edge, "▁😀", "▁中国"]
        let vocabulary = pieces.enumerated().map { #"["\#($0.element)", \#(-1.0 - Double($0.offset))]"# }.joined(separator: ",")
        let json = #"{"model": {"type": "Unigram", "unk_id": 3, "vocab": [\#(vocabulary)]}, "pre_tokenizer": {"type": "Metaspace", "replacement": "▁", "prepend_scheme": "always", "split": true}}"#
        let tokenizer = try TokenizerLoader.tokenizer(fromTokenizerJSON: Data(json.utf8))
        XCTAssertEqual(tokenizer.tokenize(long), [5])
        XCTAssertEqual(tokenizer.tokenize(accented), [6])
        XCTAssertEqual(tokenizer.tokenize(edge), [7])
        XCTAssertEqual(tokenizer.tokenize("😀 中国"), [8, 9])
        // One character short of a piece is not that piece.
        XCTAssertEqual(tokenizer.tokenize(String(long.dropLast())), [4, 3])
        XCTAssertEqual(tokenizer.vocabularySize, 10)
        // Without a post-processor the XLM-R layout applies, with the ids found by name.
        XCTAssertEqual(tokenizer.template, .roberta(bos: 0, eos: 2))
        XCTAssertEqual(tokenizer.padTokenID, 1)

        // An unknown-token id outside the vocabulary is refused.
        let broken = #"{"model": {"type": "Unigram", "unk_id": 99, "vocab": [["a", -1.0]]}}"#
        XCTAssertThrowsError(try TokenizerLoader.tokenizer(fromTokenizerJSON: Data(broken.utf8))) { error in
            guard case SemanticError.tokenizerUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testTheNormalizerOfTheFileIsHonoured() throws {
        // Lowercasing is not part of XLM-R's pipeline; a file that asks for it gets it.
        let lowercasing = #"{"type":"Sequence","normalizers":[{"type":"NFKC"},{"type":"Lowercase"},{"type":"Replace","pattern":{"String":"-"},"content":" "}]}"#
        let loaded = try TokenizerLoader.tokenizer(fromTokenizerJSON: Self.unigramTokenizerJSON(normalizer: lowercasing))
        XCTAssertEqual(loaded.tokenize("HELLO-World"), [5, 6])
        // Decomposing and stripping accents.
        let stripping = #"{"type":"Sequence","normalizers":[{"type":"NFD"},{"type":"StripAccents"},{"type":"Strip","strip_left":true,"strip_right":true}]}"#
        let stripped = try TokenizerLoader.tokenizer(fromTokenizerJSON: Self.unigramTokenizerJSON(normalizer: stripping))
        XCTAssertEqual(stripped.tokenize("  héllo  "), [5])
        // Without a normalizer the text is taken as it is.
        let raw = try TokenizerLoader.tokenizer(fromTokenizerJSON: Self.unigramTokenizerJSON(normalizer: "null"))
        XCTAssertEqual(raw.tokenize("hello"), [5])
        XCTAssertNotEqual(raw.tokenize("ｈｅｌｌｏ"), [5])
    }

    func testAWordPieceTokenizerJSONBehavesLikeItsVocabulary() throws {
        let loaded = try TokenizerLoader.tokenizer(fromTokenizerJSON: Self.wordPieceTokenizerJSON())
        XCTAssertTrue(loaded is WordPieceTokenizer)
        let direct = try WordPieceTokenizer(vocabulary: WordPieceTokenizerTests.vocabulary)
        for text in ["The cats sat on the mat.", "Café, unbelievable!", "中国 map2", "xyz catx", ""] {
            XCTAssertEqual(loaded.tokenize(text), direct.tokenize(text), "text '\(text)'")
            XCTAssertEqual(loaded.encode(pair: text, "the mat", maxLength: 16), direct.encode(pair: text, "the mat", maxLength: 16))
        }
        XCTAssertEqual(loaded.template, .bert(cls: 2, sep: 3))
        XCTAssertEqual(loaded.padTokenID, 0)
        XCTAssertEqual(loaded.vocabularySize, 39)

        let cased = try TokenizerLoader.tokenizer(fromTokenizerJSON: Self.wordPieceTokenizerJSON(lowercase: false))
        XCTAssertEqual(cased.tokenize("Hello café"), [36, 34, 35])
    }

    func testUnsupportedOrMalformedDescriptionsAreRefused() {
        func assertUnavailable(_ data: Data, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try TokenizerLoader.tokenizer(fromTokenizerJSON: data), message, line: line) { error in
                guard case SemanticError.tokenizerUnavailable = error else { return XCTFail("\(message): unexpected \(error)", line: line) }
            }
        }
        assertUnavailable(Data("not json".utf8), "not JSON")
        assertUnavailable(Data(#"{"version": "1.0"}"#.utf8), "no model")
        assertUnavailable(Self.unigramTokenizerJSON(modelType: "BPE"), "byte-pair encoding")
        assertUnavailable(Self.unigramTokenizerJSON(normalizer: #"{"type":"Mystery"}"#), "unknown normalizer")
        assertUnavailable(Self.unigramTokenizerJSON(normalizer: #"{"type":"Replace","pattern":{"Regex":"(("},"content":""}"#), "invalid regular expression")
        assertUnavailable(Data(#"{"model": {"type": "Unigram", "unk_id": 0, "vocab": []}}"#.utf8), "empty vocabulary")
        assertUnavailable(Data(#"{"model": {"type": "Unigram", "vocab": [["a", -1.0]]}}"#.utf8), "no unknown token")
        assertUnavailable(Data(#"{"model": {"type": "Unigram", "unk_id": 0, "vocab": [["a"]]}}"#.utf8), "malformed entry")
        assertUnavailable(Data(#"{"model": {"type": "WordPiece", "vocab": {"the": 0}}}"#.utf8), "WordPiece without special tokens")
    }

    // MARK: Files

    func testTheFilesNextToTheModelSelectTheTokenizer() throws {
        let directory = try TemporaryDirectory()
        let model = directory.file("Embedding.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)

        // Nothing next to the model.
        XCTAssertNil(TokenizerLoader.tokenizerDirectory(forModelAt: model))
        XCTAssertThrowsError(try TokenizerLoader.load(forModelAt: model)) { error in
            guard case SemanticError.tokenizerUnavailable = error else { return XCTFail("unexpected \(error)") }
        }

        // vocab.txt loose in the model's directory: WordPiece, with BERT's defaults.
        let vocabulary = WordPieceTokenizerTests.vocabulary.joined(separator: "\n") + "\n"
        try Data(vocabulary.utf8).write(to: directory.file("vocab.txt"))
        var tokenizer = try TokenizerLoader.load(forModelAt: model)
        XCTAssertTrue(tokenizer is WordPieceTokenizer)
        XCTAssertEqual(tokenizer.vocabularySize, 39, "the final newline does not start a piece")
        XCTAssertEqual(tokenizer.tokenize("The cats"), [5, 6, 10])

        // tokenizer_config.json refines it.
        try Data(#"{"do_lower_case": false, "strip_accents": null, "unk_token": "[UNK]", "pad_token": {"content": "[PAD]"}}"#.utf8)
            .write(to: directory.file("tokenizer_config.json"))
        tokenizer = try TokenizerLoader.load(forModelAt: model)
        XCTAssertEqual(tokenizer.tokenize("Hello The"), [36, 1])

        // tokenizer.json wins over vocab.txt.
        try Self.unigramTokenizerJSON().write(to: directory.file("tokenizer.json"))
        tokenizer = try TokenizerLoader.load(forModelAt: model)
        XCTAssertTrue(tokenizer is UnigramTokenizer)
        XCTAssertEqual(tokenizer.tokenize("hello world"), [5, 6])

        // And a `<Name>.tokenizer` directory wins over loose files: it is what the conversion
        // scripts write, so two models can sit side by side.
        let named = directory.file("Embedding.tokenizer")
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        try Self.wordPieceTokenizerJSON().write(to: named.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(TokenizerLoader.tokenizerDirectory(forModelAt: model)?.lastPathComponent, "Embedding.tokenizer")
        tokenizer = try TokenizerLoader.load(forModelAt: model)
        XCTAssertTrue(tokenizer is WordPieceTokenizer)
        let reranker = directory.file("Reranker.mlmodelc")
        XCTAssertEqual(TokenizerLoader.tokenizerDirectory(forModelAt: reranker)?.path, directory.url.path)
    }

    func testVocabularyFilesWithWindowsLineEndingsAndEmptyFilesAreHandled() throws {
        let windows = Data(WordPieceTokenizerTests.vocabulary.joined(separator: "\r\n").utf8)
        let tokenizer = try TokenizerLoader.wordPieceTokenizer(fromVocabulary: windows)
        XCTAssertEqual(tokenizer.vocabularySize, 39)
        XCTAssertEqual(tokenizer.tokenize("the cat"), [5, 6])
        XCTAssertThrowsError(try TokenizerLoader.wordPieceTokenizer(fromVocabulary: Data()))
        XCTAssertThrowsError(try TokenizerLoader.wordPieceTokenizer(fromVocabulary: windows, configuration: Data("[]".utf8)))
    }

    // MARK: Building blocks

    func testThePieceTableFindsExactlyWhatItHolds() {
        let pieces = (0..<5_000).map { (piece: "piece\($0)", id: Int32($0)) } + [(piece: "▁città", id: 9_000), (piece: "piece7", id: 9_999), (piece: "", id: 1)]
        let table = PieceTable(pieces)
        XCTAssertEqual(table.count, 5_001, "repeats and empty pieces are skipped")
        for index in stride(from: 0, to: 5_000, by: 37) {
            XCTAssertEqual(table.id(of: "piece\(index)"), Int32(index))
        }
        XCTAssertEqual(table.id(of: "piece7"), 7, "the first id of a repeated piece wins")
        XCTAssertEqual(table.id(of: "▁città"), 9_000)
        XCTAssertNil(table.id(of: "piece5000"))
        XCTAssertNil(table.id(of: "piec"))
        XCTAssertNil(table.id(of: ""))
        XCTAssertNil(table.id(of: "▁citta"))
        XCTAssertEqual(table.longestPiece, "piece4999".utf8.count)
        XCTAssertNil(PieceTable([]).id(of: "anything"))
    }

    func testMetaspaceKeepsTheMarkerInFrontOfEveryWord() {
        let marker: Unicode.Scalar = "▁"
        let always = TextPreTokenizer.metaspace(marker: marker, prepend: .always, split: true)
        XCTAssertEqual(always.apply(["hello world"]), ["▁hello", "▁world"])
        XCTAssertEqual(always.apply(["hello  world"]), ["▁hello", "▁", "▁world"])
        XCTAssertEqual(always.apply([" hello"]), ["▁hello"])
        XCTAssertEqual(always.apply(["a", "b"]), ["▁a", "▁b"])
        let first = TextPreTokenizer.metaspace(marker: marker, prepend: .first, split: true)
        XCTAssertEqual(first.apply(["a", "b c"]), ["▁a", "b", "▁c"])
        let never = TextPreTokenizer.metaspace(marker: marker, prepend: .never, split: false)
        XCTAssertEqual(never.apply(["hello world"]), ["hello▁world"])
        let sequence = TextPreTokenizer.sequence([.whitespaceSplit, always])
        XCTAssertEqual(sequence.apply(["  hello \n world "]), ["▁hello", "▁world"])
        XCTAssertEqual(TextPreTokenizer.bert.apply(["hello, world!  ok"]), ["hello", ",", "world", "!", "ok"])
    }
}
