// swift-tools-version: 5.10
// PennyCore — shared on-device LLM engine for the Penny macOS app.
// Mirrors finquery/backend/src/services/llm_provider.py, but in Swift via mlx-swift.
import PackageDescription

let package = Package(
    name: "PennyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PennyCore", targets: ["PennyCore"]),
        .library(name: "PennyTxnStore", targets: ["PennyTxnStore"]),
        .executable(name: "penny-cli", targets: ["penny-cli"]),
        .executable(name: "penny-conformance", targets: ["penny-conformance"]),
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
                "PennyTxnStore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]
        ),
        // Statement ingestion: PDF text extraction (MuPDF-parity), bank parsers,
        // deterministic categorization, SQLite store. Port of finquery's
        // backend/src/services/txn_store — NO MLX dependency so it builds/runs
        // with plain `swift build` and is testable against contract/fixtures.
        .target(
            name: "PennyTxnStore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // CLI proof of the vertical slice: load model → read PDF → one question → streamed answer.
        // Lets us verify MLX inference end-to-end from the terminal before touching Xcode.
        .executableTarget(
            name: "penny-cli",
            dependencies: ["PennyCore"]
        ),
        // Contract conformance runner: parses finquery/contract/fixtures/*.pdf through
        // the Swift pipeline and exact-matches the *_expected.json files. Also exposes
        // dump-words/dump-text subcommands to diff raw extraction against pymupdf.
        .executableTarget(
            name: "penny-conformance",
            dependencies: ["PennyTxnStore"]
        ),
        // XCTest layer over the same deterministic pipeline: the 22-fixture
        // conformance contract plus component tests (router, retriever, DB,
        // dates/money/categorisation). No MLX dependency — runs with `swift test`.
        .testTarget(
            name: "PennyTxnStoreTests",
            dependencies: ["PennyTxnStore"]
        ),
        // Real-model integration smoke: loads an already-downloaded MLX model and
        // runs one short grounded generation. Skips itself when no weights are on
        // disk, so plain `swift test` stays fast and network-free.
        .testTarget(
            name: "PennyCoreSmokeTests",
            dependencies: ["PennyCore"]
        ),
    ]
)
