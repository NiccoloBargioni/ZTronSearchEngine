import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

/// Shared work, cancellation and `evict(_:)`.
final class SharingAndEvictionTests: XCTestCase {
    private let wifiOnlyPrefetch = NetworkPolicy(prefetchOnExpensive: false, prefetchOnConstrained: false)

    // MARK: Shared work

    func testConcurrentFetchesOfOneAssetShareTheirRequests() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)
        let total = model.asset.totalBytes

        let (first, second) = try await withTimeLimit {
            var one = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            var two = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            // Each stream has an element: both are attached before anything completes.
            let started = [try await one.next(), try await two.next()]
            XCTAssertEqual(started, [.downloading(bytes: 0, of: total), .downloading(bytes: 0, of: total)])
            await harness.client.wait { $0.heldResolves == 4 }
            await harness.complete(model)
            return (await drain(&one), await drain(&two))
        }

        let directory = try XCTUnwrap(first.directory, "the stream ended with \(String(describing: first.error))")
        XCTAssertEqual(second.directory, directory)
        let resolved = await harness.client.resolved
        XCTAssertEqual(resolved.count, 4, "one request per file, not one per stream")
        XCTAssertEqual(Set(resolved), Set(model.identifiers))
        let subscriptions = await harness.client.count(of: .subscribe)
        XCTAssertEqual(subscriptions, 1)
        for record in [first, second] {
            XCTAssertEqual(record.byteCounts, record.byteCounts.sorted())
            XCTAssertEqual(record.byteCounts.last, total)
        }
    }

    func testAStreamThatAttachesLaterStartsAtTheLatestProgress() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)
        let total = model.asset.totalBytes

        try await withTimeLimit {
            var early = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            _ = try await early.next()
            await harness.client.wait { $0.heldResolves == 4 }
            await harness.client.complete(model.identifier("tokenizer.json"))
            let progressed = try await early.next()
            XCTAssertEqual(progressed, .downloading(bytes: 2_048, of: total))

            var late = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            let first = try await late.next()
            XCTAssertEqual(first, .downloading(bytes: 2_048, of: total))

            await harness.complete(model)
            var last: ModelAssetAvailability?
            while let value = try await late.next() {
                last = value
            }
            guard case .available? = last else {
                return XCTFail("expected .available, got \(String(describing: last))")
            }
        }
        let resolved = await harness.client.resolved
        XCTAssertEqual(resolved.count, 4)
    }

    func testFetchesUnderDifferentPoliciesAskOnTheirOwnLanes() async throws {
        let harness = try Harness(for: self, network: wifiOnlyPrefetch)
        let model = ModelFixture.standard()
        await harness.hold(model)

        let (wifi, cellular) = try await withTimeLimit {
            let wifi = Task { await collect(harness.provider.fetch(model.asset, policy: .wifiOnly)) }
            let cellular = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 8 }
            // The network turns cellular: only the Wi-Fi fetch has to stop.
            await harness.client.setConditions(.cellular)
            let stopped = await outcome(of: wifi)
            await harness.complete(model)
            return (stopped, await outcome(of: cellular))
        }

        XCTAssertEqual(wifi.modelError, .policy)
        XCTAssertNotNil(cellular.directory)
        let lanes = await harness.client.lanes
        XCTAssertEqual(lanes, [.prefetch, .userInitiated])
    }

    // MARK: Cancellation

    func testCancellingTheOnlyReaderWithdrawsEveryRequest() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)

        let record = try await withTimeLimit {
            let reading = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 4 && $0.subscribers == 1 }
            reading.cancel()
            await harness.client.wait { $0.cancelledResolves == 4 && $0.subscribers == 0 }
            return await outcome(of: reading)
        }

        XCTAssertNil(record.directory)
        let stored = await harness.client.storedIdentifiers
        XCTAssertTrue(stored.isEmpty)
        let availability = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(availability, .missing, "no fetch is left running")
    }

    func testDroppingAStreamWithoutReadingItWithdrawsEveryRequest() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)

        try await withTimeLimit {
            var stream: AsyncThrowingStream<ModelAssetAvailability, any Error>? = harness.provider.fetch(model.asset, policy: .allowCellular)
            await harness.client.wait { $0.heldResolves == 4 }
            XCTAssertNotNil(stream)
            stream = nil
            await harness.client.wait { $0.cancelledResolves == 4 && $0.subscribers == 0 }
        }
    }

    func testCancellingOneOfTwoReadersKeepsTheFetchRunning() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)

        let record = try await withTimeLimit {
            var staying = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            _ = try await staying.next()
            let (attached, signal) = AsyncStream.makeStream(of: Void.self)
            let leaving = Task {
                await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) { signal.yield() }
            }
            for await _ in attached {
                break
            }
            await harness.client.wait { $0.heldResolves == 4 }

            leaving.cancel()
            _ = await outcome(of: leaving)
            await harness.complete(model)
            return await drain(&staying)
        }

        XCTAssertNotNil(record.directory, "the stream ended with \(String(describing: record.error))")
        let census = await harness.client.census
        XCTAssertEqual(census.cancelledResolves, 0, "the reader that stayed still wanted every file")
        let resolved = await harness.client.resolved
        XCTAssertEqual(resolved.count, 4)
    }

    func testAFetchAfterACancelledOneStartsAgain() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)

        let record = try await withTimeLimit {
            let first = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 4 }
            await harness.client.complete(model.identifier("config.json"))
            await harness.client.wait { $0.stored == 1 }
            first.cancel()
            _ = await outcome(of: first)
            await harness.client.wait { $0.cancelledResolves == 3 }

            await harness.scriptDeliveries(of: model)
            return await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertNotNil(record.directory)
        XCTAssertEqual(record.values.first, .downloading(bytes: 937, of: model.asset.totalBytes), "the file stored before the cancellation is kept")
        let resolved = await harness.client.resolved
        XCTAssertEqual(resolved.count, 4 + 3)
    }

    // MARK: Evict

    func testEvictRemovesThePinsTheFilesAndTheDirectory() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        let identifiers = Set(model.identifiers)
        let pinnedBefore = await harness.client.pinned
        XCTAssertEqual(pinnedBefore, identifiers)

        try await harness.provider.evict(model.asset)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let pinned = await harness.client.pinned
        XCTAssertTrue(pinned.isEmpty)
        let stored = await harness.client.storedIdentifiers
        XCTAssertTrue(stored.isEmpty)
        let calls = await harness.client.calls
        XCTAssertEqual(Array(calls.suffix(2)), [.unpin(identifiers), .purge(.scope(.identifiers(identifiers)))])
        let availability = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(availability, .missing)
    }

    func testEvictStopsARunningFetch() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)

        let record = try await withTimeLimit {
            let reading = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 4 }
            try await harness.provider.evict(model.asset)
            await harness.client.wait { $0.cancelledResolves == 4 && $0.subscribers == 0 }
            return await outcome(of: reading)
        }

        XCTAssertTrue(record.error is CancellationError, "got \(String(describing: record.error))")
    }

    func testEvictLetsARejectedModelBeFetchedAgain() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)
        let weights = model.identifier("model.safetensors")
        await harness.client.script(.deliver(bytes(4_096, seed: 99)), for: weights)
        let rejected = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }
        XCTAssertEqual(rejected.modelError, .checksum)
        let before = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(before, .failed(.checksum))

        try await harness.provider.evict(model.asset)

        let after = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(after, .missing)
        // The catalog now publishes the described bytes.
        await harness.client.script(.deliver(model.data("model.safetensors")), for: weights)
        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }
        XCTAssertNotNil(record.directory)
    }

    func testEvictReportsAPurgeThatFailed() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        await harness.client.failPurge(with: .storageUnavailable(.degradedReadOnly))

        do {
            try await harness.provider.evict(model.asset)
            XCTFail("evict returned although nothing was deleted")
        } catch {
            XCTAssertEqual(error as? ModelAssetError, .diskFull)
        }
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.clientFailed(.purge, .storageUnavailable(.degradedReadOnly), reportedAs: .diskFull)])
    }

    func testEvictingOneRevisionLeavesTheOtherAvailable() async throws {
        let harness = try Harness(for: self)
        let first = ModelFixture.standard(revision: "r1")
        let second = ModelFixture.standard(revision: "r2")
        // The two revisions hold the same bytes, so the store keeps one blob per file for both.
        try await harness.preload(first)
        try await harness.preload(second)
        guard case .available(let firstDirectory) = await harness.provider.availability(of: first.asset),
            case .available(let secondDirectory) = await harness.provider.availability(of: second.asset)
        else {
            return XCTFail("expected both revisions to be available")
        }
        XCTAssertNotEqual(firstDirectory, secondDirectory)

        try await harness.provider.evict(first.asset)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
        let remaining = await harness.provider.availability(of: second.asset)
        XCTAssertEqual(remaining, .available(secondDirectory))
        XCTAssertEqual(try Data(contentsOf: secondDirectory.appendingPathComponent("model.safetensors")), second.data("model.safetensors"))
        let firstAfter = await harness.provider.availability(of: first.asset)
        XCTAssertEqual(firstAfter, .missing)
    }
}
