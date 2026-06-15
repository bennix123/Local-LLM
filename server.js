// Local web server for the offline bank-statement assistant.
// Everything runs on your machine: file parsing, SQLite storage, and the LLM.
// After the model is downloaded once, no internet connection is required.

import express from "express";
import multer from "multer";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { MODELS } from "./src/models.js";
import {
  initDb,
  replaceDocument,
  clearDocument,
  getMeta,
  hasDocument,
} from "./src/db.js";
import { parseFile } from "./src/ingest.js";
import { computeStatsSummary } from "./src/stats.js";
import {
  listDownloadedModels,
  downloadModel,
  loadModel,
  getLoadedModelId,
  isReady,
  chat,
} from "./src/llm.js";
import { buildSystemPrompt } from "./src/rag.js";
import { initChromaDb, isChromaReady, replaceChromaDocument, clearChromaDocument, getChromaError } from "./src/chromaDb.js";
import { initRedis, isRedisReady, getRedisError, cacheSet, cacheGet, cacheDel, disconnectRedis } from "./src/redis.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 3000;

initDb();
await initChromaDb();
await initRedis();

process.on("SIGTERM", async () => { await disconnectRedis(); process.exit(0); });
process.on("SIGINT", async () => { await disconnectRedis(); process.exit(0); });

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 25 * 1024 * 1024 }, // 25 MB
});

// --- App state ------------------------------------------------------------
app.get("/api/state", (req, res) => {
  const downloaded = listDownloadedModels();
  res.json({
    models: MODELS,
    downloaded,
    loadedModelId: getLoadedModelId(),
    ready: isReady(),
    offline: downloaded.length > 0, // a model is on disk → no internet needed
    document: hasDocument() ? getMeta() : null,
    chroma: { ready: isChromaReady(), error: getChromaError() },
    redis: { ready: isRedisReady(), error: getRedisError() },
  });
});

// --- Download a model (Server-Sent Events for progress) -------------------
app.get("/api/download", async (req, res) => {
  const id = String(req.query.id || "");
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });
  const send = (event, data) =>
    res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

  try {
    let last = 0;
    await downloadModel(id, ({ downloadedSize, totalSize }) => {
      // Throttle progress events a little to avoid flooding the stream.
      const now = Date.now();
      if (now - last > 200 || downloadedSize === totalSize) {
        last = now;
        send("progress", { downloadedSize, totalSize });
      }
    });

    send("status", { message: "Loading model into memory…" });
    await loadModel(id);
    send("done", { id, ready: isReady() });
  } catch (err) {
    send("error", { message: err.message });
  } finally {
    res.end();
  }
});

// --- Load an already-downloaded model -------------------------------------
app.post("/api/load", async (req, res) => {
  try {
    await loadModel(req.body.id);
    res.json({ ok: true, loadedModelId: getLoadedModelId(), ready: isReady() });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// --- Upload & ingest a bank statement -------------------------------------
app.post("/api/upload", upload.single("file"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "No file uploaded." });
  try {
    const { originalname, buffer } = req.file;
    const parsed = await parseFile(originalname, buffer);
    if (!parsed.chunks.length) {
      return res
        .status(400)
        .json({ error: "Could not read any rows/text from that file." });
    }
    const summary = computeStatsSummary(parsed.columns, parsed.records);
    replaceDocument({
      fileName: originalname,
      columns: parsed.columns,
      rowCount: parsed.rowCount,
      chunks: parsed.chunks,
      summary,
    });

    replaceChromaDocument(parsed.chunks, { fileName: originalname });
    cacheDel("bank:*");

    res.json({ ok: true, document: getMeta() });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.post("/api/reset", (req, res) => {
  clearDocument();
  clearChromaDocument();
  cacheDel("bank:*");
  res.json({ ok: true });
});

// --- Chat (streamed plain-text response) ----------------------------------
function deterministicAnswer(question, meta) {
  if (!meta.summary) return null;
  const facts = meta.summary;
  const q = question.toLowerCase();

  // ── SPECIFIC CATEGORY / PAYEE LOOKUPS (checked first) ──

  const catMatch = q.match(/(?:spend|spent)\s+(?:on|for|at|in)\s+(.+?)(?:\?|$)/i);
  if (catMatch) {
    const term = catMatch[1].trim();
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const m = facts.match(new RegExp(`${escaped}:\\s*\\d+\\s*txn,\\s*spent\\s*\\$?([\\d,]+\\.\\d{2})`, "i"));
    if (m) return `${term}: spent $${m[1]}`;
    const m2 = facts.match(new RegExp(`${escaped}:\\s*\\d+\\s*txn,\\s*earned\\s*\\$?([\\d,]+\\.\\d{2})`, "i"));
    if (m2) return `${term}: earned $${m2[1]}`;
  }

  const earnMatch = q.match(/(?:earn|earned|made)\s+(?:from|on|in)\s+(.+?)(?:\?|$)/i);
  if (earnMatch) {
    const term = earnMatch[1].trim();
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const m = facts.match(new RegExp(`${escaped}:\\s*\\d+\\s*txn,\\s*earned\\s*\\$?([\\d,]+\\.\\d{2})`, "i"));
    if (m) return `${term}: earned $${m[1]}`;
    const m2 = facts.match(new RegExp(`${escaped}:\\s*\\d+\\s*txn,\\s*spent\\s*\\$?([\\d,]+\\.\\d{2})`, "i"));
    if (m2) return `${term}: spent $${m2[1]}`;
  }

  const monthMatch = q.match(/((?:january|february|march|april|may|june|july|august|september|october|november|december)\s*\d{4})/i);
  if (monthMatch) {
    const monthName = monthMatch[1].trim();
    const months = { january: "01", february: "02", march: "03", april: "04", may: "05", june: "06", july: "07", august: "08", september: "09", october: "10", november: "11", december: "12" };
    const yearNum = monthName.match(/(\d{4})/)?.[1] || "2025";
    const monthNum = months[monthName.toLowerCase().replace(/\s*\d{4}/, "")];
    if (monthNum) {
      const key = `${yearNum}-${monthNum}`;
      const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const m = facts.match(new RegExp(`${escaped}:\\s*(.+)`, "i"));
      if (m) return `${monthName}: ${m[1]}`;
    }
  }

  const topMatch = q.match(/top\s*(\d+)\s*(spending|expense)?\s*categor/i);
  if (topMatch) {
    const n = parseInt(topMatch[1]);
    const section = facts.match(/=== TOP SPENDING CATEGORIES ===\n([\s\S]*?)(?:\n\n|\n===|$)/i);
    if (section) return section[1].trim().split("\n").slice(0, n).join("\n");
  }

  if (/\b(all\s+)?(my\s+)?(list\s+)?categor(y|ies)\b/i.test(q) && !/top|spend/i.test(q)) {
    const section = facts.match(/=== CATEGORY BREAKDOWN[\s\S]*?(?=\n\n===|\n$)/i);
    if (section) return section[0].split("\n").filter((l) => l.includes(" txn, ")).join("\n");
  }

  // ── SPECIFIC TRANSACTION QUESTIONS ──

  if ((/\b(biggest|largest|highest)\b/i.test(q)) &&
      /\b(expense|debit|purchase|transaction|payment|spend|spending|charge|withdrawal)\b/i.test(q)) {
    const m = facts.match(/Largest debit:\s*(-?\$-?[\d,]+\.\d{2})\s+to\s+(.+)/i);
    if (m) return `Largest single expense: ${m[1]} to ${m[2]}`;
  }

  if ((/\blargest\b/i.test(q) || /\bbiggest\b/i.test(q) || /\bhighest\b/i.test(q)) &&
      /\b(credit|income|deposit|earning)\b/i.test(q)) {
    const m = facts.match(/Largest credit:\s*(-?\$-?[\d,]+\.\d{2})\s+from\s+(.+)/i);
    if (m) return `Largest single income: ${m[1]} from ${m[2]}`;
  }

// ── Generic financial overview ──

  if ((/\btotal\b/i.test(q) || /\bhow much\b.*\bspen[dt]\b/i.test(q) || /\boverall\b/i.test(q)) &&
      /\b(spen[dt]|expenses?)\b/i.test(q)) {
    const m = facts.match(/Total expenses:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (m) return `Total expenses: ${m[1]}`;
  }

  if ((/\btotal\b/i.test(q) || /\bhow much\b/i.test(q)) &&
      /\bincome\b/i.test(q) && !/\bfrom\b/i.test(q)) {
    const m = facts.match(/Total income:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (m) return `Total income: ${m[1]}`;
  }

  if (/\bnet\b/i.test(q) && /\b(total|income|amount|worth|sum|balance)\b/i.test(q)) {
    const m = facts.match(/Net total:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (m) return `Net total: ${m[1]}`;
  }

  if (/\baverage\b/i.test(q) && /\b(transaction|amount|txn|spend|spending)\b/i.test(q)) {
    const m = facts.match(/Average transaction:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (m) return `Average transaction: ${m[1]}`;
  }

  if (/\bhow many (transaction|row|entry|line)/i.test(q)) {
    const m = facts.match(/Total transactions:\s*(\d+)/i);
    if (m) return `${m[1]} transactions in this statement.`;
  }

  return null;
}

app.post("/api/chat", async (req, res) => {
  const message = String(req.body.message || "").trim();
  if (!message) return res.status(400).json({ error: "Empty message." });
  if (!hasDocument())
    return res
      .status(400)
      .json({ error: "Upload a bank statement first." });

  const meta = getMeta();
  const cacheKey = `bank:chat:${meta.fileName}:${message}`;

  const preAnswer = deterministicAnswer(message, meta);
  if (preAnswer) {
    res.writeHead(200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
      "X-Answer": "deterministic",
    });
    res.write(preAnswer);
    cacheSet(cacheKey, preAnswer, 1800);
    return res.end();
  }

  if (!isReady())
    return res.status(400).json({ error: "No model loaded yet." });

  const cached = await cacheGet(cacheKey);
  if (cached) {
    res.writeHead(200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
      "X-Cache": "HIT",
    });
    res.write(cached);
    return res.end();
  }

  res.writeHead(200, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-cache",
  });

  try {
    const systemPrompt = await buildSystemPrompt(message);
    let fullResponse = "";
    await chat(systemPrompt, message, (chunk) => {
      fullResponse += chunk;
      res.write(chunk);
    });
    cacheSet(cacheKey, fullResponse, 1800);
    res.end();
  } catch (err) {
    res.write(`\n[error] ${err.message}`);
    res.end();
  }
});

app.listen(PORT, () => {
  console.log(`\n  Local LLM Bank Assistant running:  http://localhost:${PORT}\n`);
});
