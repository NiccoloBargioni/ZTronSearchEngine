import Foundation
import XCTest
import ZTronAssetKit
import ZTronSearchEngine
@testable import ZTronSearchEngineAssetKit

/// The pure parts: descriptor checks, the identifier mapping, blob names, lanes and byte counts.
final class PlanAndLaneTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)

    private func plan(_ files: [ModelFile], id: String = "m", revision: String = "r") throws(InvalidDescriptor) -> ModelAssetPlan {
        try ModelAssetPlan(asset: ModelAsset(id: id, revision: revision, files: files), identifier: AssetKitModelAssetProvider.defaultIdentifier)
    }

    private func reason(_ files: [ModelFile]) -> String? {
        do {
            _ = try plan(files)
            return nil
        } catch {
            return error.reason
        }
    }

    // MARK: Identifier mapping

    func testTheDefaultIdentifierNamesTheModelTheRevisionAndTheFile() {
        let asset = ModelAsset(id: "qwen3-1.7b-4bit", revision: "3b1b176", files: [])
        let file = ModelFile(name: "config.json", byteCount: 1, sha256: sha)
        XCTAssertEqual(
            AssetKitModelAssetProvider.defaultIdentifier(asset: asset, file: file),
            AssetID("model/qwen3-1.7b-4bit@3b1b176/config.json")
        )
    }

    func testAnotherRevisionMapsToOtherIdentifiersAndAnotherDirectory() throws {
        let files = [ModelFile(name: "config.json", byteCount: 1, sha256: sha)]
        let first = try plan(files, revision: "r1")
        let second = try plan(files, revision: "r2")
        XCTAssertEqual(first.identifiers, [AssetID("model/m@r1/config.json")])
        XCTAssertEqual(second.identifiers, [AssetID("model/m@r2/config.json")])
        XCTAssertNotEqual(first.directoryName, second.directoryName)
    }

    func testTwoNamesMappedToOneAssetOfTheSameContentShareIt() throws {
        let files = [
            ModelFile(name: "a.json", byteCount: 3, sha256: sha),
            ModelFile(name: "b.json", byteCount: 3, sha256: sha),
        ]
        let shared = try ModelAssetPlan(asset: ModelAsset(id: "m", revision: "r", files: files)) { _, _ in "shared" }
        XCTAssertEqual(shared.identifiers, ["shared"])
        XCTAssertEqual(shared.entries(of: "shared").map(\.file.name), ["a.json", "b.json"])
    }

    // MARK: Descriptor checks

    func testAnUppercaseChecksumIsAccepted() throws {
        let plan = try plan([ModelFile(name: "config.json", byteCount: 1, sha256: sha.uppercased())])
        XCTAssertEqual(plan.entries[0].sha256, sha)
    }

    func testUnusableDescriptorsAreRefused() {
        XCTAssertNotNil(reason([ModelFile(name: "a", byteCount: 1, sha256: "")]))
        XCTAssertNotNil(reason([ModelFile(name: "a", byteCount: 1, sha256: String(repeating: "g", count: 64))]))
        XCTAssertNotNil(reason([ModelFile(name: "a", byteCount: 1, sha256: String(repeating: "a", count: 63))]))
        XCTAssertNotNil(reason([ModelFile(name: "a", byteCount: -1, sha256: sha)]))
        for name in ["", "/etc/passwd", "../outside", "a/../b", "a//b", "a/", "./a", "a\0b"] {
            XCTAssertNotNil(reason([ModelFile(name: name, byteCount: 1, sha256: sha)]), "'\(name)' was accepted")
        }
    }

    func testCollidingNamesAreRefused() {
        let file = ModelFile(name: "config.json", byteCount: 1, sha256: sha)
        XCTAssertNotNil(reason([file, file]))
        XCTAssertNotNil(reason([file, ModelFile(name: "Config.JSON", byteCount: 1, sha256: sha)]))
        XCTAssertNotNil(reason([ModelFile(name: "weights", byteCount: 1, sha256: sha), ModelFile(name: "weights/part.bin", byteCount: 1, sha256: sha)]))
    }

    func testDifferentContentMappedToOneAssetIsRefused() {
        let files = [
            ModelFile(name: "a.json", byteCount: 3, sha256: sha),
            ModelFile(name: "b.json", byteCount: 3, sha256: String(repeating: "cd", count: 32)),
        ]
        XCTAssertThrowsError(try ModelAssetPlan(asset: ModelAsset(id: "m", revision: "r", files: files)) { _, _ in "shared" })
    }

    func testNestedNamesBecomePathComponents() throws {
        let plan = try plan([ModelFile(name: "weights/part-0.bin", byteCount: 1, sha256: sha)])
        XCTAssertEqual(plan.entries[0].pathComponents, ["weights", "part-0.bin"])
    }

    func testTheDirectoryNameIsOneSafePathComponent() throws {
        let plan = try plan([ModelFile(name: "config.json", byteCount: 1, sha256: sha)], id: "mlx-community/Qwen3 1.7B", revision: "../main")
        XCTAssertFalse(plan.directoryName.contains("/"))
        XCTAssertFalse(plan.directoryName.contains(" "))
        XCTAssertFalse(plan.directoryName.hasPrefix("."))
        XCTAssertTrue(plan.directoryName.hasPrefix("mlx-community_Qwen3_1.7B@.._main-"))
    }

    func testTheDirectoryNameNeverStartsWithADot() throws {
        let plan = try plan([ModelFile(name: "config.json", byteCount: 1, sha256: sha)], id: ".hidden", revision: "r")
        XCTAssertTrue(plan.directoryName.hasPrefix("_.hidden@r-"))
        let unnamed = try self.plan([ModelFile(name: "config.json", byteCount: 1, sha256: sha)], id: "", revision: "")
        XCTAssertTrue(unnamed.directoryName.hasPrefix("@-"))
    }

    func testTheDirectoryNameDependsOnTheFiles() throws {
        let one = try plan([ModelFile(name: "config.json", byteCount: 1, sha256: sha)])
        let other = try plan([ModelFile(name: "config.json", byteCount: 2, sha256: sha)])
        let again = try plan([ModelFile(name: "config.json", byteCount: 1, sha256: sha)])
        XCTAssertNotEqual(one.directoryName, other.directoryName)
        XCTAssertEqual(one.directoryName, again.directoryName)
    }

    // MARK: Blob names

    func testABlobURLYieldsTheHashItIsNamedBy() {
        let url = URL(fileURLWithPath: "/store/ZTronAssetKit/v1/blobs/ab/\(sha).bin")
        XCTAssertEqual(StoredBlob.contentHash(of: url), sha)
    }

    func testOtherNamesYieldNoHash() {
        for name in ["model.safetensors", "\(sha)", "\(sha).", "\(sha.uppercased()).bin", "\(sha).tar.gz", "\(sha.dropLast()).bin", "x\(sha).bin"] {
            XCTAssertNil(StoredBlob.contentHash(of: URL(fileURLWithPath: "/store/blobs/ab/\(name)")), "'\(name)' was read as a blob name")
        }
    }

    // MARK: Lanes

    func testNeverHasNoLane() {
        XCTAssertNil(AssetKitModelAssetProvider.lane(for: .never, under: NetworkPolicy()))
    }

    func testWifiOnlyHasNoLaneUnderTheDefaultNetworkPolicy() {
        XCTAssertNil(AssetKitModelAssetProvider.lane(for: .wifiOnly, under: NetworkPolicy()))
    }

    func testWifiOnlyTakesTheMostUrgentLaneThatStaysOffExpensiveNetworks() {
        XCTAssertEqual(
            AssetKitModelAssetProvider.lane(for: .wifiOnly, under: NetworkPolicy(prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)),
            .userInitiated
        )
        XCTAssertEqual(AssetKitModelAssetProvider.lane(for: .wifiOnly, under: NetworkPolicy(prefetchOnExpensive: false)), .prefetch)
        XCTAssertEqual(AssetKitModelAssetProvider.lane(for: .wifiOnly, under: NetworkPolicy(bulkOnExpensive: false)), .bulk)
        XCTAssertEqual(
            AssetKitModelAssetProvider.lane(for: .wifiOnly, under: NetworkPolicy(bulkOnExpensive: false, prefetchOnExpensive: false)),
            .prefetch
        )
        // Without the override the user-initiated lane follows the prefetch rules, which allow cellular here.
        XCTAssertNil(AssetKitModelAssetProvider.lane(for: .wifiOnly, under: NetworkPolicy(userInitiatedOverridesPolicy: false)))
    }

    func testAllowCellularTakesTheMostUrgentLaneThatMayUseExpensiveNetworks() {
        XCTAssertEqual(AssetKitModelAssetProvider.lane(for: .allowCellular, under: NetworkPolicy()), .userInitiated)
        XCTAssertEqual(AssetKitModelAssetProvider.lane(for: .allowCellular, under: NetworkPolicy(prefetchOnExpensive: false)), .userInitiated)
        XCTAssertEqual(
            AssetKitModelAssetProvider.lane(for: .allowCellular, under: NetworkPolicy(prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)),
            .bulk
        )
        XCTAssertEqual(
            AssetKitModelAssetProvider.lane(
                for: .allowCellular,
                under: NetworkPolicy(bulkOnExpensive: false, prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)
            ),
            .userInitiated
        )
    }

    func testALaneRepeatsTheEnginesPermissions() {
        let network = NetworkPolicy(bulkOnExpensive: false, bulkOnConstrained: true, prefetchOnExpensive: true, prefetchOnConstrained: false)
        let power = PowerPolicy(bulkInLowPowerMode: false, prefetchInLowPowerMode: true)

        let user = DownloadLane(priority: .userInitiated, network: network, power: power)
        XCTAssertEqual([user.allowsExpensive, user.allowsConstrained, user.allowsLowPowerMode], [true, true, true])

        var restricted = network
        restricted.userInitiatedOverridesPolicy = false
        let followingPrefetch = DownloadLane(priority: .userInitiated, network: restricted, power: power)
        XCTAssertEqual([followingPrefetch.allowsExpensive, followingPrefetch.allowsConstrained, followingPrefetch.allowsLowPowerMode], [true, false, true])

        let prefetch = DownloadLane(priority: .prefetch, network: network, power: power)
        XCTAssertEqual([prefetch.allowsExpensive, prefetch.allowsConstrained, prefetch.allowsLowPowerMode], [true, false, true])

        let bulk = DownloadLane(priority: .bulk, network: network, power: power)
        XCTAssertEqual([bulk.allowsExpensive, bulk.allowsConstrained, bulk.allowsLowPowerMode], [false, true, false])
    }

    func testALaneIsRefusedOnlyOnAUsableNetworkItMayNotUse() {
        let lane = DownloadLane(priority: .prefetch, network: NetworkPolicy(prefetchOnExpensive: false), power: PowerPolicy(prefetchInLowPowerMode: false))
        XCTAssertFalse(lane.isRefused(under: .wifi))
        XCTAssertTrue(lane.isRefused(under: .cellular))
        XCTAssertTrue(lane.isRefused(under: .lowDataWifi))
        XCTAssertTrue(lane.isRefused(under: .lowPowerWifi))
        XCTAssertFalse(lane.isRefused(under: .offline))

        let thermal = DeviceConditions(
            network: NetworkConditions(satisfied: true, expensive: false, constrained: false),
            power: PowerConditions(lowPowerMode: false, thermal: .critical)
        )
        XCTAssertFalse(lane.isRefused(under: thermal))

        let open = DownloadLane(priority: .userInitiated, network: NetworkPolicy(), power: PowerPolicy())
        XCTAssertFalse(open.isRefused(under: .cellular))
        XCTAssertFalse(open.isRefused(under: .lowDataWifi))
        XCTAssertFalse(open.isRefused(under: .lowPowerWifi))
    }

    // MARK: Byte counts

    func testByteCountsNeverFallAndStopAtTheFileSize() throws {
        let model = ModelFixture.standard()
        let plan = try ModelAssetPlan(asset: model.asset, identifier: AssetKitModelAssetProvider.defaultIdentifier)
        var ledger = ProgressLedger(plan: plan, stored: [model.identifier("config.json")])
        XCTAssertEqual(ledger.bytes, 937)

        XCTAssertTrue(ledger.record(1_000, for: model.identifier("model.safetensors")))
        XCTAssertEqual(ledger.bytes, 1_937)
        XCTAssertFalse(ledger.record(400, for: model.identifier("model.safetensors")), "a count that falls is ignored")
        XCTAssertEqual(ledger.bytes, 1_937)
        XCTAssertTrue(ledger.record(1_000_000, for: model.identifier("model.safetensors")))
        XCTAssertEqual(ledger.bytes, 937 + 4_096)
        XCTAssertFalse(ledger.record(10, for: "another/asset"))
        XCTAssertFalse(ledger.complete(model.identifier("config.json")), "a stored file is counted already")

        XCTAssertTrue(ledger.complete(model.identifier("tokenizer.json")))
        XCTAssertTrue(ledger.complete(model.identifier("tokenizer_config.json")))
        XCTAssertEqual(ledger.bytes, model.asset.totalBytes)
    }

    func testProgressOfOneContentIsCreditedToEveryFileThatHasIt() throws {
        let same = bytes(1_000, seed: 9)
        let model = ModelFixture(id: "m", revision: "r", files: [("a.bin", same), ("b.bin", same), ("c.bin", bytes(10, seed: 8))])
        let plan = try ModelAssetPlan(asset: model.asset, identifier: AssetKitModelAssetProvider.defaultIdentifier)
        var ledger = ProgressLedger(plan: plan, stored: [])

        // ZTronAssetKit reports one transfer of the shared content under one of its identifiers.
        XCTAssertTrue(ledger.record(600, for: model.identifier("a.bin")))
        XCTAssertEqual(ledger.bytes, 1_200)
        XCTAssertTrue(ledger.complete(model.identifier("a.bin")))
        XCTAssertEqual(ledger.bytes, 1_600)
        XCTAssertTrue(ledger.complete(model.identifier("b.bin")))
        XCTAssertEqual(ledger.bytes, 2_000)
    }
}
