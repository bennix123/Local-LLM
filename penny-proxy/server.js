// penny-proxy — a tiny, dependency-free reverse proxy in front of the Anthropic
// Messages API. Penny's macOS/TestFlight app POSTs its categorization requests
// here; this process injects the REAL Anthropic key server-side and forwards
// them, so end users never need their own key (the reason categories showed as
// all "Other" for testers).
//
// It is deliberately a transparent pass-through: the app already builds a valid
// Anthropic `/v1/messages` body (model, system, messages, structured-output
// schema), so we forward it verbatim and only add authentication.
//
// Run:  ANTHROPIC_API_KEY=sk-ant-... APP_TOKEN=some-shared-token node server.js
// Needs Node 18+ (uses the built-in global `fetch`).

import http from "node:http";

const PORT = process.env.PORT || 8787;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const APP_TOKEN = process.env.APP_TOKEN || "";                 // optional shared token
const UPSTREAM = "https://api.anthropic.com/v1/messages";
const MAX_BODY = 4 * 1024 * 1024;                              // 4 MB request cap

if (!ANTHROPIC_API_KEY) {
  console.error("penny-proxy: set ANTHROPIC_API_KEY before starting.");
  process.exit(1);
}

// Naive per-IP rate limiter — raises the bar against someone hammering the open
// endpoint with a leaked URL. Tune LIMIT/WINDOW for your tester count.
const WINDOW_MS = 60_000, LIMIT = 90;
const hits = new Map();                                        // ip -> { count, resetAt }
function rateLimited(ip) {
  const now = Date.now();
  const e = hits.get(ip);
  if (!e || now > e.resetAt) { hits.set(ip, { count: 1, resetAt: now + WINDOW_MS }); return false; }
  e.count += 1;
  return e.count > LIMIT;
}

const json = (res, status, obj) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(obj));
};

const server = http.createServer((req, res) => {
  // Health check for the tunnel / platform.
  if (req.method === "GET" && (req.url === "/" || req.url === "/health")) {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("penny-proxy ok");
  }
  if (req.method !== "POST" || !req.url.startsWith("/v1/messages")) {
    return json(res, 404, { error: "not_found" });
  }

  const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim()
    || req.socket.remoteAddress || "?";
  if (rateLimited(ip)) return json(res, 429, { error: "rate_limited" });

  // Optional shared-token gate. Not a hard secret (it ships in the app binary),
  // but it stops casual abuse and can be rotated to revoke old builds.
  if (APP_TOKEN) {
    const auth = req.headers["authorization"] || "";
    if (auth !== `Bearer ${APP_TOKEN}`) return json(res, 401, { error: "unauthorized" });
  }

  const chunks = [];
  let size = 0, aborted = false;
  req.on("data", (c) => {
    size += c.length;
    if (size > MAX_BODY) { aborted = true; req.destroy(); return; }
    chunks.push(c);
  });
  req.on("end", async () => {
    if (aborted) return;
    const body = Buffer.concat(chunks);
    try {
      const upstream = await fetch(UPSTREAM, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": req.headers["anthropic-version"] || "2023-06-01",
        },
        body,
      });
      const text = await upstream.text();
      res.writeHead(upstream.status, { "content-type": "application/json" });
      res.end(text);
    } catch (e) {
      json(res, 502, { error: "upstream_error", message: String(e && e.message || e) });
    }
  });
});

server.listen(PORT, () => console.log(`penny-proxy listening on :${PORT}`));
