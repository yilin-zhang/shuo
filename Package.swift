// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Shuo",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Shuo", targets: ["Shuo"]),
        .library(name: "QwenStreaming", targets: ["QwenStreaming"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
    ],
    targets: [
        .target(
            name: "QwenStreaming",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift")
            ]
        ),
        .testTarget(name: "QwenStreamingTests", dependencies: ["QwenStreaming"]),
        .executableTarget(
            name: "Shuo",
            dependencies: [
                "QwenStreaming",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ],
            path: "Sources/Shuo",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ShuoTests",
            dependencies: ["Shuo"],
            path: "Tests/ShuoTests"
        ),
    ]
)
