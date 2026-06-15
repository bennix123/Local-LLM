
// Redis integration for caching and session management.
// Connects to a locally-running Redis server (default: redis://localhost:6379).
//
// To run Redis locally on macOS:
//   brew install redis && brew services start redis
// Or via Docker:
//   docker run -d --name redis -p 6379:6379 redis:alpine

import Redis from "ioredis";

const REDIS_URL = process.env.REDIS_URL || "redis://localhost:6379";

let client = null;
let ready = false;
let connectionError = null;

export function isRedisReady() {
  return ready;
}

export function getRedisError() {
  return connectionError;
}

export async function initRedis() {
  try {
    client = new Redis(REDIS_URL, {
      maxRetriesPerRequest: 3,
      retryStrategy(times) {
        if (times > 3) return null;
        return Math.min(times * 200, 2000);
      },
      lazyConnect: true,
    });

    client.on("error", (err) => {
      connectionError = err.message;
      ready = false;
    });

    client.on("connect", () => {
      ready = true;
      connectionError = null;
    });

    client.on("close", () => {
      ready = false;
    });

    await client.connect();
    await client.ping();
    ready = true;
    connectionError = null;
    console.log(`  Redis connected: ${REDIS_URL}\n`);
  } catch (err) {
    ready = false;
    connectionError = err.message;
    console.warn(`  Redis not available (${REDIS_URL}): ${err.message}`);
    console.warn("  Caching and session features disabled.\n");
  }
}

export async function cacheSet(key, value, ttlSeconds = 3600) {
  if (!ready || !client) return false;
  try {
    const serialized = JSON.stringify(value);
    if (ttlSeconds > 0) {
      await client.setex(key, ttlSeconds, serialized);
    } else {
      await client.set(key, serialized);
    }
    return true;
  } catch (err) {
    console.error("Redis cacheSet error:", err.message);
    return false;
  }
}

export async function cacheGet(key) {
  if (!ready || !client) return null;
  try {
    const raw = await client.get(key);
    return raw ? JSON.parse(raw) : null;
  } catch (err) {
    console.error("Redis cacheGet error:", err.message);
    return null;
  }
}

export async function cacheDel(pattern) {
  if (!ready || !client) return 0;
  try {
    if (pattern.includes("*") || pattern.includes("?")) {
      const keys = [];
      let cursor = "0";
      do {
        const [nextCursor, found] = await client.scan(cursor, "MATCH", pattern, "COUNT", 100);
        cursor = nextCursor;
        keys.push(...found);
      } while (cursor !== "0");
      if (keys.length === 0) return 0;
      return await client.unlink(...keys);
    }
    return await client.unlink(pattern);
  } catch (err) {
    console.error("Redis cacheDel error:", err.message);
    return 0;
  }
}

export async function disconnectRedis() {
  if (client) {
    try { await client.quit(); } catch {}
  }
  ready = false;
}
