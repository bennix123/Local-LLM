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
  getRecords,
  hasDocument,
} from "./src/db.js";
import { parseFile } from "./src/ingest.js";
import { computeStatsSummary } from "./src/stats.js";
import {
  aggregateByKeywords,
  topTransactions,
  smallestDebit,
  recAmount,
  recMonth,
  monthLabel,
  payeeOf,
} from "./src/aggregate.js";
import { fmtAmountLabel, getCurrencyCode, setCurrency } from "./src/currency.js";
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
// Restore the currency detected at upload time (it's runtime-only otherwise).
const _startMeta = getMeta();
if (_startMeta.currency) setCurrency(_startMeta.currency);
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
      records: parsed.records,
      currency: getCurrencyCode(),
    });

    clearChromaDocument();
    replaceChromaDocument(parsed.chunks, { fileName: originalname });

    // Also build contextual embeddings for new data (Anthropic Contextual Retrieval)
    const { contextualizeChunks } = await import("./src/context.js");
    const { replaceChromaDocumentContextual } = await import("./src/chromaDb.js");
    const ctxChunks = contextualizeChunks(parsed.chunks, getMeta());
    replaceChromaDocumentContextual(ctxChunks, { fileName: originalname });

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
app.post("/api/chat", async (req, res) => {
  const message = String(req.body.message || "").trim();
  if (!message) return res.status(400).json({ error: "Empty message." });
  if (!hasDocument())
    return res.status(400).json({ error: "Upload a bank statement first." });

  // Gate: only block true gibberish (random keyboard smashing)
  const realWords = (message.match(/\b[a-zA-Z]{2,}\b/g) || [])
    .filter(w => !/^(xyz|asdf|qwer|zxcv|wasd|uiop|hjkl|bnm)$/i.test(w));
  if (realWords.length < 1) {
    return res.status(400).json({ error: "Please ask a clearer question about your bank statement." });
  }

  if (!isReady())
    return res.status(400).json({ error: "No model loaded yet." });

  const meta = getMeta();
  const cacheKey = `bank:chat:${meta.fileName}:${message}`;
  const cached = await cacheGet(cacheKey);
  if (cached) {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-cache", "X-Cache": "HIT" });
    res.write(cached);
    return res.end();
  }

  res.writeHead(200, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-cache",
  });

  // Signal: retrieving data
  res.write(" Retrieving data...\n\n");

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
