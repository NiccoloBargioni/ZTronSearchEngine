import Foundation
import os

/// Routes ``SearchDiagnostic`` values to the unified log and to the host's sink.
struct DiagnosticReporter: Sendable {
    private static let logger = Logger(subsystem: "com.ztron.searchengine", category: "engine")

    let sink: (@Sendable (SearchDiagnostic) -> Void)?
    let assertsOnProgrammerError: Bool

    init(sink: (@Sendable (SearchDiagnostic) -> Void)? = nil, assertsOnProgrammerError: Bool = true) {
        self.sink = sink
        self.assertsOnProgrammerError = assertsOnProgrammerError
    }

    init(_ configuration: SearchEngineConfiguration) {
        self.init(sink: configuration.diagnostics, assertsOnProgrammerError: configuration.assertsOnProgrammerError)
    }

    func report(_ diagnostic: SearchDiagnostic) {
        let message = Self.describe(diagnostic)
        if diagnostic.isProgrammerError {
            Self.logger.error("\(message, privacy: .public)")
        } else {
            Self.logger.notice("\(message, privacy: .public)")
        }
        sink?(diagnostic)
        if diagnostic.isProgrammerError && assertsOnProgrammerError {
            assertionFailure(message)
        }
    }

    /// A debug-only note: logged in debug builds, always forwarded to the sink.
    func debug(_ diagnostic: SearchDiagnostic) {
        #if DEBUG
        let message = Self.describe(diagnostic)
        Self.logger.debug("\(message, privacy: .public)")
        #endif
        sink?(diagnostic)
    }

    static func describe(_ diagnostic: SearchDiagnostic) -> String {
        switch diagnostic {
        case .unknownKind(let id, let rawKind):
            return "Dropped document \(id.rawValue): kind '\(rawKind)' is unknown to this build."
        case .unknownFilter(let id, let record):
            return "Ignored filter \(record.key)=\(record.value) on \(id.rawValue): unknown to this build."
        case .filterTypeMismatch(let id, let itemFilter, let schemaFilter):
            return "Item \(id.rawValue) declares filters of type \(itemFilter); the schema expects \(schemaFilter). Its filters were dropped."
        case .duplicateID(let id):
            return "SearchableID \(id.rawValue) is not unique inside its context."
        case .unresolvedLocalizationKey(let key, let table, let language):
            return "Localization key '\(key)' (table \(table ?? "nil"), language \(language)) resolved to nothing; the field indexes nothing."
        case .indexDiscarded(let reason):
            return "Persisted index discarded: \(reason)."
        case .channelDegraded(let channel, let reason):
            return "Channel \(channel.rawValue) skipped for this snapshot: \(reason)."
        case .channelDisabled(let channel, let reason):
            return "Channel \(channel.rawValue) disabled for the session: \(reason)."
        case .signalProviderFailed(let signal):
            return "Signal provider '\(signal)' threw; treated as absent for this query."
        case .unknownCitation(let id):
            return "Dropped citation '\(id)': not among the sources."
        case .databaseFailure(let table, let message):
            return "Database source '\(table)' failed: \(message)."
        case .persistenceFailed(let message):
            return "The index could not be persisted: \(message)."
        case .rebuildSkipped(let reason):
            return "Rebuild skipped: \(reason)."
        case .sourceChangedWhileReading(let table):
            return "Table '\(table)' kept changing while it was read; call refresh() once the writes settle."
        }
    }
}
