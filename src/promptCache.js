// Prompt cache for LLM generations, keyed by a hash of the full prompt
// (model + system + user). Two-tier so it works both in dev and offline on
// device:
//   1. Redis  — fast shared cache when the server is present (dev)
//   2. SQLite — persistent on-device fallback (works fully offline)
// Used by the period-summary build so rebuilds skip the ~120+ narrative
// generations for any period whose facts (and thus prompt) are unchanged.

import crypto from "node:crypto";
import { cacheGet, cacheSet, isRedisReady } from "./redis.js";
import { promptCacheGet, promptCacheSet } from "./db.js";

const DEFAULT_TTL = 60 * 60 * 24 * 30; // 30 days (Redis only)

export function promptKey(...parts) {
  const h = crypto.createHash("sha256").update(parts.join(" ")).digest("hex").slice(0, 40);
  return `promptcache:${h}`;
}

// Returns { text, cached } where cached is "redis" | "sqlite" | false.
export async function cachedGenerate(keyParts, genFn, ttl = DEFAULT_TTL) {
  const key = promptKey(...keyParts);

  if (isRedisReady()) {
    const hit = await cacheGet(key);
    if (hit != null) return { text: hit, cached: "redis" };
  }
  try {
    const s = promptCacheGet(key);
    if (s != null) return { text: s, cached: "sqlite" };
  } catch { /* db not ready */ }

  const text = await genFn();
  if (text && String(text).trim()) {
    if (isRedisReady()) await cacheSet(key, text, ttl);
    try { promptCacheSet(key, text); } catch { /* db not ready */ }
  }
  return { text, cached: false };
}
