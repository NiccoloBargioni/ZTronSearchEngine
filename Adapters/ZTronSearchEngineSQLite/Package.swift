// swift-tools-version: 6.0
import PackageDescription

// ZTronSearchEngineSQLite: the reference SQLite.swift adapter of ZTronSearchEngine
// (specification section 9.2, rules 7 and 8).
//
// A separate package on purpose: core never imports SQLite.swift, so the adapter and its
// dependency never reach the core products.
let package = Package(
    name: "ZTronSearchEngineSQLite",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ZTronSearchEngineSQLite", targets: ["ZTronSearchEngineSQLite"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.16.0"),
        // The core package, by path: this package lives in `Adapters/ZTronSearchEngineSQLite` of
        // the ZTronSearchEngine repository. Keep `name:`: it is what the targets below refer to,
        // whatever the directory of the checkout is called.
        .package(
            name: "ZTronSearchEngine",
            path: "../.."
        ),
    ],
    targets: [
        .target(
            name: "ZTronSearchEngineSQLite",
            dependencies: [
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),
        .testTarget(
            name: "ZTronSearchEngineSQLiteTests",
            dependencies: [
                "ZTronSearchEngineSQLite",
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
