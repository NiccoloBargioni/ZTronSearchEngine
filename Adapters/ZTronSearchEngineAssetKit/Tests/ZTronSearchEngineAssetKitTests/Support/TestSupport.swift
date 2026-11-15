import CryptoKit
import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

// MARK: - Model fixtures

/// A small model whose files have real SHA-256 values, with the bytes of each file.
struct ModelFixture: Sendable {
    let asset: ModelAsset
    let payloads: [String: Data]

    /// Four files named as the reference model names them, sized 937, 4,096, 2,048 and 512 bytes.
    static func standard(id: String = "qwen3-test", revision: String = "r1") -> ModelFixture {
        ModelFixture(
            id: id,
            revision: revision,
            files: [
                ("config.json", bytes(937, seed: 1)),
                ("model.safetensors", bytes(4_096, seed: 2)),
                ("tokenizer.json", bytes(2_048, seed: 3)),
                ("tokenizer_config.json", bytes(512, seed: 4)),
            ]
        )
    }

    init(id: String, revision: String, files: [(name: String, data: Data)]) {
        asset = ModelAsset(
            id: id,
            revision: revision,
            files: files.map { ModelFile(name: $0.name, byteCount: Int64($0.data.count), sha256: sha256Hex($0.data)) }
        )
        payloads = Dictionary(files.map { ($0.name, $0.data) }, uniquingKeysWith: { first, _ in first })
    }

    /// The catalog asset of a file under the provider's default mapping.
    func identifier(_ name: String) -> AssetID {
        AssetID("model/\(asset.id)@\(asset.revision)/\(name)")
    }

    var identifiers: [AssetID] {
        asset.files.map { identifier($0.name) }
    }

    func data(_ name: String) -> Data {
        payloads[name] ?? Data()
    }

    func byteCount(_ name: String) -> Int64 {
        Int64(data(name).count)
    }
}

/// `count` bytes that depend on `seed` only.
func bytes(_ count: Int, seed: UInt8) -> Data {
    var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
    var data = Data(capacity: count)
    for _ in 0..<count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        data.append(UInt8(truncatingIfNeeded: state >> 33))
    }
    return data
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Harness

/// One provider over one scripted client, with directories of their own.
struct Harness: Sendable {
    let client: ScriptedAssetClient
    let provider: AssetKitModelAssetProvider
    let diagnostics: DiagnosticLog
    /// Where the provider creates model directories.
    let models: URL
    let scratch: URL

    init(
        for testCase: XCTestCase,
        network: NetworkPolicy = NetworkPolicy(),
        power: PowerPolicy = PowerPolicy(),
        identifier: AssetKitModelAssetProvider.IdentifierMapping? = nil
    ) throws {
        scratch = try makeScratchDirectory(for: testCase)
        models = scratch.appendingPathComponent("Models", isDirectory: true)
        client = ScriptedAssetClient(root: scratch.appendingPathComponent("store", isDirectory: true), network: network, power: power)
        let log = DiagnosticLog()
        diagnostics = log
        provider = AssetKitModelAssetProvider(
            client: client,
            directory: models,
            identifier: identifier ?? AssetKitModelAssetProvider.defaultIdentifier,
            diagnostics: { log.record($0) }
        )
    }

    /// Stores every file of `fixture`, or only those named.
    func preload(_ fixture: ModelFixture, only names: [String]? = nil) async throws {
        for file in fixture.asset.files where names?.contains(file.name) ?? true {
            try await client.preload(fixture.data(file.name), for: fixture.identifier(file.name))
        }
    }

    /// Makes `resolve` deliver every file of `fixture` at once.
    func scriptDeliveries(of fixture: ModelFixture) async {
        for file in fixture.asset.files {
            await client.script(.deliver(fixture.data(file.name)), for: fixture.identifier(file.name))
        }
    }

    /// Makes `resolve` wait for `complete(_:)` for every file of `fixture`.
    func hold(_ fixture: ModelFixture) async {
        for file in fixture.asset.files {
            await client.script(.hold(fixture.data(file.name)), for: fixture.identifier(file.name))
        }
    }

    /// Lets every held `resolve` of `fixture` store its file and return.
    func complete(_ fixture: ModelFixture) async {
        for file in fixture.asset.files {
            await client.complete(fixture.identifier(file.name))
        }
    }
}

/// A directory of its own for one test, removed when the test is done.
func makeScratchDirectory(for testCase: XCTestCase) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZTronSearchEngineAssetKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: directory)
    }
    return directory
}

/// Collects the diagnostics a provider reports, in the order it reported them.
final class DiagnosticLog: Sendable {
    private enum Item: Sendable {
        case diagnostic(AssetKitBridgeDiagnostic)
        case marker
    }

    private actor History {
        var entries: [AssetKitBridgeDiagnostic] = []

        func append(_ diagnostic: AssetKitBridgeDiagnostic) {
            entries.append(diagnostic)
        }
    }

    private let stream: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation
    private let history = History()

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Item.self)
    }

    /// Called from any thread.
    func record(_ diagnostic: AssetKitBridgeDiagnostic) {
        continuation.yield(.diagnostic(diagnostic))
    }

    /// Everything recorded before this call. One caller at a time.
    func entries() async -> [AssetKitBridgeDiagnostic] {
        continuation.yield(.marker)
        for await item in stream {
            switch item {
            case .diagnostic(let diagnostic):
                await history.append(diagnostic)
            case .marker:
                return await history.entries
            }
        }
        return await history.entries
    }
}

// MARK: - Streams

/// What a fetch stream produced: every element, and the error it ended with, if any.
struct StreamRecord: Sendable {
    var values: [ModelAssetAvailability] = []
    var error: (any Error)?

    /// The byte counts of the `.downloading` elements, in order.
    var byteCounts: [Int64] {
        values.compactMap { value in
            if case .downloading(let bytes, _) = value {
                return bytes
            }
            return nil
        }
    }

    /// The directory of a final `.available`, when the stream ended with one and no error.
    var directory: URL? {
        guard error == nil, case .available(let url)? = values.last else {
            return nil
        }
        return url
    }

    var modelError: ModelAssetError? {
        error as? ModelAssetError
    }
}

/// Reads `stream` to its end. `onValue` is called after each element, so a test can tell that
/// the stream is attached to its fetch.
func collect(
    _ stream: AsyncThrowingStream<ModelAssetAvailability, any Error>,
    onValue: (@Sendable () -> Void)? = nil
) async -> StreamRecord {
    var record = StreamRecord()
    do {
        for try await value in stream {
            record.values.append(value)
            onValue?()
        }
    } catch {
        record.error = error
    }
    return record
}

/// Reads the rest of a stream through its iterator.
func drain(_ iterator: inout AsyncThrowingStream<ModelAssetAvailability, any Error>.Iterator) async -> StreamRecord {
    var record = StreamRecord()
    do {
        while let value = try await iterator.next() {
            record.values.append(value)
        }
    } catch {
        record.error = error
    }
    return record
}

/// The result of a reading task. The task is cancelled with the caller, so a time limit also
/// ends a reader whose stream would never end.
func outcome<Value: Sendable>(of task: Task<Value, Never>) async -> Value {
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

// MARK: - Time limit

struct TimedOut: Error {}

/// Runs `work`, failing instead of hanging when it takes longer than `seconds`. The limit is
/// wide on purpose: it exists to end a test that waits for something that never comes, also on a
/// machine that is busy with other work.
func withTimeLimit<Value: Sendable>(
    _ seconds: Double = 60,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOut()
        }
        defer {
            group.cancelAll()
        }
        guard let value = try await group.next() else {
            throw TimedOut()
        }
        return value
    }
}

// MARK: - Files

/// Every item under `directory` as a relative path, sorted; directories are left out.
func files(in directory: URL) throws -> [String] {
    try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        .filter { path in
            let type = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)[.type] as? FileAttributeType
            return type != .typeDirectory
        }
        .sorted()
}

/// The inode of the item itself, not of what a link points at.
func inode(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

extension DeviceConditions {
    static let wifi = DeviceConditions.unrestricted

    static let cellular = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: true, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )

    static let lowDataWifi = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: false, constrained: true),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )

    static let lowPowerWifi = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: false, constrained: false),
        power: PowerConditions(lowPowerMode: true, thermal: .nominal)
    )

    static let offline = DeviceConditions(
        network: NetworkConditions(satisfied: false, expensive: false, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )
}
