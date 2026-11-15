import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

/// `availability(of:)` in each state of the store, and the directory it hands out.
final class AvailabilityTests: XCTestCase {
    private let names = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]

    // MARK: States

    func testNothingStoredIsMissingAndNothingIsRequested() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers)])
    }

    func testEveryFileStoredAndVerifiedIsAvailable() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)

        let availability = await harness.provider.availability(of: model.asset)

        guard case .available(let directory) = availability else {
            return XCTFail("expected .available, got \(availability)")
        }
        XCTAssertEqual(directory.deletingLastPathComponent().path, harness.models.path)
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers), .pin(Set(model.identifiers))])
    }

    func testSomeFilesStoredIsMissing() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json", "tokenizer.json"])

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
        let pinned = await harness.client.pinned
        XCTAssertTrue(pinned.isEmpty, "an incomplete model is not pinned")
    }

    func testStoredBytesThatAreNotTheDescribedOnesAreNotAvailable() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model, only: ["config.json", "tokenizer.json", "tokenizer_config.json"])
        try await harness.client.preload(bytes(4_096, seed: 77), for: model.identifier("model.safetensors"))

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
        let calls = await harness.client.calls
        XCTAssertEqual(calls, [.start, .locations(model.identifiers)], "availability reads; it deletes nothing")
    }

    func testABlobOfTheRightNameButAnotherRecordedSizeIsNotAvailable() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        let identifier = model.identifier("config.json")
        let stored = await harness.client.location(of: identifier)
        let location = try XCTUnwrap(stored)
        await harness.client.preload(
            AssetLocation(id: identifier, url: location.url, fileExtension: location.fileExtension, byteSize: 936, integrity: .verified, isStale: false)
        )

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
    }

    func testAStartFailureIsReportedAsFailed() async throws {
        let cases: [(AssetError, ModelAssetError)] = [
            (.storageUnavailable(.locked), .diskFull),
            (.storageUnavailable(.protectedDataUnavailable), .diskFull),
            (.shutDown, .offline),
        ]
        for (error, expected) in cases {
            let harness = try Harness(for: self)
            let model = ModelFixture.standard()
            try await harness.preload(model)
            await harness.client.failStart(with: error)

            let availability = await harness.provider.availability(of: model.asset)

            XCTAssertEqual(availability, .failed(expected), "\(error)")
            let diagnostics = await harness.diagnostics.entries()
            XCTAssertEqual(diagnostics, [.clientFailed(.start, error, reportedAs: expected)])
        }
    }

    func testAnUnusableDescriptorIsFailedWithoutAskingTheClient() async throws {
        let harness = try Harness(for: self)
        let asset = ModelAsset(id: "m", revision: "r", files: [ModelFile(name: "../config.json", byteCount: 3, sha256: String(repeating: "ab", count: 32))])

        let availability = await harness.provider.availability(of: asset)

        XCTAssertEqual(availability, .failed(.checksum))
        let calls = await harness.client.calls
        XCTAssertTrue(calls.isEmpty)
        let diagnostics = await harness.diagnostics.entries()
        guard case .invalidDescriptor(let assetID, let revision, _)? = diagnostics.first else {
            return XCTFail("expected an invalidDescriptor diagnostic, got \(diagnostics)")
        }
        XCTAssertEqual([assetID, revision], ["m", "r"])
        XCTAssertTrue(harness.provider.identifiers(of: asset).isEmpty)
    }

    func testAModelWithoutFilesIsAvailableInAnEmptyDirectory() async throws {
        let harness = try Harness(for: self)
        let asset = ModelAsset(id: "empty", revision: "r", files: [])

        let availability = await harness.provider.availability(of: asset)

        guard case .available(let directory) = availability else {
            return XCTFail("expected .available, got \(availability)")
        }
        XCTAssertEqual(try files(in: directory), [])
    }

    func testAnotherRevisionOfAStoredModelIsMissing() async throws {
        let harness = try Harness(for: self)
        let first = ModelFixture.standard(revision: "r1")
        let second = ModelFixture.standard(revision: "r2")
        try await harness.preload(first)

        let firstAvailability = await harness.provider.availability(of: first.asset)
        let secondAvailability = await harness.provider.availability(of: second.asset)

        guard case .available = firstAvailability else {
            return XCTFail("expected .available, got \(firstAvailability)")
        }
        XCTAssertEqual(secondAvailability, .missing, "the same files at another revision are another asset")
        XCTAssertTrue(Set(harness.provider.identifiers(of: first.asset)).isDisjoint(with: harness.provider.identifiers(of: second.asset)))
    }

    // MARK: The directory

    func testTheDirectoryHoldsEveryFileUnderItsOwnName() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)

        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }

        XCTAssertEqual(try files(in: directory), names)
        for name in names {
            let item = directory.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: item), model.data(name), name)
            let stored = await harness.client.location(of: model.identifier(name))
            let blob = try XCTUnwrap(stored).url
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: item.path), blob.path, "\(name) is a link to its blob")
        }
        XCTAssertEqual(directory.pathExtension, "", "the directory is named after the model, not after a file")
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("qwen3-test@r1-"))
    }

    func testASecondCallLeavesTheDirectoryUnchanged() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        let before = try snapshot(of: directory)

        let second = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(second, .available(directory))
        XCTAssertEqual(try snapshot(of: directory), before, "nothing was created again")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.models.path), [directory.lastPathComponent])
    }

    func testFilesInSubdirectoriesKeepTheirPaths() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture(
            id: "nested",
            revision: "r1",
            files: [("config.json", bytes(10, seed: 1)), ("weights/part-0.bin", bytes(20, seed: 2)), ("weights/deep/part-1.bin", bytes(30, seed: 3))]
        )
        try await harness.preload(model)

        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }

        XCTAssertEqual(try files(in: directory), ["config.json", "weights/deep/part-1.bin", "weights/part-0.bin"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("weights/deep/part-1.bin")), model.data("weights/deep/part-1.bin"))
        let again = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(again, .available(directory))
    }

    func testTwoFilesOfTheSameContentLinkToOneBlob() async throws {
        let harness = try Harness(for: self)
        let same = bytes(64, seed: 5)
        let model = ModelFixture(id: "twins", revision: "r1", files: [("a.json", same), ("b.json", same)])
        try await harness.preload(model)

        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }

        let first = try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("a.json").path)
        let second = try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("b.json").path)
        XCTAssertEqual(first, second)
    }

    func testAnythingElseInTheDirectoryIsRemoved() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        // A weight file the runtime would pick up by its extension.
        try Data("stray".utf8).write(to: directory.appendingPathComponent("old.safetensors"))

        let again = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(again, .available(directory))
        XCTAssertEqual(try files(in: directory), names)
    }

    func testTheLinksFollowABlobThatMoved() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        // The store's root changed (an app container that moved): same blob name, another path.
        let identifier = model.identifier("tokenizer.json")
        let stored = await harness.client.location(of: identifier)
        let old = try XCTUnwrap(stored)
        let moved = harness.scratch.appendingPathComponent("moved", isDirectory: true).appendingPathComponent(old.url.lastPathComponent)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old.url, to: moved)
        await harness.client.preload(
            AssetLocation(id: identifier, url: moved, fileExtension: old.fileExtension, byteSize: old.byteSize, integrity: .verified, isStale: false)
        )

        let again = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(again, .available(directory))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("tokenizer.json").path), moved.path)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("tokenizer.json")), model.data("tokenizer.json"))
    }

    // MARK: What the store lost

    func testTheDirectoryGoesWhenTheStoreNoLongerHoldsAFile() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        // The host purged, or the catalog dropped the entry and the store pruned it.
        _ = try await harness.client.purge(.scope(.identifiers([model.identifier("model.safetensors")])))

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "no directory with a dangling link is left behind")
    }

    func testTheDirectoryStaysWhileItsLinksHold() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        let before = try snapshot(of: directory)
        // The snapshot does not list a file whose blob is still on disk: it trails a download that
        // just finished, or the store is about to delete the blob.
        let weights = model.identifier("model.safetensors")
        let listed = await harness.client.location(of: weights)
        let location = try XCTUnwrap(listed)
        await harness.client.unlist(weights)

        let trailing = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(trailing, .missing)
        XCTAssertEqual(try snapshot(of: directory), before, "a directory that still works is not deleted on a missing listing")

        await harness.client.preload(location)
        let caughtUp = await harness.provider.availability(of: model.asset)
        XCTAssertEqual(caughtUp, .available(directory))
        XCTAssertEqual(try snapshot(of: directory), before)
    }

    func testABlobThatIsGoneFromTheDiskIsNotAvailable() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        let stored = await harness.client.location(of: model.identifier("model.safetensors"))
        try FileManager.default.removeItem(at: try XCTUnwrap(stored).url)

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
        let diagnostics = await harness.diagnostics.entries()
        XCTAssertEqual(diagnostics, [.damagedBlob(identifier: model.identifier("model.safetensors"), fileName: "model.safetensors")])
        let pinned = await harness.client.pinned
        XCTAssertTrue(pinned.isEmpty)
    }

    func testADirectoryWithABrokenLinkIsRemoved() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        guard case .available(let directory) = await harness.provider.availability(of: model.asset) else {
            return XCTFail("expected .available")
        }
        // The blob is gone from the disk while the store still lists it.
        let stored = await harness.client.location(of: model.identifier("config.json"))
        try FileManager.default.removeItem(at: try XCTUnwrap(stored).url)

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testABlobThatWasCutShortOnDiskIsNotAvailable() async throws {
        let harness = try Harness(for: self)
        let model = ModelFixture.standard()
        try await harness.preload(model)
        let stored = await harness.client.location(of: model.identifier("tokenizer.json"))
        try model.data("tokenizer.json").prefix(100).write(to: try XCTUnwrap(stored).url)

        let availability = await harness.provider.availability(of: model.asset)

        XCTAssertEqual(availability, .missing)
    }

    // MARK: - Helpers

    /// The inode and the link destination of the directory and of everything in it.
    private func snapshot(of directory: URL) throws -> [String: String] {
        var result = [".": String(try inode(of: directory))]
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let item = directory.appendingPathComponent(path)
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "-"
            result[path] = "\(try inode(of: item)) \(destination)"
        }
        return result
    }
}
