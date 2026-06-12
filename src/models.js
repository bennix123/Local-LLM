// Catalog of small, instruction-tuned GGUF models the user can download on
// first run. All are quantized (Q4_K_M) to stay small and run on modest CPUs.
// `uri` uses node-llama-cpp's Hugging Face scheme: hf:<user>/<repo>:<quant>

export const MODELS = [
  {
    id: "llama-3.2-1b",
    name: "Llama 3.2 1B Instruct",
    uri: "hf:bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M",
    approxSize: "~0.8 GB",
    blurb: "Smallest & fastest. Best for low-RAM machines. (Default)",
    recommended: true,
  },
  {
    id: "lfm2-1.2b",
    name: "Liquid AI · LFM2 1.2B",
    uri: "hf:LiquidAI/LFM2-1.2B-GGUF:Q4_K_M",
    approxSize: "~0.8 GB",
    blurb: "Liquid AI's edge model — very fast, low memory.",
    vendor: "Liquid AI",
    vendorUrl: "https://www.liquid.ai/",
  },
  {
    id: "lfm2-2.6b",
    name: "Liquid AI · LFM2 2.6B",
    uri: "hf:LiquidAI/LFM2-2.6B-GGUF:Q4_K_M",
    approxSize: "~1.7 GB",
    blurb: "Larger Liquid AI model — better reasoning, still efficient.",
    vendor: "Liquid AI",
    vendorUrl: "https://www.liquid.ai/",
  },
  {
    id: "qwen2.5-1.5b",
    name: "Qwen2.5 1.5B Instruct",
    uri: "hf:bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M",
    approxSize: "~1.0 GB",
    blurb: "Strong small model. Good size/quality balance.",
  },
  {
    id: "llama-3.2-3b",
    name: "Llama 3.2 3B Instruct",
    uri: "hf:bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
    approxSize: "~2.0 GB",
    blurb: "Best answers for reasoning over numbers. Needs more RAM.",
  },
  {
    id: "qwen2.5-0.5b",
    name: "Qwen2.5 0.5B Instruct",
    uri: "hf:bartowski/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M",
    approxSize: "~0.4 GB",
    blurb: "Tiny. Fastest possible, lowest quality. For very old machines.",
  },
];

export function getModel(id) {
  return MODELS.find((m) => m.id === id) || null;
}
