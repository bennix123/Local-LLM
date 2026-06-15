// Embedded LLM engine powered by node-llama-cpp.
// Runs the model fully in-process (llama.cpp) — no Ollama, no external server,
// no network once the model file is on disk. Prebuilt llama.cpp binaries ship
// with the npm package, so this works on macOS & Windows without a compiler.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  getLlama,
  createModelDownloader,
  LlamaChatSession,
} from "node-llama-cpp";
import { getModel } from "./models.js";

import os from "node:os";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const APP_DATA_DIR =
  process.env.LOCALAPPDATA ||
  process.env.APPDATA ||
  path.join(os.homedir(), ".local", "share");

const MODELS_DIR = path.join(
  APP_DATA_DIR,
  "LocalLLMBankRAG",
  "models"
);

const MANIFEST_PATH = path.join(
  MODELS_DIR,
  "manifest.json"
);

let llama = null;
let model = null;
let context = null;
let contextSequence = null;
let loadedModelId = null;
let useCpu = false; // flips to true once a GPU OOM forces a CPU fallback

// Serialize prompts: one generation at a time on the single context sequence.
let queue = Promise.resolve();

function ensureDir() {
  fs.mkdirSync(MODELS_DIR, { recursive: true });
}

function readManifest() {
  try {
    return JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
  } catch {
    return {};
  }
}

function writeManifest(manifest) {
  fs.writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2));
}

/** Models that have been fully downloaded and are present on disk. */
export function listDownloadedModels() {
  const manifest = readManifest();
  return Object.entries(manifest)
    .filter(([, filePath]) => filePath && fs.existsSync(filePath))
    .map(([id]) => id);
}

export function getLoadedModelId() {
  return loadedModelId;
}

export function isReady() {
  return Boolean(model && contextSequence);
}

/**
 * Download a model by catalog id. `onProgress({downloadedSize, totalSize})`
 * is called repeatedly so the UI can show a progress bar.
 */
export async function downloadModel(id, onProgress) {
  const entry = getModel(id);
  if (!entry) throw new Error(`Unknown model id: ${id}`);
  ensureDir();

  const downloader = await createModelDownloader({
    modelUri: entry.uri,
    dirPath: MODELS_DIR,
    onProgress,
  });
  const modelPath = await downloader.download();

  const manifest = readManifest();
  manifest[id] = modelPath;
  writeManifest(manifest);
  return modelPath;
}

/** Load a downloaded model into memory and prepare a chat context. */
export async function loadModel(id) {
  const manifest = readManifest();
  const modelPath = manifest[id];
  if (!modelPath || !fs.existsSync(modelPath)) {
    throw new Error(`Model "${id}" is not downloaded yet.`);
  }

  // Tear down any previously loaded model first.
  await unload();

  // Keep the context small: a big KV cache is what makes low-VRAM GPUs run out
  // of memory (Vulkan "ErrorOutOfDeviceMemory"). 8192 comfortably fits a whole
  // bank statement (~6k tokens) + question + answer.
  const CONTEXT_SIZE = 8192;

  async function tryLoad(forceCpu) {
    llama = await getLlama(forceCpu ? { gpu: false } : {});
    model = await llama.loadModel({ modelPath });
    context = await model.createContext({ contextSize: CONTEXT_SIZE });
    contextSequence = context.getSequence();
  }

  try {
    await tryLoad(useCpu);
  } catch (err) {
    // GPU likely ran out of memory — fall back to CPU and retry once.
    if (!useCpu) {
      console.warn(
        "[llm] GPU load failed (" +
          (err?.message || err) +
          "). Falling back to CPU."
      );
      useCpu = true;
      await unload();
      await tryLoad(true);
    } else {
      throw err;
    }
  }
  loadedModelId = id;

  // Warm-up: the first inference pays a one-time cost (buffer allocation,
  // graph build, cache warm). Pay it now — during the "Loading model…" state —
  // so the user's FIRST real question responds quickly instead of stalling.
  try {
    const warm = new LlamaChatSession({ contextSequence });
    await warm.prompt("Hi", { maxTokens: 1 });
    warm.dispose();
    await contextSequence.clearHistory(); // discard warm-up tokens
  } catch {
    /* warm-up is best-effort; ignore failures */
  }
  return id;
}

export async function unload() {
  try {
    if (context) await context.dispose();
  } catch {
    /* ignore */
  }
  context = null;
  contextSequence = null;
  if (model) {
    try {
      await model.dispose();
    } catch {
      /* ignore */
    }
  }
  model = null;
  loadedModelId = null;
}

/**
 * Run one chat turn. `systemPrompt` carries the bank-statement context built
 * by the caller; `userMessage` is the question. Streams tokens via onChunk.
 * Returns the full response text.
 */
export function chat(systemPrompt, userMessage, onChunk) {
  // Chain onto the queue so concurrent requests don't corrupt the sequence.
  const run = queue.then(async () => {
    if (!isReady()) throw new Error("No model is loaded.");
    const session = new LlamaChatSession({ contextSequence, systemPrompt });
    try {
      const response = await session.prompt(userMessage, {
        temperature: 0.2, // low temp: we want faithful numbers, not creativity
        maxTokens: 500,
        // Penalize repetition so weak models don't loop the same sentence.
        repeatPenalty: {
          penalty: 1.3,
          frequencyPenalty: 0.3,
          presencePenalty: 0.3,
          lastTokens: 256,
        },
        // DRY penalty: specifically targets repeated multi-token sequences,
        // i.e. the "same sentence over and over" degeneration loop.
        dryRepeatPenalty: { strength: 0.8 },
        onTextChunk: (text) => {
          if (onChunk) onChunk(text);
        },
      });
      return response;
    } finally {
      session.dispose();
    }
  });
  // Keep the queue alive even if this turn throws.
  queue = run.catch(() => {});
  return run;
}
