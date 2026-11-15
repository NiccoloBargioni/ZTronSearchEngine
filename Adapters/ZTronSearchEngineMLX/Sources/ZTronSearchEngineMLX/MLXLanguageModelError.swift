import Foundation

/// What can go wrong in ``MLXLanguageModel``.
///
/// Errors of the MLX and tokenizer libraries are carried as their description, so the type stays
/// `Sendable` and `Hashable` and core can compare and log it without importing either library.
public enum MLXLanguageModelError: Error, Sendable, Hashable {
    /// `load(from:)` was given a path that is not a directory.
    case directoryNotFound(String)
    /// The directory lacks files the runtime needs; the names are listed.
    case missingFiles([String])
    /// The directory holds no `.safetensors` weight file.
    case missingWeights
    /// Neither `tokenizer_config.json` nor a `chat_template.jinja` / `chat_template.json` file
    /// carries a chat template. The runtime never falls back to a hand-written template.
    case missingChatTemplate
    /// `generation_config.json` exists but cannot be read as a JSON object.
    case invalidGenerationConfig(String)
    /// A tokenizer file cannot be read or is not what the tokenizer library expects.
    case invalidTokenizer(String)
    /// MLX could not build the model or read its weights.
    case loadFailed(String)
    /// The load was superseded by `unload()` or by a load of another directory.
    case loadSuperseded
    /// `generate(_:)` was called while no model is loaded.
    case notLoaded
    /// The request has no messages.
    case emptyRequest
    /// The chat template of the asset rejected the messages.
    case chatTemplateFailed(String)
    /// The rendered prompt leaves no room for a reply inside the context window.
    case promptTooLong(promptTokens: Int, contextWindow: Int)
    /// MLX refused the generation parameters.
    case generationFailed(String)
    /// A calibration stream ended without reporting usage and a stop reason.
    case calibrationIncomplete
}

extension MLXLanguageModelError: LocalizedError {
    /// The error as one sentence, for logs and diagnostics.
    public var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "The model directory does not exist: \(path)"
        case .missingFiles(let names):
            return "The model directory lacks: \(names.joined(separator: ", "))"
        case .missingWeights:
            return "The model directory holds no .safetensors weight file."
        case .missingChatTemplate:
            return "The model directory ships no chat template."
        case .invalidGenerationConfig(let reason):
            return "generation_config.json cannot be used: \(reason)"
        case .invalidTokenizer(let reason):
            return "The tokenizer cannot be loaded: \(reason)"
        case .loadFailed(let reason):
            return "The model cannot be loaded: \(reason)"
        case .loadSuperseded:
            return "The load was superseded by an unload or by another load."
        case .notLoaded:
            return "No model is loaded."
        case .emptyRequest:
            return "The generation request has no messages."
        case .chatTemplateFailed(let reason):
            return "The chat template rejected the messages: \(reason)"
        case .promptTooLong(let promptTokens, let contextWindow):
            return "The prompt has \(promptTokens) tokens and the context window holds \(contextWindow)."
        case .generationFailed(let reason):
            return "Generation cannot start: \(reason)"
        case .calibrationIncomplete:
            return "The generation ended before it reported usage and a stop reason."
        }
    }
}
