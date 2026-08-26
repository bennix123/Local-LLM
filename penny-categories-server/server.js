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
//   POST /v1/messages      → OPTIONAL categorization LLM proxy, active when a
//                            provider key is set. DEEPSEEK_API_KEY (translated
//                            to/from the OpenAI dialect) takes precedence, else
//                            ANTHROPIC_API_KEY is a passthrough — so penny1 stays
//                            Penny's single backend either way.
//
// Run:  PORT=8999 node server.js
//       (optional) APP_TOKEN=... ANTHROPIC_API_KEY=sk-ant-... node server.js
//       (optional) DEEPSEEK_API_KEY=sk-... DEEPSEEK_MODEL=deepseek-v4-flash node server.js

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
// DeepSeek can stand in for Anthropic on /v1/messages: when DEEPSEEK_API_KEY is
// set it takes precedence, and requests are translated Anthropic⇄OpenAI both ways
// so the app needs no change. Image-bearing requests still fall back to Anthropic.
const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY || "";
const DEEPSEEK_MODEL = process.env.DEEPSEEK_MODEL || "deepseek-v4-flash";
// Model used for STRUCTURED (json_schema) requests — i.e. Penny's categorization
// batches. Measured 2026-08-26 through this proxy: deepseek-v4-flash spends
// 64–77% of its billed output tokens on hidden reasoning before the JSON
// (3-merchant batch: 289 billed vs ~67 visible; 24-merchant: 3,317 vs ~1,000),
// which is pure latency — the app's prompt already encodes the reasoning steps.
// DeepSeek switches thinking off by MODEL NAME, so classification defaults to
// the documented non-thinking model. Override with DEEPSEEK_FAST_MODEL (set it
// equal to DEEPSEEK_MODEL to restore the old single-model behaviour).
const DEEPSEEK_FAST_MODEL = process.env.DEEPSEEK_FAST_MODEL || "deepseek-chat";
const DEEPSEEK_UPSTREAM = "https://api.deepseek.com/chat/completions";
const LLM_PROVIDER = DEEPSEEK_API_KEY ? "deepseek" : (ANTHROPIC_API_KEY ? "anthropic" : "none");
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

// ── Anthropic ⇄ DeepSeek translation (for the /v1/messages proxy) ──────────────
// The Penny app speaks the Anthropic Messages dialect (system + output_config
// json_schema + content[] blocks); DeepSeek speaks the OpenAI chat-completions
// dialect. These helpers let DeepSeek serve the proxy with no app change: the app
// still POSTs an Anthropic request and still reads back content[].text JSON.

// Flatten an Anthropic message `content` (a string OR an array of blocks) to text.
function flattenContent(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.filter((b) => b && b.type === "text" && typeof b.text === "string")
                  .map((b) => b.text).join("\n");
  }
  return "";
}
// True if any message carries non-text content (e.g. an image block) — a DeepSeek
// text model can't handle those, so such requests bounce to Anthropic instead.
function hasNonTextContent(messages) {
  return (messages || []).some((m) => Array.isArray(m.content)
    && m.content.some((b) => b && b.type && b.type !== "text"));
}

// Anthropic request → DeepSeek (OpenAI) request body.
function anthropicToDeepSeek(reqObj) {
  const messages = [];
  let system = typeof reqObj.system === "string" ? reqObj.system : "";
  const schema = reqObj?.output_config?.format?.schema;
  const jsonMode = Boolean(schema) || reqObj?.output_config?.format?.type === "json_schema";
  // Fold the app's json_schema into the system prompt so DeepSeek emits the exact
  // { results: [...] } envelope the app parses. JSON mode also *requires* the word
  // "json" to appear in the prompt — this instruction supplies it.
  if (schema) {
    system += (system ? "\n\n" : "") +
      "Respond with ONLY a single JSON object that validates against this JSON Schema — " +
      "no markdown, no code fences, no prose before or after:\n" + JSON.stringify(schema);
  }
  if (system) messages.push({ role: "system", content: system });
  for (const m of reqObj.messages || []) {
    messages.push({ role: m.role === "assistant" ? "assistant" : "user",
                    content: flattenContent(m.content) });
  }
  // Reasoning models spend completion tokens on hidden reasoning before the JSON,
  // so the app's max_tokens (sized for Anthropic's smaller thinking block) is too
  // tight and would truncate — add headroom, capped to a safe ceiling.
  const askedMax = Number(reqObj.max_tokens) || 4096;
  // Structured (json_schema) requests are Penny's categorization batches: pure
  // classification where hidden chain-of-thought is 64–77% of the billed output
  // (measured — see DEEPSEEK_FAST_MODEL above) and adds nothing the prompt
  // doesn't already encode. Serve them with the non-thinking model.
  const body = { model: jsonMode ? DEEPSEEK_FAST_MODEL : DEEPSEEK_MODEL, messages,
                 max_tokens: Math.min(8192, askedMax + 4096) };
  if (jsonMode) body.response_format = { type: "json_object" };
  return body;
}

// DeepSeek (OpenAI) response → the minimal Anthropic Messages shape the app reads:
// a content[] with one text block carrying the model's JSON string.
function deepSeekToAnthropic(ds, requestedModel) {
  const choice = (ds.choices && ds.choices[0]) || {};
  const text = (choice.message && choice.message.content) || "";
  const stopMap = { stop: "end_turn", length: "max_tokens", tool_calls: "tool_use" };
  return {
    id: ds.id || "msg_deepseek",
    type: "message",
    role: "assistant",
    model: ds.model || requestedModel || DEEPSEEK_MODEL,
    content: [{ type: "text", text }],
    stop_reason: stopMap[choice.finish_reason] || "end_turn",
    stop_sequence: null,
    usage: {
      input_tokens: ds?.usage?.prompt_tokens ?? 0,
      output_tokens: ds?.usage?.completion_tokens ?? 0,
    },
  };
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

  // Categorization LLM proxy. Served by DeepSeek when DEEPSEEK_API_KEY is set
  // (translated to/from the OpenAI dialect), else an Anthropic passthrough.
  // Disabled (404) when neither key is configured.
  if (req.method === "POST" && url === "/v1/messages") {
    if (LLM_PROVIDER === "none") return sendJSON(res, 404, { error: "proxy_disabled" });
    if (rateLimited(ip)) return sendJSON(res, 429, { error: "rate_limited" });
    if (!bearerOK(req)) return sendJSON(res, 401, { error: "unauthorized" });
    let body;
    try { body = await readBody(req); } catch (e) { return sendJSON(res, 413, { error: String(e.message || e) }); }
    const bodyText = body.toString("utf8");
    let reqObj = null;
    try { reqObj = JSON.parse(bodyText); } catch {}
    const requestedModel = (reqObj && reqObj.model) || "?";
    const proxyStart = Date.now();

    // DeepSeek path — translate Anthropic→OpenAI and back. Image-bearing requests
    // fall back to Anthropic when a key for it is available (DeepSeek is text-only).
    const useDeepSeek = DEEPSEEK_API_KEY && reqObj
      && !(hasNonTextContent(reqObj.messages) && ANTHROPIC_API_KEY);
    if (useDeepSeek) {
      try {
        const dsBody = anthropicToDeepSeek(reqObj);
        const upstream = await fetch(DEEPSEEK_UPSTREAM, {
          method: "POST",
          headers: { "content-type": "application/json",
                     "authorization": `Bearer ${DEEPSEEK_API_KEY}` },
          body: JSON.stringify(dsBody),
        });
        const text = await upstream.text();
        // On success, hand the app an Anthropic-shaped body; on error, pass through.
        let out = text;
        if (upstream.ok) {
          try { out = JSON.stringify(deepSeekToAnthropic(JSON.parse(text), requestedModel)); }
          catch {}
        }
        logEvent({ type: "proxy", provider: "deepseek", ip, model: dsBody.model,
                   requestedModel, status: upstream.status, ms: Date.now() - proxyStart,
                   request: bodyField(bodyText), response: bodyField(out) });
        res.writeHead(upstream.ok ? 200 : upstream.status,
                      { "content-type": "application/json", ...CORS });
        return res.end(out);
      } catch (e) {
        logEvent({ type: "proxy", provider: "deepseek", ip, model: DEEPSEEK_MODEL,
                   requestedModel, error: String(e.message || e),
                   ms: Date.now() - proxyStart, request: bodyField(bodyText) });
        return sendJSON(res, 502, { error: "upstream_error", message: String(e.message || e) });
      }
    }

    // Anthropic passthrough: what the app sent AND what Anthropic answered.
    if (!ANTHROPIC_API_KEY) return sendJSON(res, 502, { error: "anthropic_unavailable" });
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
      logEvent({ type: "proxy", provider: "anthropic", ip, model: requestedModel,
                 status: upstream.status, ms: Date.now() - proxyStart,
                 request: bodyField(bodyText), response: bodyField(text) });
      res.writeHead(upstream.status, { "content-type": "application/json", ...CORS });
      return res.end(text);
    } catch (e) {
      logEvent({ type: "proxy", provider: "anthropic", ip, model: requestedModel,
                 error: String(e.message || e),
                 ms: Date.now() - proxyStart, request: bodyField(bodyText) });
      return sendJSON(res, 502, { error: "upstream_error", message: String(e.message || e) });
    }
  }

  return sendJSON(res, 404, { error: "not_found" });
});

server.listen(PORT, () => {
  logEvent({ type: "server", msg: "penny-categories-server started", port: PORT,
             categories: state.payload.categories.length, version: state.payload.version,
             proxy: LLM_PROVIDER !== "none", provider: LLM_PROVIDER,
             model: LLM_PROVIDER === "deepseek" ? DEEPSEEK_MODEL : undefined,
             fastModel: LLM_PROVIDER === "deepseek" ? DEEPSEEK_FAST_MODEL : undefined,
             log: LOG_PATH });
});
