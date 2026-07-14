import Foundation
import Observation

/// Front door for the whole app. Picks a backend by capability, owns the loaded model,
/// and is the ONLY thing the rest of Penny talks to.
///
/// Build variants (this is what keeps App Store review happy):
///
///   APP STORE target  -> MLXProvider (+ FoundationModels, + Cloud). NO llama.cpp.
///   DMG target        -> the above, PLUS LlamaCppProvider for Intel Macs.
///
/// The llama.cpp/Ollama backend must be compiled OUT of the App Store binary — its
/// JIT / unsigned-exec entitlements and subprocess needs are exactly what gets rejected.
/// Gate it with a build flag (`-D ALLOW_LOCAL_LLAMACPP` on the DMG target only).
@MainActor
@Observable
final class AiEngine {

    private(set) var provider: AiProvider
    private(set) var status: String = "idle"
    private(set) var downloadProgress: Double = 0

    var loadedModel: ModelSpec? { provider.loadedModel }
    var isReady: Bool { provider.loadedModel != nil }

    init() {
        // Preference order: on-device MLX -> (Intel-only) llama.cpp -> cloud.
        let mlx = MLXProvider()
        if mlx.isAvailable {
            provider = mlx
        } else {
            #if ALLOW_LOCAL_LLAMACPP
            provider = LlamaCppProvider()      // DMG build only (Intel Macs)
            #else
            provider = CloudProvider()         // App Store fallback for non-Apple-Silicon
            #endif
        }
    }

    /// Download (if needed) + load. Drives the model-picker progress bar.
    func load(_ spec: ModelSpec) async throws {
        status = "preparing \(spec.name)…"
        downloadProgress = 0
        do {
            try await provider.prepare(spec) { [weak self] fraction, line in
                Task { @MainActor in
                    self?.downloadProgress = fraction
                    self?.status = line
                }
            }
            status = "ready · \(spec.name)"
        } catch {
            status = "failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Switch models at runtime (same UX as the picker we already ship).
    func switchTo(_ spec: ModelSpec) async throws {
        provider.unload()
        try await load(spec)
    }

    // MARK: - The ONLY two things Penny asks the model for
    //
    // Everything numeric — totals, category/merchant/time breakdowns, top expenses,
    // balances, counts — is answered by the deterministic SQL layer with ZERO model
    // involvement (and therefore zero hallucination). Keep it that way.

    /// Free-form advice / "roast my spending". Grounded: pass pre-computed SQL facts in.
    func advice(facts: String, question: String) -> AsyncThrowingStream<String, Error> {
        let system = """
        You are Penny, an offline finance assistant. Use ONLY the figures given to you.
        Never invent numbers. If a figure isn't provided, say you don't have it.
        """
        return provider.stream(
            prompt: "FACTS (from the user's statements):\n\(facts)\n\nQUESTION: \(question)",
            system: system,
            params: .advice
        )
    }

    /// Mop-up categoriser: only for merchants the deterministic rules couldn't place.
    /// Returns a category string from the fixed taxonomy.
    func categorize(unknownDescriptions: [String]) async throws -> [String: String] {
        guard !unknownDescriptions.isEmpty else { return [:] }
        let categories = [
            "Groceries", "Transport", "Food & Dining", "Shopping", "Utilities",
            "Entertainment", "Healthcare", "Investment & Insurance", "Income",
            "Cash", "Transfers", "Rent", "Other",
        ]
        let system = """
        Classify each bank-transaction description into EXACTLY one of:
        \(categories.joined(separator: ", ")).
        Reply as JSON: {"<description>": "<category>"}. No prose.
        """
        let text = try await provider.complete(
            prompt: unknownDescriptions.joined(separator: "\n"),
            system: system,
            params: .deterministic
        )
        guard let data = text.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        // Only trust values inside the taxonomy.
        return map.filter { categories.contains($0.value) }
    }
}
