import Foundation

// SPM deps (Package.swift / Xcode "Add Package"):
//   https://github.com/ml-explore/mlx-swift-examples   -> products: MLXLLM, MLXLMCommon
//   (pulls in mlx-swift + swift-transformers/Hub transitively)
import MLX
import MLXLLM
import MLXLMCommon

/// On-device inference via Apple's MLX (Metal). App-Store-safe:
///   • no JIT of our own code   • no subprocess   • weights are DATA, not executable code
///   • Apple Silicon ONLY (MLX does not support Intel Macs)
@MainActor
final class MLXProvider: AiProvider {

    let id = "mlx"

    private var container: ModelContainer?
    private(set) var loadedModel: ModelSpec?

    nonisolated var isAvailable: Bool {
        #if arch(arm64)
        return true          // Apple Silicon
        #else
        return false         // Intel Mac -> fall back to llama.cpp (DMG) or cloud
        #endif
    }

    // MARK: - Load

    func prepare(_ spec: ModelSpec,
                 onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard isAvailable else { throw AiError.unsupportedHardware }
        guard ModelCatalog.canRun(spec) else {
            throw AiError.insufficientMemory(needGB: spec.minRAMGB, haveGB: ModelCatalog.physicalRAMGB)
        }
        if loadedModel?.id == spec.id, container != nil { return }   // already resident

        // Keep the Metal cache bounded so an 8B model doesn't balloon resident memory.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        onProgress(0, "preparing \(spec.name)…")

        let config = ModelConfiguration(id: spec.repo)

        // Downloads on first use (into HF cache), then loads. Progress drives the same
        // bar the current Ollama picker shows.
        //
        // ⚠️ VERIFY against the mlx-swift-examples version you pin: recent releases expose
        //    `LLMModelFactory.shared.loadContainer(configuration:progressHandler:)`.
        let loaded = try await LLMModelFactory.shared.loadContainer(configuration: config) { progress in
            onProgress(progress.fractionCompleted,
                       "downloading \(spec.name) — \(Int(progress.fractionCompleted * 100))%")
        }

        self.container = loaded
        self.loadedModel = spec
        onProgress(1.0, "ready")
    }

    // MARK: - Generate

    func stream(prompt: String, system: String?, params: GenParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let container = self.container else {
                    continuation.finish(throwing: AiError.notLoaded)
                    return
                }
                do {
                    let genParams = GenerateParameters(
                        temperature: Float(params.temperature),
                        topP: Float(params.topP)
                    )

                    var messages: [Chat.Message] = []
                    if let system { messages.append(.system(system)) }
                    messages.append(.user(prompt))

                    _ = try await container.perform { context in
                        let input = try await context.processor.prepare(input: UserInput(chat: messages))

                        // Decode the full sequence each tick and emit only the DELTA.
                        // (Simple + UTF-8 safe. For fewer allocations swap in
                        //  MLXLMCommon's NaiveStreamingDetokenizer.)
                        var emitted = 0

                        return try MLXLMCommon.generate(
                            input: input, parameters: genParams, context: context
                        ) { tokens in
                            let text = context.tokenizer.decode(tokens: tokens)
                            if text.count > emitted {
                                let start = text.index(text.startIndex, offsetBy: emitted)
                                continuation.yield(String(text[start...]))
                                emitted = text.count
                            }
                            return tokens.count >= params.maxTokens ? .stop : .more
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Teardown

    func unload() {
        container = nil
        loadedModel = nil
        MLX.GPU.clearCache()
    }
}

// NOTE — a much shorter path exists in newer mlx-swift-examples:
//
//     let session = ChatSession(model)
//     for try await chunk in session.streamResponse(to: prompt) { continuation.yield(chunk) }
//
// If the version you pin has `ChatSession`, prefer it and delete the manual
// prepare/generate/detokenize plumbing above.
