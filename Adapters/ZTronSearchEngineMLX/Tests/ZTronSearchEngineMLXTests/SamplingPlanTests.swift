import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineMLX

final class SamplingPlanTests: XCTestCase {
    /// What a model tuned for thinking mode typically ships.
    private let assetConfig = AssetGenerationConfig(temperature: 0.6, topP: 0.95, topK: 20)

    // MARK: - Precedence

    func testSpecificationDefaultsApplyWithoutGenerationConfig() {
        let plan = SamplingPlan(options: .default, generationConfig: nil)
        XCTAssertEqual(plan.temperature, 0.7)
        XCTAssertEqual(plan.topP, 0.8)
        XCTAssertEqual(plan.maxNewTokens, 512)
        XCTAssertEqual(plan.topK, 0)
        XCTAssertNil(plan.repetitionPenalty)
        XCTAssertNil(plan.seed)
    }

    func testGenerationConfigWinsOverTheDefaults() {
        let plan = SamplingPlan(options: .default, generationConfig: assetConfig)
        XCTAssertEqual(plan.temperature, 0.6)
        XCTAssertEqual(plan.topP, 0.95)
        XCTAssertEqual(plan.topK, 20)
        XCTAssertEqual(plan.maxNewTokens, 512)
    }

    func testExplicitRequestOptionsWinOverGenerationConfig() {
        let options = GenerationOptions(temperature: 0.2, topP: 0.5, maxNewTokens: 100)
        let plan = SamplingPlan(options: options, generationConfig: assetConfig)
        XCTAssertEqual(plan.temperature, 0.2)
        XCTAssertEqual(plan.topP, 0.5)
        XCTAssertEqual(plan.maxNewTokens, 100)
        // The request has no top-k of its own, so the asset's still applies.
        XCTAssertEqual(plan.topK, 20)
    }

    func testEachOptionIsResolvedOnItsOwn() {
        let onlyTemperature = SamplingPlan(options: GenerationOptions(temperature: 1.0), generationConfig: assetConfig)
        XCTAssertEqual(onlyTemperature.temperature, 1.0)
        XCTAssertEqual(onlyTemperature.topP, 0.95)

        let onlyTopP = SamplingPlan(options: GenerationOptions(topP: 0.3), generationConfig: assetConfig)
        XCTAssertEqual(onlyTopP.temperature, 0.6)
        XCTAssertEqual(onlyTopP.topP, 0.3)
    }

    func testAValueTheRequestSetsWinsEvenWhenItEqualsTheDefault() {
        // 0.7 and 0.8 asked for by name are a request like any other.
        let plan = SamplingPlan(
            options: GenerationOptions(temperature: GenerationOptions.defaultTemperature, topP: GenerationOptions.defaultTopP),
            generationConfig: assetConfig
        )
        XCTAssertEqual(plan.temperature, 0.7)
        XCTAssertEqual(plan.topP, 0.8)
        XCTAssertNil(GenerationOptions.default.temperature)
        XCTAssertNil(GenerationOptions.default.topP)
    }

    func testGenerationConfigWithoutAKeyLeavesTheDefault() {
        let plan = SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(topK: 40))
        XCTAssertEqual(plan.temperature, 0.7)
        XCTAssertEqual(plan.topP, 0.8)
        XCTAssertEqual(plan.topK, 40)
    }

    func testDoSampleFalseMeansGreedyUnlessTheRequestIsExplicit() {
        let greedyAsset = AssetGenerationConfig(temperature: 0.6, doSample: false)
        XCTAssertEqual(SamplingPlan(options: .default, generationConfig: greedyAsset).temperature, 0)
        XCTAssertEqual(
            SamplingPlan(options: GenerationOptions(temperature: 0.9), generationConfig: greedyAsset).temperature,
            0.9
        )
        let samplingAsset = AssetGenerationConfig(temperature: 0.6, doSample: true)
        XCTAssertEqual(SamplingPlan(options: .default, generationConfig: samplingAsset).temperature, 0.6)
    }

    func testExplicitGreedyRequestIsHonoured() {
        let plan = SamplingPlan(options: GenerationOptions(temperature: 0, topP: 1), generationConfig: assetConfig)
        XCTAssertEqual(plan.temperature, 0)
        XCTAssertEqual(plan.topP, 1)
    }

    func testMaxNewTokensIsTheCallersBudget() {
        // The asset may lower the default budget…
        XCTAssertEqual(
            SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(maxNewTokens: 256)).maxNewTokens,
            256
        )
        // …but never raise it…
        XCTAssertEqual(
            SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(maxNewTokens: 2_048)).maxNewTokens,
            512
        )
        // …and an explicit budget is used as is.
        XCTAssertEqual(
            SamplingPlan(options: GenerationOptions(maxNewTokens: 100), generationConfig: AssetGenerationConfig(maxNewTokens: 50)).maxNewTokens,
            100
        )
        XCTAssertEqual(
            SamplingPlan(options: GenerationOptions(maxNewTokens: 1_000), generationConfig: AssetGenerationConfig(maxNewTokens: 50)).maxNewTokens,
            1_000
        )
    }

    func testSeedComesFromTheRequestAlone() {
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(seed: 42), generationConfig: assetConfig).seed, 42)
        XCTAssertNil(SamplingPlan(options: .default, generationConfig: assetConfig).seed)
    }

    func testRepetitionPenaltyComesFromTheAsset() {
        XCTAssertEqual(
            SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(repetitionPenalty: 1.05)).repetitionPenalty,
            1.05
        )
        // 1 is the neutral value and a non-positive one is meaningless: both switch it off.
        XCTAssertNil(SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(repetitionPenalty: 1)).repetitionPenalty)
        XCTAssertNil(SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(repetitionPenalty: 0)).repetitionPenalty)
    }

    func testOutOfRangeValuesAreMadeSafe() {
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(temperature: -1), generationConfig: nil).temperature, 0)
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(temperature: .nan), generationConfig: nil).temperature, 0.7)
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(topP: 0), generationConfig: nil).topP, 1)
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(topP: 1.5), generationConfig: nil).topP, 1)
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(topP: .infinity), generationConfig: nil).topP, 1)
        XCTAssertEqual(SamplingPlan(options: GenerationOptions(maxNewTokens: -5), generationConfig: nil).maxNewTokens, 0)
        XCTAssertEqual(SamplingPlan(options: .default, generationConfig: AssetGenerationConfig(topK: -3)).topK, 0)
    }

    // MARK: - Context window

    func testTokenBudgetStaysInsideTheContextWindow() {
        let plan = SamplingPlan(options: .default, generationConfig: nil)
        XCTAssertEqual(plan.tokenBudget(promptTokens: 1_000, contextWindow: 4_096), 512)
        XCTAssertEqual(plan.tokenBudget(promptTokens: 3_584, contextWindow: 4_096), 512)
        XCTAssertEqual(plan.tokenBudget(promptTokens: 4_000, contextWindow: 4_096), 96)
        XCTAssertEqual(plan.tokenBudget(promptTokens: 4_096, contextWindow: 4_096), 0)
        XCTAssertEqual(plan.tokenBudget(promptTokens: 5_000, contextWindow: 4_096), 0)
    }

    // MARK: - generation_config.json

    func testParsesTheSamplingKeys() throws {
        let json = """
            {
              "bos_token_id": 151643,
              "do_sample": true,
              "eos_token_id": [151645, 151643],
              "pad_token_id": 151643,
              "temperature": 0.6,
              "top_k": 20,
              "top_p": 0.95,
              "repetition_penalty": 1.05,
              "max_new_tokens": 2048,
              "transformers_version": "4.51.0"
            }
            """
        let config = try AssetGenerationConfig(json: Data(json.utf8))
        XCTAssertEqual(config.temperature, 0.6)
        XCTAssertEqual(config.topP, 0.95)
        XCTAssertEqual(config.topK, 20)
        XCTAssertEqual(config.doSample, true)
        XCTAssertEqual(config.repetitionPenalty, 1.05)
        XCTAssertEqual(config.maxNewTokens, 2_048)
    }

    func testAbsentNullAndMistypedKeysAreNil() throws {
        let json = #"{"temperature": null, "top_p": "0.9", "top_k": 20.5, "do_sample": 1, "max_new_tokens": true}"#
        let config = try AssetGenerationConfig(json: Data(json.utf8))
        XCTAssertEqual(config, AssetGenerationConfig())
        XCTAssertEqual(try AssetGenerationConfig(json: Data("{}".utf8)), AssetGenerationConfig())
    }

    func testIntegersWrittenAsFloatsAreAccepted() throws {
        let config = try AssetGenerationConfig(json: Data(#"{"top_k": 20.0, "temperature": 1}"#.utf8))
        XCTAssertEqual(config.topK, 20)
        XCTAssertEqual(config.temperature, 1)
    }

    func testMalformedFileIsAnError() {
        XCTAssertThrowsError(try AssetGenerationConfig(json: Data("not json".utf8))) { error in
            guard case MLXLanguageModelError.invalidGenerationConfig = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try AssetGenerationConfig(json: Data("[1, 2]".utf8))) { error in
            guard case MLXLanguageModelError.invalidGenerationConfig = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLoadReturnsNilWhenTheDirectoryHasNoFile() throws {
        let directory = try ModelDirectoryFixture.make(for: self)
        XCTAssertNil(try AssetGenerationConfig.load(from: directory))
    }

    func testLoadReadsTheFileOfTheDirectory() throws {
        var layout = ModelDirectoryFixture.Layout()
        layout.generationConfig = #"{"temperature": 0.6, "top_p": 0.95, "top_k": 20}"#
        let directory = try ModelDirectoryFixture.make(layout, for: self)
        XCTAssertEqual(try AssetGenerationConfig.load(from: directory), assetConfig)
    }
}
