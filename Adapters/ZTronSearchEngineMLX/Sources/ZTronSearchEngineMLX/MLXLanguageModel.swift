import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ZTronSearchEngine

/// The MLX runtime behind core's `LocalLanguageModel` boundary (specification section 14).
///
/// One instance owns one model: its weights, its tokenizer and the chat template that ships with
/// it. All of it is read from a local directory; the runtime never opens a network connection.
///
/// ## Threading
///
/// The actor runs on a thread of its own instead of Swift's cooperative pool. Applying the chat
/// template, the prompt prefill and every decode step happen on that thread, so a generation
/// never occupies a cooperative thread. A generation is one uninterrupted job: other calls to the
/// same instance (`countTokens`, `load`, another `generate`) wait until it ends, in arrival order.
/// Reading the weight files is done by mlx-swift-lm on a global dispatch queue.
///
/// ## Events
///
/// `generate(_:)` yields `.delta` for each decoded piece of visible text, then one `.usage`, then
/// one `.finished`, and ends. `<think>` blocks never reach `.delta`. Errors found before the first
/// token (no model loaded, a prompt that does not fit) end the stream by throwing.
///
/// ## Cancellation
///
/// A generation stops when the consumer of its stream goes away (its task is cancelled or it
/// stops iterating), when ``cancelGenerations()`` is called and when `unload()` is called. No
/// token is requested after that: at most the token that was being computed completes. A
/// consumer that went away cannot receive anything more, so `.finished(.cancelled)` reaches only
/// consumers whose generation was stopped by ``cancelGenerations()`` or `unload()`. During the
/// prompt prefill, cancellation takes effect between two prefill chunks.
public actor MLXLanguageModel: LocalLanguageModel {
    /// Knobs of the runtime that are not part of core's contract.
    public struct Tuning: Sendable, Hashable {
        /// Upper bound, in bytes, of the buffers MLX keeps for reuse after they are freed.
        ///
        /// MLX's default lets this cache grow to gigabytes, which an iPhone does not survive. The
        /// limit is a process-wide MLX setting and is applied on every `load`. `nil` leaves MLX's
        /// own setting alone.
        public var bufferCacheLimit: Int?

        /// Most prompt tokens evaluated in one forward pass while the prompt is prefilled.
        ///
        /// Smaller chunks make cancellation during a long prefill take effect sooner and cost
        /// some throughput. `nil` keeps the model's default (512 for Qwen3).
        public var prefillStepSize: Int?

        /// Creates a tuning.
        public init(bufferCacheLimit: Int? = 32 * 1024 * 1024, prefillStepSize: Int? = nil) {
            self.bufferCacheLimit = bufferCacheLimit
            self.prefillStepSize = prefillStepSize
        }

        /// A 32 MB buffer cache and the model's own prefill chunking.
        public static let `default` = Tuning()
    }

    /// The working window of specification section 14.2, in tokens.
    public static let defaultContextWindow = 4_096

    /// Physical memory the device gate asks for: 6 GB, counted as 6 × 1024³ bytes.
    public static let minimumPhysicalMemory: Int64 = 6 * 1024 * 1024 * 1024

    /// The OS floor of mlx-swift on the platform this was built for: iOS 17.0, or macOS 14.0.
    ///
    /// The device gate compares it with the version the process runs on, and on a Mac that is
    /// the macOS version. A flat 17.0 would switch chat off on macOS 14 and 15.
    public static let minimumOS: OperatingSystemVersion = {
        #if os(macOS)
            return OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        #else
            return OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0)
        #endif
    }()

    /// The descriptor of this runtime for `asset`: a 4,096-token window unless told otherwise,
    /// 6 GB of physical memory, and ``minimumOS``.
    public static func descriptor(
        for asset: ModelAsset,
        contextWindow: Int = MLXLanguageModel.defaultContextWindow
    ) -> LanguageModelDescriptor {
        LanguageModelDescriptor(
            asset: asset,
            contextWindow: contextWindow,
            minimumPhysicalMemory: minimumPhysicalMemory,
            minimumOS: minimumOS
        )
    }

    /// What core's device gate reads: the asset, the context window, and the memory and OS floors.
    public nonisolated let descriptor: LanguageModelDescriptor

    /// The tuning this instance was created with.
    public nonisolated let tuning: Tuning

    private nonisolated let executor: DedicatedThreadExecutor
    /// The generations that are running or waiting for the thread.
    nonisolated let generations = GenerationRegistry()

    /// The executor of the actor: one dedicated thread, not Swift's cooperative pool.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// What `load` leaves behind.
    private struct LoadedModel {
        /// Standardized path of the directory, the identity loads are compared by.
        let directoryPath: String
        let context: ModelContext
        let stopTokens: StopTokens
        let generationConfig: AssetGenerationConfig?
    }

    /// A load that has not finished yet.
    private struct PendingLoad {
        let id: UInt64
        let directoryPath: String
        let task: Task<Void, Error>
    }

    private var loaded: LoadedModel?
    private var pendingLoad: PendingLoad?
    private var loadCounter: UInt64 = 0
    /// The directory of the last successful load, kept across `unload()` for token counting.
    private var lastDirectory: URL?
    /// A tokenizer loaded on its own to count tokens while no model is loaded.
    private var standbyTokenizer: Task<(any MLXLMCommon.Tokenizer)?, Never>?

    /// Creates a runtime for `asset` with the descriptor of ``descriptor(for:contextWindow:)``.
    ///
    /// Nothing is loaded yet. For the reference model, `asset` comes from
    /// ``Qwen3Asset/asset(pinnedManifestAt:)``.
    public init(
        asset: ModelAsset,
        contextWindow: Int = MLXLanguageModel.defaultContextWindow,
        tuning: Tuning = .default
    ) {
        self.init(descriptor: Self.descriptor(for: asset, contextWindow: contextWindow), tuning: tuning)
    }

    /// Creates a runtime with a descriptor of the caller's making.
    public init(descriptor: LanguageModelDescriptor, tuning: Tuning = .default) {
        self.descriptor = descriptor
        self.tuning = tuning
        self.executor = DedicatedThreadExecutor(threadName: "ZTronSearchEngineMLX.MLXLanguageModel")
    }

    deinit {
        executor.shutdown()
    }

    // MARK: - Loading

    /// Loads the weights, the tokenizer and the chat template from `directory`.
    ///
    /// The directory must hold `config.json`, `tokenizer.json`, `tokenizer_config.json`, at least
    /// one `.safetensors` file and a chat template (inside `tokenizer_config.json`, or as
    /// `chat_template.jinja` / `chat_template.json`). This is checked first, before MLX is
    /// touched, and reported as ``MLXLanguageModelError``. Only local files are read.
    ///
    /// Loading the directory that is already loaded does nothing. A second call for a directory
    /// that is still loading waits for that load. Loading another directory unloads the current
    /// model first. A load that `unload()` or another `load` overtakes throws
    /// ``MLXLanguageModelError/loadSuperseded``.
    public func load(from directory: URL) async throws {
        let directory = directory.standardizedFileURL
        let path = directory.path
        if let loaded, loaded.directoryPath == path {
            return
        }
        if let pendingLoad, pendingLoad.directoryPath == path {
            return try await pendingLoad.task.value
        }

        // Another directory, or nothing loaded yet. A tokenizer that was loaded to count tokens
        // for this very directory is handed to the load instead of being parsed again.
        let standby = lastDirectory?.path == path ? standbyTokenizer : nil
        releaseModel()
        loadCounter += 1
        let id = loadCounter
        let task = Task {
            try await self.performLoad(from: directory, id: id, reusing: standby)
        }
        pendingLoad = PendingLoad(id: id, directoryPath: path, task: task)
        try await task.value
    }

    private func performLoad(
        from directory: URL,
        id: UInt64,
        reusing standby: Task<(any MLXLMCommon.Tokenizer)?, Never>?
    ) async throws {
        defer {
            if pendingLoad?.id == id {
                pendingLoad = nil
            }
        }
        guard pendingLoad?.id == id else {
            throw MLXLanguageModelError.loadSuperseded
        }

        // Plain file inspection first: a directory that cannot work is rejected before any MLX
        // state exists.
        let validated = try ModelDirectory(validating: directory)
        let generationConfig = try AssetGenerationConfig.load(from: validated.url)

        if let limit = tuning.bufferCacheLimit {
            MLX.Memory.cacheLimit = limit
        }

        // The tokenizer loads while mlx-swift-lm reads the weights.
        let tokenizerTask = Task<any MLXLMCommon.Tokenizer, Error>.detached {
            if let tokenizer = await standby?.value {
                return tokenizer
            }
            return try await LocalTokenizerLoader().load(from: validated.url)
        }

        let context: ModelContext
        do {
            context = try await LLMModelFactory.shared.load(
                from: validated.url,
                using: SharedTokenizerLoader(task: tokenizerTask)
            )
        } catch let error as MLXLanguageModelError {
            throw error
        } catch {
            throw MLXLanguageModelError.loadFailed(Self.describe(error))
        }

        guard pendingLoad?.id == id else {
            // `unload()` or another `load` ran while the weights were being read. The context
            // dies with this scope; hand its buffers back.
            MLX.Memory.clearCache()
            throw MLXLanguageModelError.loadSuperseded
        }

        let tokenizer = context.tokenizer
        let extraTokenIDs = context.configuration.extraEOSTokens.compactMap { tokenizer.convertTokenToId($0) }
        loaded = LoadedModel(
            directoryPath: directory.path,
            context: context,
            stopTokens: StopTokens(
                configured: context.configuration.eosTokenIds,
                eosTokenID: tokenizer.eosTokenId,
                unknownTokenID: tokenizer.unknownTokenId,
                extraTokenIDs: extraTokenIDs
            ),
            generationConfig: generationConfig
        )
        lastDirectory = directory
        standbyTokenizer = nil
    }

    /// Stops every generation, frees the weights, the tokenizer and the chat template, and
    /// empties MLX's buffer cache.
    ///
    /// Generations that are running or waiting end with `.finished(.cancelled)`; the one that is
    /// running stops within one token. A load in progress is abandoned and throws
    /// ``MLXLanguageModelError/loadSuperseded`` to its caller. The model files stay on disk.
    public nonisolated func unload() async {
        generations.cancelAll()
        await releaseModel()
    }

    private func releaseModel() {
        pendingLoad = nil
        standbyTokenizer = nil
        guard loaded != nil else {
            // Nothing was loaded, so MLX may never have been initialised: leave it alone.
            return
        }
        loaded = nil
        MLX.Memory.clearCache()
    }

    /// `true` while a model is loaded.
    public var isLoaded: Bool {
        loaded != nil
    }

    // MARK: - Tokens

    /// The number of tokens `text` encodes to, without special tokens.
    ///
    /// While a model is loaded this is the count of its tokenizer. After `unload()` the tokenizer
    /// alone is loaded again from the last directory, on first use, so counts stay exact between
    /// an idle unload and the next load. Before the first successful load there is no tokenizer:
    /// the result is then the number of UTF-8 bytes of `text`, which no byte-level tokenizer can
    /// exceed. It is an upper bound to budget with, not a count.
    public func countTokens(_ text: String) async -> Int {
        guard !text.isEmpty else { return 0 }
        guard let tokenizer = await countingTokenizer() else {
            return text.utf8.count
        }
        return tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    private func countingTokenizer() async -> (any MLXLMCommon.Tokenizer)? {
        if let loaded {
            return loaded.context.tokenizer
        }
        if standbyTokenizer == nil, let directory = lastDirectory {
            standbyTokenizer = Task.detached {
                try? await LocalTokenizerLoader().load(from: directory)
            }
        }
        return await standbyTokenizer?.value
    }

    // MARK: - Generation

    /// Generates a reply to `request.messages`.
    ///
    /// The messages are rendered with the chat template of the asset. Thinking mode is requested
    /// from the template through its `enable_thinking` variable and is off unless
    /// `request.options.thinking` is `true`; whatever the model does, `<think>` blocks are removed
    /// from the text. Sampling follows ``SamplingPlan``. The reply never takes the prompt plus the
    /// generated tokens past `descriptor.contextWindow`: a prompt that leaves no room throws
    /// ``MLXLanguageModelError/promptTooLong(promptTokens:contextWindow:)``, and a reply that
    /// reaches the edge of the window ends with `.finished(.maxTokens)`.
    ///
    /// `.usage` reports the tokens of the rendered prompt and the tokens the model produced,
    /// those inside `<think>` blocks included and the end-of-turn token excluded.
    public nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        let cancellation = generations.register()
        let task = Task { [generations] in
            await self.run(request, cancellation: cancellation, continuation: continuation)
            generations.unregister(cancellation)
        }
        cancellation.attach(task)
        continuation.onTermination = { _ in
            cancellation.cancel()
        }
        return stream
    }

    /// Stops every generation that is running or waiting, without unloading the model.
    ///
    /// Their streams stay open long enough to end with `.usage` and `.finished(.cancelled)`.
    /// This is the way to stop a generation and still learn how many tokens it produced: a
    /// consumer that cancels its own task loses the stream with it.
    public nonisolated func cancelGenerations() {
        generations.cancelAll()
    }

    /// The numbers of one finished generation.
    private struct Completion {
        let promptTokens: Int
        let generatedTokens: Int
        let stopReason: StopReason
    }

    private func run(
        _ request: GenerationRequest,
        cancellation: GenerationCancellation,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) {
        do {
            let completion = try generateSynchronously(request, cancellation: cancellation) { text in
                if case .terminated = continuation.yield(.delta(text)) {
                    return false
                }
                return true
            }
            continuation.yield(.usage(prompt: completion.promptTokens, generated: completion.generatedTokens))
            continuation.yield(.finished(completion.stopReason))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Runs one generation from prompt to last token on the runtime's thread.
    private func generateSynchronously(
        _ request: GenerationRequest,
        cancellation: GenerationCancellation,
        emit: (String) -> Bool
    ) throws -> Completion {
        if cancellation.isCancelled {
            return Completion(promptTokens: 0, generatedTokens: 0, stopReason: .cancelled)
        }
        guard let loaded else {
            throw MLXLanguageModelError.notLoaded
        }
        guard !request.messages.isEmpty else {
            throw MLXLanguageModelError.emptyRequest
        }

        let tokenizer = loaded.context.tokenizer
        let promptTokens: [Int]
        do {
            promptTokens = try tokenizer.applyChatTemplate(
                messages: ChatPrompt.templateMessages(request.messages),
                tools: nil,
                additionalContext: ChatPrompt.templateContext(thinking: request.options.thinking)
            )
        } catch {
            throw MLXLanguageModelError.chatTemplateFailed(Self.describe(error))
        }

        let contextWindow = descriptor.contextWindow
        guard promptTokens.count < contextWindow else {
            throw MLXLanguageModelError.promptTooLong(promptTokens: promptTokens.count, contextWindow: contextWindow)
        }

        let plan = SamplingPlan(options: request.options, generationConfig: loaded.generationConfig)
        let budget = plan.tokenBudget(promptTokens: promptTokens.count, contextWindow: contextWindow)
        guard budget > 0 else {
            return Completion(promptTokens: promptTokens.count, generatedTokens: 0, stopReason: .maxTokens)
        }

        var parameters = GenerateParameters(
            maxTokens: budget,
            temperature: Float(plan.temperature),
            topP: Float(plan.topP),
            topK: plan.topK,
            repetitionPenalty: plan.repetitionPenalty.map { Float($0) },
            seed: plan.seed
        )
        parameters.prefill.stepSize = tuning.prefillStepSize

        // Creating the iterator evaluates the prompt. mlx-swift-lm checks the task for
        // cancellation between prefill chunks and throws `CancellationError`.
        var iterator: TokenIterator
        do {
            iterator = try autoreleasepool {
                try TokenIterator(
                    input: LMInput(tokens: MLXArray(promptTokens)),
                    model: loaded.context.model,
                    parameters: parameters
                )
            }
        } catch is CancellationError {
            MLX.Stream.defaultStream.synchronize()
            return Completion(promptTokens: promptTokens.count, generatedTokens: 0, stopReason: .cancelled)
        } catch {
            throw MLXLanguageModelError.generationFailed(Self.describe(error))
        }

        var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        let stopTokens = loaded.stopTokens
        let outcome = GenerationLoop.run(
            tokenBudget: budget,
            nextToken: {
                // One forward pass leaves hundreds of autoreleased objects; drain them per token.
                autoreleasepool { iterator.next() }
            },
            isStopToken: { stopTokens.contains($0) },
            detokenize: { token in
                autoreleasepool {
                    detokenizer.append(token: token)
                    return detokenizer.next()
                }
            },
            isCancelled: { cancellation.isCancelled || Task.isCancelled },
            emit: emit
        )

        // The iterator computes one token ahead with `asyncEval`. Wait for that work so nothing
        // is still evaluating when the model is released or the app goes to the background.
        MLX.Stream.defaultStream.synchronize()

        return Completion(
            promptTokens: promptTokens.count,
            generatedTokens: outcome.generatedTokens,
            stopReason: outcome.stopReason
        )
    }

    // MARK: - Support

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Turns core's chat messages into what a chat template consumes.
enum ChatPrompt {
    /// The messages as the role/content dictionaries every Hugging Face chat template expects.
    static func templateMessages(_ messages: [ChatMessage]) -> [[String: any Sendable]] {
        messages.map { ["role": $0.role.rawValue, "content": $0.content] }
    }

    /// The extra template variables: `enable_thinking` switches Qwen3's thinking mode. With
    /// `false` the template closes an empty `<think>` block in the prompt, so the model answers
    /// directly. Templates that do not know the variable ignore it.
    static func templateContext(thinking: Bool) -> [String: any Sendable] {
        ["enable_thinking": thinking]
    }
}
