import Foundation

// Boundaries of specification section 14. Core knows neither ZTronAssetKit nor MLX: both arrive
// as existentials through the `ZTronSearch` facade.

// MARK: - Model assets

public struct ModelFile: Hashable, Sendable, Codable {
    public let name: String
    public let byteCount: Int64
    /// Lowercase hexadecimal SHA-256 of the file.
    public let sha256: String

    public init(name: String, byteCount: Int64, sha256: String) {
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// The files of one model at one pinned revision.
///
/// The same `id` at another `revision` is another asset, fetched and verified again.
public struct ModelAsset: Hashable, Sendable, Codable {
    /// e.g. `"qwen3-1.7b-4bit"`.
    public let id: String
    /// Pinned commit or tag, never `"main"`.
    public let revision: String
    /// Name, byte count, SHA-256.
    public let files: [ModelFile]

    public init(id: String, revision: String, files: [ModelFile]) {
        self.id = id
        self.revision = revision
        self.files = files
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }
}

public enum ModelAssetError: Error, Sendable, Hashable {
    case offline
    case checksum
    case diskFull
    case policy
}

public enum ModelAssetAvailability: Sendable, Hashable {
    /// Directory holding every file, checksums verified.
    case available(URL)
    case downloading(bytes: Int64, of: Int64)
    case missing
    case failed(ModelAssetError)
}

public enum DownloadPolicy: Sendable, Hashable {
    case wifiOnly
    case allowCellular
    /// The host pre-bundles the files; nothing is ever downloaded.
    case never
}

/// The boundary entity: implemented by the host over ZTronAssetKit, injected through `ZTronSearch`.
public protocol ModelAssetProviding: Sendable {
    func availability(of asset: ModelAsset) async -> ModelAssetAvailability
    /// Resumable; verifies SHA-256 per file; ends with `.available`.
    func fetch(_ asset: ModelAsset, policy: DownloadPolicy) -> AsyncThrowingStream<ModelAssetAvailability, Error>
    func evict(_ asset: ModelAsset) async throws
}

// MARK: - Language model runtime

public struct LanguageModelDescriptor: Sendable, Hashable {
    public let asset: ModelAsset
    /// Tokens the runtime accepts per request.
    public let contextWindow: Int
    public let minimumPhysicalMemory: Int64
    public let minimumOS: OperatingSystemVersion

    public init(asset: ModelAsset, contextWindow: Int, minimumPhysicalMemory: Int64, minimumOS: OperatingSystemVersion) {
        self.asset = asset
        self.contextWindow = contextWindow
        self.minimumPhysicalMemory = minimumPhysicalMemory
        self.minimumOS = minimumOS
    }

    public static func == (lhs: LanguageModelDescriptor, rhs: LanguageModelDescriptor) -> Bool {
        lhs.asset == rhs.asset
            && lhs.contextWindow == rhs.contextWindow
            && lhs.minimumPhysicalMemory == rhs.minimumPhysicalMemory
            && lhs.minimumOS.majorVersion == rhs.minimumOS.majorVersion
            && lhs.minimumOS.minorVersion == rhs.minimumOS.minorVersion
            && lhs.minimumOS.patchVersion == rhs.minimumOS.patchVersion
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(asset)
        hasher.combine(contextWindow)
        hasher.combine(minimumPhysicalMemory)
        hasher.combine(minimumOS.majorVersion)
        hasher.combine(minimumOS.minorVersion)
        hasher.combine(minimumOS.patchVersion)
    }
}

public struct ChatMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Sampling settings of one generation (specification section 14.2).
///
/// The defaults are temperature 0.7 and top-p 0.8, and the asset's `generation_config.json`
/// wins over them when present. A value the caller sets wins over both, which is why the two
/// are optional: `nil` says "not set", a number says "use exactly this".
public struct GenerationOptions: Sendable, Hashable {
    /// Sampling temperature; `nil` leaves it to the asset, then to ``defaultTemperature``.
    public var temperature: Double?
    /// Nucleus sampling; `nil` leaves it to the asset, then to ``defaultTopP``.
    public var topP: Double?
    public var maxNewTokens: Int
    /// Fixed in tests; `nil` = the runtime picks.
    public var seed: UInt64?
    /// Thinking mode; off by default. Any `<think>` block is stripped before `.delta` regardless.
    public var thinking: Bool

    public static let defaultTemperature = 0.7
    public static let defaultTopP = 0.8

    public init(temperature: Double? = nil, topP: Double? = nil, maxNewTokens: Int = 512, seed: UInt64? = nil, thinking: Bool = false) {
        self.temperature = temperature
        self.topP = topP
        self.maxNewTokens = maxNewTokens
        self.seed = seed
        self.thinking = thinking
    }

    public static let `default` = GenerationOptions()
}

public struct GenerationRequest: Sendable {
    public var messages: [ChatMessage]
    public var options: GenerationOptions

    public init(messages: [ChatMessage], options: GenerationOptions = .default) {
        self.messages = messages
        self.options = options
    }
}

public enum StopReason: Sendable, Hashable {
    /// The model ended its turn.
    case endOfTurn
    /// `maxNewTokens` was reached.
    case maxTokens
    /// The consuming task was cancelled.
    case cancelled
}

public enum GenerationEvent: Sendable, Hashable {
    case delta(String)
    case usage(prompt: Int, generated: Int)
    case finished(StopReason)
}

/// Implemented by the runtime package; core only streams through it.
///
/// `generate` streams, honours task cancellation within one decoded token, and never blocks the
/// cooperative pool.
public protocol LocalLanguageModel: Sendable {
    var descriptor: LanguageModelDescriptor { get }
    func load(from directory: URL) async throws
    func unload() async
    func countTokens(_ text: String) async -> Int
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}

// MARK: - Chat

public struct ChatSessionID: Hashable, Sendable, Identifiable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// What a session's answers are grounded in.
public enum ChatGrounding<Kind: SearchItemKind>: Sendable, Hashable {
    /// The indexed corpus: the top `topK` hits for each message, restricted to `kinds`.
    case corpus(topK: Int, kinds: Set<Kind>?)
    /// No retrieval; the model answers from the conversation alone.
    case none
}

public enum UnavailableReason: Sendable, Hashable {
    /// The device fails the gate (OS, memory or calibration), or a boundary is absent.
    case device
    /// `ChatConfiguration.availability` is `.off`.
    case disabled
    /// Less than twice `asset.totalBytes` is free.
    case insufficientDisk
    /// The files are missing and the download policy forbids fetching them.
    case downloadNotAllowed
    /// Fetching failed; a retry is allowed.
    case assetFailed(ModelAssetError)
    /// Loading the weights failed; a retry is allowed.
    case loadFailed

    /// `true` when `prepare()` may succeed if called again.
    public var isRetryable: Bool {
        switch self {
        case .assetFailed, .loadFailed, .insufficientDisk, .downloadNotAllowed: return true
        case .device, .disabled: return false
        }
    }
}

public enum ChatReadiness: Sendable, Hashable {
    case checking
    case downloading(bytes: Int64, of: Int64)
    case loading
    case ready
    case unavailable(UnavailableReason)
}

public struct ChatUsage: Sendable, Hashable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let stopReason: StopReason

    public init(promptTokens: Int, generatedTokens: Int, stopReason: StopReason) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.stopReason = stopReason
    }
}

public enum ChatEvent<Kind: SearchItemKind>: Sendable {
    /// Retrieved before generation; kind-aware, so rows switch on kind.
    case sources([SearchHit<Kind>])
    case delta(String)
    /// The model wrote `[kind:id]`; emitted only when the id is among the sources.
    case citation(SearchableID)
    case finished(ChatUsage)
}

/// The device gate override (specification section 14.4).
public enum ChatAvailability: Sendable, Hashable {
    /// OS, memory, disk and calibration must all hold.
    case auto
    /// Skip the gate, for QA builds.
    case on
    /// Chat is unavailable.
    case off
}

/// The facts the device gate reads. Injectable so tests can describe an iPhone 6s.
public struct ChatDeviceProfile: Sendable, Hashable {
    public var operatingSystem: OperatingSystemVersion
    public var physicalMemory: Int64
    /// Free bytes on the volume that will hold the model; `nil` = unknown, the disk check passes.
    public var freeDiskBytes: Int64?
    /// Changes when the app or the OS updates; a persisted calibration verdict is keyed by it.
    public var buildFingerprint: String

    public init(operatingSystem: OperatingSystemVersion, physicalMemory: Int64, freeDiskBytes: Int64?, buildFingerprint: String) {
        self.operatingSystem = operatingSystem
        self.physicalMemory = physicalMemory
        self.freeDiskBytes = freeDiskBytes
        self.buildFingerprint = buildFingerprint
    }

    public static func == (lhs: ChatDeviceProfile, rhs: ChatDeviceProfile) -> Bool {
        lhs.operatingSystem.majorVersion == rhs.operatingSystem.majorVersion
            && lhs.operatingSystem.minorVersion == rhs.operatingSystem.minorVersion
            && lhs.operatingSystem.patchVersion == rhs.operatingSystem.patchVersion
            && lhs.physicalMemory == rhs.physicalMemory
            && lhs.freeDiskBytes == rhs.freeDiskBytes
            && lhs.buildFingerprint == rhs.buildFingerprint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(operatingSystem.majorVersion)
        hasher.combine(operatingSystem.minorVersion)
        hasher.combine(operatingSystem.patchVersion)
        hasher.combine(physicalMemory)
        hasher.combine(freeDiskBytes)
        hasher.combine(buildFingerprint)
    }

    /// The reference device of the specification: iPhone 6s, A9, 2 GB, iOS 15.8.
    public static let iPhone6s = ChatDeviceProfile(
        operatingSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 8, patchVersion: 0),
        physicalMemory: 2 * 1024 * 1024 * 1024,
        freeDiskBytes: 8 * 1024 * 1024 * 1024,
        buildFingerprint: "iphone6s-15.8"
    )
}

/// Stores the calibration verdict. Injectable; the default keeps it in `UserDefaults`.
public protocol ChatCalibrationStoring: Sendable {
    func verdict(forKey key: String) async -> Bool?
    func setVerdict(_ verdict: Bool, forKey key: String) async
}

public struct ChatConfiguration: Sendable {
    public var availability: ChatAvailability
    /// Working window the chat service fits a request into; the model's own window when smaller.
    public var contextWindow: Int
    public var options: GenerationOptions
    /// Tokens kept free between the prompt and the reply.
    public var safetyMargin: Int
    /// Most tokens of one rendered source.
    public var maximumSourceTokens: Int
    /// Idle time after which the model unloads; a session keeps its history across unloads.
    public var idleUnload: TimeInterval
    /// Calibration thresholds: time to first token and decode rate.
    public var maximumTimeToFirstToken: TimeInterval
    public var minimumTokensPerSecond: Double
    /// The device the gate judges; `nil` = the device the process runs on.
    public var device: ChatDeviceProfile?
    public var calibrationStore: (any ChatCalibrationStoring)?
    /// Receives chat diagnostics (unknown citations).
    public var diagnostics: (@Sendable (SearchDiagnostic) -> Void)?

    public init(
        availability: ChatAvailability = .auto,
        contextWindow: Int = 4_096,
        options: GenerationOptions = .default,
        safetyMargin: Int = 64,
        maximumSourceTokens: Int = 80,
        idleUnload: TimeInterval = 120,
        maximumTimeToFirstToken: TimeInterval = 3,
        minimumTokensPerSecond: Double = 8,
        device: ChatDeviceProfile? = nil,
        calibrationStore: (any ChatCalibrationStoring)? = nil,
        diagnostics: (@Sendable (SearchDiagnostic) -> Void)? = nil
    ) {
        self.availability = availability
        self.contextWindow = contextWindow
        self.options = options
        self.safetyMargin = safetyMargin
        self.maximumSourceTokens = maximumSourceTokens
        self.idleUnload = idleUnload
        self.maximumTimeToFirstToken = maximumTimeToFirstToken
        self.minimumTokensPerSecond = minimumTokensPerSecond
        self.device = device
        self.calibrationStore = calibrationStore
        self.diagnostics = diagnostics
    }

    public static let `default` = ChatConfiguration()
}
