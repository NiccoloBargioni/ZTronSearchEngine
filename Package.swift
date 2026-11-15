// swift-tools-version: 6.0
import PackageDescription

// ZTronSearchEngine — fully offline, typo-tolerant, multilingual search (specification section 2).
//
// One package, three library products. No third-party dependency is declared here, on purpose:
// the SQLite.swift adapter, the MLX runtime and the UIKit parity host are separate packages
// under `Adapters/` and `ParityHost/`, so their floors and dependencies never reach these products.
let package = Package(
    name: "ZTronSearchEngine",
    defaultLocalization: "en",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ZTronSearchEngine", targets: ["ZTronSearchEngine"]),
        .library(name: "ZTronSearchEngineSemantic", targets: ["ZTronSearchEngineSemantic"]),
        .library(name: "ZTronSearchEngineUI", targets: ["ZTronSearchEngineUI"]),
    ],
    targets: [
        // Core: Foundation, NaturalLanguage and Accelerate only.
        .target(name: "ZTronSearchEngine"),

        // Semantic: Core ML and Accelerate. Injected into core through `SemanticSearching` / `Reranking`.
        .target(
            name: "ZTronSearchEngineSemantic",
            dependencies: ["ZTronSearchEngine"]
        ),

        // UI: SwiftUI only, never UIKit (enforced by the lint test in ZTronSearchEngineUITests).
        .target(
            name: "ZTronSearchEngineUI",
            dependencies: ["ZTronSearchEngine"],
            resources: [.process("Resources")]
        ),

        // Shared fixtures: the golden query set and the synthetic corpus generator.
        .target(
            name: "ZTronSearchFixtures",
            dependencies: ["ZTronSearchEngine"]
        ),

        .testTarget(
            name: "ZTronSearchEngineTests",
            dependencies: ["ZTronSearchEngine", "ZTronSearchFixtures"]
        ),
        .testTarget(
            name: "ZTronSearchFixturesTests",
            dependencies: ["ZTronSearchFixtures", "ZTronSearchEngine"]
        ),
        .testTarget(
            name: "ZTronSearchEngineSemanticTests",
            dependencies: ["ZTronSearchEngineSemantic", "ZTronSearchEngine", "ZTronSearchFixtures"]
        ),
        .testTarget(
            name: "ZTronSearchEngineUITests",
            dependencies: ["ZTronSearchEngineUI", "ZTronSearchEngine", "ZTronSearchFixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
