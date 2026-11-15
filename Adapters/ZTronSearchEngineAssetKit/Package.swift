// swift-tools-version: 6.3
import PackageDescription

// ZTronSearchEngineAssetKit: the model-asset boundary of ZTronSearchEngine (specification
// section 14.1, `ModelAssetProviding`) implemented over ZTronAssetKit.
//
// A separate package on purpose: core never imports ZTronAssetKit, so this bridge is the only
// place where both packages meet.
//
// Tools version 6.3 because ZTronAssetKit's manifest declares 6.3 and its sources use
// `@concurrent` (Swift 6.2): no older toolchain can resolve or build this graph anyway, and
// declaring it here makes an older toolchain fail on this manifest with a clear message.
/// Where ZTronAssetKit is checked out. By default it sits next to the ZTronSearchEngine
/// checkout (`<parent>/ZTronSearchEngine` and `<parent>/ZTronAssetKit`); set
/// `ZTRON_ASSETKIT_PATH` to build against a checkout anywhere else.
let assetKitPath = Context.environment["ZTRON_ASSETKIT_PATH"] ?? "../../../ZTronAssetKit"

let package = Package(
    name: "ZTronSearchEngineAssetKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ZTronSearchEngineAssetKit", targets: ["ZTronSearchEngineAssetKit"]),
    ],
    dependencies: [
        // The core package, by path: this package lives at `Adapters/ZTronSearchEngineAssetKit`
        // inside the ZTronSearchEngine repository.
        .package(name: "ZTronSearchEngine", path: "../.."),
        .package(name: "ZTronAssetKit", path: assetKitPath),
    ],
    targets: [
        .target(
            name: "ZTronSearchEngineAssetKit",
            dependencies: [
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
                .product(name: "ZTronAssetKit", package: "ZTronAssetKit"),
            ]
        ),
        .testTarget(
            name: "ZTronSearchEngineAssetKitTests",
            dependencies: [
                "ZTronSearchEngineAssetKit",
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
                .product(name: "ZTronAssetKit", package: "ZTronAssetKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
