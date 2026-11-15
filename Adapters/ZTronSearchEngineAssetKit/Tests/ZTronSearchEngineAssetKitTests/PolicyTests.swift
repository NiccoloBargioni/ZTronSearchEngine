import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

/// The three download policies, the lane each one asks for, and the device conditions.
final class PolicyTests: XCTestCase {
    /// A host that keeps the prefetch lane off expensive networks, so `.wifiOnly` has a lane.
    private let wifiOnlyPrefetch = NetworkPolicy(prefetchOnExpensive: false, prefetchOnConstrained: false)

    // MARK: .never

    func testNeverDownloadsNothingAndFailsWithPolicyWhenAFileIsMissing() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json"])
        await harness.scriptDeliveries(of: model)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .never))
        }

        XCTAssertEqual(record.modelError, .policy)
        XCTAssertTrue(record.values.isEmpty)
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers)], "no request, no subscription")
    }

    func testNeverEndsWithAvailableWhenEveryFileIsStored() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .never))
        }

        let directory = try XCTUnwrap(record.directory)
        XCTAssertEqual(record.values, [.available(directory)])
    }

    func testNeverLeavesOlderBytesStoredAndFailsWithPolicy() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json", "tokenizer.json", "tokenizer_config.json"])
        let weights = model.identifier("model.safetensors")
        let blob = try await harness.client.preload(bytes(4_096, seed: 99), for: weights, isStale: true)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .never))
        }

        XCTAssertEqual(record.modelError, .policy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path), "replacing them would need a download")
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers)])
    }

    // MARK: Lanes

    func testWifiOnlyDownloadsNothingWhenNoLaneStaysOffExpensiveNetworks() async throws {
        // `NetworkPolicy()` lets every lane use cellular: nothing could keep this download off it.
        let harness = try Harness(for: self, network: NetworkPolicy())
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
        }

        XCTAssertEqual(record.modelError, .policy)
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers)])
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.wifiOnlyNotEnforceable])
    }

    func testWifiOnlyAsksOnTheLaneTheHostKeepsOffExpensiveNetworks() async throws {
        let cases: [(NetworkPolicy, AssetPriority)] = [
            (NetworkPolicy(prefetchOnExpensive: false), .prefetch),
            (NetworkPolicy(prefetchOnExpensive: false, userInitiatedOverridesPolicy: false), .userInitiated),
            (NetworkPolicy(bulkOnExpensive: false), .bulk),
        ]
        for (network, lane) in cases {
            let harness = try Harness(for: self, network: network)
            let model = ModelFixture.standard()
            await harness.scriptDeliveries(of: model)

            let record = try await withTimeLimit {
                await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
            }

            XCTAssertNotNil(record.directory, "\(network)")
            let lanes = await harness.client.lanes
            XCTAssertEqual(lanes, [lane], "\(network)")
        }
    }

    func testAllowCellularAsksOnTheUserInitiatedLane() async throws {
        for network in [NetworkPolicy(), wifiOnlyPrefetch] {
            let harness = try Harness(for: self, network: network)
            let model = ModelFixture.standard()
            await harness.scriptDeliveries(of: model)

            let record = try await withTimeLimit {
                await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
            }

            XCTAssertNotNil(record.directory)
            let lanes = await harness.client.lanes
            XCTAssertEqual(lanes, [.userInitiated])
        }
    }

    // MARK: Cellular conditions

    func testWifiOnlyFailsWithPolicyOnACellularNetworkAndWithdrawsItsRequests() async throws {
        let harness = try Harness(for: self, network: wifiOnlyPrefetch)
        let model = ModelFixture.standard()
        await harness.hold(model)
        await harness.client.setConditions(.cellular)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
        }

        XCTAssertEqual(record.modelError, .policy)
        XCTAssertEqual(record.values, [.downloading(bytes: 0, of: model.asset.totalBytes)])
        await harness.client.wait { $0.heldResolves == 0 && $0.subscribers == 0 }
        let stored = await harness.client.storedIdentifiers
        XCTAssertTrue(stored.isEmpty, "nothing was downloaded")
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.networkRefused(.wifiOnly, .cellular)])
        let availability = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(availability, .missing)
    }

    func testWifiOnlyStopsWhenTheNetworkTurnsCellularDuringTheDownload() async throws {
        let harness = try Harness(for: self, network: wifiOnlyPrefetch)
        let model = ModelFixture.standard()
        await harness.hold(model)
        await harness.client.setConditions(.wifi)
        let total = model.asset.totalBytes

        try await withTimeLimit {
            var stream = harness.provider.fetch(model.asset, policy: .wifiOnly).makeAsyncIterator()
            let first = try await stream.next()
            XCTAssertEqual(first, .downloading(bytes: 0, of: total))
            await harness.client.wait { $0.heldResolves == 4 }
            await harness.client.complete(model.identifier("config.json"))
            let second = try await stream.next()
            XCTAssertEqual(second, .downloading(bytes: 937, of: total))

            await harness.client.setConditions(.cellular)
            do {
                _ = try await stream.next()
                XCTFail("the stream went on over cellular")
            } catch {
                XCTAssertEqual(error as? ModelAssetError, .policy)
            }
            await harness.client.wait { $0.cancelledResolves == 3 && $0.subscribers == 0 }
        }
        // The file that arrived over Wi-Fi is kept for the retry.
        let stored = await harness.client.storedIdentifiers
        XCTAssertEqual(stored, [model.identifier("config.json")])
    }

    func testAllowCellularKeepsDownloadingOnACellularNetwork() async throws {
        let harness = try Harness(for: self, network: wifiOnlyPrefetch)
        let model = ModelFixture.standard()
        await harness.hold(model)
        await harness.client.setConditions(.cellular)

        let record = try await withTimeLimit {
            let reading = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 4 }
            await harness.client.setConditions(.lowDataWifi)
            await harness.client.setConditions(.cellular)
            await harness.complete(model)
            return await outcome(of: reading)
        }

        XCTAssertNotNil(record.directory, "the stream ended with \(String(describing: record.error))")
    }

    func testLowDataModeFailsWithPolicyOnALaneThatMayNotUseIt() async throws {
        let harness = try Harness(for: self, network: wifiOnlyPrefetch)
        let model = ModelFixture.standard()
        await harness.hold(model)
        await harness.client.setConditions(.lowDataWifi)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
        }

        XCTAssertEqual(record.modelError, .policy)
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.networkRefused(.wifiOnly, .lowDataWifi)])
    }

    func testLowPowerModeFailsWithPolicyOnALaneTheEngineParksInIt() async throws {
        // Only the bulk lane stays off cellular here, and the engine does not run bulk work in Low Power Mode.
        let harness = try Harness(for: self, network: NetworkPolicy(bulkOnExpensive: false), power: PowerPolicy(bulkInLowPowerMode: false))
        let model = ModelFixture.standard()
        await harness.hold(model)
        await harness.client.setConditions(.lowPowerWifi)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
        }

        XCTAssertEqual(record.modelError, .policy)
        let lanes = await harness.client.lanes
        XCTAssertTrue(lanes.isSubset(of: [.bulk]))
    }

    func testAnUnusablePathIsLeftForTheClientToReportAsOffline() async throws {
        let harness = try Harness(for: self, network: wifiOnlyPrefetch)
        let model = ModelFixture.standard()
        await harness.hold(model)
        await harness.client.setConditions(.offline)

        let record = try await withTimeLimit {
            let reading = Task { await collect(harness.provider.fetch(model.asset, policy: .wifiOnly)) }
            await harness.client.wait { $0.heldResolves == 4 }
            // The engine answers a waiter whose lane has no path with `.offline`.
            await harness.client.fail(model.identifier("model.safetensors"), with: .offline)
            return await outcome(of: reading)
        }

        XCTAssertEqual(record.modelError, .offline)
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.clientFailed(.resolve, .offline, reportedAs: .offline)])
    }
}
