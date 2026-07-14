import Foundation

// MARK: - Model description

/// A model the app can download + run. `repo` is a HuggingFace repo in MLX format
/// (the mlx-community org hosts pre-converted weights — GGUF is NOT usable here).
struct ModelSpec: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let repo: String
    let downloadGB: Double
    let minRAMGB: Int
    let note: String
}

// MARK: - Generation parameters

struct GenParams: Sendable {
    var temperature: Double = 0.2
    var topP: Double = 0.9
    var maxTokens: Int = 512

    static let deterministic = GenParams(temperature: 0.0, topP: 1.0, maxTokens: 256)
    static let advice        = GenParams(temperature: 0.4, topP: 0.9, maxTokens: 512)
}

// MARK: - Errors

enum AiError: LocalizedError {
    case unsupportedHardware
    case notLoaded
    case insufficientMemory(needGB: Int, haveGB: Int)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "This Mac can't run models on-device (Apple Silicon required)."
        case .notLoaded:
            return "No model is loaded yet."
        case .insufficientMemory(let need, let have):
            return "That model needs about \(need) GB of memory; this Mac has \(have) GB."
        case .downloadFailed(let why):
            return "Model download failed: \(why)"
        }
    }
}

// MARK: - The abstraction every backend implements

/// One interface, several backends:
///   • MLXProvider              — Apple Silicon, on-device      [App Store build ✓]
///   • FoundationModelsProvider — Apple Intelligence (~3B)      [App Store build ✓]
///   • LlamaCppProvider         — Intel Macs / legacy           [DMG build only]
///   • CloudProvider            — fallback                      [either]
///
/// IMPORTANT: the llama.cpp/Ollama backend must be compiled OUT of the App Store
/// target (its JIT / subprocess needs are what App Review rejects).
protocol AiProvider: AnyObject, Sendable {
    var id: String { get }

    /// Can this backend run on this machine at all (hardware / OS / entitlements)?
    var isAvailable: Bool { get }

    /// Which model is currently resident, if any.
    var loadedModel: ModelSpec? { get }

    /// Download (if needed) + load the model. `onProgress` reports 0...1 and a status line,
    /// so it can drive the same progress bar the Ollama picker uses today.
    func prepare(_ spec: ModelSpec, onProgress: @escaping @Sendable (Double, String) -> Void) async throws

    /// Stream the reply token-by-token.
    func stream(prompt: String, system: String?, params: GenParams) -> AsyncThrowingStream<String, Error>

    /// One-shot convenience (buffers the stream).
    func complete(prompt: String, system: String?, params: GenParams) async throws -> String

    /// Free the weights + GPU cache.
    func unload()
}

extension AiProvider {
    func complete(prompt: String, system: String? = nil, params: GenParams = .advice) async throws -> String {
        var out = ""
        for try await piece in stream(prompt: prompt, system: system, params: params) {
            out += piece
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
