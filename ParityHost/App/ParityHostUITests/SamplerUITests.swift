import XCTest
import ZTronSearchEngineUIParity

/// Samples the UIKit reference on the simulator the test runs on (specification section 12.4).
/// `Tools/sample.sh` runs it once per content size and appearance and merges what it writes.
final class SamplerUITests: XCTestCase {
    private func output() throws -> (out: String, channel: URL) {
        let environment = ProcessInfo.processInfo.environment
        guard let out = environment["ZTRON_PARITY_SAMPLE_OUT"], let scratch = environment["ZTRON_PARITY_SCRATCH"] else {
            throw XCTSkip("sampling needs ZTRON_PARITY_SAMPLE_OUT and ZTRON_PARITY_SCRATCH; use Tools/sample.sh")
        }
        return (out, URL(fileURLWithPath: scratch).appendingPathComponent("channel-sample"))
    }

    private func write<Value: Encodable>(_ value: Value, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Lengths, colors and defaults of the reference under the simulator's current content
    /// size and appearance.
    @MainActor
    func testSampleAppearance() throws {
        let (out, channel) = try output()
        let remote = try ParityRemote(channelDirectory: channel, language: "en", region: "US")
        guard let sample = try remote.send(.sample, timeout: 90).sample else {
            return XCTFail("the host app returned no sample")
        }
        try write(sample, to: out)
        remote.app.terminate()
    }

    /// What the reference does where the specification says "recorded, never assumed", driven
    /// by real touches and keys: the flags the product is generated with, and the log of every
    /// elementary action, which is what the clone's log is held to.
    @MainActor
    func testSampleBehavior() throws {
        let (out, channel) = try output()
        let remote = try ParityRemote(channelDirectory: channel, language: "en", region: "US")
        let actions = BehaviorProfile.actions

        var behavior = SampledBehavior()
        var states: [String: FieldGeometry] = [:]
        for action in actions {
            for side in FieldSide.allCases {
                var log: [String] = []
                var final = "not reached"
                do {
                    try remote.send(.begin(action.setup))
                    for step in action.steps { try remote.perform(step, on: side, input: .software) }
                    let state = try remote.geometry(side)
                    log = state.events.map(\.description)
                    final = "text \(ParityEvent.quoted(state.text)), tokens \(state.tokenLabels), selected \(state.selectedLabels), "
                        + (state.isEditing ? "editing" : "not editing")
                    if side == .reference { states[action.name] = state }
                } catch {
                    log.append("failed: \(error)")
                }
                switch side {
                case .reference:
                    behavior.eventProfile[action.name] = log
                    behavior.finalStates[action.name] = final
                case .clone:
                    behavior.cloneEventProfile[action.name] = log
                    behavior.cloneFinalStates[action.name] = final
                }
            }
        }

        func state(_ name: String) throws -> FieldGeometry {
            guard let state = states[name] else { throw ParityRemote.Failure(description: "the reference did not complete \(name)") }
            return state
        }
        behavior.clearRemovesTokens = try state("clear-while-editing").tokenLabels.isEmpty
        behavior.clearBeginsEditing = try state("clear-while-not-editing").isEditing
        let typedOver = try state("type-over-selected-token")
        behavior.typingReplacesSelectedTokens = typedOver.tokenLabels == ["Tips"]
        behavior.submitKeepsEditing = try state("submit").isEditing
        behavior.conversionSelectsToken = try state("text-to-token").selectedLabels == ["ab"]
        behavior.notes = [
            "typing x over the selected token Maps left the text \"\(typedOver.text)\" and the tokens \(typedOver.tokenLabels)",
            "typing x after a conversion left the text \"\(try state("type-after-conversion").text)\" and the tokens \(try state("type-after-conversion").tokenLabels)",
            "the clear button, tapped while not editing, left the tokens \(try state("clear-while-not-editing").tokenLabels)",
            "backspace with allowsDeletingTokens off left the tokens \(try state("backspace-with-deletion-disabled").tokenLabels), selected \(try state("backspace-with-deletion-disabled").selectedLabels)",
        ]
        try write(behavior, to: out)
        remote.app.terminate()
    }
}

/// What the reference does, as `Samples/ios-<major>.json` stores it under `behavior`.
struct SampledBehavior: Codable {
    var clearRemovesTokens = false
    var clearBeginsEditing = false
    var typingReplacesSelectedTokens = false
    var submitKeepsEditing = false
    var conversionSelectsToken = false
    /// The reference's log of each elementary action, one entry per delegate callback.
    var eventProfile: [String: [String]] = [:]
    /// The clone's log of the same actions, for the record of the sampling run.
    var cloneEventProfile: [String: [String]] = [:]
    /// The state each action left the reference in, and the clone.
    var finalStates: [String: String] = [:]
    var cloneFinalStates: [String: String] = [:]
    var notes: [String] = []
}
