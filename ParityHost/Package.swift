// swift-tools-version: 6.0
import PackageDescription

// ZTronSearchEngineUIParity — the UIKit parity host of the pure SwiftUI search field
// (specification sections 2 and 12.5). A test host, never shipped: this is the only place in
// the repository where UIKit is imported.
let package = Package(
    name: "ZTronSearchEngineUIParity",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ZTronSearchEngineUIParity", targets: ["ZTronSearchEngineUIParity"]),
    ],
    dependencies: [
        .package(name: "ZTronSearchEngine", path: ".."),
    ],
    targets: [
        // The UIKit reference field, the shared scenario scripts and the four comparators.
        .target(
            name: "ZTronSearchEngineUIParity",
            dependencies: [
                .product(name: "ZTronSearchEngineUI", package: "ZTronSearchEngine"),
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
            ]
        ),
        // Runs the matrix for whatever simulator it is launched on.
        .testTarget(
            name: "ZTronSearchEngineUIParityTests",
            dependencies: ["ZTronSearchEngineUIParity"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
