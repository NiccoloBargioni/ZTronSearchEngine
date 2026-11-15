import Foundation
import XCTest

/// Writes throwaway model directories for tests that need no weights.
///
/// The tokenizer is a tiny BPE tokenizer over single characters, with the ChatML control tokens
/// and the two think tags as added tokens. It is enough to exercise the real tokenizer library,
/// the real Jinja engine and the directory checks of the runtime without a model.
enum ModelDirectoryFixture {
    /// Which parts of a model directory to write.
    struct Layout {
        var config = true
        var tokenizer = true
        var tokenizerConfig = true
        var weights = true
        /// The `chat_template` value of `tokenizer_config.json`; `nil` leaves the key out.
        var inlineChatTemplate: String? = ModelDirectoryFixture.chatTemplate
        /// Named templates, written as the list form of `chat_template` instead of a string.
        var namedChatTemplates: [(name: String, template: String)]?
        /// Contents of `chat_template.jinja`; `nil` writes no such file.
        var jinjaChatTemplate: String?
        /// Contents of the `chat_template` key of `chat_template.json`; `nil` writes no such file.
        var jsonChatTemplate: String?
        /// Raw contents of `generation_config.json`; `nil` writes no such file.
        var generationConfig: String?
    }

    /// A ChatML-style template with Qwen3's switch: when `enable_thinking` is `false`, the
    /// generation prompt ends with an empty think block.
    static let chatTemplate =
        "{%- for message in messages %}"
        + "{{- '<|im_start|>' + message.role + '\\n' + message.content + '<|im_end|>\\n' }}"
        + "{%- endfor %}"
        + "{%- if add_generation_prompt %}"
        + "{{- '<|im_start|>assistant\\n' }}"
        + "{%- if enable_thinking is defined and enable_thinking is false %}"
        + "{{- '<think>\\n\\n</think>\\n\\n' }}"
        + "{%- endif %}"
        + "{%- endif %}"

    static let controlTokens = ["<|endoftext|>", "<|im_start|>", "<|im_end|>", "<think>", "</think>"]

    /// The id of `<|im_end|>`, the end-of-sequence token of the fixture.
    static let endOfTurnTokenID = 2

    /// Creates the directory and registers its removal with `testCase`.
    static func make(_ layout: Layout = Layout(), for testCase: XCTestCase) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZTronSearchEngineMLXTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        if layout.config {
            try write(["model_type": "qwen3", "eos_token_id": endOfTurnTokenID], to: "config.json", in: directory)
        }
        if layout.tokenizer {
            try write(tokenizerJSON(), to: "tokenizer.json", in: directory)
        }
        if layout.tokenizerConfig {
            var config: [String: Any] = [
                "tokenizer_class": "PreTrainedTokenizer",
                "eos_token": "<|im_end|>",
                "pad_token": "<|endoftext|>",
                "model_max_length": 131_072,
            ]
            if let templates = layout.namedChatTemplates {
                config["chat_template"] = templates.map { ["name": $0.name, "template": $0.template] }
            } else if let template = layout.inlineChatTemplate {
                config["chat_template"] = template
            }
            try write(config, to: "tokenizer_config.json", in: directory)
        }
        if layout.weights {
            // Not a real safetensors file: the tests stop before anything would read it.
            try Data("not weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        }
        if let template = layout.jinjaChatTemplate {
            try Data(template.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        }
        if let template = layout.jsonChatTemplate {
            try write(["chat_template": template], to: "chat_template.json", in: directory)
        }
        if let generationConfig = layout.generationConfig {
            try Data(generationConfig.utf8).write(to: directory.appendingPathComponent("generation_config.json"))
        }
        return directory
    }

    /// A character-level BPE tokenizer: ids 0–4 are the control tokens, then newline and the
    /// printable ASCII characters, then the merged pieces `th` and `the`.
    private static func tokenizerJSON() -> [String: Any] {
        var vocabulary: [String: Int] = [:]
        var addedTokens: [[String: Any]] = []
        for (id, token) in controlTokens.enumerated() {
            vocabulary[token] = id
            addedTokens.append([
                "id": id,
                "content": token,
                "single_word": false,
                "lstrip": false,
                "rstrip": false,
                "normalized": false,
                "special": id < 3,
            ])
        }
        var next = controlTokens.count
        for scalar in ["\n"] + (UInt8(32) ... UInt8(126)).map({ String(UnicodeScalar($0)) }) {
            vocabulary[scalar] = next
            next += 1
        }
        for piece in ["th", "the"] {
            vocabulary[piece] = next
            next += 1
        }
        return [
            "version": "1.0",
            "added_tokens": addedTokens,
            "model": [
                "type": "BPE",
                "vocab": vocabulary,
                "merges": [["t", "h"], ["th", "e"]],
            ] as [String: Any],
        ]
    }

    private static func write(_ object: [String: Any], to name: String, in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent(name))
    }
}
