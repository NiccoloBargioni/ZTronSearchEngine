import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

/// The provider over a real `AssetClient`: ZTronAssetKit's engine, store, index and snapshot,
/// built from its public product only, with an origin in memory (`MemoryOrigin`) in place of the
/// network. These tests pin what the bridge takes from ZTronAssetKit on trust.
final class RealClientTests: XCTestCase {
    /// A host that keeps the prefetch lane off cellular and Low Data Mode, so `.wifiOnly` has a lane.
    private let wifiOnlyPrefetch = NetworkPolicy(prefetchOnExpensive: false, prefetchOnConstrained: false)

    // MARK: Download, verify, link

    func testAModelIsDownloadedVerifiedPinnedAndLinked() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])

        try await withTimeLimit {
            let before = await host.provider.availability(of: model.asset)
            XCTAssertEqual(before, .missing)
            // A catalog sync leaves the model alone: its entries are published `onDemand`.
            let sync = await host.client.sync(.force)
            guard case .complete = sync else {
                return XCTFail("the sync ended with \(sync)")
            }
            let requestsAfterSync = await host.origin.requests
            XCTAssertTrue(requestsAfterSync.isEmpty, "a sync downloaded model files nobody asked for")

            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))

            let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")
            XCTAssertEqual(record.values.first, .downloading(bytes: 0, of: model.asset.totalBytes))
            XCTAssertEqual(record.byteCounts, record.byteCounts.sorted())
            XCTAssertEqual(record.byteCounts.last, model.asset.totalBytes)
            XCTAssertEqual(try files(in: directory), ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])

            let blobs = host.storeRoot.appendingPathComponent("ZTronAssetKit/v1/blobs", isDirectory: true)
            for file in model.asset.files {
                let item = directory.appendingPathComponent(file.name)
                XCTAssertEqual(try Data(contentsOf: item), model.data(file.name), file.name)
                // The store named the blob by the SHA-256 of its bytes: the property the bridge verifies by.
                let blob = URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: item.path))
                XCTAssertEqual(blob.deletingPathExtension().lastPathComponent, file.sha256, file.name)
                XCTAssertEqual(blob.deletingLastPathComponent().deletingLastPathComponent().path, blobs.path, file.name)
            }
            // `model.safetensors` is published under a short extension; the link gives the name back.
            let weights = try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("model.safetensors").path)
            XCTAssertTrue(weights.hasSuffix(".bin"))

            let requests = await host.origin.requests
            XCTAssertEqual(requests.map(\.remotePath).sorted(), model.asset.files.map { host.remotePath(of: $0.name, in: model) }.sorted())
            XCTAssertTrue(requests.allSatisfy { $0.priority == .userInitiated && $0.access == .unrestricted })

            let report = try await host.client.storageReport()
            XCTAssertEqual(report.pinnedBytes, model.asset.totalBytes, "every file of the model is pinned")
            let after = await host.provider.availability(of: model.asset)
            XCTAssertEqual(after, .available(directory))
        }
    }

    func testASecondFetchRequestsNothing() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])

        try await withTimeLimit {
            let first = await collect(host.provider.fetch(model.asset, policy: .allowCellular))
            let directory = try XCTUnwrap(first.directory, "the stream ended with \(String(describing: first.error))")
            let requested = await host.origin.requests.count

            let second = await collect(host.provider.fetch(model.asset, policy: .allowCellular))

            XCTAssertEqual(second.values, [.available(directory)])
            let requestedAfter = await host.origin.requests.count
            XCTAssertEqual(requestedAfter, requested, "a verified file is never downloaded again")
        }
    }

    func testAFetchThatFailedResumesWithTheFilesTheStoreKept() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        let weights = host.remotePath(of: "model.safetensors", in: model)
        await host.origin.gate(weights)
        let total = model.asset.totalBytes
        let small: Int64 = 937 + 2_048 + 512

        try await withTimeLimit {
            // First attempt: the three small files are stored, the first quarter of the weights arrived,
            // then the network goes away.
            var first = host.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            try await host.read(&first, until: small + 1_024)
            await host.origin.fail(weights, with: .offline(.noConnection))
            let failed = await drain(&first)
            XCTAssertEqual(failed.modelError, .offline)
            await host.origin.wait { $0.active == 0 }

            // Second attempt.
            let second = await collect(host.provider.fetch(model.asset, policy: .allowCellular))

            XCTAssertNotNil(second.directory, "the stream ended with \(String(describing: second.error))")
            XCTAssertEqual(second.values.first, .downloading(bytes: small, of: total), "it starts at the files that are stored")
            for file in model.asset.files where file.name != "model.safetensors" {
                let requests = await host.origin.requests(for: host.remotePath(of: file.name, in: model))
                XCTAssertEqual(requests.count, 1, "\(file.name) was stored and verified, and was requested again")
            }
            let attempts = await host.origin.requests(for: weights)
            XCTAssertGreaterThanOrEqual(attempts.count, 2)
        }
    }

    // MARK: Policies on the real engine

    func testWifiOnlyRequestsCarryTheSystemEnforcedRestriction() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: wifiOnlyPrefetch, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .wifiOnly))

            let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")
            let requests = await host.origin.requests
            XCTAssertEqual(requests.count, 4)
            for request in requests {
                XCTAssertEqual(request.priority, .prefetch)
                // What the HTTP transport copies onto the URLRequest: the operating system refuses cellular.
                XCTAssertFalse(request.access.allowsExpensive)
                XCTAssertFalse(request.access.allowsCellular)
                XCTAssertFalse(request.access.allowsConstrained)
            }
            XCTAssertEqual(record.byteCounts, record.byteCounts.sorted())
            XCTAssertEqual(record.byteCounts.last, model.asset.totalBytes)
            // The snapshot `availability` reads may trail a prefetch-lane commit by a moment.
            let settled = await host.availability(of: model.asset, eventually: .available(directory))
            XCTAssertEqual(settled, .available(directory))
        }
    }

    func testWifiOnlyOnACellularNetworkSendsNoRequest() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: wifiOnlyPrefetch, conditions: .cellular, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .wifiOnly))

            XCTAssertEqual(record.modelError, .policy)
            let requests = await host.origin.requests
            XCTAssertTrue(requests.isEmpty, "the engine parks the lane; nothing reaches the origin")
            let availability = await host.provider.availability(of: model.asset)
            XCTAssertEqual(availability, .missing)
        }
    }

    func testAllowCellularDownloadsOnACellularNetwork() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: wifiOnlyPrefetch, conditions: .cellular, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))

            XCTAssertNotNil(record.directory, "the stream ended with \(String(describing: record.error))")
            let requests = await host.origin.requests
            XCTAssertTrue(requests.allSatisfy { $0.priority == .userInitiated && $0.access.allowsExpensive && $0.access.allowsCellular })
        }
    }

    func testWifiOnlyStopsItsTransferWhenTheNetworkTurnsCellular() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: wifiOnlyPrefetch, publishing: [model])
        let weights = host.remotePath(of: "model.safetensors", in: model)
        await host.origin.gate(weights)

        try await withTimeLimit {
            // The small files are stored and the weights are in transit over Wi-Fi.
            var stream = host.provider.fetch(model.asset, policy: .wifiOnly).makeAsyncIterator()
            try await host.read(&stream, until: 937 + 2_048 + 512 + 1_024)

            await host.conditions.set(.cellular)
            let record = await drain(&stream)

            XCTAssertEqual(record.modelError, .policy)
            // The engine pauses the transfer its policy refuses, or cancels it once nobody waits for it.
            await host.origin.wait { $0.active == 0 }
            let stops = await host.origin.stops
            XCTAssertEqual(stops.map(\.path), [weights])
            let stored = await host.client.locations(of: [model.identifier("model.safetensors")])
            XCTAssertTrue(stored.isEmpty)
        }
    }

    func testWifiOnlyOnTheBulkLaneReportsWholeFiles() async throws {
        // A host that keeps only bulk work off cellular: the one lane `.wifiOnly` can use publishes no byte progress.
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: NetworkPolicy(bulkOnExpensive: false), publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .wifiOnly))

            let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")
            let requests = await host.origin.requests
            XCTAssertEqual(requests.count, 4)
            XCTAssertTrue(requests.allSatisfy { $0.priority == .bulk && !$0.access.allowsExpensive && !$0.access.allowsCellular })
            // Every count is a sum of whole files: the bulk lane reports no bytes of a file in transit.
            var wholeFiles: Set<Int64> = [0]
            for file in model.asset.files {
                wholeFiles.formUnion(wholeFiles.map { $0 + file.byteCount })
            }
            XCTAssertTrue(record.byteCounts.allSatisfy(wholeFiles.contains), "\(record.byteCounts)")
            XCTAssertEqual(record.byteCounts, record.byteCounts.sorted())
            XCTAssertEqual(record.byteCounts.last, model.asset.totalBytes)
            let settled = await host.availability(of: model.asset, eventually: .available(directory))
            XCTAssertEqual(settled, .available(directory))
        }
    }

    func testDefaultNetworkPolicyCannotServeWifiOnly() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: NetworkPolicy(), publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .wifiOnly))

            XCTAssertEqual(record.modelError, .policy)
            let requests = await host.origin.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    // MARK: Verification on the real store

    func testBytesThatDoNotMatchTheCatalogChecksumAreNeverStored() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        let weights = host.remotePath(of: "model.safetensors", in: model)
        await host.origin.script(.serveInstead(bytes(4_096, seed: 99)), for: weights)

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))

            XCTAssertEqual(record.modelError, .checksum)
            let stored = await host.client.locations(of: [model.identifier("model.safetensors")])
            XCTAssertTrue(stored.isEmpty, "the store deleted the staged bytes instead of publishing them")
            let diagnostics = await host.diagnostics.entries()
            XCTAssertTrue(diagnostics.contains(.clientFailed(.resolve, .integrityFailure, reportedAs: .checksum)), "\(diagnostics)")

            // ZTronAssetKit holds the asset back for its integrity backoff: a retry asks, and is refused, without a transfer.
            let attempts = await host.origin.requests(for: weights).count
            let again = await collect(host.provider.fetch(model.asset, policy: .allowCellular))
            XCTAssertEqual(again.modelError, .checksum)
            let attemptsAfter = await host.origin.requests(for: weights).count
            XCTAssertEqual(attemptsAfter, attempts)
        }
    }

    func testACatalogThatPublishesOtherBytesThanTheDescriptorIsPurged() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        // The catalog is consistent with itself, but its weights are not the ones the descriptor names.
        let other = bytes(4_096, seed: 99)
        await host.origin.publish(host.entry(for: "model.safetensors", in: model, data: other))

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))

            XCTAssertEqual(record.modelError, .checksum)
            let stored = await host.client.locations(of: [model.identifier("model.safetensors")])
            XCTAssertTrue(stored.isEmpty, "the mismatched asset was deleted through the client")
            let diagnostics = await host.diagnostics.entries()
            XCTAssertTrue(
                diagnostics.contains(
                    .contentMismatch(
                        identifier: model.identifier("model.safetensors"),
                        fileName: "model.safetensors",
                        expectedSHA256: sha256Hex(model.data("model.safetensors")),
                        storedSHA256: sha256Hex(other)
                    )
                ),
                "\(diagnostics)"
            )
            let availability = await host.provider.availability(of: model.asset)
            XCTAssertEqual(availability, .failed(.checksum))
        }
    }

    func testAnAssetTheCatalogDoesNotListFailsWithChecksum() async throws {
        let model = ModelFixture.standard()
        let unpublished = ModelFixture.standard(revision: "r2")
        let host = try await RealHost(for: self, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(unpublished.asset, policy: .allowCellular))

            XCTAssertEqual(record.modelError, .checksum)
            let diagnostics = await host.diagnostics.entries()
            XCTAssertTrue(diagnostics.contains(.clientFailed(.resolve, .notFound, reportedAs: .checksum)), "\(diagnostics)")
        }
    }

    // MARK: Errors of the real engine

    func testAnOriginWithoutANetworkPathFailsWithOffline() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        for file in model.asset.files {
            await host.origin.script(.fail(.offline(.noConnection)), for: host.remotePath(of: file.name, in: model))
        }

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))
            XCTAssertEqual(record.modelError, .offline)
        }
    }

    func testAnUnsatisfiedPathFailsWithOffline() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, network: wifiOnlyPrefetch, conditions: .offline, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .wifiOnly))

            XCTAssertEqual(record.modelError, .offline)
            let requests = await host.origin.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testAVolumeWithoutRoomFailsWithDiskFull() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        let weights = host.remotePath(of: "model.safetensors", in: model)
        // More than any volume holds, so the engine's own free-space read confirms the shortage.
        await host.origin.script(.fail(.insufficientSpace(requiredBytes: 1 << 60)), for: weights)

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))
            XCTAssertEqual(record.modelError, .diskFull)
        }
    }

    // MARK: Sharing and cancellation on the real engine

    func testTwoStreamsShareOneTransferPerFile() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        let weights = host.remotePath(of: "model.safetensors", in: model)
        await host.origin.gate(weights)

        try await withTimeLimit {
            var one = host.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            var two = host.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            _ = try await one.next()
            _ = try await two.next()
            await host.origin.wait { $0.waiting.contains(weights) }
            await host.origin.open(weights)
            let first = await drain(&one)
            let second = await drain(&two)

            let directory = try XCTUnwrap(first.directory, "the stream ended with \(String(describing: first.error))")
            XCTAssertEqual(second.directory, directory)
            let requests = await host.origin.requests
            XCTAssertEqual(requests.count, 4)
        }
    }

    func testCancellingTheReaderCancelsTheTransfer() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])
        let weights = host.remotePath(of: "model.safetensors", in: model)
        await host.origin.gate(weights)

        try await withTimeLimit {
            let reading = Task { await collect(host.provider.fetch(model.asset, policy: .allowCellular)) }
            // The small files are stored and the weights wait at the gate, a quarter in.
            await host.origin.wait { $0.waiting.contains(weights) && $0.active == 1 }
            let small = model.identifiers.filter { $0 != model.identifier("model.safetensors") }
            let stored = await host.waitUntilStored(small)
            XCTAssertTrue(stored)

            reading.cancel()
            _ = await outcome(of: reading)

            // Nobody waits for the file any more: the engine cancels its transfer.
            await host.origin.wait { $0.active == 0 }
            let stops = await host.origin.stops
            XCTAssertEqual(stops.map(\.path), [weights])
            XCTAssertEqual(stops.map(\.control), [.cancel])
            let availability = await host.provider.availability(of: model.asset)
            XCTAssertEqual(availability, .missing)
        }
    }

    // MARK: Lifetime

    func testEvictDeletesTheFilesFromTheStore() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))
            let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")

            try await host.provider.evict(model.asset)

            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            let stored = await host.client.locations(of: model.identifiers)
            XCTAssertTrue(stored.isEmpty)
            let report = try await host.client.storageReport()
            XCTAssertEqual(report.pinnedBytes, 0)
            let availability = await host.provider.availability(of: model.asset)
            XCTAssertEqual(availability, .missing)
        }
    }

    func testAHostPurgeMakesTheModelMissingAndRemovesTheDirectory() async throws {
        let model = ModelFixture.standard()
        let host = try await RealHost(for: self, publishing: [model])

        try await withTimeLimit {
            let record = await collect(host.provider.fetch(model.asset, policy: .allowCellular))
            let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")

            // A pin keeps eviction away, not a purge.
            _ = try await host.client.purge(.all)

            let availability = await host.provider.availability(of: model.asset)
            XCTAssertEqual(availability, .missing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testTheModelIsAvailableAfterARelaunchWithoutAnyRequest() async throws {
        let model = ModelFixture.standard()
        let first = try await RealHost(for: self, publishing: [model])
        let directory: URL = try await withTimeLimit {
            let record = await collect(first.provider.fetch(model.asset, policy: .allowCellular))
            let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")
            await first.client.shutdown()
            return directory
        }

        // A new process: a new client over the same store, a new provider over the same directory root.
        let second = try await RealHost(for: self, publishing: [model], reusing: first)
        try await withTimeLimit {
            // Read before the provider is asked, which would pin again.
            let report = try await second.client.storageReport()
            XCTAssertEqual(report.pinnedBytes, model.asset.totalBytes, "pins are part of the store's index")

            let availability = await second.provider.availability(of: model.asset)

            XCTAssertEqual(availability, .available(directory))
            let requests = await second.origin.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }
}

// MARK: - A host with a real client

/// A real `AssetClient` whose store is a directory of the test, whose origin is in memory and
/// whose device conditions the test sets.
struct RealHost: Sendable {
    let client: AssetClient
    let origin: MemoryOrigin
    let conditions: ScriptedConditions
    let provider: AssetKitModelAssetProvider
    let diagnostics: DiagnosticLog
    /// The base directory of the store: the store itself is `<storeRoot>/ZTronAssetKit/v1`.
    let storeRoot: URL
    let models: URL

    init(
        for testCase: XCTestCase,
        network: NetworkPolicy = NetworkPolicy(),
        conditions initial: DeviceConditions = .wifi,
        publishing fixtures: [ModelFixture],
        reusing previous: RealHost? = nil
    ) async throws {
        let scratch = try previous.map { $0.storeRoot.deletingLastPathComponent() } ?? makeScratchDirectory(for: testCase)
        storeRoot = scratch.appendingPathComponent("store", isDirectory: true)
        models = scratch.appendingPathComponent("Models", isDirectory: true)
        // A `.custom` base has to exist: the store creates `ZTronAssetKit/v1` inside it, not the base.
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let origin = MemoryOrigin()
        self.origin = origin
        let conditions = ScriptedConditions(initial)
        self.conditions = conditions

        var configuration = AssetClientConfiguration(remote: RemoteConfiguration(), location: .custom(storeRoot))
        configuration.network = network
        configuration.legacy = LegacyMigrationPolicy(enabled: false)
        // Short waits, so a purge and a failed attempt take milliseconds.
        configuration.storage.deletionGrace = 0.05
        let quick = RetryPolicy(baseDelay: 0.01, maxDelay: 0.02, maxAttemptsPerRun: 2, maxRetryAfter: 1, interactiveMaxWait: 1)
        configuration.tuning.retry = quick
        configuration.tuning.interactiveRetry = quick

        var environment = AssetEnvironment.live()
        environment.conditions = conditions
        environment.remoteSources = MemoryRemoteSourceFactory(origin: origin)
        environment.legacyDefaults = NoLegacyDefaults()
        environment.logSink = TapOnlyLogSink()

        let client = AssetClient(configuration: configuration, environment: environment)
        self.client = client
        testCase.addTeardownBlock {
            await client.shutdown()
        }

        let log = DiagnosticLog()
        diagnostics = log
        provider = AssetKitModelAssetProvider(client: client, directory: models, diagnostics: { log.record($0) })

        for fixture in fixtures {
            for file in fixture.asset.files {
                await origin.publish(entry(for: file.name, in: fixture, data: fixture.data(file.name)))
            }
        }
    }

    /// Where the origin serves a file from.
    func remotePath(of name: String, in fixture: ModelFixture) -> String {
        "models/\(fixture.asset.id)/\(fixture.asset.revision)/\(name)"
    }

    /// The catalog entry of a file, announcing the checksum and the size of `data`.
    ///
    /// The store allows at most eight letters or digits as an extension, so `safetensors` is
    /// published as `bin`: the provider's directory gives the file its name back.
    func entry(for name: String, in fixture: ModelFixture, data: Data) -> MemoryOrigin.Entry {
        let fileExtension = (name as NSString).pathExtension
        return MemoryOrigin.Entry(
            identifier: fixture.identifier(name),
            fileExtension: fileExtension.count <= 8 && !fileExtension.isEmpty ? fileExtension : "bin",
            remotePath: remotePath(of: name, in: fixture),
            data: data,
            checksum: sha256Hex(data),
            byteSize: Int64(data.count)
        )
    }

    /// Reads `stream` until it reports exactly `bytes`, failing when it ends or passes them.
    func read(_ stream: inout AsyncThrowingStream<ModelAssetAvailability, any Error>.Iterator, until bytes: Int64) async throws {
        var latest: Int64 = -1
        while latest < bytes, case .downloading(let count, _)? = try await stream.next() {
            latest = count
        }
        XCTAssertEqual(latest, bytes)
    }

    /// Asks the client's snapshot, for up to thirty seconds, until it lists every asset of `identifiers`.
    func waitUntilStored(_ identifiers: [AssetID]) async -> Bool {
        for _ in 0..<3_000 {
            if await client.locations(of: identifiers).count == identifiers.count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// `availability(of:)`, asked again for up to thirty seconds until it is `expected`: the
    /// snapshot it reads may trail a commit of the prefetch lane by about 0.2 s.
    func availability(of asset: ModelAsset, eventually expected: ModelAssetAvailability) async -> ModelAssetAvailability {
        var latest = await provider.availability(of: asset)
        for _ in 0..<600 where latest != expected {
            try? await Task.sleep(nanoseconds: 50_000_000)
            latest = await provider.availability(of: asset)
        }
        return latest
    }
}
