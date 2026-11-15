import Foundation

/// Which other languages feed the low-weight `localizedAlt` field (specification section 5, rule 3).
public enum SecondaryLanguages: Sendable, Hashable {
    /// The other entries of `Locale.preferredLanguages`. The default.
    case preferredLanguages
    /// Every language an item is localized in.
    case all
    /// No secondary language. The base surface is still indexed when a localization shadows it.
    case none
    /// An explicit list of BCP 47 tags, for hosts and tests that need a fixed set.
    case explicit([String])
}

/// The capability gate of the cross-encoder stage (specification section 7.4).
public enum RerankingMode: Sendable, Hashable {
    /// Run a one-time calibration on first use and enable only inside its thresholds.
    case auto
    /// Force the stage, for QA builds.
    case on
    /// Never load the model.
    case off
}

/// The bounded-work limits of specification section 10.
public struct SearchLimits: Sendable, Hashable {
    /// At most this many lexical candidates are scored.
    public var lexicalCandidates: Int
    /// Fuzzy correction candidates per token.
    public var fuzzyCandidatesPerToken: Int
    /// Vocabulary terms the final token may expand to.
    public var prefixExpansions: Int
    /// Neighbours the semantic channel brings into fusion. A query with hard constraints asks
    /// the index for four times as many (200 at most), because the constraints are applied to
    /// what comes back; the list fused is still this long at most.
    public var semanticNeighbours: Int
    /// Entries each channel may bring into fusion (3 channels x 200 = 600 entries).
    public var fusionEntriesPerChannel: Int
    /// Hits kept for paging.
    public var retainedHits: Int

    public init(
        lexicalCandidates: Int = 2_000,
        fuzzyCandidatesPerToken: Int = 8,
        prefixExpansions: Int = 32,
        semanticNeighbours: Int = 50,
        fusionEntriesPerChannel: Int = 200,
        retainedHits: Int = 200
    ) {
        self.lexicalCandidates = max(1, lexicalCandidates)
        self.fuzzyCandidatesPerToken = max(0, fuzzyCandidatesPerToken)
        self.prefixExpansions = max(1, prefixExpansions)
        self.semanticNeighbours = max(1, semanticNeighbours)
        self.fusionEntriesPerChannel = max(1, fusionEntriesPerChannel)
        self.retainedHits = max(1, retainedHits)
    }

    public static let `default` = SearchLimits()
}

/// A condition the engine noticed and handled. Hosts and tests observe them through
/// ``SearchEngineConfiguration/diagnostics``; every one is also written to the unified log.
public enum SearchDiagnostic: Sendable, Hashable {
    /// A document's stored kind is unknown to the running build; the document was dropped.
    case unknownKind(id: SearchableID, rawKind: String)
    /// A stored filter record is unknown to the running build; the record was ignored.
    case unknownFilter(id: SearchableID, record: FilterRecord)
    /// Programmer error: an item's `Filter` type differs from the schema's; its filters were dropped.
    case filterTypeMismatch(id: SearchableID, itemFilter: String, schemaFilter: String)
    /// Programmer error: two items of one context share an id; the later one replaced the earlier.
    case duplicateID(id: SearchableID)
    /// A localization key resolved to nothing; the field indexed nothing.
    case unresolvedLocalizationKey(key: String, table: String?, language: String)
    /// A persisted index was discarded and will be rebuilt.
    case indexDiscarded(reason: String)
    /// A channel was skipped for one snapshot.
    case channelDegraded(channel: SearchChannel, reason: String)
    /// A channel was disabled for the session.
    case channelDisabled(channel: SearchChannel, reason: String)
    /// A signal provider threw and was treated as absent for the query.
    case signalProviderFailed(signal: String)
    /// The model wrote a citation whose id is not among the sources; it was dropped.
    case unknownCitation(id: String)
    /// A database source could not be read.
    case databaseFailure(table: String, message: String)
    /// The index could not be persisted; it stays in memory.
    case persistenceFailed(message: String)
    /// A rebuild was asked for but the service holds no source to rebuild from.
    case rebuildSkipped(reason: String)
    /// A table kept changing while it was read page by page. Its changes were applied after the
    /// read, but a row moved across a page boundary by a concurrent delete may have been
    /// missed: call `refresh()` once the writes settle.
    case sourceChangedWhileReading(table: String)

    /// `true` for the conditions the specification calls programmer errors (debug assertions).
    public var isProgrammerError: Bool {
        switch self {
        case .filterTypeMismatch, .duplicateID: return true
        default: return false
        }
    }
}

/// Engine-wide settings (specification sections 5, 7.4 and 10).
public struct SearchEngineConfiguration: Sendable {
    /// The active locale; resolved to a BCP 47 tag once per index generation.
    public var locale: Locale
    /// Rebuild under `Locale.current` when the system posts
    /// `NSLocale.currentLocaleDidChangeNotification`. A context with its own locale never follows.
    public var followsSystemLocale: Bool
    public var secondaryLanguages: SecondaryLanguages
    /// Source of the user's preferred languages; injectable so tests stay deterministic.
    public var preferredLanguages: @Sendable () -> [String]

    public var reranking: RerankingMode

    /// Debounce before the lexical phase, in seconds.
    public var lexicalDebounce: TimeInterval
    /// Typing pause before the semantic phase, in seconds, measured from the keystroke.
    public var semanticDebounce: TimeInterval
    /// Hard cap on the semantic phase; past it the channel is skipped for the snapshot.
    public var semanticHardCap: TimeInterval
    /// Hard cap on the rerank stage; past it the fused order stands.
    public var rerankHardCap: TimeInterval
    /// Consecutive breaches after which a channel is disabled for the session.
    public var breachesBeforeDisable: Int
    /// Idle time after which the embedding model and the reranker unload.
    public var modelIdleUnload: TimeInterval

    /// Queries shorter than this return an empty final snapshot. A query that carries tokens or
    /// filters, or a character in a script without word spacing, is never too short.
    public var minimumQueryLength: Int
    /// Queries shorter than this skip the semantic and rerank phases.
    public var minimumSemanticQueryLength: Int
    /// The longest token must reach this length before the fuzzy channel runs.
    public var minimumFuzzyTokenLength: Int

    public var limits: SearchLimits
    /// `.automatic` contexts scan up to this many documents and index above.
    public var scanThreshold: Int
    /// Rows per page when reading database sources.
    public var databasePageSize: Int

    /// Lets `NLLanguageRecognizer` hint the normalization locale for queries of 8 or more
    /// characters. Off by default: recognition costs more than the whole tokenization budget.
    public var queryLanguageHinting: Bool

    /// Receives every ``SearchDiagnostic``.
    public var diagnostics: (@Sendable (SearchDiagnostic) -> Void)?
    /// Programmer errors trap in debug builds. Tests that exercise them turn this off and
    /// observe the diagnostic instead.
    public var assertsOnProgrammerError: Bool
    /// The clock freshness is computed against.
    public var now: @Sendable () -> Date

    public init(
        locale: Locale = .current,
        followsSystemLocale: Bool = true,
        secondaryLanguages: SecondaryLanguages = .preferredLanguages,
        preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
        reranking: RerankingMode = .auto,
        lexicalDebounce: TimeInterval = 0.120,
        semanticDebounce: TimeInterval = 0.300,
        semanticHardCap: TimeInterval = 0.300,
        rerankHardCap: TimeInterval = 0.400,
        breachesBeforeDisable: Int = 3,
        modelIdleUnload: TimeInterval = 60,
        minimumQueryLength: Int = 2,
        minimumSemanticQueryLength: Int = 3,
        minimumFuzzyTokenLength: Int = 3,
        limits: SearchLimits = .default,
        scanThreshold: Int = 500,
        databasePageSize: Int = 500,
        queryLanguageHinting: Bool = false,
        diagnostics: (@Sendable (SearchDiagnostic) -> Void)? = nil,
        assertsOnProgrammerError: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locale = locale
        self.followsSystemLocale = followsSystemLocale
        self.secondaryLanguages = secondaryLanguages
        self.preferredLanguages = preferredLanguages
        self.reranking = reranking
        self.lexicalDebounce = lexicalDebounce
        self.semanticDebounce = semanticDebounce
        self.semanticHardCap = semanticHardCap
        self.rerankHardCap = rerankHardCap
        self.breachesBeforeDisable = max(1, breachesBeforeDisable)
        self.modelIdleUnload = modelIdleUnload
        self.minimumQueryLength = max(1, minimumQueryLength)
        self.minimumSemanticQueryLength = max(1, minimumSemanticQueryLength)
        self.minimumFuzzyTokenLength = max(1, minimumFuzzyTokenLength)
        self.limits = limits
        self.scanThreshold = max(0, scanThreshold)
        self.databasePageSize = max(1, databasePageSize)
        self.queryLanguageHinting = queryLanguageHinting
        self.diagnostics = diagnostics
        self.assertsOnProgrammerError = assertsOnProgrammerError
        self.now = now
    }

    public static let `default` = SearchEngineConfiguration()
}
