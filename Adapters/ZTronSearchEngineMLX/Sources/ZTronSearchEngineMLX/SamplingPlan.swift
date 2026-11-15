import Foundation
import ZTronSearchEngine

/// The sampling keys of an asset's `generation_config.json`.
///
/// Only the keys this runtime acts on are kept. A key that is absent, `null` or of the wrong type
/// is `nil`. The end-of-sequence ids of the same file are read by the MLX loader, not here.
public struct AssetGenerationConfig: Sendable, Hashable {
    /// `temperature`.
    public var temperature: Double?
    /// `top_p`.
    public var topP: Double?
    /// `top_k`; `0` disables it.
    public var topK: Int?
    /// `do_sample`; `false` asks for greedy decoding.
    public var doSample: Bool?
    /// `max_new_tokens`.
    public var maxNewTokens: Int?
    /// `repetition_penalty`.
    public var repetitionPenalty: Double?

    /// The name of the file inside a model directory.
    public static let fileName = "generation_config.json"

    /// Creates a configuration from explicit values.
    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        doSample: Bool? = nil,
        maxNewTokens: Int? = nil,
        repetitionPenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.doSample = doSample
        self.maxNewTokens = maxNewTokens
        self.repetitionPenalty = repetitionPenalty
    }

    /// Parses the contents of a `generation_config.json`.
    ///
    /// - Throws: ``MLXLanguageModelError/invalidGenerationConfig(_:)`` when `data` is not a JSON object.
    public init(json data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MLXLanguageModelError.invalidGenerationConfig(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw MLXLanguageModelError.invalidGenerationConfig("the top level is not a JSON object")
        }
        self.init(
            temperature: Self.number(dictionary["temperature"]),
            topP: Self.number(dictionary["top_p"]),
            topK: Self.integer(dictionary["top_k"]),
            doSample: Self.boolean(dictionary["do_sample"]),
            maxNewTokens: Self.integer(dictionary["max_new_tokens"]),
            repetitionPenalty: Self.number(dictionary["repetition_penalty"])
        )
    }

    /// Reads `generation_config.json` from a model directory.
    ///
    /// - Returns: `nil` when the directory has no such file.
    /// - Throws: ``MLXLanguageModelError/invalidGenerationConfig(_:)`` when the file exists but cannot be read or parsed.
    public static func load(from directory: URL) throws -> AssetGenerationConfig? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MLXLanguageModelError.invalidGenerationConfig(error.localizedDescription)
        }
        return try AssetGenerationConfig(json: data)
    }

    // JSON booleans are `NSNumber` too, so a number is accepted only when it is not a boolean.

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let double = number(value), double == double.rounded(), abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }
}

/// The sampling settings one generation actually runs with.
///
/// ## Precedence
///
/// The specification sets the defaults (temperature 0.7, top-p 0.8, at most 512 new tokens), says
/// the asset's `generation_config.json` wins when present, and leaves explicit request options to
/// the caller. For each setting:
///
/// 1. `temperature`, `topP`: a value the request sets is used as is. When the request leaves
///    one `nil`, the asset's value is used if `generation_config.json` has the key, and the
///    default otherwise.
/// 2. `do_sample: false` in the asset means greedy decoding (temperature 0), unless the request
///    sets a temperature.
/// 3. `top_k` and `repetition_penalty` exist only in the asset and are used whenever it has them.
/// 4. `maxNewTokens` is the caller's budget and is never exceeded. The asset's `max_new_tokens`
///    can only lower it, and only while the request still carries the default.
/// 5. `seed` comes from the request alone; `nil` lets MLX seed the sampler from system entropy.
///
/// A temperature of 0 selects the most likely token every time; top-p, top-k and the seed then
/// have no effect.
public struct SamplingPlan: Sendable, Hashable {
    /// Sampling temperature; `0` is greedy decoding.
    public let temperature: Double
    /// Nucleus sampling mass in `(0, 1]`; `1` disables it.
    public let topP: Double
    /// Top-k cut; `0` disables it.
    public let topK: Int
    /// Repetition penalty; `nil` disables it.
    public let repetitionPenalty: Double?
    /// Most tokens to generate, before the context window is taken into account.
    public let maxNewTokens: Int
    /// Seed of the sampler; `nil` = system entropy.
    public let seed: UInt64?

    /// Resolves the settings for one request against the asset's configuration.
    public init(options: GenerationOptions, generationConfig: AssetGenerationConfig?) {
        let defaults = GenerationOptions.default
        let config = generationConfig

        // A value the request sets wins; otherwise the asset's configuration, then the defaults.
        let temperature: Double
        if let requested = options.temperature {
            temperature = requested
        } else if config?.doSample == false {
            temperature = 0
        } else {
            temperature = config?.temperature ?? GenerationOptions.defaultTemperature
        }
        let topP = options.topP ?? config?.topP ?? GenerationOptions.defaultTopP

        var maxNewTokens = options.maxNewTokens
        if options.maxNewTokens == defaults.maxNewTokens, let assetMaximum = config?.maxNewTokens {
            maxNewTokens = min(maxNewTokens, assetMaximum)
        }

        self.temperature = temperature.isFinite ? max(0, temperature) : GenerationOptions.defaultTemperature
        self.topP = (topP.isFinite && topP > 0 && topP < 1) ? topP : 1
        self.topK = max(0, config?.topK ?? 0)
        if let penalty = config?.repetitionPenalty, penalty > 0, penalty != 1 {
            self.repetitionPenalty = penalty
        } else {
            self.repetitionPenalty = nil
        }
        self.maxNewTokens = max(0, maxNewTokens)
        self.seed = options.seed
    }

    /// The number of tokens that may be generated after a prompt of `promptTokens` tokens without
    /// leaving a window of `contextWindow` tokens.
    public func tokenBudget(promptTokens: Int, contextWindow: Int) -> Int {
        max(0, min(maxNewTokens, contextWindow - promptTokens))
    }
}
