import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

/// `fetch(_:policy:)`: progress, resume, verification and error mapping.
final class FetchTests: XCTestCase {
    // MARK: Progress and completion

    func testFetchDownloadsWhatIsMissingAndEndsWithAvailable() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")
        XCTAssertEqual(record.values.first, .downloading(bytes: 0, of: model.asset.totalBytes))
        XCTAssertEqual(record.byteCounts, record.byteCounts.sorted(), "the byte count never falls")
        XCTAssertEqual(record.byteCounts.last, model.asset.totalBytes)
        XCTAssertEqual(try files(in: directory), ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.safetensors")), model.data("model.safetensors"))

        let resolved = await harness.client.resolved
        XCTAssertEqual(Set(resolved), Set(model.identifiers))
        XCTAssertEqual(resolved.count, 4, "each missing file is requested once")
        let pinned = await harness.client.pinned
        XCTAssertEqual(pinned, Set(model.identifiers))
        let availability = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(availability, .available(directory))
    }

    func testProgressCountsEveryFileAndNeverFalls() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)
        let total = model.asset.totalBytes
        let weights = model.identifier("model.safetensors")

        try await withTimeLimit {
            var stream = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            let first = try await stream.next()
            XCTAssertEqual(first, .downloading(bytes: 0, of: total))
            await harness.client.wait { $0.heldResolves == 4 }

            await harness.client.emit(.transferProgress(weights, TransferProgress(received: 1_000, expected: 4_096)))
            let second = try await stream.next()
            XCTAssertEqual(second, .downloading(bytes: 1_000, of: total))

            // A transfer that started again reports less; an unrelated asset reports something. Neither shows.
            await harness.client.emit(.transferProgress(weights, TransferProgress(received: 200, expected: 4_096)))
            await harness.client.emit(.transferProgress("carousel/page-1", TransferProgress(received: 9_999, expected: nil)))
            await harness.client.emit(.transferProgress(weights, TransferProgress(received: 3_000, expected: 4_096)))
            let third = try await stream.next()
            XCTAssertEqual(third, .downloading(bytes: 3_000, of: total))

            await harness.client.complete(model.identifier("config.json"))
            let fourth = try await stream.next()
            XCTAssertEqual(fourth, .downloading(bytes: 3_937, of: total))

            await harness.client.complete(weights)
            let fifth = try await stream.next()
            XCTAssertEqual(fifth, .downloading(bytes: 937 + 4_096, of: total))

            await harness.client.complete(model.identifier("tokenizer.json"))
            let sixth = try await stream.next()
            XCTAssertEqual(sixth, .downloading(bytes: 937 + 4_096 + 2_048, of: total))

            await harness.client.complete(model.identifier("tokenizer_config.json"))
            let seventh = try await stream.next()
            XCTAssertEqual(seventh, .downloading(bytes: total, of: total))

            let last = try await stream.next()
            guard case .available(let directory)? = last else {
                return XCTFail("expected .available, got \(String(describing: last))")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
            let end = try await stream.next()
            XCTAssertNil(end)
        }
    }

    func testAvailabilityIsDownloadingWhileAFetchRuns() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json"])
        for name in ["model.safetensors", "tokenizer.json", "tokenizer_config.json"] {
            await harness.client.script(.hold(model.data(name)), for: model.identifier(name))
        }
        let total = model.asset.totalBytes

        try await withTimeLimit {
            var stream = harness.provider.fetch(model.asset, policy: .allowCellular).makeAsyncIterator()
            let first = try await stream.next()
            XCTAssertEqual(first, .downloading(bytes: 937, of: total), "a fetch starts at the bytes that are stored")

            let during = await harness.provider.availability(of: model.asset)
            XCTAssertEqual(during, .downloading(bytes: 937, of: total))

            await harness.client.wait { $0.heldResolves == 3 }
            for name in ["model.safetensors", "tokenizer.json", "tokenizer_config.json"] {
                await harness.client.complete(model.identifier(name))
            }
            var last: ModelAssetAvailability?
            while let value = try await stream.next() {
                last = value
            }
            guard case .available(let directory)? = last else {
                return XCTFail("expected .available, got \(String(describing: last))")
            }
            let after = await harness.provider.availability(of: model.asset)
            XCTAssertEqual(after, .available(directory))
        }
    }

    // MARK: Resume

    func testFetchIsANoOpWhenEveryFileIsStoredAndVerified() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
        }

        let directory = try XCTUnwrap(record.directory)
        XCTAssertEqual(record.values, [.available(directory)])
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers), .pin(Set(model.identifiers))], "nothing is requested and nobody subscribes")
    }

    func testARetryRequestsOnlyTheFilesThatAreNotStored() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json", "tokenizer.json", "tokenizer_config.json"])
        await harness.client.script(.deliver(model.data("model.safetensors")), for: model.identifier("model.safetensors"))

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertNotNil(record.directory)
        XCTAssertEqual(record.values.first, .downloading(bytes: 937 + 2_048 + 512, of: model.asset.totalBytes))
        let resolved = await harness.client.resolved
        XCTAssertEqual(resolved, [model.identifier("model.safetensors")], "stored and verified files are not requested again")
    }

    func testAFetchThatFailedResumesWithTheFilesItStored() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)
        await harness.client.script(.hold(model.data("model.safetensors")), for: model.identifier("model.safetensors"))

        try await withTimeLimit {
            // First attempt: the small files arrive, then the network goes away during the large one.
            let first = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 1 && $0.stored == 3 }
            let stored = await harness.client.storedIdentifiers
            XCTAssertEqual(stored, Set(model.identifiers).subtracting([model.identifier("model.safetensors")]))
            await harness.client.fail(model.identifier("model.safetensors"), with: .offline)
            let failed = await outcome(of: first)
            XCTAssertEqual(failed.modelError, .offline)
            let between = await harness.provider.availability(of: model.asset)
            XCTAssertEqual(between, .missing)

            // Second attempt.
            let before = await harness.client.resolved.count
            await harness.client.script(.deliver(model.data("model.safetensors")), for: model.identifier("model.safetensors"))
            let second = await collect(harness.provider.fetch(model.asset, policy: .allowCellular))

            XCTAssertNotNil(second.directory)
            XCTAssertEqual(second.values.first, .downloading(bytes: 937 + 2_048 + 512, of: model.asset.totalBytes))
            let resolved = await harness.client.resolved
            XCTAssertEqual(Array(resolved[before...]), [model.identifier("model.safetensors")])
        }
    }

    // MARK: Verification

    func testBytesTheStoreRejectedFailWithChecksumAndNothingIsStored() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)
        // ZTronAssetKit hashed the download, found another checksum than the manifest's and deleted the staged bytes.
        await harness.client.script(.fail(.integrityFailure), for: model.identifier("model.safetensors"))

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertEqual(record.modelError, .checksum)
        XCTAssertNil(record.directory)
        let stored = await harness.client.storedIdentifiers
        XCTAssertFalse(stored.contains(model.identifier("model.safetensors")))
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.clientFailed(.resolve, .integrityFailure, reportedAs: .checksum)])
        let availability = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(availability, .missing, "ZTronAssetKit keeps the failure and its backoff; the bridge adds none")
    }

    func testDownloadedBytesThatAreNotTheDescribedOnesAreDeletedBeforeFailingWithChecksum() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)
        // The catalog publishes other bytes under this identifier: ZTronAssetKit verifies them against
        // the catalog's own checksum and stores them.
        let other = bytes(4_096, seed: 99)
        let weights = model.identifier("model.safetensors")
        await harness.client.script(.deliver(other), for: weights)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertEqual(record.modelError, .checksum)
        let purges = await harness.client.count(of: .purge(.scope(.identifiers([weights]))))
        XCTAssertEqual(purges, 1, "the mismatched file is removed through the client")
        let stored = await harness.client.storedIdentifiers
        XCTAssertFalse(stored.contains(weights))
        let blob = harness.client.root.appendingPathComponent("blobs/\(sha256Hex(other).prefix(2))/\(sha256Hex(other)).bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(
            diagnostics,
            [.contentMismatch(identifier: weights, fileName: "model.safetensors", expectedSHA256: sha256Hex(model.data("model.safetensors")), storedSHA256: sha256Hex(other))]
        )

        // The catalog would deliver the same bytes again: the model is not fetched a second time.
        let callsBefore = await harness.client.calls.count
        let availability = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(availability, .failed(.checksum))
        let again = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }
        XCTAssertEqual(again.modelError, .checksum)
        let callsAfter = await harness.client.calls.count
        XCTAssertEqual(callsAfter, callsBefore, "no second download of bytes that are known to be wrong")
    }

    func testTheOtherRequestsAreWithdrawnBeforeAMismatchedDownloadIsDeleted() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.hold(model)
        let config = model.identifier("config.json")
        await harness.client.script(.hold(bytes(937, seed: 99)), for: config)

        let record = try await withTimeLimit {
            let reading = Task { await collect(harness.provider.fetch(model.asset, policy: .allowCellular)) }
            await harness.client.wait { $0.heldResolves == 4 }
            // The small file arrives first and is not the described one, while the weights are in transit.
            await harness.client.complete(config)
            return await outcome(of: reading)
        }

        XCTAssertEqual(record.modelError, .checksum)
        let heldAtPurge = await harness.client.heldResolvesAtPurge
        XCTAssertEqual(heldAtPurge, [0], "nothing keeps downloading while the purge waits for the store")
        let cancelled = await harness.client.cancelledResolves
        XCTAssertEqual(cancelled.count, 3)
    }

    func testStoredBytesThatContradictTheDescriptorAreDeletedBeforeFailingWithChecksum() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json", "tokenizer.json", "tokenizer_config.json"])
        let weights = model.identifier("model.safetensors")
        let blob = try await harness.client.preload(bytes(4_096, seed: 99), for: weights)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .wifiOnly))
        }

        XCTAssertEqual(record.modelError, .checksum)
        XCTAssertTrue(record.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers), .purge(.scope(.identifiers([weights])))], "nothing is downloaded")
    }

    func testADescriptorWhoseSizeContradictsItsChecksumFailsWithChecksumAndKeepsTheBytes() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        // The same files, with a size for the weights that their SHA-256 does not have.
        let asset = ModelAsset(
            id: model.asset.id,
            revision: model.asset.revision,
            files: model.asset.files.map { file in
                file.name == "model.safetensors" ? ModelFile(name: file.name, byteCount: file.byteCount + 1, sha256: file.sha256) : file
            }
        )

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(asset, policy: .allowCellular))
        }

        XCTAssertEqual(record.modelError, .checksum)
        let stored = await harness.client.storedIdentifiers
        XCTAssertEqual(stored, Set(model.identifiers), "bytes that carry the described SHA-256 are not deleted")
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers)])
        let diagnostics = await harness.diagnostics.entries()
        guard case .invalidDescriptor(_, _, let reason)? = diagnostics.first, diagnostics.count == 1 else {
            return XCTFail("expected one invalidDescriptor diagnostic, got \(diagnostics)")
        }
        XCTAssertTrue(reason.contains("model.safetensors"))
    }

    func testOlderBytesAreReplacedWhenTheCatalogAnnouncesNewContent() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json", "tokenizer.json", "tokenizer_config.json"])
        let weights = model.identifier("model.safetensors")
        try await harness.client.preload(bytes(4_096, seed: 99), for: weights, isStale: true)
        await harness.client.script(.deliver(model.data("model.safetensors")), for: weights)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        let directory = try XCTUnwrap(record.directory, "the stream ended with \(String(describing: record.error))")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.safetensors")), model.data("model.safetensors"))
        let calls = await harness.client.calls
        let purge = try XCTUnwrap(calls.firstIndex(of: .purge(.scope(.identifiers([weights])))))
        let resolve = try XCTUnwrap(calls.firstIndex(of: .resolve(weights, .userInitiated)))
        XCTAssertLessThan(purge, resolve, "the stored copy goes first: a stored asset is answered without a transfer")
    }

    func testABlobThatIsGoneFromTheDiskIsDownloadedAgain() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        let weights = model.identifier("model.safetensors")
        let stored = await harness.client.location(of: weights)
        let blob = try XCTUnwrap(stored).url
        try FileManager.default.removeItem(at: blob)
        await harness.client.script(.deliver(model.data("model.safetensors")), for: weights)

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertNotNil(record.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        let resolved = await harness.client.resolved
        XCTAssertEqual(resolved, [weights])
        let purges = await harness.client.count(of: .purge(.scope(.identifiers([weights]))))
        XCTAssertEqual(purges, 1)
    }

    func testAnUnusableDescriptorFailsWithChecksum() async throws {
        let harness = try Harness(for: self)
        let asset = ModelAsset(id: "m", revision: "r", files: [ModelFile(name: "config.json", byteCount: 3, sha256: "not a checksum")])

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(asset, policy: .allowCellular))
        }

        XCTAssertEqual(record.modelError, .checksum)
        let calls = await harness.client.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Error mapping

    func testClientErrorsMapToTheFourBoundaryErrors() async throws {
        let cases: [(AssetError, ModelAssetError)] = [
            (.offline, .offline),
            (.serverUnavailable(retryAfter: 30), .offline),
            (.authRejected(.confirmed), .offline),
            (.authRejected(.ambiguous), .offline),
            (.shutDown, .offline),
            (.integrityFailure, .checksum),
            (.notFound, .checksum),
            (.insufficientSpace(required: 968_080_210, available: 1_024), .diskFull),
            (.storageUnavailable(.degradedReadOnly), .diskFull),
            (.storageUnavailable(.ioFailure), .diskFull),
        ]
        for (error, expected) in cases {
            let harness = try Harness(for: self)
            let model = ModelFixture.standard()
            await harness.hold(model)
            await harness.client.script(.fail(error), for: model.identifier("model.safetensors"))

            let record = try await withTimeLimit {
                await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
            }

            XCTAssertEqual(record.modelError, expected, "\(error)")
            let diagnostics = await harness.diagnostics.entries()
            XCTAssertEqual(diagnostics, [.clientFailed(.resolve, error, reportedAs: expected)], "\(error)")
            await harness.client.wait { $0.heldResolves == 0 && $0.subscribers == 0 }
        }
    }

    func testAFailureToStartOrToSubscribeFailsTheFetch() async throws {
        let model = ModelFixture.standard()

        let unopened = try Harness(for: self)
        await unopened.client.failStart(with: .storageUnavailable(.locked))
        let first = try await withTimeLimit {
            await collect(unopened.provider.fetch(model.asset, policy: .allowCellular))
        }
        XCTAssertEqual(first.modelError, .diskFull)

        let deaf = try Harness(for: self)
        await deaf.scriptDeliveries(of: model)
        await deaf.client.failSubscribe(with: .shutDown)
        let second = try await withTimeLimit {
            await collect(deaf.provider.fetch(model.asset, policy: .allowCellular))
        }
        XCTAssertEqual(second.modelError, .offline)
        let resolved = await deaf.client.resolved
        XCTAssertTrue(resolved.isEmpty)
    }

    func testARequestTheClientCancelledEndsTheStreamWithCancellation() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        await harness.scriptDeliveries(of: model)
        await harness.client.script(.fail(.cancelled), for: model.identifier("config.json"))

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertTrue(record.error is CancellationError, "got \(String(describing: record.error))")
    }

    func testTheModelFilesOfACustomMappingAreRequestedUnderItsIdentifiers() async throws {
        let harness = try Harness(for: self, identifier: { asset, file in AssetID("llm.\(asset.revision).\(file.name)") })
        let model = ModelFixture.standard()
        for file in model.asset.files {
            await harness.client.script(.deliver(model.data(file.name)), for: AssetID("llm.r1.\(file.name)"))
        }

        let record = try await withTimeLimit {
            await collect(harness.provider.fetch(model.asset, policy: .allowCellular))
        }

        XCTAssertNotNil(record.directory)
        let resolved = await harness.client.resolved
        XCTAssertEqual(Set(resolved), Set(model.asset.files.map { AssetID("llm.r1.\($0.name)") }))
        XCTAssertEqual(harness.provider.identifiers(of: model.asset), model.asset.files.map { AssetID("llm.r1.\($0.name)") })
    }
}
