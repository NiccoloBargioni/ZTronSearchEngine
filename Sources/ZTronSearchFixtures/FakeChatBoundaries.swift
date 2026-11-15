import Foundation
import ZTronSearchEngine

/// A fake runtime with a scripted token stream, delays and failures
/// (specification section 16, "Local chat").
public actor FakeLanguageModel: LocalLanguageModel {
    public nonisolated let descriptor: LanguageModelDescriptor

    public struct Failure: Error, Sendable, Hashable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    private var reply: [String]
    private var replies: [[String]] = []
    private var tokenDelay: UInt64 = 0
    private var firstTokenDelay: UInt64 = 0
    private var loadDelay: UInt64 = 0
    private var failsLoad = false
    private var failsAfterTokens: Int?

    public private(set) var isLoaded = false
    public private(set) var loadCalls = 0
    public private(set) var unloadCalls = 0
    public private(set) var generateCalls = 0
    public private(set) var cancelledGenerations = 0
    public private(set) var requests: [GenerationRequest] = []
    public private(set) var loadedDirectories: [URL] = []
    private var active = 0
    public private(set) var maximumConcurrentGenerations = 0

    /// - Parameter contextWindow: tokens the fake accepts per request; tokens are whitespace-separated words.
    public init(
        asset: ModelAsset = FakeModelAssetProvider.sampleAsset,
        contextWindow: Int = 4_096,
        minimumPhysicalMemory: Int64 = 6 * 1024 * 1024 * 1024,
        minimumOS: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0),
        reply: [String] = ["Hello", " there", "."]
    ) {
        descriptor = LanguageModelDescriptor(
            asset: asset, contextWindow: contextWindow, minimumPhysicalMemory: minimumPhysicalMemory, minimumOS: minimumOS
        )
        self.reply = reply
    }

    // MARK: Scripting

    /// The deltas every generation produces, unless a queued reply takes precedence.
    public func setReply(_ deltas: [String]) { reply = deltas }

    /// Queues one reply per upcoming generation, in order.
    public func queueReplies(_ deltas: [[String]]) { replies.append(contentsOf: deltas) }

    public func setTokenDelay(seconds: Double) { tokenDelay = UInt64(seconds * 1_000_000_000) }
    public func setFirstTokenDelay(seconds: Double) { firstTokenDelay = UInt64(seconds * 1_000_000_000) }
    public func setLoadDelay(seconds: Double) { loadDelay = UInt64(seconds * 1_000_000_000) }
    public func setFailsLoad(_ fails: Bool) { failsLoad = fails }
    /// A generation throws after this many deltas. `nil` = never.
    public func setFailsAfterTokens(_ count: Int?) { failsAfterTokens = count }
    public func resetRequests() { requests = [] }

    // MARK: Boundary

    public func load(from directory: URL) async throws {
        loadCalls += 1
        if loadDelay > 0 { try await Task.sleep(nanoseconds: loadDelay) }
        if failsLoad { throw Failure("load failed") }
        loadedDirectories.append(directory)
        isLoaded = true
    }

    public func unload() async {
        unloadCalls += 1
        isLoaded = false
    }

    /// Whitespace-separated words: deterministic and easy to reason about in budget tests.
    public func countTokens(_ text: String) async -> Int {
        Self.tokens(in: text)
    }

    public nonisolated static func tokens(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public nonisolated func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        let task = Task {
            let script = await self.begin(request)
            var generated = 0
            do {
                guard script.isLoaded else { throw Failure("generate called before load") }
                if script.firstTokenDelay > 0 { try await Task.sleep(nanoseconds: script.firstTokenDelay) }
                var stop = StopReason.endOfTurn
                for delta in script.deltas {
                    try Task.checkCancellation()
                    if let limit = script.failsAfterTokens, generated >= limit { throw Failure("generation failed") }
                    if generated >= request.options.maxNewTokens {
                        stop = .maxTokens
                        break
                    }
                    continuation.yield(.delta(delta))
                    generated += 1
                    if script.tokenDelay > 0 { try await Task.sleep(nanoseconds: script.tokenDelay) }
                }
                continuation.yield(.usage(prompt: script.promptTokens, generated: generated))
                continuation.yield(.finished(stop))
                await self.end(cancelled: false)
                continuation.finish()
            } catch is CancellationError {
                continuation.yield(.usage(prompt: script.promptTokens, generated: generated))
                continuation.yield(.finished(.cancelled))
                await self.end(cancelled: true)
                continuation.finish(throwing: CancellationError())
            } catch {
                await self.end(cancelled: false)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private struct Script: Sendable {
        let deltas: [String]
        let tokenDelay: UInt64
        let firstTokenDelay: UInt64
        let failsAfterTokens: Int?
        let promptTokens: Int
        let isLoaded: Bool
    }

    private func begin(_ request: GenerationRequest) -> Script {
        generateCalls += 1
        requests.append(request)
        active += 1
        maximumConcurrentGenerations = max(maximumConcurrentGenerations, active)
        let deltas = replies.isEmpty ? reply : replies.removeFirst()
        return Script(
            deltas: deltas, tokenDelay: tokenDelay, firstTokenDelay: firstTokenDelay, failsAfterTokens: failsAfterTokens,
            promptTokens: request.messages.reduce(0) { $0 + Self.tokens(in: $1.content) }, isLoaded: isLoaded
        )
    }

    private func end(cancelled: Bool) {
        active -= 1
        if cancelled { cancelledGenerations += 1 }
    }
}

/// A fake asset provider scripted as available, missing, downloading, checksum failure and
/// offline. It keeps what it has "downloaded", so a retry resumes instead of starting over.
public actor FakeModelAssetProvider: ModelAssetProviding {
    public static let sampleAsset = ModelAsset(
        id: "fake-llm-4bit",
        revision: "0123abcd",
        files: [
            ModelFile(name: "model.safetensors", byteCount: 900, sha256: String(repeating: "a", count: 64)),
            ModelFile(name: "tokenizer.json", byteCount: 80, sha256: String(repeating: "b", count: 64)),
            ModelFile(name: "config.json", byteCount: 20, sha256: String(repeating: "c", count: 64)),
        ]
    )

    public enum Step: Sendable, Hashable {
        /// Downloads and verifies this many more bytes.
        case progress(Int64)
        /// The fetch fails here. Verified bytes are kept; a checksum failure discards the
        /// mismatched file, i.e. the bytes of the last progress step.
        case fail(ModelAssetError)
        /// Suspends until the stream is cancelled: a download that never ends.
        case stall
    }

    public nonisolated let directory: URL
    private var available: Bool
    private var verifiedBytes: Int64 = 0
    private var lastProgress: Int64 = 0
    private var scripts: [[Step]] = []
    private var stepDelay: UInt64 = 0
    private var isFetching = false

    public private(set) var availabilityCalls = 0
    public private(set) var fetchCalls = 0
    public private(set) var evictCalls = 0
    public private(set) var cancelledFetches = 0
    public private(set) var policies: [DownloadPolicy] = []
    /// Bytes each fetch started from: a resumed fetch starts where the last one stopped.
    public private(set) var resumeOffsets: [Int64] = []

    public init(available: Bool = false, directory: URL = URL(fileURLWithPath: "/models/fake-llm-4bit", isDirectory: true)) {
        self.available = available
        self.directory = directory
    }

    // MARK: Scripting

    public func setAvailable(_ available: Bool) {
        self.available = available
        if available { verifiedBytes = Self.sampleAsset.totalBytes }
    }

    /// Queues the steps of upcoming fetches, one list per fetch. A fetch with no script downloads
    /// everything that is left in four steps.
    public func queueFetch(_ steps: [Step]) { scripts.append(steps) }

    public func setStepDelay(seconds: Double) { stepDelay = UInt64(seconds * 1_000_000_000) }

    public func downloadedBytes() -> Int64 { verifiedBytes }

    // MARK: Boundary

    public func availability(of asset: ModelAsset) async -> ModelAssetAvailability {
        availabilityCalls += 1
        if available { return .available(directory) }
        if isFetching { return .downloading(bytes: verifiedBytes, of: asset.totalBytes) }
        return .missing
    }

    public nonisolated func fetch(_ asset: ModelAsset, policy: DownloadPolicy) -> AsyncThrowingStream<ModelAssetAvailability, Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelAssetAvailability, Error>.makeStream()
        let task = Task {
            let script = await self.beginFetch(asset, policy: policy)
            do {
                for step in script.steps {
                    try Task.checkCancellation()
                    if script.delay > 0 { try await Task.sleep(nanoseconds: script.delay) }
                    switch step {
                    case .progress(let bytes):
                        let total = await self.advance(bytes, of: asset)
                        continuation.yield(.downloading(bytes: total, of: asset.totalBytes))
                    case .fail(let error):
                        await self.fail(error)
                        throw error
                    case .stall:
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                }
                let complete = await self.finishFetch(asset)
                if complete {
                    continuation.yield(.available(self.directory))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ModelAssetError.offline)
                }
            } catch is CancellationError {
                await self.endFetch(cancelled: true)
                continuation.finish(throwing: CancellationError())
            } catch {
                await self.endFetch(cancelled: false)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func evict(_ asset: ModelAsset) async throws {
        evictCalls += 1
        available = false
        verifiedBytes = 0
    }

    private func beginFetch(_ asset: ModelAsset, policy: DownloadPolicy) -> (steps: [Step], delay: UInt64) {
        fetchCalls += 1
        policies.append(policy)
        resumeOffsets.append(verifiedBytes)
        isFetching = true
        if available { return ([], 0) }
        if !scripts.isEmpty { return (scripts.removeFirst(), stepDelay) }
        let remaining = asset.totalBytes - verifiedBytes
        let chunk = max(1, remaining / 4)
        var steps: [Step] = []
        var left = remaining
        while left > 0 {
            steps.append(.progress(min(chunk, left)))
            left -= min(chunk, left)
        }
        return (steps, stepDelay)
    }

    private func advance(_ bytes: Int64, of asset: ModelAsset) -> Int64 {
        lastProgress = min(bytes, asset.totalBytes - verifiedBytes)
        verifiedBytes += lastProgress
        return verifiedBytes
    }

    private func fail(_ error: ModelAssetError) {
        // A mismatched file is deleted before failing; everything verified before it stays.
        if error == .checksum { verifiedBytes -= lastProgress }
        lastProgress = 0
    }

    private func finishFetch(_ asset: ModelAsset) -> Bool {
        isFetching = false
        if verifiedBytes >= asset.totalBytes { available = true }
        return available
    }

    private func endFetch(cancelled: Bool) {
        isFetching = false
        if cancelled { cancelledFetches += 1 }
    }
}

/// A calibration store that lives in memory.
public actor FakeCalibrationStore: ChatCalibrationStoring {
    private var verdicts: [String: Bool] = [:]
    public private(set) var writes = 0

    public init() {}

    public func verdict(forKey key: String) async -> Bool? { verdicts[key] }

    public func setVerdict(_ verdict: Bool, forKey key: String) async {
        verdicts[key] = verdict
        writes += 1
    }

    public func all() -> [String: Bool] { verdicts }
}
