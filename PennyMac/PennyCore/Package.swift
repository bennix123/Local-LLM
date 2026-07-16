// swift-tools-version: 5.10
// PennyCore — shared on-device LLM engine for the Penny macOS app.
// Mirrors finquery/backend/src/services/llm_provider.py, but in Swift via mlx-swift.
import PackageDescription

let package = Package(
    name: "PennyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PennyCore", targets: ["PennyCore"]),
        .executable(name: "penny-cli", targets: ["penny-cli"]),
    ],
    dependencies: [
        // MLXLLM / MLXLMCommon: tokenizer, chat template, generation.
        // (These libraries moved out of mlx-swift-examples into mlx-swift-lm.)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        // The MLXHuggingFace macros expand *into this module* and reference
        // HuggingFace.HubClient + Tokenizers.AutoTokenizer — so we declare both here.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    ],
    targets: [
        .target(
            name: "PennyCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]
        ),
        // CLI proof of the vertical slice: load model → read PDF → one question → streamed answer.
        // Lets us verify MLX inference end-to-end from the terminal before touching Xcode.
        .executableTarget(
            name: "penny-cli",
            dependencies: ["PennyCore"]
        ),
    ]
)
