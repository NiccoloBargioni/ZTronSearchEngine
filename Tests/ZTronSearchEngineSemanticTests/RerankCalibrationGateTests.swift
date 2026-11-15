import XCTest
import ZTronSearchEngine
@testable import ZTronSearchEngineSemantic

/// A device whose clock, memory, memory warnings and versions are set by the test.
private actor ScriptedDevice: CalibrationEnvironment {
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var uptime: UInt64 = 5_000_000_000
    private var memory: UInt64
    private var warning: Date?
    private var versions: String

    init(memory: UInt64 = 3_952_000_000, fingerprint: String = "app 1.0 (1), os 15.8") {
        self.memory = memory
        self.versions = fingerprint
    }

    func now() async -> Date { date }
    func uptimeNanoseconds() async -> UInt64 { uptime }
    func physicalMemory() async -> UInt64 { memory }
    func lastMemoryWarning() async -> Date? { warning }
    func fingerprint() async -> String { versions }

    /// Lets time pass on both clocks.
    func advance(seconds: Double) {
        uptime += UInt64((seconds * 1_000_000_000).rounded())
        date = date.addingTimeInterval(seconds)
    }

    func receiveMemoryWarning() { warning = date }
    func setFingerprint(_ fingerprint: String) { versions = fingerprint }
}

private actor InMemoryVerdictStore: CalibrationVerdictStore {
    private(set) var values: [String: Data] = [:]
    private(set) var writeCount = 0

    func verdictData(forKey key: String) async -> Data? { values[key] }

    func setVerdictData(_ data: Data?, forKey key: String) async {
        writeCount += 1
        values[key] = data
    }

    func corrupt(key: String) { values[key] = Data("not a verdict".utf8) }
}

/// A reranker whose every call takes a scripted time on the scripted device's clock, and that
/// counts loads the way a real model would incur them: on the first call after an unload.
private actor ScriptedReranker: Reranking {
    nonisolated let modelID: String
    private let device: ScriptedDevice
    /// Seconds per pair, by call; the last value repeats. The first call is the warm-up.
    private var pairSeconds: [Double]
    private let loadSeconds: Double
    private var failure: (any Error)?
    /// A call number at which the device receives a memory warning.
    private var warningAtCall: Int?

    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var callCount = 0
    private(set) var pairCount = 0
    private(set) var isLoaded = false

    init(device: ScriptedDevice, modelID: String = "reranker-v1", pairSeconds: [Double] = [0.010], loadSeconds: Double = 5) {
        self.device = device
        self.modelID = modelID
        self.pairSeconds = pairSeconds
        self.loadSeconds = loadSeconds
    }

    func isEnabled() async -> Bool { true }

    func scores(query: String, passages: [String]) async throws -> [Float] {
        if let failure { throw failure }
        if !isLoaded {
            isLoaded = true
            loadCount += 1
            await device.advance(seconds: loadSeconds)
        }
        let seconds = pairSeconds[min(callCount, pairSeconds.count - 1)]
        callCount += 1
        pairCount += passages.count
        if warningAtCall == callCount { await device.receiveMemoryWarning() }
        await device.advance(seconds: seconds * Double(passages.count))
        return passages.map { _ in 0.5 }
    }

    func unload() async {
        if isLoaded {
            isLoaded = false
            unloadCount += 1
        }
    }

    func fail(with error: (any Error)?) { failure = error }
    func warnDuringCall(_ call: Int) { warningAtCall = call }
}

/// The capability gate of the rerank stage (specification section 7.4).
final class RerankCalibrationGateTests: XCTestCase {
    /// What `ProcessInfo.physicalMemory` reports on devices sold as 2, 3 and 4 GB.
    private let twoGigabyteDevice: UInt64 = 2_104_541_184
    private let threeGigabyteDevice: UInt64 = 2_960_523_264
    private let fourGigabyteDevice: UInt64 = 3_952_000_000

    private func gate(_ device: ScriptedDevice, _ store: InMemoryVerdictStore, modelID: String = "reranker-v1") -> RerankCalibrationGate {
        RerankCalibrationGate(modelID: modelID, store: store, environment: device)
    }

    // MARK: Thresholds

    func testTheStageIsEnabledInsideAllThreeThresholds() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        // The warm-up call takes a whole second on top of five seconds of loading; neither is timed.
        let reranker = ScriptedReranker(device: device, pairSeconds: [1.0, 0.010], loadSeconds: 5)
        let gate = gate(device, store)

        let enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertTrue(enabled)
        let calls = await reranker.callCount
        let pairs = await reranker.pairCount
        XCTAssertEqual(calls, 17, "one warm-up, then the 16 synthetic pairs")
        XCTAssertEqual(pairs, 17)
        let isLoaded = await reranker.isLoaded
        XCTAssertTrue(isLoaded, "an enabled model stays loaded for the rerank that follows")

        let stored = await gate.storedVerdict()
        let verdict = try XCTUnwrap(stored)
        XCTAssertTrue(verdict.isEnabled)
        XCTAssertEqual(verdict.reason, .withinBudget)
        XCTAssertEqual(verdict.modelID, "reranker-v1")
        XCTAssertEqual(verdict.fingerprint, "app 1.0 (1), os 15.8")
        XCTAssertEqual(try XCTUnwrap(verdict.p95PerPair), 0.010, accuracy: 1e-9)
        XCTAssertEqual(verdict.physicalMemory, fourGigabyteDevice)
    }

    func testAP95Above15MillisecondsAloneDisablesTheStage() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        // Fifteen pairs at 5 ms and a single one at 16 ms: with 16 samples the 95th percentile
        // is the slowest.
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.005, 0.005, 0.005, 0.005, 0.016, 0.005])
        let gate = gate(device, store)

        let enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(enabled)
        let stored = await gate.storedVerdict()
        let verdict = try XCTUnwrap(stored)
        XCTAssertFalse(verdict.isEnabled)
        XCTAssertEqual(verdict.reason, .tooSlow)
        XCTAssertEqual(try XCTUnwrap(verdict.p95PerPair), 0.016, accuracy: 1e-9)
        let isLoaded = await reranker.isLoaded
        let unloads = await reranker.unloadCount
        XCTAssertFalse(isLoaded, "a model that will not be used is released")
        XCTAssertEqual(unloads, 1)

        // Exactly 15 ms is within the threshold.
        let onTheLine = ScriptedReranker(device: device, pairSeconds: [0.015])
        let passes = await self.gate(device, InMemoryVerdictStore()).isEnabled(calibrating: onTheLine)
        XCTAssertTrue(passes)
    }

    func testLessThan3GBOfMemoryAloneDisablesTheStageWithoutEverLoadingTheModel() async throws {
        let device = ScriptedDevice(memory: twoGigabyteDevice)
        let store = InMemoryVerdictStore()
        // A model that would pass the timing easily.
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.001])
        let gate = gate(device, store)

        let enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(enabled)
        let loads = await reranker.loadCount
        let calls = await reranker.callCount
        XCTAssertEqual(loads, 0, "the reference device never loads the cross-encoder")
        XCTAssertEqual(calls, 0)
        let stored = await gate.storedVerdict()
        let verdict = try XCTUnwrap(stored)
        XCTAssertFalse(verdict.isEnabled)
        XCTAssertEqual(verdict.reason, .insufficientMemory)
        XCTAssertNil(verdict.p95PerPair)

        // A device sold as 3 GB reports about 2.8 GB: it is a 3 GB device.
        let threeGB = ScriptedDevice(memory: threeGigabyteDevice)
        let passes = await self.gate(threeGB, InMemoryVerdictStore()).isEnabled(calibrating: ScriptedReranker(device: threeGB))
        XCTAssertTrue(passes)
    }

    func testAMemoryWarningInTheLast10MinutesAloneKeepsTheStageOffWithoutPersistingIt() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.001])
        let gate = gate(device, store)

        await device.receiveMemoryWarning()
        await device.advance(seconds: 5 * 60)
        var enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(enabled)
        var calls = await reranker.callCount
        XCTAssertEqual(calls, 0, "nothing is measured while the device is under pressure")
        var stored = await gate.storedVerdict()
        XCTAssertNil(stored, "a passing condition is not a verdict")

        // One second short of ten minutes: still off.
        await device.advance(seconds: 5 * 60 - 1)
        enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(enabled)
        calls = await reranker.callCount
        XCTAssertEqual(calls, 0)

        // Ten minutes after the warning the pass runs, and its verdict is persisted.
        await device.advance(seconds: 1)
        enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertTrue(enabled)
        calls = await reranker.callCount
        XCTAssertEqual(calls, 17)
        stored = await gate.storedVerdict()
        XCTAssertEqual(stored?.isEnabled, true)
    }

    func testAMemoryWarningDuringThePassVoidsIt() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.001])
        await reranker.warnDuringCall(9)
        let gate = gate(device, store)

        let enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(enabled)
        let stored = await gate.storedVerdict()
        XCTAssertNil(stored)
        let isLoaded = await reranker.isLoaded
        XCTAssertFalse(isLoaded, "the model is released when the device is under pressure")
    }

    // MARK: Persistence

    func testAStoredVerdictIsReusedAndTheModelIsNeverLoadedAgain() async throws {
        for pairSeconds in [0.010, 0.040] {
            let device = ScriptedDevice(memory: fourGigabyteDevice)
            let store = InMemoryVerdictStore()
            let reranker = ScriptedReranker(device: device, pairSeconds: [pairSeconds])
            let first = gate(device, store)
            let expected = pairSeconds <= 0.015

            let measured = await first.isEnabled(calibrating: reranker)
            XCTAssertEqual(measured, expected)
            let callsAfterPass = await reranker.callCount
            let loadsAfterPass = await reranker.loadCount
            XCTAssertEqual(callsAfterPass, 17)
            XCTAssertEqual(loadsAfterPass, 1)
            let writes = await store.writeCount
            XCTAssertEqual(writes, 1)

            // Asked again in the same launch: the answer, no model.
            for _ in 0..<5 {
                let again = await first.isEnabled(calibrating: reranker)
                XCTAssertEqual(again, expected)
            }
            let callsLater = await reranker.callCount
            XCTAssertEqual(callsLater, 17)

            // The next launch: a new gate and a model that has not been loaded yet.
            let nextLaunch = gate(device, store)
            let fresh = ScriptedReranker(device: device, pairSeconds: [pairSeconds])
            let reused = await nextLaunch.isEnabled(calibrating: fresh)
            XCTAssertEqual(reused, expected)
            let freshLoads = await fresh.loadCount
            let freshCalls = await fresh.callCount
            XCTAssertEqual(freshLoads, 0, "a stored verdict never loads the model")
            XCTAssertEqual(freshCalls, 0)
            let writesAfter = await store.writeCount
            XCTAssertEqual(writesAfter, 1)
        }
    }

    func testTheVerdictIsMeasuredAgainAfterAnAppOrOSUpdate() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice, fingerprint: "app 1.0 (1), os 15.8")
        let store = InMemoryVerdictStore()
        let enabled = await gate(device, store).isEnabled(calibrating: ScriptedReranker(device: device, pairSeconds: [0.010]))
        XCTAssertTrue(enabled)

        for update in ["app 1.1 (1), os 15.8", "app 1.1 (2), os 15.8", "app 1.1 (2), os 16.0"] {
            await device.setFingerprint(update)
            // After the update the model is slower than the threshold allows: only a new
            // measurement can notice.
            let slower = ScriptedReranker(device: device, pairSeconds: [0.020])
            let nextLaunch = gate(device, store)
            let verdict = await nextLaunch.isEnabled(calibrating: slower)
            XCTAssertFalse(verdict, "after '\(update)'")
            let calls = await slower.callCount
            XCTAssertEqual(calls, 17, "after '\(update)' the pass runs again")
            let stored = await nextLaunch.storedVerdict()
            XCTAssertEqual(stored?.fingerprint, update)
            XCTAssertEqual(stored?.isEnabled, false)

            // And a launch after that, under the same versions, reuses the new verdict.
            let unchanged = ScriptedReranker(device: device, pairSeconds: [0.001])
            let reused = await gate(device, store).isEnabled(calibrating: unchanged)
            XCTAssertFalse(reused)
            let unchangedCalls = await unchanged.callCount
            XCTAssertEqual(unchangedCalls, 0)

            // Back to a fast model for the next update, so every step flips the verdict.
            await device.setFingerprint(update + " (b)")
            let faster = await gate(device, store).isEnabled(calibrating: ScriptedReranker(device: device, pairSeconds: [0.010]))
            XCTAssertTrue(faster)
        }
    }

    func testVerdictsAreKeptPerModelAndUnreadableOnesAreIgnored() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        let first = await gate(device, store, modelID: "reranker-v1").isEnabled(calibrating: ScriptedReranker(device: device, modelID: "reranker-v1"))
        XCTAssertTrue(first)

        // Another model has no verdict yet.
        let other = ScriptedReranker(device: device, modelID: "reranker-v2", pairSeconds: [0.030])
        let otherGate = gate(device, store, modelID: "reranker-v2")
        let second = await otherGate.isEnabled(calibrating: other)
        XCTAssertFalse(second)
        let calls = await other.callCount
        XCTAssertEqual(calls, 17)
        XCTAssertNotEqual(otherGate.storageKey, RerankCalibrationGate(modelID: "reranker-v1").storageKey)
        let values = await store.values
        XCTAssertEqual(values.count, 2)

        // Bytes that are not a verdict are measured over.
        await store.corrupt(key: otherGate.storageKey)
        let again = ScriptedReranker(device: device, modelID: "reranker-v2", pairSeconds: [0.005])
        let third = await gate(device, store, modelID: "reranker-v2").isEnabled(calibrating: again)
        XCTAssertTrue(third)
        let againCalls = await again.callCount
        XCTAssertEqual(againCalls, 17)
    }

    func testInvalidationTurnsTheStageOffForTheLaunchAndForcesANewMeasurementAtTheNext() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.010])
        let gate = gate(device, store)
        let enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertTrue(enabled)

        // Core calls this after three consecutive breaches of the rerank cap.
        await gate.invalidate()
        var stored = await gate.storedVerdict()
        XCTAssertNil(stored, "the verdict is gone")
        let afterInvalidation = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(afterInvalidation, "off for the rest of this launch")
        let calls = await reranker.callCount
        XCTAssertEqual(calls, 17, "and not measured again in this launch")

        // The next launch measures again.
        let nextLaunch = self.gate(device, store)
        let fresh = ScriptedReranker(device: device, pairSeconds: [0.010])
        let remeasured = await nextLaunch.isEnabled(calibrating: fresh)
        XCTAssertTrue(remeasured)
        let freshCalls = await fresh.callCount
        XCTAssertEqual(freshCalls, 17)
        stored = await nextLaunch.storedVerdict()
        XCTAssertEqual(stored?.isEnabled, true)

        // Invalidating before anything was decided also keeps the stage off for the launch.
        let untouched = self.gate(device, InMemoryVerdictStore())
        await untouched.invalidate()
        let never = ScriptedReranker(device: device)
        let off = await untouched.isEnabled(calibrating: never)
        XCTAssertFalse(off)
        let neverCalls = await never.callCount
        XCTAssertEqual(neverCalls, 0)
    }

    func testAModelThatFailsKeepsTheStageOffForTheLaunchWithoutPersistingIt() async throws {
        struct ModelFailure: Error {}
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        let reranker = ScriptedReranker(device: device)
        await reranker.fail(with: ModelFailure())
        let gate = gate(device, store)

        let enabled = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(enabled)
        let stored = await gate.storedVerdict()
        XCTAssertNil(stored, "a failure is not a measurement")

        // Not retried in this launch, even once the model works.
        await reranker.fail(with: nil)
        let again = await gate.isEnabled(calibrating: reranker)
        XCTAssertFalse(again)
        let calls = await reranker.callCount
        XCTAssertEqual(calls, 0)
        // The next launch tries again.
        let retried = await self.gate(device, store).isEnabled(calibrating: reranker)
        XCTAssertTrue(retried)
    }

    func testConcurrentCallersShareOneCalibrationPass() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.010])
        let gate = gate(device, InMemoryVerdictStore())
        let answers = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 {
                group.addTask { await gate.isEnabled(calibrating: reranker) }
            }
            var answers: [Bool] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        XCTAssertEqual(answers, [Bool](repeating: true, count: 12))
        let calls = await reranker.callCount
        let loads = await reranker.loadCount
        XCTAssertEqual(calls, 17, "the model is measured once")
        XCTAssertEqual(loads, 1)
    }

    func testTheThresholdsAreConfigurable() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let reranker = ScriptedReranker(device: device, pairSeconds: [0.030])
        let lenient = RerankCalibrationGate(
            modelID: "reranker-v1", store: InMemoryVerdictStore(), environment: device,
            thresholds: .init(pairCount: 4, maximumP95PerPair: 0.050, minimumMemoryGigabytes: 2, memoryWarningQuietPeriod: 60)
        )
        let enabled = await lenient.isEnabled(calibrating: reranker)
        XCTAssertTrue(enabled)
        let calls = await reranker.callCount
        XCTAssertEqual(calls, 5)

        let strict = RerankCalibrationGate(
            modelID: "reranker-v1", store: InMemoryVerdictStore(), environment: device,
            thresholds: .init(minimumMemoryGigabytes: 6)
        )
        let disabled = await strict.isEnabled(calibrating: ScriptedReranker(device: device))
        XCTAssertFalse(disabled)
        XCTAssertEqual(RerankCalibrationGate.Thresholds.default, .init(pairCount: 16, maximumP95PerPair: 0.015, minimumMemoryGigabytes: 3, memoryWarningQuietPeriod: 600))
    }

    // MARK: Wrapper

    func testTheCalibratedRerankerAnswersCoreWithTheGatesVerdict() async throws {
        let device = ScriptedDevice(memory: fourGigabyteDevice)
        let store = InMemoryVerdictStore()
        let model = ScriptedReranker(device: device, pairSeconds: [0.010])
        let reranker: any Reranking = CalibratedReranker(model, store: store, environment: device)
        XCTAssertEqual(reranker.modelID, "reranker-v1")

        // Under `.auto` core asks once, on first use.
        let enabled = await reranker.isEnabled()
        XCTAssertTrue(enabled)
        var calls = await model.callCount
        XCTAssertEqual(calls, 17)
        let again = await reranker.isEnabled()
        XCTAssertTrue(again)

        // Scoring and unloading reach the model.
        let scores = try await reranker.scores(query: "q", passages: ["a", "b", "c"])
        XCTAssertEqual(scores, [0.5, 0.5, 0.5])
        calls = await model.callCount
        XCTAssertEqual(calls, 18)
        await reranker.unload()
        let isLoaded = await model.isLoaded
        XCTAssertFalse(isLoaded)

        // Three breaches of the cap: core invalidates.
        await reranker.invalidateCalibration()
        let afterInvalidation = await reranker.isEnabled()
        XCTAssertFalse(afterInvalidation)
        let values = await store.values
        XCTAssertTrue(values.values.allSatisfy { _ in false }, "nothing is stored any more")

        // A 2 GB device behind the wrapper never loads the model.
        let small = ScriptedDevice(memory: twoGigabyteDevice)
        let unused = ScriptedReranker(device: small)
        let off = await CalibratedReranker(unused, store: InMemoryVerdictStore(), environment: small).isEnabled()
        XCTAssertFalse(off)
        let loads = await unused.loadCount
        XCTAssertEqual(loads, 0)
    }

    // MARK: Building blocks

    func testPercentilesUseTheNearestRank() {
        let samples = (1...16).map { Double($0) }
        XCTAssertEqual(RerankCalibrationGate.percentile(samples, 0.95), 16)
        XCTAssertEqual(RerankCalibrationGate.percentile(samples.shuffled(), 0.50), 8)
        XCTAssertEqual(RerankCalibrationGate.percentile(samples, 0), 1)
        XCTAssertEqual(RerankCalibrationGate.percentile(samples, 1), 16)
        XCTAssertEqual(RerankCalibrationGate.percentile((1...100).map(Double.init), 0.95), 95)
        XCTAssertEqual(RerankCalibrationGate.percentile([0.012], 0.95), 0.012)
        XCTAssertEqual(RerankCalibrationGate.percentile([], 0.95), .infinity, "no sample never passes a threshold")
    }

    func testMemoryIsCountedInTheGigabytesADeviceIsSoldWith() {
        XCTAssertEqual(RerankCalibrationGate.wholeGigabytes(twoGigabyteDevice), 2)
        XCTAssertEqual(RerankCalibrationGate.wholeGigabytes(threeGigabyteDevice), 3)
        XCTAssertEqual(RerankCalibrationGate.wholeGigabytes(fourGigabyteDevice), 4)
        XCTAssertEqual(RerankCalibrationGate.wholeGigabytes(3 * 1_073_741_824), 3)
        XCTAssertEqual(RerankCalibrationGate.wholeGigabytes(8 * 1_073_741_824 - 300_000_000), 8)
        XCTAssertEqual(RerankCalibrationGate.wholeGigabytes(0), 0)
    }

    func testTheSyntheticPairsAreDeterministicAndFillTheWindow() {
        let pairs = RerankCalibrationGate.syntheticPairs(count: 16)
        XCTAssertEqual(pairs.count, 16)
        let again = RerankCalibrationGate.syntheticPairs(count: 16)
        XCTAssertEqual(pairs.map(\.query), again.map(\.query))
        XCTAssertEqual(pairs.map(\.passage), again.map(\.passage))
        for pair in pairs {
            XCTAssertFalse(pair.query.isEmpty)
            XCTAssertGreaterThan(pair.passage.unicodeScalars.count, 250, "long enough to fill 128 tokens")
        }
        XCTAssertGreaterThan(Set(pairs.map(\.passage)).count, 4)
        XCTAssertTrue(RerankCalibrationGate.syntheticPairs(count: 0).isEmpty)
    }

    func testTheUserDefaultsStoreKeepsAndRemovesTheVerdict() async throws {
        let suite = "ztron-semantic-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsVerdictStore(suiteName: suite)
        let missing = await store.verdictData(forKey: "key")
        XCTAssertNil(missing)
        await store.setVerdictData(Data([1, 2, 3]), forKey: "key")
        let kept = await UserDefaultsVerdictStore(suiteName: suite).verdictData(forKey: "key")
        XCTAssertEqual(kept, Data([1, 2, 3]))
        await store.setVerdictData(nil, forKey: "key")
        let removed = await store.verdictData(forKey: "key")
        XCTAssertNil(removed)

        // The gate against the real store: the verdict survives into a second gate.
        let device = ScriptedDevice()
        let enabled = await RerankCalibrationGate(modelID: "m", store: store, environment: device)
            .isEnabled(calibrating: ScriptedReranker(device: device, modelID: "m"))
        XCTAssertTrue(enabled)
        let unused = ScriptedReranker(device: device, modelID: "m")
        let reused = await RerankCalibrationGate(modelID: "m", store: UserDefaultsVerdictStore(suiteName: suite), environment: device)
            .isEnabled(calibrating: unused)
        XCTAssertTrue(reused)
        let calls = await unused.callCount
        XCTAssertEqual(calls, 0)
    }

    func testMemoryWarningsAreObservedByNameWithoutUIKit() async throws {
        XCTAssertEqual(MemoryWarningMonitor.notificationName.rawValue, "UIApplicationDidReceiveMemoryWarningNotification")
        let center = NotificationCenter()
        let stamp = Date(timeIntervalSince1970: 1_234_567)
        let monitor = MemoryWarningMonitor(center: center, now: { stamp })
        let before = await monitor.lastWarning()
        XCTAssertNil(before)

        // Posted right after the monitor was created: the observer is already registered.
        center.post(name: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil)
        var recorded: Date?
        for _ in 0..<200 {
            recorded = await monitor.lastWarning()
            if recorded != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(recorded, stamp)

        // Another notification is not a memory warning.
        let other = MemoryWarningMonitor(center: center, now: { stamp })
        center.post(name: Notification.Name("UIApplicationWillEnterForegroundNotification"), object: nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        let none = await other.lastWarning()
        XCTAssertNil(none)

        // The live environment reads the monitor, the device and the bundle.
        let live = LiveCalibrationEnvironment(memoryWarnings: monitor)
        let warning = await live.lastMemoryWarning()
        XCTAssertEqual(warning, stamp)
        let memory = await live.physicalMemory()
        XCTAssertEqual(memory, ProcessInfo.processInfo.physicalMemory)
        let fingerprint = await live.fingerprint()
        XCTAssertTrue(fingerprint.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        XCTAssertEqual(
            LiveCalibrationEnvironment.fingerprint(appVersion: "2.1", appBuild: "57", systemVersion: "Version 15.8 (Build 19H370)"),
            "app 2.1 (57), os Version 15.8 (Build 19H370)"
        )
        XCTAssertNotEqual(
            LiveCalibrationEnvironment.fingerprint(appVersion: "2.1", appBuild: "58", systemVersion: "Version 15.8 (Build 19H370)"),
            LiveCalibrationEnvironment.fingerprint(appVersion: "2.1", appBuild: "57", systemVersion: "Version 15.8 (Build 19H370)")
        )
        let first = await live.uptimeNanoseconds()
        let second = await live.uptimeNanoseconds()
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
