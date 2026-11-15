import Foundation
import Hub
import MLXLMCommon
import Tokenizers

// mlx-swift-lm 3.x ships no tokenizer of its own: the client adapts one to `MLXLMCommon.Tokenizer`.
// This file adapts the tokenizer of swift-transformers and reads its files from a local directory
// with Foundation alone. The Hub client of swift-transformers is never created, so loading a
// tokenizer opens no session, starts no network monitor and sends nothing.

/// The files of a model directory the runtime reads, checked before MLX is touched.
struct ModelDirectory: Sendable, Hashable {
    static let configFile = "config.json"
    static let tokenizerFile = "tokenizer.json"
    static let tokenizerConfigFile = "tokenizer_config.json"
    static let chatTemplateJinjaFile = "chat_template.jinja"
    static let chatTemplateJSONFile = "chat_template.json"

    /// Files that must be present, whatever the model.
    static let requiredFiles = [configFile, tokenizerFile, tokenizerConfigFile]

    /// The directory, standardized.
    let url: URL

    /// Checks that `url` is a directory that holds the required files, at least one weight file
    /// and a chat template. Nothing here calls into MLX.
    init(validating url: URL) throws {
        let url = url.standardizedFileURL
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MLXLanguageModelError.directoryNotFound(url.path)
        }

        let missing = Self.requiredFiles.filter {
            !fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw MLXLanguageModelError.missingFiles(missing)
        }

        let contents = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        guard contents.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw MLXLanguageModelError.missingWeights
        }

        let tokenizerConfig = try Self.jsonObject(named: Self.tokenizerConfigFile, in: url)
        guard try Self.chatTemplate(in: url, tokenizerConfig: tokenizerConfig) != nil else {
            throw MLXLanguageModelError.missingChatTemplate
        }

        self.url = url
    }

    /// Reads a JSON file whose top level is an object.
    ///
    /// The result is the Foundation object graph as `JSONSerialization` built it. It is left
    /// unbridged on purpose: `tokenizer.json` has hundreds of thousands of entries.
    static func jsonObject(named name: String, in directory: URL) throws -> NSDictionary {
        let data: Data
        do {
            data = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
        } catch {
            throw MLXLanguageModelError.invalidTokenizer("\(name): \(error.localizedDescription)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MLXLanguageModelError.invalidTokenizer("\(name): \(error.localizedDescription)")
        }
        guard let dictionary = object as? NSDictionary else {
            throw MLXLanguageModelError.invalidTokenizer("\(name): the top level is not a JSON object")
        }
        return dictionary
    }

    /// The chat template that ships with the asset, as the tokenizer configuration should carry it.
    ///
    /// Newer conversions keep the template in its own file, so the order is the one Hugging Face
    /// tooling applies: `chat_template.jinja`, then `chat_template.json`, then the `chat_template`
    /// key of `tokenizer_config.json`. The last one may be a string or a list of named templates
    /// and is returned untouched.
    ///
    /// - Returns: `nil` when the asset ships no template.
    static func chatTemplate(in directory: URL, tokenizerConfig: NSDictionary) throws -> Any? {
        let fileManager = FileManager.default

        let jinjaURL = directory.appendingPathComponent(chatTemplateJinjaFile)
        if fileManager.fileExists(atPath: jinjaURL.path) {
            do {
                return try String(contentsOf: jinjaURL, encoding: .utf8)
            } catch {
                throw MLXLanguageModelError.invalidTokenizer("\(chatTemplateJinjaFile): \(error.localizedDescription)")
            }
        }

        if fileManager.fileExists(atPath: directory.appendingPathComponent(chatTemplateJSONFile).path) {
            let object = try jsonObject(named: chatTemplateJSONFile, in: directory)
            if let template = object["chat_template"] as? String {
                return template
            }
        }

        switch tokenizerConfig["chat_template"] {
        case let template as String where !template.isEmpty:
            return template
        case let templates as [Any] where !templates.isEmpty:
            return templates
        default:
            return nil
        }
    }
}

/// Adapts a swift-transformers tokenizer to the protocol mlx-swift-lm generates with.
struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads a tokenizer and the chat template that ships with it from a local directory.
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    /// Loads on a global dispatch queue: parsing an 11 MB `tokenizer.json` is a few hundred
    /// milliseconds of work that does not belong on a cooperative thread.
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.loadSynchronously(from: directory) })
            }
        }
    }

    /// Reads `tokenizer.json`, `tokenizer_config.json` and the chat template, and builds the tokenizer.
    static func loadSynchronously(from directory: URL) throws -> any MLXLMCommon.Tokenizer {
        let directory = directory.standardizedFileURL

        // The parsed JSON of a real tokenizer is about a million Foundation objects. The pool
        // releases them as soon as they are converted, before the tokenizer builds its own tables.
        let (tokenizerConfig, tokenizerData) = try autoreleasepool { () throws -> (Config, Config) in
            let rawConfig = try ModelDirectory.jsonObject(named: ModelDirectory.tokenizerConfigFile, in: directory)
            guard let chatTemplate = try ModelDirectory.chatTemplate(in: directory, tokenizerConfig: rawConfig) else {
                throw MLXLanguageModelError.missingChatTemplate
            }
            let configWithTemplate = NSMutableDictionary(dictionary: rawConfig)
            configWithTemplate["chat_template"] = chatTemplate

            let rawData = try ModelDirectory.jsonObject(named: ModelDirectory.tokenizerFile, in: directory)
            return (JSONConfig.make(configWithTemplate), JSONConfig.make(rawData))
        }

        do {
            let upstream = try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
            return TransformersTokenizerBridge(upstream: upstream)
        } catch {
            throw MLXLanguageModelError.invalidTokenizer(String(describing: error))
        }
    }
}

/// Builds the `Config` tree the tokenizer library consumes from a `JSONSerialization` object graph.
///
/// `Config(_: [NSString: Any])` does the same through a chain of Swift dynamic casts at every
/// node, which takes about a second for a real `tokenizer.json`. Here each node is classified
/// once by its Core Foundation type. Strings keep their exact UTF-16 code units: vocabulary keys
/// that differ only by Unicode normalization must stay distinct.
enum JSONConfig {
    /// A `Config` holding JSON `null`: what a `Config` returns for a key it does not have.
    private static let null = Config([BinaryDistinctString: Config]())[BinaryDistinctString("null")]

    private static let stringType = CFStringGetTypeID()
    private static let numberType = CFNumberGetTypeID()
    private static let booleanType = CFBooleanGetTypeID()
    private static let arrayType = CFArrayGetTypeID()
    private static let dictionaryType = CFDictionaryGetTypeID()

    static func make(_ object: Any) -> Config {
        let reference = object as AnyObject
        // `JSONSerialization` only produces the toll-free bridged classes, so the Core Foundation
        // type identifies the node and the casts below cannot fail.
        let type = CFGetTypeID(reference)

        if type == stringType, let string = reference as? NSString {
            return Config(binaryDistinct(string))
        }
        if type == numberType, let number = reference as? NSNumber {
            return CFNumberIsFloatType(number) ? Config(number.floatValue) : Config(number.intValue)
        }
        if type == arrayType, let array = reference as? NSArray {
            var elements = [Config]()
            elements.reserveCapacity(array.count)
            for element in array {
                elements.append(make(element))
            }
            return Config(elements)
        }
        if type == dictionaryType, let dictionary = reference as? NSDictionary {
            var entries = [BinaryDistinctString: Config](minimumCapacity: dictionary.count)
            dictionary.enumerateKeysAndObjects { key, value, _ in
                if let key = key as? NSString {
                    entries[binaryDistinct(key)] = make(value)
                }
            }
            return Config(entries)
        }
        if type == booleanType, let number = reference as? NSNumber {
            return Config(number.boolValue)
        }
        return null
    }

    private static func binaryDistinct(_ string: NSString) -> BinaryDistinctString {
        let length = string.length
        guard length > 0 else { return BinaryDistinctString([UInt16]()) }
        let units = [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            if let base = buffer.baseAddress {
                string.getCharacters(base, range: NSRange(location: 0, length: length))
                count = length
            }
        }
        return BinaryDistinctString(units)
    }
}

/// Hands mlx-swift-lm a tokenizer that is already being loaded, so the model loader and the
/// runtime share one instance and the files are parsed once.
struct SharedTokenizerLoader: MLXLMCommon.TokenizerLoader {
    let task: Task<any MLXLMCommon.Tokenizer, Error>

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await task.value
    }
}
