
// ChromaDB vector store for semantic search over bank statements.
// Supports Contextual Retrieval (Anthropic, 2024) via a separate
// contextualized collection where each chunk carries statement-wide context.
//
// Requires a local Chroma server:  npx chroma run --path ./data/chroma

import { ChromaClient } from "chromadb";
import { DefaultEmbeddingFunction } from "@chroma-core/default-embed";

const CHROMA_HOST = process.env.CHROMA_HOST || "localhost";
const CHROMA_PORT = parseInt(process.env.CHROMA_PORT, 10) || 8000;
const RAW_COLLECTION = "bank_statements";
const CTX_COLLECTION = "bank_statements_contextual";

let client = null;
let rawCollection = null;
let ctxCollection = null;
let ready = false;
let connectionError = null;

export function isChromaReady() {
  return ready;
}

export function getChromaError() {
  return connectionError;
}

export async function initChromaDb() {
  try {
    client = new ChromaClient({ host: CHROMA_HOST, port: CHROMA_PORT });
    const embedder = new DefaultEmbeddingFunction();
    await client.heartbeat();

    rawCollection = await client.getOrCreateCollection({
      name: RAW_COLLECTION, embeddingFunction: embedder,
    });
    ctxCollection = await client.getOrCreateCollection({
      name: CTX_COLLECTION, embeddingFunction: embedder,
    });

    ready = true;
    connectionError = null;
    console.log(`  ChromaDB: http://${CHROMA_HOST}:${CHROMA_PORT}  collections="${RAW_COLLECTION}", "${CTX_COLLECTION}"\n`);
  } catch (err) {
    ready = false; connectionError = err.message;
    console.warn(`  ChromaDB not available: ${err.message}`);
    console.warn("  Semantic search falls back to SQLite FTS5.\n");
  }
}

async function batchAdd(col, ids, docs, metas) {
  const BATCH = 200;
  for (let i = 0; i < docs.length; i += BATCH) {
    const end = Math.min(i + BATCH, docs.length);
    await col.add({ ids: ids.slice(i, end), documents: docs.slice(i, end), metadatas: metas.slice(i, end) });
  }
}

async function clearCollection(col) {
  try {
    const existing = await col.get();
    if (existing.ids.length > 0) await col.delete({ ids: existing.ids });
  } catch (err) { console.error("ChromaDB clear error:", err.message); }
}

export async function replaceChromaDocument(chunks, metadata = {}) {
  if (!ready || !rawCollection) return false;
  try {
    await clearCollection(rawCollection);
    if (chunks.length === 0) return true;
    const ids = chunks.map((_, i) => `raw_${String(i).padStart(6, "0")}`);
    const metas = chunks.map((_, i) => ({ ...metadata, row_index: i, source: metadata.fileName || "unknown", contextualized: false }));
    await batchAdd(rawCollection, ids, chunks, metas);
    return true;
  } catch (err) { console.error("ChromaDB replace error:", err.message); return false; }
}

export async function replaceChromaDocumentContextual(ctxChunks, metadata = {}) {
  if (!ready || !ctxCollection) return false;
  try {
    await clearCollection(ctxCollection);
    if (ctxChunks.length === 0) return true;
    const ids = ctxChunks.map((_, i) => `ctx_${String(i).padStart(6, "0")}`);
    const metas = ctxChunks.map((_, i) => ({ ...metadata, row_index: i, source: metadata.fileName || "unknown", contextualized: true }));
    await batchAdd(ctxCollection, ids, ctxChunks, metas);
    return true;
  } catch (err) { console.error("ChromaDB contextual replace error:", err.message); return false; }
}

export async function clearChromaDocument() {
  if (!ready) return false;
  await clearCollection(rawCollection);
  await clearCollection(ctxCollection);
  return true;
}

export async function semanticSearchChunks(query, limit = 30) {
  if (!ready) return [];

  const target = ctxCollection || rawCollection;
  if (!target) return [];

  try {
    const results = await target.query({ queryTexts: [query], nResults: limit });
    return results.documents?.[0] || [];
  } catch (err) {
    console.error("ChromaDB search error:", err.message);
    if (rawCollection && target !== rawCollection) {
      try {
        const fallback = await rawCollection.query({ queryTexts: [query], nResults: limit });
        return fallback.documents?.[0] || [];
      } catch { return []; }
    }
    return [];
  }
}
