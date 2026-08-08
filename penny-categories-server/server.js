// penny-categories-server — the central categories API for Penny.
//
// Why this exists: Penny's categorization vocabulary (the merchant map + keyword
// rules in categories.json) used to be baked into each app build, so improving a
// category meant shipping a new binary and only *your* device had the change.
// This server hosts that vocabulary centrally, so **every device** fetches the
// same, always-current categories over HTTP — no app release required.
//
//   Penny app ──GET /v1/categories──▶ penny-categories-server ──▶ categories.json
//
// It is deliberately dependency-free (Node 18+ built-ins only) so it drops onto
// any host or behind the Cloudflare tunnel that fronts penny1.thescript.design.
//
// Endpoints
//   GET  /                 → health text ("penny-categories ok")
//   GET  /health           → same
//   GET  /categories       → the categories payload (alias of /v1/categories)
//   GET  /v1/categories    → { version, updatedAt, categories[], merchant_map, category_rules }
//                            honours If-None-Match (ETag) → 304
//   POST /v1/categories    → replace the hosted categories (token-gated); body is
//                            either a full categories.json or the same payload shape
//   POST /v1/messages      → OPTIONAL Anthropic proxy passthrough, active only when
//                            ANTHROPIC_API_KEY is set (folds in the old penny-proxy
//                            so penny1.thescript.design is Penny's single backend)
//
// Run:  PORT=8999 node server.js
//       (optional) APP_TOKEN=... ANTHROPIC_API_KEY=sk-ant-... node server.js

import http from "node:http";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, appendFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.PORT || 8999);
const APP_TOKEN = process.env.APP_TOKEN || "";                 // shared token, gates writes (and reads if you want)
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || ""; // enables the optional /v1/messages proxy
const ANTHROPIC_UPSTREAM = "https://api.anthropic.com/v1/messages";
const CATEGORIES_PATH = process.env.CATEGORIES_PATH || join(__dirname, "categories.json");
const MAX_BODY = 4 * 1024 * 1024;                              // 4 MB request cap

// ── The hosted categories, kept in memory and refreshed on write ──────────────
// `raw` is the exact file text (so ETag == content hash, byte-stable); `payload`
// is the enriched object the app consumes.
let state = load();

function load() {
  if (!existsSync(CATEGORIES_PATH)) {
    console.error(`penny-categories: no categories file at ${CATEGORIES_PATH}`);
    process.exit(1);
  }
  const raw = readFileSync(CATEGORIES_PATH, "utf8");
  return build(raw);
}

/// Build the in-memory state from a categories.json text: parse it, derive the
/// flat list of canonical category names (union of merchant-map categories and
/// rule categories, sorted & de-duped), and compute a content ETag/version.
function build(raw) {
  const obj = JSON.parse(raw);
  const merchant_map = obj.merchant_map || {};
  const category_rules = obj.category_rules || [];
  const names = new Set();
  for (const v of Object.values(merchant_map)) if (Array.isArray(v) && v[1]) names.add(v[1]);
  for (const r of category_rules) if (Array.isArray(r) && r[0]) names.add(r[0]);
  const categories = [...names].sort((a, b) => a.localeCompare(b));
  const etag = '"' + createHash("sha256").update(raw).digest("hex").slice(0, 32) + '"';
  const payload = { version: etag.slice(1, 9), etag, categories, merchant_map, category_rules };
  return { raw, etag, payload };
}

// ── request log ───────────────────────────────────────────────────────────────
// Every request (and each proxy round-trip, with FULL request/response bodies)
// is appended as one JSON object per line (JSON Lines — appendable, and each
// line parses on its own; a single big JSON array would need a rewrite per
// entry). Timestamps are IST. Pretty-view with:  jq . logs/requests.jsonl
// Bodies carry users' transaction descriptors/verdicts — keep this file private.
const LOG_PATH = process.env.LOG_FILE || join(__dirname, "logs", "requests.jsonl");
try { mkdirSync(dirname(LOG_PATH), { recursive: true }); } catch {}

// ISO-style timestamp pinned to IST (+05:30), matching the app/server Swift logs.
const istStamp = () =>
  new Date(Date.now() + 5.5 * 3_600_000).toISOString().replace(/\.\d+Z$/, "+05:30");

// Bodies are embedded as parsed JSON (so the log nests real objects, not escaped
// strings); non-JSON bodies fall back to the raw text. Unlimited by default —
// set LOG_BODY_MAX to cap huge bodies, which then log a preview + true length.
const LOG_BODY_MAX = Number(process.env.LOG_BODY_MAX || 0);
function bodyField(text) {
  if (LOG_BODY_MAX > 0 && text.length > LOG_BODY_MAX) {
    return { truncated: true, length: text.length, preview: text.slice(0, LOG_BODY_MAX) };
  }
  try { return JSON.parse(text); } catch { return text; }
}

function logEvent(event) {
  const line = JSON.stringify({ ts: istStamp(), ...event }) + "\n";
  process.stdout.write(line);
  try { appendFileSync(LOG_PATH, line); } catch {}
}

// ── tiny helpers ──────────────────────────────────────────────────────────────
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "authorization,content-type,anthropic-version,if-none-match",
};
const sendJSON = (res, status, obj, extra = {}) => {
  res.writeHead(status, { "content-type": "application/json", ...CORS, ...extra });
  res.end(JSON.stringify(obj));
};
const sendText = (res, status, txt) => {
  res.writeHead(status, { "content-type": "text/plain", ...CORS });
  res.end(txt);
};
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) { req.destroy(); reject(new Error("body_too_large")); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}
const bearerOK = (req) =>
  !APP_TOKEN || (req.headers["authorization"] || "") === `Bearer ${APP_TOKEN}`;

// ── naive per-IP rate limiter (guards the open read endpoint) ─────────────────
const WINDOW_MS = 60_000, LIMIT = 240;
const hits = new Map();
function rateLimited(ip) {
  const now = Date.now();
  const e = hits.get(ip);
  if (!e || now > e.resetAt) { hits.set(ip, { count: 1, resetAt: now + WINDOW_MS }); return false; }
  return (e.count += 1) > LIMIT;
}

const server = http.createServer(async (req, res) => {
  const url = (req.url || "/").split("?")[0];
  const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim()
    || req.socket.remoteAddress || "?";

  // One access record per request, whichever branch answers it.
  const startedAt = Date.now();
  res.on("finish", () => {
    logEvent({ type: "http", ip, method: req.method, path: url,
               status: res.statusCode, ms: Date.now() - startedAt });
  });

  if (req.method === "OPTIONS") { res.writeHead(204, CORS); return res.end(); }

  // Health
  if (req.method === "GET" && (url === "/" || url === "/health")) {
    return sendText(res, 200, "penny-categories ok");
  }

  // Read categories
  if (req.method === "GET" && (url === "/categories" || url === "/v1/categories")) {
    if (rateLimited(ip)) return sendJSON(res, 429, { error: "rate_limited" });
    if ((req.headers["if-none-match"] || "") === state.etag) {
      res.writeHead(304, { etag: state.etag, ...CORS });
      return res.end();
    }
    return sendJSON(res, 200, state.payload, {
      etag: state.etag,
      "cache-control": "public, max-age=300",
    });
  }

  // Update categories (token-gated). Accepts a raw categories.json OR the payload
  // shape ({merchant_map, category_rules}); persists to disk and refreshes state.
  if (req.method === "POST" && (url === "/categories" || url === "/v1/categories")) {
    if (!bearerOK(req)) return sendJSON(res, 401, { error: "unauthorized" });
    let body;
    try { body = await readBody(req); } catch (e) { return sendJSON(res, 413, { error: String(e.message || e) }); }
    let obj;
    try { obj = JSON.parse(body.toString("utf8")); }
    catch { return sendJSON(res, 400, { error: "invalid_json" }); }
    if (!obj || typeof obj !== "object" || !obj.merchant_map || !obj.category_rules) {
      return sendJSON(res, 400, { error: "expected { merchant_map, category_rules }" });
    }
    // Persist only the canonical two keys, pretty-printed & stable, so the file
    // stays diff-friendly and byte-identical to what the app bundles.
    const canonical = JSON.stringify(
      { merchant_map: obj.merchant_map, category_rules: obj.category_rules }, null, 2) + "\n";
    try { writeFileSync(CATEGORIES_PATH, canonical, "utf8"); }
    catch (e) { return sendJSON(res, 500, { error: "write_failed", message: String(e.message || e) }); }
    state = build(canonical);
    logEvent({ type: "categories_update", ip, version: state.payload.version,
               categories: state.payload.categories.length });
    return sendJSON(res, 200, { ok: true, version: state.payload.version, categories: state.payload.categories });
  }

  // Optional Anthropic proxy passthrough (only when a key is configured).
  if (req.method === "POST" && url === "/v1/messages") {
    if (!ANTHROPIC_API_KEY) return sendJSON(res, 404, { error: "proxy_disabled" });
    if (rateLimited(ip)) return sendJSON(res, 429, { error: "rate_limited" });
    if (!bearerOK(req)) return sendJSON(res, 401, { error: "unauthorized" });
    let body;
    try { body = await readBody(req); } catch (e) { return sendJSON(res, 413, { error: String(e.message || e) }); }
    const bodyText = body.toString("utf8");
    let model = "?";
    try { model = JSON.parse(bodyText).model || "?"; } catch {}
    const proxyStart = Date.now();
    try {
      const upstream = await fetch(ANTHROPIC_UPSTREAM, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": req.headers["anthropic-version"] || "2023-06-01",
        },
        body,
      });
      const text = await upstream.text();
      // One record per round-trip: what the app sent AND what Anthropic answered.
      logEvent({ type: "proxy", ip, model, status: upstream.status,
                 ms: Date.now() - proxyStart,
                 request: bodyField(bodyText), response: bodyField(text) });
      res.writeHead(upstream.status, { "content-type": "application/json", ...CORS });
      return res.end(text);
    } catch (e) {
      logEvent({ type: "proxy", ip, model, error: String(e.message || e),
                 ms: Date.now() - proxyStart, request: bodyField(bodyText) });
      return sendJSON(res, 502, { error: "upstream_error", message: String(e.message || e) });
    }
  }

  return sendJSON(res, 404, { error: "not_found" });
});

server.listen(PORT, () => {
  logEvent({ type: "server", msg: "penny-categories-server started", port: PORT,
             categories: state.payload.categories.length, version: state.payload.version,
             proxy: Boolean(ANTHROPIC_API_KEY), log: LOG_PATH });
});
