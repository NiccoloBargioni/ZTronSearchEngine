import Foundation

/// Picks and reads the tokenizer of a model from the files that sit next to it.
///
/// The conversion scripts write the tokenizer files of a model `Name.mlmodelc` into a sibling
/// directory `Name.tokenizer`; a model that ships alone may also keep them loose in its own
/// directory. Whichever is found decides the implementation:
///
/// - `tokenizer.json` with a `Unigram` model: ``UnigramTokenizer``.
/// - `tokenizer.json` with a `WordPiece` model: ``WordPieceTokenizer``.
/// - `vocab.txt`, with the options of `tokenizer_config.json` when present:
///   ``WordPieceTokenizer``.
///
/// These functions read files synchronously, memory-mapped. The Core ML adapters call them on
/// their own serial queues; call them off the cooperative thread pool.
public enum TokenizerLoader: Sendable {
    /// The Hugging Face tokenizer description: model, normalizer, pre-tokenizer and template.
    public static let tokenizerJSONFileName = "tokenizer.json"
    /// A WordPiece vocabulary, one piece per line.
    public static let vocabularyFileName = "vocab.txt"
    /// The options that go with a `vocab.txt`.
    public static let configurationFileName = "tokenizer_config.json"

    /// The directory that holds the tokenizer files of the model at `modelURL`:
    /// `<Name>.tokenizer` next to it, else the directory the model is in.
    public static func tokenizerDirectory(forModelAt modelURL: URL) -> URL? {
        let parent = modelURL.deletingLastPathComponent()
        let name = modelURL.deletingPathExtension().lastPathComponent
        let candidates = [parent.appendingPathComponent(name + ".tokenizer", isDirectory: true), parent]
        return candidates.first { directory in
            [tokenizerJSONFileName, vocabularyFileName].contains { name in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
        }
    }

    /// Reads the tokenizer of the model at `modelURL`.
    public static func load(forModelAt modelURL: URL) throws -> any TextTokenizing {
        guard let directory = tokenizerDirectory(forModelAt: modelURL) else {
            throw SemanticError.tokenizerUnavailable(
                "no \(tokenizerJSONFileName) or \(vocabularyFileName) next to \(modelURL.lastPathComponent)"
            )
        }
        return try load(from: directory)
    }

    /// Reads the tokenizer whose files are in `directory`.
    public static func load(from directory: URL) throws -> any TextTokenizing {
        let manager = FileManager.default
        let json = directory.appendingPathComponent(tokenizerJSONFileName)
        if manager.fileExists(atPath: json.path) {
            return try tokenizer(fromTokenizerJSON: read(json))
        }
        let vocabulary = directory.appendingPathComponent(vocabularyFileName)
        if manager.fileExists(atPath: vocabulary.path) {
            let configuration = directory.appendingPathComponent(configurationFileName)
            return try wordPieceTokenizer(
                fromVocabulary: read(vocabulary),
                configuration: manager.fileExists(atPath: configuration.path) ? read(configuration) : nil
            )
        }
        throw SemanticError.tokenizerUnavailable(
            "no \(tokenizerJSONFileName) or \(vocabularyFileName) in \(directory.lastPathComponent)"
        )
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try FileAccess.map(url)
        } catch {
            throw SemanticError.tokenizerUnavailable("cannot read \(url.lastPathComponent)")
        }
    }

    // MARK: vocab.txt

    /// A WordPiece tokenizer from the bytes of a `vocab.txt`, one piece per line, and optionally
    /// the bytes of the `tokenizer_config.json` that goes with it.
    public static func wordPieceTokenizer(fromVocabulary data: Data, configuration: Data? = nil) throws -> WordPieceTokenizer {
        // Cut at line feeds on the bytes: in a Swift string a carriage return and the line feed
        // after it are one character, and would not split.
        var lines: [String] = []
        data.withUnsafeBytes { raw in
            var start = raw.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            func append(upTo end: Int) {
                let trimmed = end > start && raw[end - 1] == 0x0D ? end - 1 : end
                lines.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<trimmed]), as: UTF8.self))
            }
            for index in raw.indices where raw[index] == 0x0A {
                append(upTo: index)
                start = index + 1
            }
            // A final newline does not start another piece.
            if start < raw.count { append(upTo: raw.count) }
        }
        guard !lines.isEmpty else {
            throw SemanticError.tokenizerUnavailable("\(vocabularyFileName) is empty")
        }

        var options = WordPieceTokenizer.Options()
        if let configuration {
            guard let object = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
                throw SemanticError.tokenizerUnavailable("\(configurationFileName) is not a JSON object")
            }
            if let lowercase = object["do_lower_case"] as? Bool { options.lowercase = lowercase }
            if let stripAccents = object["strip_accents"] as? Bool { options.stripAccents = stripAccents }
            if let chinese = object["tokenize_chinese_chars"] as? Bool { options.handleChineseCharacters = chinese }
            if let token = tokenName(object["unk_token"]) { options.unknownToken = token }
            if let token = tokenName(object["cls_token"]) { options.classifierToken = token }
            if let token = tokenName(object["sep_token"]) { options.separatorToken = token }
            if let token = tokenName(object["pad_token"]) { options.padToken = token }
        }
        return try WordPieceTokenizer(vocabulary: lines, options: options)
    }

    /// A special token is spelled either as a string or as an object with a `content` field.
    private static func tokenName(_ value: Any?) -> String? {
        if let name = value as? String { return name }
        return (value as? [String: Any])?["content"] as? String
    }

    // MARK: tokenizer.json

    /// A tokenizer from the bytes of a Hugging Face `tokenizer.json`.
    ///
    /// - Throws: ``SemanticError/tokenizerUnavailable(_:)`` when the file is malformed or
    ///   describes something this package does not implement (byte-pair encoding, an unknown
    ///   normalizer). An unsupported file is refused rather than tokenized approximately.
    public static func tokenizer(fromTokenizerJSON data: Data) throws -> any TextTokenizing {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any] else {
            throw SemanticError.tokenizerUnavailable("\(tokenizerJSONFileName) is not a tokenizer description")
        }
        let added = (root["added_tokens"] as? [[String: Any]] ?? []).compactMap { token -> AddedToken? in
            guard let content = token["content"] as? String, let id = integer(token["id"]) else { return nil }
            return AddedToken(piece: content, id: Int32(id), isSpecial: token["special"] as? Bool ?? false)
        }
        let type = model["type"] as? String ?? (model["vocab"] is [Any] ? "Unigram" : "WordPiece")
        switch type {
        case "Unigram":
            return try unigram(root: root, model: model, added: added)
        case "WordPiece":
            return try wordPiece(root: root, model: model, added: added)
        default:
            throw SemanticError.tokenizerUnavailable("'\(type)' tokenizers are not supported; use a Unigram or WordPiece model")
        }
    }

    /// An entry of `added_tokens`.
    private struct AddedToken {
        var piece: String
        var id: Int32
        var isSpecial: Bool
    }

    /// Finds special tokens by name: among the added tokens, else in the model's vocabulary.
    private struct SpecialTokens {
        var added: [String: Int32]
        var vocabulary: (String) -> Int32?

        func id(of name: String) -> Int32? {
            added[name] ?? vocabulary(name)
        }
    }

    private static func unigram(root: [String: Any], model: [String: Any], added: [AddedToken]) throws -> UnigramTokenizer {
        guard let vocabulary = model["vocab"] as? NSArray, vocabulary.count > 0 else {
            throw SemanticError.tokenizerUnavailable("the unigram model has no vocabulary")
        }
        guard let unknown = integer(model["unk_id"]) else {
            throw SemanticError.tokenizerUnavailable("the unigram model names no unknown token")
        }
        func entry(_ index: Int) throws -> (piece: NSString, score: Double) {
            guard let entry = vocabulary[index] as? NSArray, entry.count == 2,
                  let piece = entry[0] as? NSString, let score = entry[1] as? NSNumber else {
                throw SemanticError.tokenizerUnavailable("the unigram vocabulary holds a malformed entry")
            }
            return (piece, score.doubleValue)
        }

        let specials = SpecialTokens(
            added: Dictionary(added.map { ($0.piece, $0.id) }, uniquingKeysWith: { first, _ in first }),
            vocabulary: { name in
                let index = vocabulary.indexOfObject(passingTest: { element, _, _ in
                    ((element as? NSArray)?.firstObject as? NSString)?.isEqual(to: name) ?? false
                })
                return index == NSNotFound ? nil : Int32(index)
            }
        )
        let vocabularySize = max(vocabulary.count, Int(added.map(\.id).max() ?? -1) + 1)
        let template = try template(from: root["post_processor"], specials: specials)
            ?? .roberta(bos: specials.id(of: "<s>") ?? 0, eos: specials.id(of: "</s>") ?? 2)
        let padTokenID = padID(root: root, specials: specials, names: ["<pad>", "[PAD]"])
        let reserved = UnigramTokenizer.reserved(
            Set(added.filter(\.isSpecial).map(\.id)), template: template, unknownTokenID: Int32(unknown), padTokenID: padTokenID
        )

        // The vocabulary of a multilingual model holds 250,000 entries. It is walked as the
        // Foundation array it was parsed into, and every piece goes from its Foundation string
        // straight into the table as UTF-8: no Swift array and no Swift string per entry.
        var table = PieceTable(capacity: vocabulary.count)
        var scores = [Double](repeating: 0, count: vocabulary.count)
        var scratch = [UInt8](repeating: 0, count: 512)
        for index in 0..<vocabulary.count {
            let (piece, score) = try entry(index)
            scores[index] = score
            if reserved.contains(Int32(index)) { continue }
            var used = 0
            var remaining = NSRange(location: 0, length: 0)
            let converted = scratch.withUnsafeMutableBytes { buffer in
                piece.getBytes(
                    buffer.baseAddress, maxLength: buffer.count, usedLength: &used, encoding: String.Encoding.utf8.rawValue,
                    options: [], range: NSRange(location: 0, length: piece.length), remaining: &remaining
                )
            }
            if converted, remaining.length == 0 {
                scratch.withUnsafeBufferPointer { table.insert(UnsafeBufferPointer(rebasing: $0[..<used]), id: Int32(index)) }
            } else {
                // A piece that does not fit the scratch buffer, or does not convert: the slow way.
                var string = piece as String
                string.withUTF8 { table.insert($0, id: Int32(index)) }
            }
        }

        return try UnigramTokenizer(
            table: table,
            scores: scores,
            unknownTokenID: Int32(unknown),
            padTokenID: padTokenID,
            vocabularySize: vocabularySize,
            normalizer: try normalizer(from: root["normalizer"]) ?? .sequence([]),
            preTokenizer: try preTokenizer(from: root["pre_tokenizer"]) ?? .sequence([]),
            template: template
        )
    }

    private static func wordPiece(root: [String: Any], model: [String: Any], added: [AddedToken]) throws -> WordPieceTokenizer {
        guard let vocabulary = model["vocab"] as? [String: Any], !vocabulary.isEmpty else {
            throw SemanticError.tokenizerUnavailable("the WordPiece model has no vocabulary")
        }
        var entries: [(piece: String, id: Int32)] = []
        entries.reserveCapacity(vocabulary.count)
        for (piece, value) in vocabulary {
            guard let id = integer(value) else {
                throw SemanticError.tokenizerUnavailable("the WordPiece vocabulary holds a malformed entry")
            }
            entries.append((piece, Int32(id)))
        }
        entries.sort { $0.id < $1.id }

        var options = WordPieceTokenizer.Options()
        if let token = model["unk_token"] as? String { options.unknownToken = token }
        if let prefix = model["continuing_subword_prefix"] as? String { options.continuationPrefix = prefix }
        if let limit = integer(model["max_input_chars_per_word"]) { options.maxCharactersPerWord = limit }
        if let padding = root["padding"] as? [String: Any], let token = padding["pad_token"] as? String {
            options.padToken = token
        }
        let specials = SpecialTokens(
            added: Dictionary(added.map { ($0.piece, $0.id) }, uniquingKeysWith: { first, _ in first }),
            vocabulary: { name in integer(vocabulary[name]).map(Int32.init) }
        )
        let vocabularySize = Int(max(entries.last?.id ?? -1, added.map(\.id).max() ?? -1)) + 1
        return try WordPieceTokenizer(
            entries: entries,
            vocabularySize: vocabularySize,
            normalizer: try normalizer(from: root["normalizer"])
                ?? .bert(cleanText: true, handleChineseCharacters: true, stripAccents: true, lowercase: true),
            preTokenizer: try preTokenizer(from: root["pre_tokenizer"]) ?? .bert,
            template: try template(from: root["post_processor"], specials: specials),
            options: options
        )
    }

    private static func padID(root: [String: Any], specials: SpecialTokens, names: [String]) -> Int32 {
        if let padding = root["padding"] as? [String: Any], let id = integer(padding["pad_id"]) {
            return Int32(id)
        }
        for name in names {
            if let id = specials.id(of: name) { return id }
        }
        return 0
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) < Double(Int32.max) else { return nil }
        return number.intValue
    }

    private static func normalizer(from value: Any?) throws -> TextNormalizer? {
        guard let object = value as? [String: Any], let type = object["type"] as? String else { return nil }
        let normalizer: TextNormalizer
        switch type {
        case "Sequence":
            normalizer = .sequence(try (object["normalizers"] as? [Any] ?? []).compactMap(Self.normalizer(from:)))
        case "NFC": normalizer = .nfc
        case "NFD": normalizer = .nfd
        case "NFKC": normalizer = .nfkc
        case "NFKD": normalizer = .nfkd
        case "Lowercase": normalizer = .lowercase
        case "StripAccents": normalizer = .stripAccents
        case "Strip":
            normalizer = .strip(left: object["strip_left"] as? Bool ?? true, right: object["strip_right"] as? Bool ?? true)
        case "Precompiled", "Nmt":
            normalizer = .sentencePiece
        case "Replace":
            let content = object["content"] as? String ?? ""
            let pattern = object["pattern"] as? [String: Any]
            if let literal = pattern?["String"] as? String {
                normalizer = .replaceString(literal, with: content)
            } else if let expression = pattern?["Regex"] as? String {
                normalizer = .replaceRegex(expression, with: content)
            } else {
                throw SemanticError.tokenizerUnavailable("a Replace normalizer has no pattern")
            }
        case "BertNormalizer":
            let lowercase = object["lowercase"] as? Bool ?? true
            normalizer = .bert(
                cleanText: object["clean_text"] as? Bool ?? true,
                handleChineseCharacters: object["handle_chinese_chars"] as? Bool ?? true,
                stripAccents: object["strip_accents"] as? Bool ?? lowercase,
                lowercase: lowercase
            )
        default:
            throw SemanticError.tokenizerUnavailable("the normalizer '\(type)' is not supported")
        }
        guard normalizer.isValid else {
            throw SemanticError.tokenizerUnavailable("a Replace normalizer holds an invalid regular expression")
        }
        return normalizer
    }

    private static func preTokenizer(from value: Any?) throws -> TextPreTokenizer? {
        guard let object = value as? [String: Any], let type = object["type"] as? String else { return nil }
        switch type {
        case "Sequence":
            return .sequence(try (object["pretokenizers"] as? [Any] ?? []).compactMap(Self.preTokenizer(from:)))
        case "WhitespaceSplit":
            return .whitespaceSplit
        case "BertPreTokenizer":
            return .bert
        case "Metaspace":
            let marker = (object["replacement"] as? String)?.unicodeScalars.first ?? UnigramTokenizer.metaspace
            let prepend: MetaspacePrepend
            switch object["prepend_scheme"] as? String {
            case "always": prepend = .always
            case "first": prepend = .first
            case "never": prepend = .never
            default: prepend = (object["add_prefix_space"] as? Bool ?? true) ? .always : .never
            }
            return .metaspace(marker: marker, prepend: prepend, split: object["split"] as? Bool ?? true)
        default:
            throw SemanticError.tokenizerUnavailable("the pre-tokenizer '\(type)' is not supported")
        }
    }

    /// The special-token layout of a `TemplateProcessing`, `BertProcessing` or
    /// `RobertaProcessing` post-processor; `nil` when the file has none.
    private static func template(from value: Any?, specials: SpecialTokens) throws -> SequenceTemplate? {
        guard let object = value as? [String: Any], let type = object["type"] as? String else { return nil }
        func named(_ key: String) throws -> Int32 {
            guard let pair = object[key] as? [Any], pair.count == 2, let id = integer(pair[1]) else {
                throw SemanticError.tokenizerUnavailable("the post-processor names no '\(key)' token")
            }
            return Int32(id)
        }
        switch type {
        case "BertProcessing":
            return .bert(cls: try named("cls"), sep: try named("sep"))
        case "RobertaProcessing":
            return .roberta(bos: try named("cls"), eos: try named("sep"))
        case "Sequence":
            for processor in object["processors"] as? [Any] ?? [] {
                if let template = try template(from: processor, specials: specials) { return template }
            }
            return nil
        case "TemplateProcessing":
            let declaredTokens = object["special_tokens"] as? [String: Any] ?? [:]
            func parts(_ key: String) throws -> [SequenceTemplate.Part] {
                var parts: [SequenceTemplate.Part] = []
                for element in object[key] as? [[String: Any]] ?? [] {
                    if let sequence = element["Sequence"] as? [String: Any] {
                        let typeID = Int32(integer(sequence["type_id"]) ?? 0)
                        parts.append((sequence["id"] as? String) == "B" ? .second(typeID: typeID) : .first(typeID: typeID))
                    } else if let special = element["SpecialToken"] as? [String: Any], let name = special["id"] as? String {
                        let typeID = Int32(integer(special["type_id"]) ?? 0)
                        let declared = ((declaredTokens[name] as? [String: Any])?["ids"] as? [Any] ?? []).compactMap(integer)
                        let ids = declared.isEmpty ? [specials.id(of: name)].compactMap { $0 }.map(Int.init) : declared
                        guard !ids.isEmpty else {
                            throw SemanticError.tokenizerUnavailable("the template names an unknown special token '\(name)'")
                        }
                        parts.append(contentsOf: ids.map { .special(id: Int32($0), typeID: typeID) })
                    }
                }
                return parts
            }
            let single = try parts("single")
            let pair = try parts("pair")
            guard single.contains(where: { if case .first = $0 { return true } else { return false } }),
                  pair.contains(where: { if case .second = $0 { return true } else { return false } }) else {
                throw SemanticError.tokenizerUnavailable("the template of the post-processor is incomplete")
            }
            return SequenceTemplate(single: single, pair: pair)
        default:
            return nil
        }
    }
}
