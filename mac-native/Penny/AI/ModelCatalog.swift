import Foundation

/// RAM-aware model catalogue.
///
/// The point that matters: going MLX does NOT force you down to a small model —
/// MLX is a framework, not a model. Llama 3.1 8B (4-bit) is the default and is the
/// same model you run through Ollama today, just in MLX format.
///
/// (Contrast: Apple Intelligence / Foundation Models is a FIXED ~3B model you don't choose.)
enum ModelCatalog {

    /// Ordered strongest -> lightest. Verify repo IDs against huggingface.co/mlx-community
    /// before shipping — the org's naming does change.
    static let all: [ModelSpec] = [
        ModelSpec(id: "llama-3.1-8b-4bit",
                  name: "Llama 3.1 8B",
                  repo: "mlx-community/Llama-3.1-8B-Instruct-4bit",
                  downloadGB: 4.5, minRAMGB: 16,
                  note: "Best reasoning · recommended"),

        ModelSpec(id: "qwen2.5-7b-4bit",
                  name: "Qwen 2.5 7B",
                  repo: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                  downloadGB: 4.3, minRAMGB: 16,
                  note: "Strong all-rounder"),

        ModelSpec(id: "llama-3.2-3b-4bit",
                  name: "Llama 3.2 3B",
                  repo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                  downloadGB: 1.8, minRAMGB: 8,
                  note: "Balanced · low memory"),

        ModelSpec(id: "qwen2.5-3b-4bit",
                  name: "Qwen 2.5 3B",
                  repo: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                  downloadGB: 1.7, minRAMGB: 8,
                  note: "Fast · lightest"),
    ]

    static var physicalRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Models this Mac can actually hold, strongest first.
    static var supported: [ModelSpec] {
        let ram = physicalRAMGB
        return all.filter { $0.minRAMGB <= ram }
    }

    /// What we preselect in the picker: the best model this machine can run.
    static var recommended: ModelSpec {
        supported.first ?? all[all.count - 1]
    }

    static func canRun(_ spec: ModelSpec) -> Bool {
        spec.minRAMGB <= physicalRAMGB
    }

    /// Where weights live. MUST be userData-style (Application Support), never inside the
    /// app bundle — writing into the bundle breaks code signing / notarization.
    static var modelsDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Penny/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
