// In-process, offline embedding + brute-force vector search.
//
// Uses @chroma-core/default-embed (all-MiniLM-L6-v2, ONNX) directly — no Chroma
// server required, so it runs on-device/offline. For the period-summary store
// (hundreds, low-thousands of vectors) a brute-force cosine scan is instant and
// avoids any external vector DB, which matters for the 4GB iPhone target.

import { DefaultEmbeddingFunction } from "@chroma-core/default-embed";

let ef = null;
function embedder() {
  if (!ef) ef = new DefaultEmbeddingFunction();
  return ef;
}

export async function embed(texts) {
  const arr = Array.isArray(texts) ? texts : [texts];
  if (!arr.length) return [];
  return embedder().generate(arr);
}

export async function embedOne(text) {
  return (await embed([text]))[0];
}

export function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return dot / (Math.sqrt(na * nb) || 1);
}

// items: [{ ...fields, embedding: number[] }]. Returns top-k by cosine to queryVec.
export function topK(queryVec, items, k = 5) {
  return items
    .map((it) => ({ item: it, score: it.embedding ? cosine(queryVec, it.embedding) : -1 }))
    .sort((a, b) => b.score - a.score)
    .slice(0, k);
}
