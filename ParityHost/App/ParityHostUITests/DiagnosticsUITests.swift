import XCTest
import ZTronSearchEngineUIParity

/// A debugging aid, not part of the matrix: runs scripts without comparing and, at every
/// checkpoint, writes what both fields logged, their view hierarchies and layout, and a
/// picture of the stage. Use it to find out why a cell differs.
///
///     TEST_RUNNER_ZTRON_PARITY_DUMP=/tmp/dump TEST_RUNNER_ZTRON_PARITY_SCRIPTS=tap-select \
///       xcodebuild test-without-building ... -only-testing:ParityHostUITests/DiagnosticsUITests
final class DiagnosticsUITests: XCTestCase {
    @MainActor
    func testDumpScripts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let out = environment["ZTRON_PARITY_DUMP"] else { throw XCTSkip("set ZTRON_PARITY_DUMP to a directory") }
        let direction = ParityDirection(rawValue: environment["ZTRON_PARITY_DIRECTIONS"] ?? "ltr") ?? .ltr
        let input = ParityInput(rawValue: environment["ZTRON_PARITY_INPUTS"] ?? "software") ?? .software
        let scripts = (environment["ZTRON_PARITY_SCRIPTS"] ?? "").split(separator: ",").compactMap { ParityScript(rawValue: String($0)) }
        let remote = try ParityRemote(channelDirectory: URL(fileURLWithPath: out), language: direction.language, region: direction.region)
        var notes: [String] = []
        // ZTRON_PARITY_SYMBOLS=map,wrench: how the reference draws those token icons.
        for symbol in (environment["ZTRON_PARITY_SYMBOLS"] ?? "").split(separator: ",") {
            try remote.send(.dump(name: "symbol-lab-\(symbol)"), timeout: 300)
        }
        // ZTRON_PARITY_ACTIONS=blur-with-selected-token,...: elementary actions of the
        // behavior profile, dumped once they are done.
        let actions = (environment["ZTRON_PARITY_ACTIONS"] ?? "").split(separator: ",").compactMap { BehaviorProfile.action(named: String($0)) }
        for action in actions {
            for side in FieldSide.allCases {
                do {
                    try remote.send(.begin(action.setup))
                    for step in action.steps { try remote.perform(step, on: side, input: input) }
                    try remote.send(.dump(name: "action-\(action.name)-\(side.rawValue)"))
                } catch {
                    notes.append("\(action.name) on the \(side.rawValue): \(error)")
                }
            }
        }
        if environment["ZTRON_PARITY_SYMBOLS"] != nil || !actions.isEmpty, scripts.isEmpty {
            try notes.joined(separator: "\n").write(to: URL(fileURLWithPath: out).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            remote.app.terminate()
            return
        }
        for script in scripts.isEmpty ? ParityScript.allCases : scripts {
            for side in FieldSide.allCases {
                let prefix = "\(script.rawValue)-\(side.rawValue)"
                do {
                    try remote.send(.begin(script.setup))
                    try remote.send(.dump(name: "\(prefix)-0-initial"))
                    var index = 1
                    for action in script.actions {
                        switch action {
                        case .step(let step):
                            try remote.perform(step, on: side, input: input)
                        case .checkpoint(let name):
                            try remote.send(.dump(name: "\(prefix)-\(index)-\(name)"))
                            index += 1
                        }
                    }
                } catch {
                    notes.append("\(prefix): \(error)")
                }
            }
        }
        try notes.joined(separator: "\n").write(to: URL(fileURLWithPath: out).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        remote.app.terminate()
    }
}
