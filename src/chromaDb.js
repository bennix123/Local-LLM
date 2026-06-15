
// ChromaDB vector store for semantic search over bank statements.
// Uses @chroma-core/default-embed for automatic text-to-vector embeddings.
//
// Requires a local Chroma server:  npx chroma run --path ./data/chroma

import { ChromaClient } from "chromadb";
import { DefaultEmbeddingFunction } from "@chroma-core/default-embed";

const CHROMA_HOST = process.env.CHROMA_HOST || "localhost";
const CHROMA_PORT = parseInt(process.env.CHROMA_PORT, 10) || 8000;
const CHROMA_COLLECTION = "bank_statements";

let client = null;
let collection = null;
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
    client = new ChromaClient({
      host: CHROMA_HOST,
      port: CHROMA_PORT,
    });

    const embedder = new DefaultEmbeddingFunction();
    await client.heartbeat();

    collection = await client.getOrCreateCollection({
      name: CHROMA_COLLECTION,
      embeddingFunction: embedder,
    });

    ready = true;
    connectionError = null;
    console.log(
      `  ChromaDB connected: http://${CHROMA_HOST}:${CHROMA_PORT}  collection="${CHROMA_COLLECTION}"\n`
    );
  } catch (err) {
    ready = false;
    connectionError = err.message;
    console.warn(
      `  ChromaDB not available (http://${CHROMA_HOST}:${CHROMA_PORT}): ${err.message}`
    );
    console.warn("  Semantic search will fall back to SQLite FTS5.\n");
  }
}

export async function replaceChromaDocument(chunks, metadata = {}) {
  if (!ready || !collection) return false;

  try {
    const existing = await collection.get();
    if (existing.ids.length > 0) {
      await collection.delete({ ids: existing.ids });
    }

    if (chunks.length === 0) return true;

    const ids = chunks.map((_, i) => `chunk_${i.toString().padStart(6, "0")}`);
    const metadatas = chunks.map((_, i) => ({
      ...metadata,
      row_index: i,
      source: metadata.fileName || "unknown",
    }));

    const BATCH = 200;
    for (let i = 0; i < chunks.length; i += BATCH) {
      const slice = chunks.slice(i, i + BATCH);
      await collection.add({
        ids: ids.slice(i, i + BATCH),
        documents: slice,
        metadatas: metadatas.slice(i, i + BATCH),
      });
    }

    return true;
  } catch (err) {
    console.error("ChromaDB replace error:", err.message);
    return false;
  }
}

export async function clearChromaDocument() {
  if (!ready || !collection) return false;

  try {
    const existing = await collection.get();
    if (existing.ids.length > 0) {
      await collection.delete({ ids: existing.ids });
    }
    return true;
  } catch (err) {
    console.error("ChromaDB clear error:", err.message);
    return false;
  }
}

export async function semanticSearchChunks(query, limit = 30) {
  if (!ready || !collection) return [];

  try {
    const results = await collection.query({
      queryTexts: [query],
      nResults: limit,
    });

    if (!results.documents || !results.documents[0]) return [];
    return results.documents[0];
  } catch (err) {
    console.error("ChromaDB search error:", err.message);
    return [];
  }
}
