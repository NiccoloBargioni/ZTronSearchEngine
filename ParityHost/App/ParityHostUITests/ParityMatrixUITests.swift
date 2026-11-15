import XCTest
import ZTronSearchEngineUIParity

/// Runs the cells of the parity matrix (specification section 12.5) that belong to the
/// simulator the test is launched on and to the device-level configuration it is in.
///
/// One invocation covers one appearance and one content size, which `Tools/run-matrix.sh` set
/// on the simulator beforehand, and inside it every layout direction, input and script asked
/// for. The cell's axes come from the environment (`TEST_RUNNER_ZTRON_PARITY_*` on the
/// `xcodebuild` command line); the app checks that the simulator really is in that
/// configuration before a comparison counts.
final class ParityMatrixUITests: XCTestCase {
    private func list<Value: RawRepresentable>(_ name: String, default all: [Value]) -> [Value] where Value.RawValue == String {
        guard let text = ProcessInfo.processInfo.environment[name], !text.isEmpty else { return all }
        return text.split(separator: ",").compactMap { Value(rawValue: String($0)) }
    }

    /// A simulator announces a hardware keyboard the first time one types on it, in an alert
    /// of its home screen that XCUITest trips over. `Tools/run-matrix.sh` runs this once per
    /// simulator before the matrix so that the announcement is over by then. The first key is
    /// expected to fail the first time, and only then.
    @MainActor
    func testPrepareHardwareKeyboard() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("the first key of a hardware keyboard raises the system's announcement", options: options) {
            app.typeKey("a", modifierFlags: [])
        }
        app.terminate()
    }

    @MainActor
    func testMatrix() throws {
        // One step XCUITest could not perform fails its cell, not every cell after it.
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let results = environment["ZTRON_PARITY_RESULTS"], let scratch = environment["ZTRON_PARITY_SCRATCH"],
              let os = environment["ZTRON_PARITY_OS"], let device = environment["ZTRON_PARITY_DEVICE"],
              let appearance = ParityAppearance(rawValue: environment["ZTRON_PARITY_APPEARANCE"] ?? ""),
              let contentSize = ParityContentSize(rawValue: environment["ZTRON_PARITY_CONTENT_SIZE"] ?? "") else {
            throw XCTSkip("the matrix needs ZTRON_PARITY_RESULTS, _SCRATCH, _OS, _DEVICE, _APPEARANCE and _CONTENT_SIZE; use Tools/run-matrix.sh")
        }
        let directions: [ParityDirection] = list("ZTRON_PARITY_DIRECTIONS", default: ParityDirection.allCases)
        // On-screen keys first: once a hardware key has been pressed the system puts the
        // on-screen keyboard away.
        let inputs: [ParityInput] = list("ZTRON_PARITY_INPUTS", default: [.software, .hardware])
        let scripts: [ParityScript] = list("ZTRON_PARITY_SCRIPTS", default: ParityScript.allCases)
        let resultsDirectory = URL(fileURLWithPath: results)
        var failed: [String] = []
        var ran = 0

        for direction in directions {
            var remote: ParityRemote?
            for input in inputs {
                for script in scripts {
                    let cell = ParityCell(
                        os: os, device: device, appearance: appearance, contentSize: contentSize, direction: direction,
                        input: input, script: script
                    )
                    let options = FinishOptions(
                        resultsDirectory: results,
                        driver: input == .software
                            ? "XCUITest: touches, and taps on the keys of the on-screen keyboard"
                            : "XCUITest: touches, and key events of a hardware keyboard (typeKey)",
                        keepsAllSnapshots: environment["ZTRON_PARITY_SNAPSHOTS"] == "all",
                        referenceSnapshotsDirectory: environment["ZTRON_PARITY_REFERENCE_SNAPSHOTS"]
                    )
                    do {
                        if remote == nil {
                            remote = try ParityRemote(
                                channelDirectory: URL(fileURLWithPath: scratch).appendingPathComponent("channel-\(direction.rawValue)"),
                                language: direction.language, region: direction.region
                            )
                        }
                        guard let current = remote else { continue }
                        let summary = try current.run(cell, options: options)
                        ran += 1
                        if summary.status == .fail {
                            failed.append("\(cell.relativePath): \(summary.failures.first ?? "failed") (+\(max(0, summary.failures.count - 1)) more)")
                        }
                        if current.isStalled {
                            // This app process costs a minute per event from now on: the next
                            // cell gets a fresh one.
                            current.app.terminate()
                            remote = nil
                        }
                    } catch {
                        // The app stopped answering: the cell fails, and the next one gets a fresh app.
                        var result = CellResult(cell: cell, status: .fail, reason: "\(error)", driver: options.driver)
                        result.failures = ["driver: \(error)"]
                        try? result.write(under: resultsDirectory)
                        failed.append("\(cell.relativePath): \(error)")
                        remote?.app.terminate()
                        remote = nil
                    }
                }
            }
            remote?.app.terminate()
        }
        print("ZTRON_PARITY: \(ran) cells compared, \(failed.count) failed")
        for failure in failed {
            XCTFail(failure)
        }
    }
}
