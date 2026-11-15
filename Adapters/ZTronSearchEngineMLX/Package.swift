// swift-tools-version: 6.0
import PackageDescription

// ZTronSearchEngineMLX — the reference local-LLM runtime of ZTronSearchEngine (specification
// section 14.2). It is a package of its own so that mlx-swift's iOS 17 / macOS 14 floor never
// raises the iOS 15 floor of the core package.
//
// Every remote dependency is pinned to the exact version the package was built and tested with.
// MLX must be linked once per process: an app that already depends on mlx-swift has to resolve
// to this same version rather than add a second copy.
let package = Package(
    name: "ZTronSearchEngineMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZTronSearchEngineMLX", targets: ["ZTronSearchEngineMLX"]),
    ],
    dependencies: [
        // Core, by path: this package lives at `Adapters/ZTronSearchEngineMLX` inside the
        // ZTronSearchEngine repository.
        .package(
            name: "ZTronSearchEngine",
            path: "../.."
        ),
        // Arrays, the Metal backend and the neural-network layers.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // The LLM layer ("mlx-swift-lm"): model loading, the Qwen3 architecture, token generation.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        // mlx-swift-lm 3.x ships no tokenizer: this provides the tokenizer and the Jinja engine
        // that renders the chat template of the asset.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
    ],
    targets: [
        .target(
            name: "ZTronSearchEngineMLX",
            dependencies: [
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "ZTronSearchEngineMLXTests",
            dependencies: [
                "ZTronSearchEngineMLX",
                .product(name: "ZTronSearchEngine", package: "ZTronSearchEngine"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
