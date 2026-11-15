import MLXLMCommon
import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

/// Exercises the real tokenizer library and the real Jinja engine on a tiny tokenizer written to
/// a temporary directory. No weights and no MLX evaluation are involved.
final class LocalTokenizerTests: XCTestCase {
    private func loadTokenizer(_ layout: ModelDirectoryFixture.Layout = .init()) throws -> any MLXLMCommon.Tokenizer {
        try LocalTokenizerLoader.loadSynchronously(from: ModelDirectoryFixture.make(layout, for: self))
    }

    private func render(
        _ messages: [ChatMessage],
        thinking: Bool,
        with tokenizer: any MLXLMCommon.Tokenizer
    ) throws -> String {
        let tokens = try tokenizer.applyChatTemplate(
            messages: ChatPrompt.templateMessages(messages),
            tools: nil,
            additionalContext: ChatPrompt.templateContext(thinking: thinking)
        )
        return tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
    }

    // MARK: - Loading

    func testLoadsFromALocalDirectory() throws {
        let tokenizer = try loadTokenizer()
        XCTAssertEqual(tokenizer.eosToken, "<|im_end|>")
        XCTAssertEqual(tokenizer.eosTokenId, ModelDirectoryFixture.endOfTurnTokenID)
        XCTAssertNil(tokenizer.unknownToken)
        XCTAssertEqual(tokenizer.convertTokenToId("<think>"), 3)
        XCTAssertEqual(tokenizer.convertIdToToken(4), "</think>")
    }

    func testAsyncLoaderProducesTheSameTokenizer() async throws {
        let directory = try ModelDirectoryFixture.make(for: self)
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        XCTAssertEqual(tokenizer.encode(text: "the cat", addSpecialTokens: false).count, 5)
    }

    func testEncodesAndDecodes() throws {
        let tokenizer = try loadTokenizer()
        // "the" is one merged piece; the other characters are one token each.
        let tokens = tokenizer.encode(text: "the cat", addSpecialTokens: false)
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false), "the cat")
        // Control tokens are single tokens, not runs of characters.
        XCTAssertEqual(tokenizer.encode(text: "<|im_start|>user\nhi<|im_end|>", addSpecialTokens: false).count, 9)
    }

    func testMissingFilesAreReported() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.tokenizer = false
        XCTAssertThrowsError(try loadTokenizer(layout)) { error in
            guard case MLXLanguageModelError.invalidTokenizer(let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("tokenizer.json"), reason)
        }
    }

    func testCorruptTokenizerFileIsReported() throws {
        let directory = try ModelDirectoryFixture.make(for: self)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try LocalTokenizerLoader.loadSynchronously(from: directory)) { error in
            guard case MLXLanguageModelError.invalidTokenizer = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Chat template

    func testAppliesTheTemplateOfTheAssetWithThinkingOff() throws {
        let tokenizer = try loadTokenizer()
        let prompt = try render(
            [ChatMessage(role: .system, content: "be brief"), ChatMessage(role: .user, content: "hi")],
            thinking: false,
            with: tokenizer
        )
        XCTAssertEqual(
            prompt,
            "<|im_start|>system\nbe brief<|im_end|>\n<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        )
    }

    func testThinkingOnLeavesTheGenerationPromptOpen() throws {
        let tokenizer = try loadTokenizer()
        let prompt = try render([ChatMessage(role: .user, content: "hi")], thinking: true, with: tokenizer)
        XCTAssertEqual(prompt, "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n")
    }

    func testAssistantTurnsOfTheHistoryAreRendered() throws {
        let tokenizer = try loadTokenizer()
        let prompt = try render(
            [
                ChatMessage(role: .user, content: "a"),
                ChatMessage(role: .assistant, content: "b"),
                ChatMessage(role: .user, content: "c"),
            ],
            thinking: true,
            with: tokenizer
        )
        XCTAssertEqual(
            prompt,
            "<|im_start|>user\na<|im_end|>\n<|im_start|>assistant\nb<|im_end|>\n<|im_start|>user\nc<|im_end|>\n<|im_start|>assistant\n"
        )
    }

    func testJinjaFileWinsOverTheInlineTemplate() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.jinjaChatTemplate = "{%- for message in messages %}{{- '[' + message.content + ']' }}{%- endfor %}"
        layout.jsonChatTemplate = "{{- 'from json' }}"
        let tokenizer = try loadTokenizer(layout)
        XCTAssertEqual(try render([ChatMessage(role: .user, content: "hi")], thinking: false, with: tokenizer), "[hi]")
    }

    func testJSONFileWinsOverTheInlineTemplate() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.jsonChatTemplate = "{%- for message in messages %}{{- '(' + message.content + ')' }}{%- endfor %}"
        let tokenizer = try loadTokenizer(layout)
        XCTAssertEqual(try render([ChatMessage(role: .user, content: "hi")], thinking: false, with: tokenizer), "(hi)")
    }

    func testTemplateFileAloneIsEnough() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.inlineChatTemplate = nil
        layout.jinjaChatTemplate = ModelDirectoryFixture.chatTemplate
        let directory = try ModelDirectoryFixture.make(layout, for: self)
        XCTAssertNoThrow(try ModelDirectory(validating: directory))
        let tokenizer = try LocalTokenizerLoader.loadSynchronously(from: directory)
        let prompt = try render([ChatMessage(role: .user, content: "hi")], thinking: true, with: tokenizer)
        XCTAssertEqual(prompt, "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n")
    }

    func testListOfNamedTemplatesUsesTheDefaultOne() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.namedChatTemplates = [
            (name: "tool_use", template: "{{- 'tools' }}"),
            (name: "default", template: "{%- for message in messages %}{{- '<' + message.content + '>' }}{%- endfor %}"),
        ]
        let directory = try ModelDirectoryFixture.make(layout, for: self)
        XCTAssertNoThrow(try ModelDirectory(validating: directory))
        let tokenizer = try LocalTokenizerLoader.loadSynchronously(from: directory)
        XCTAssertEqual(try render([ChatMessage(role: .user, content: "hi")], thinking: false, with: tokenizer), "<hi>")
    }

    func testMissingTemplateIsAnErrorNotAFallback() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.inlineChatTemplate = nil
        XCTAssertThrowsError(try loadTokenizer(layout)) { error in
            XCTAssertEqual(error as? MLXLanguageModelError, .missingChatTemplate)
        }
    }

    // MARK: - Directory checks

    func testCompleteDirectoryPassesTheCheck() throws {
        let directory = try ModelDirectoryFixture.make(for: self)
        XCTAssertEqual(try ModelDirectory(validating: directory).url, directory.standardizedFileURL)
    }

    // MARK: - Streaming text end to end

    /// Decodes token by token with mlx-swift-lm's streaming detokenizer, the way a generation
    /// does, and runs the pieces through the generation loop.
    private func stream(_ text: String, with tokenizer: any MLXLMCommon.Tokenizer) -> (emitted: [String], outcome: GenerationLoop.Outcome) {
        let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
        var position = 0
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        var emitted: [String] = []
        let stopTokens = StopTokens(configured: [], eosTokenID: tokenizer.eosTokenId, unknownTokenID: tokenizer.unknownTokenId)
        let outcome = GenerationLoop.run(
            tokenBudget: 512,
            nextToken: {
                guard position < tokens.count else { return nil }
                defer { position += 1 }
                return tokens[position]
            },
            isStopToken: { stopTokens.contains($0) },
            detokenize: { token in
                detokenizer.append(token: token)
                return detokenizer.next()
            },
            isCancelled: { false },
            emit: { emitted.append($0); return true }
        )
        return (emitted, outcome)
    }

    func testThinkBlockOfARealTokenStreamIsStripped() throws {
        let tokenizer = try loadTokenizer()
        let reply = "<think>\nthe user says hi\n</think>\n\nHello there!<|im_end|>ignored"
        let result = stream(reply, with: tokenizer)
        XCTAssertEqual(result.emitted.joined(), "Hello there!")
        XCTAssertEqual(result.outcome.stopReason, .endOfTurn)
        // Every token before the end-of-turn token counts, the hidden ones included.
        let generated = tokenizer.encode(text: "<think>\nthe user says hi\n</think>\n\nHello there!", addSpecialTokens: false)
        XCTAssertEqual(result.outcome.generatedTokens, generated.count)
    }

    func testPlainReplyStreamsCharacterByCharacter() throws {
        let tokenizer = try loadTokenizer()
        let result = stream("Hi <b>all</b>!<|im_end|>", with: tokenizer)
        XCTAssertEqual(result.emitted.joined(), "Hi <b>all</b>!")
        // "<" is held until the next character shows it starts no tag, so pieces are not 1:1 with tokens.
        XCTAssertTrue(result.emitted.contains("<b"))
    }
}
