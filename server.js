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

// Precise aggregation over the structured records (exact sums the LLM can't do
// reliably). Returns a string answer, or null to fall through to summary/LLM.
const STOP_TERMS = new Set([
  "food", "delivery", "groceries", "grocery", "internet", "mobile", "recharge",
  "entertainment", "like", "money", "total", "overall", "my", "the", "a", "an",
  "in", "on", "for", "at", "to", "of", "spending", "spend", "spent", "transaction",
  "transactions", "account", "statement", "period", "entire", "things", "stuff",
  "payment", "payments", "everything", "all", "month", "months",
  "january", "february", "march", "april", "may", "june", "july", "august",
  "september", "october", "november", "december",
]);
const money = (n) => fmtAmountLabel(Math.abs(n));

function termToKeywords(term) {
  return term
    .split(/,|\band\b|\/|&|\+|;/)
    .map((s) => s.replace(/[?.!,]/g, "").replace(/\b(in total|across all months|across|every month|per month|each month|monthly|during|over|specifically)\b/gi, "").trim())
    .filter((s) => s.length > 1 && !STOP_TERMS.has(s.toLowerCase()));
}

function extractEntityKeywords(question) {
  const paren = question.match(/\(([^)]+)\)/);
  if (paren) { const k = termToKeywords(paren[1]); if (k.length) return k; }
  const like = question.match(/\blike\s+(.+?)(?:\?|$)/i);
  if (like) { const k = termToKeywords(like[1]); if (k.length) return k; }
  // Capitalized proper nouns (skip question/stop words)
  const caps = [...question.matchAll(/\b([A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+){0,2})\b/g)]
    .map((m) => m[1])
    .filter((c) => !/^(How|What|Which|Did|Do|Does|Is|Are|My|The|Yes|No|I|A|An|Spending|Total)$/i.test(c.split(" ")[0]) || c.split(" ").length > 1);
  if (caps.length) { const k = termToKeywords(caps.join(", ")); if (k.length) return k; }
  const prep = question.match(/\b(?:to|on|for|at)\s+(.+?)(?:\?|$)/i);
  if (prep) { const k = termToKeywords(prep[1]); if (k.length) return k; }
  return [];
}

function preciseAnswer(question) {
  const records = getRecords();
  if (!records.length) return null;
  const q = question.toLowerCase();
  const perMonth = /\b(every month|per month|each month|monthly|month wise|month-wise|by month)\b/i.test(question);

  // Global total spending (no specific merchant) — e.g. "total spending for the
  // entire statement period", "how much did I spend overall"
  if (/\b(spend|spending|spent|expenses?)\b/i.test(q) && /\b(total|overall|altogether|entire|in all|in total)\b/i.test(q)) {
    const ents = extractEntityKeywords(question);
    const meaningful = ents.filter((e) => aggregateByKeywords(records, [e]).count > 0);
    if (!meaningful.length) {
      const debits = records.filter((r) => recAmount(r) < 0);
      const tot = debits.reduce((s, r) => s + Math.abs(recAmount(r)), 0);
      return `Total spending: ${money(tot)} across ${debits.length} debit transactions.`;
    }
  }

  // UPI count
  if (/\bupi\b/i.test(q) && /\b(how many|number of|count|total number|how much)\b/i.test(q)) {
    const n = records.filter((r) => /upi/i.test(r.Description)).length;
    return `${n} of ${records.length} transactions were made via UPI.`;
  }

  // Smallest single expense
  if (/\b(smallest|least|lowest|minimum|tiniest)\b/i.test(q) && /\b(amount|spent|spend|transaction|expense|purchase)\b/i.test(q) && !/categor|month/i.test(q)) {
    const s = smallestDebit(records);
    if (s) return `Smallest expense: ${money(recAmount(s))} — ${payeeOf(s)} on ${s.Date}.`;
  }

  // Top-N largest expenses
  const topN = q.match(/top\s*(\d+)/i);
  if (topN && /\b(transaction|purchase|expense|spending|spend|payment)\b/i.test(q) && !/categor/i.test(q)) {
    const n = Math.min(20, Math.max(1, parseInt(topN[1])));
    const list = topTransactions(records, n, "debit").map((r, i) => `${i + 1}. ${money(recAmount(r))} — ${payeeOf(r)} (${r.Date})`);
    return `Top ${n} largest expenses:\n${list.join("\n")}`;
  }
  if (/\b(biggest|largest|highest)\b/i.test(q) && /\b(single\s+)?(transaction|purchase|expense|payment|debit)\b/i.test(q) && !/categor|month|income|credit|deposit/i.test(q)) {
    const t = topTransactions(records, 1, "debit")[0];
    if (t) return `Largest single expense: ${money(recAmount(t))} — ${payeeOf(t)} on ${t.Date}.`;
  }
  if (/\b(biggest|largest|highest)\b/i.test(q) && /\b(income|credit|deposit|salary|received)\b/i.test(q)) {
    const t = topTransactions(records, 1, "credit")[0];
    if (t) return `Largest single credit: ${money(recAmount(t))} — ${payeeOf(t)} on ${t.Date}.`;
  }

  // Salary (credits matching "salary"; excludes EarlySalary loan debits)
  if (/\bsalary\b/i.test(q)) {
    const a = aggregateByKeywords(records, ["salary"]);
    const credits = [...a.byMonth.entries()].filter(([, mm]) => mm.credit > 0).sort();
    if (a.credit > 0) {
      if (perMonth) {
        const lines = credits.map(([m, mm]) => `  ${monthLabel(m)}: ${money(mm.credit)}`);
        return `Salary credited by month:\n${lines.join("\n")}\nTotal salary: ${money(a.credit)} (${credits.length} credits).`;
      }
      return `Total salary credited: ${money(a.credit)} across ${credits.length} salary credits.`;
    }
  }

  // Interest earned
  if (/\binterest\b/i.test(q)) {
    const a = aggregateByKeywords(records, ["interest"]);
    if (a.credit > 0) return `Total interest earned: ${money(a.credit)} (${a.matched.filter((r) => recAmount(r) > 0).length} credits).`;
  }

  // Money received from people (non-salary/interest credits, excluding reversals & self)
  if (/\b(receive|received|got|credited)\b/i.test(q) && /\b(people|others|other people|someone|anyone|friends|else|individuals)\b/i.test(q)) {
    const credits = records.filter((r) => recAmount(r) > 0 && !/salary|interest|\bREV\b|reversal|abhishek kumar/i.test(r.Description));
    const total = credits.reduce((s, r) => s + recAmount(r), 0);
    return `Yes. Excluding salary and interest, you received ${money(total)} across ${credits.length} credits from other parties (transfers, refunds, etc.).`;
  }

  // Which month most / least spending
  if (/\bmonth\b/i.test(q) && /\b(most|highest|maximum|max|biggest)\b/i.test(q) && /\b(spen|expense)/i.test(q)) {
    const mm = monthlyDebit(records); const arr = [...mm.entries()].sort((a, b) => b[1] - a[1]);
    if (arr.length) return `You spent the most in ${monthLabel(arr[0][0])}: ${money(arr[0][1])}.`;
  }
  if (/\bmonth\b/i.test(q) && /\b(least|lowest|minimum|min|smallest)\b/i.test(q) && /\b(spen|expense)/i.test(q)) {
    const mm = monthlyDebit(records); const arr = [...mm.entries()].sort((a, b) => a[1] - b[1]);
    if (arr.length) return `You spent the least in ${monthLabel(arr[0][0])}: ${money(arr[0][1])}.`;
  }

  // Entity / merchant aggregation
  if (/\b(spen[dt]|spending|pay|paid|send|sent|transfer|how much|total|cost|charge)\b/i.test(q)) {
    const keywords = extractEntityKeywords(question);
    if (keywords.length) {
      const a = aggregateByKeywords(records, keywords);
      if (a.count > 0) {
        const credit = /from me\b/i.test(question)
          ? false
          : /\b(received|got|credited|came from|income from)\b/i.test(question) && !/\b(spen[dt]|pay|paid|send|sent)\b/i.test(question);
        const label = keywords.join(", ");
        if (perMonth) {
          const lines = [...a.byMonth.entries()].sort().map(([m, mm]) => `  ${monthLabel(m)}: ${money(credit ? mm.credit : mm.debit)} (${mm.count} txn)`);
          const total = credit ? a.credit : a.debit;
          return `${credit ? "Received from" : "Paid to"} ${label} by month:\n${lines.join("\n")}\nTotal: ${money(total)} across ${a.count} transactions.`;
        }
        const value = credit ? a.credit : a.debit;
        return `${credit ? "Total received from" : "Total spent on"} ${label}: ${money(value)} across ${a.count} transaction${a.count > 1 ? "s" : ""}.`;
      }
    }
  }

  return null;
}

function monthlyDebit(records) {
  const m = new Map();
  for (const r of records) {
    const n = recAmount(r);
    if (n < 0) m.set(recMonth(r), (m.get(recMonth(r)) || 0) + Math.abs(n));
    else if (!m.has(recMonth(r))) m.set(recMonth(r), m.get(recMonth(r)) || 0);
  }
  return m;
}

function deterministicAnswer(question, meta) {
  const precise = preciseAnswer(question);
  if (precise) return precise;
  if (!meta.summary) return null;
  const facts = meta.summary;
  const q = question.toLowerCase();

  const months = { january:"01", february:"02", march:"03", april:"04", may:"05", june:"06", july:"07", august:"08", september:"09", october:"10", november:"11", december:"12" };

  const extractSection = (label) => {
    const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`=== ${escaped}(?:\\s*\\([^)]*\\))? ===\\n([\\s\\S]*?)(?:\\n\\n===|\\n===|$)`, "i");
    const m = facts.match(re);
    return m ? m[1].trim() : null;
  };

  const extractNumber = (label) => {
    const m = facts.match(new RegExp(`${label}:\\s*(-?[^\\d]*[\\d,]+\\.\\d{2})`, "i"));
    return m ? m[1] : null;
  };

  const fuzzyMatch = (term, text) => {
    const t = term.toLowerCase().replace(/[^a-z0-9]/g, "");
    const txt = text.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (txt.includes(t) || t.includes(txt)) return true;
    // Word-level: "freelancing" ↔ "freelance" — check prefix up to common length
    const words = txt.match(/[a-z]+/g) || [];
    return words.some(w => {
      const minLen = Math.min(t.length, w.length, 5);
      return t.substring(0, minLen) === w.substring(0, minLen);
    });
  };

  const matchPayee = (term) => {
    const esc = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    for (const section of ["TOP 20 PAYEES BY TOTAL VOLUME", "TOP SPENDING CATEGORIES", "CATEGORY BREAKDOWN"]) {
      const sec = extractSection(section);
      if (!sec) continue;
      const lines = sec.split("\n");
      for (const line of lines) {
        if (fuzzyMatch(term, line)) return line;
      }
    }
    return null;
  };

  const matchCategory = (term) => {
    for (const section of ["CATEGORY BREAKDOWN", "TOP SPENDING CATEGORIES", "BOTTOM 10 SPENDING CATEGORIES"]) {
      const sec = extractSection(section);
      if (!sec) continue;
      const lines = sec.split("\n");
      for (const line of lines) {
        if (fuzzyMatch(term, line)) return line;
      }
    }
    return null;
  };

  // ── CHECK SPECIFIC PATTERNS FIRST (before generic "how much") ──

  // Balance check
  if (/\b(remaining|current|closing|available|left)\s+balance\b/i.test(q) ||
      /\bbalance\s+(?:remaining|left|now)\b/i.test(q) ||
      (/\bbalance\b/i.test(q) && /\bhow much\b/i.test(q))) {
    const sec = extractSection("REMAINING BALANCE");
    if (sec) return sec;
    return "No balance data available.";
  }

  // Monthly — must check BEFORE generic "how much"
  if (/\bthis month\b/i.test(q) || /\bcurrent month\b/i.test(q)) {
    const now = new Date();
    const key = `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,"0")}`;
    const m = facts.match(new RegExp(`${key}:\\s*(.+)`, "i"));
    if (m) return `This month (${key}): ${m[1]}`;
    return `No data for the current month (${key}).`;
  }

  // Month with year: "january 2025"
  const monthYear = q.match(new RegExp(`(${Object.keys(months).join("|")})\\s*(\\d{4})`, "i"));
  if (monthYear) {
    const mName = monthYear[1].toLowerCase();
    const year = monthYear[2];
    const key = `${year}-${months[mName]}`;
    const m = facts.match(new RegExp(`${key}:\\s*(.+)`, "i"));
    if (m) return `${monthYear[0]}: ${m[1]}`;
    return `No data for ${monthYear[0]}.`;
  }

  // Month alone: "in january", "spent in march"
  const monthAlone = q.match(new RegExp(`\\b(${Object.keys(months).join("|")})\\b`, "i"));
  if (monthAlone && !/\d{4}/.test(q)) {
    const mName = monthAlone[1].toLowerCase();
    const prefix = months[mName];
    const m = facts.match(new RegExp(`^2025-${prefix}:\\s*(.+)`, "im"));
    if (m) return `${monthAlone[1]}: ${m[1]}`;
  }

  // Least/lowest spending
  if (/\b(smallest|least|lowest|minimum|very less|less|bottom)\b/i.test(q) && /\b(spen[dt]|category|thing|on)\b/i.test(q)) {
    const sec = extractSection("BOTTOM 10 SPENDING CATEGORIES");
    if (sec) {
      const lines = sec.split("\n").slice(0, 5);
      return `Least spending categories:\n${lines.join("\n")}`;
    }
  }

  // Biggest/largest/highest
  if (/(\bhighest\b|\bbiggest\b|\blargest\b)/i.test(q)) {
    if (/\b(spen[dt]|expense|debit|payment|purchase)\b/i.test(q) || /\bamount\b.*\bspen[dt]\b/i.test(q)) {
      const m = facts.match(/Largest debit:\s*(-?[^\d]*[\d,]+\.\d{2})\s+to\s+(.+)/i);
      if (m) return `Largest single expense: ${m[1]} to ${m[2]}`;
    }
    if (/\b(credit|income|deposit|earn)\b/i.test(q)) {
      const m = facts.match(/Largest credit:\s*(-?[^\d]*[\d,]+\.\d{2})\s+from\s+(.+)/i);
      if (m) return `Largest single income: ${m[1]} from ${m[2]}`;
    }
  }

  // ── SPECIFIC PAYEE/CATEGORY (now after pattern checks) ──

  const spendOn = q.match(/(?:spen[dt]|spending)\s+(?:on|for|at|in)\s+(.+?)(?:\?|$)/i);
  if (spendOn) {
    const term = spendOn[1].trim().replace(/[?.,!]/g, "");
    const result = matchPayee(term) || matchCategory(term);
    if (result) return result;
    if (term.length > 2 && !/\b(month|year|week|day|total|balance)\b/i.test(term)) {
      return `"${term}" not found in this statement.`;
    }
  }

  const totalOn = q.match(/(?:total|overall)\s+(?:expenses?|spending|spent)\s+(?:on|for)\s+(.+?)(?:\?|$)/i);
  if (totalOn) {
    const term = totalOn[1].trim().replace(/[?.,!]/g, "");
    const result = matchPayee(term) || matchCategory(term);
    if (result) return result;
    if (term.length > 2) return `"${term}" not found in this statement.`;
  }

  const earnMatch = q.match(/(?:earn|earned|made)\s+(?:from|on|in)\s+(.+?)(?:\?|$)/i);
  if (earnMatch) {
    const term = earnMatch[1].trim().replace(/[?.,!]/g, "");
    const result = matchPayee(term) || matchCategory(term);
    if (result) return result;
    if (term.length > 2) return `"${term}" not found in this statement.`;
  }

  // ── GENERIC FINANCIAL NUMBERS ──

  const howMuchX = q.match(/how\s+much\s+(?:did\s+(?:i|we)\s+)?(?:spend\s+)?(?:on\s+)?(.+?)(?:\?|$)/i);
  if (howMuchX) {
    const term = howMuchX[1].trim().replace(/[?.,!]/g, "").replace(/\b(total|overall|all)\b/gi, "").trim();
    if (term && term.length > 2 && !/^(much|did|the|my|our|was|is)$/i.test(term) && !/\b(month|year|week|day|balance)\b/i.test(term)) {
      const result = matchPayee(term) || matchCategory(term);
      if (result) return result;
    }
  }

  if ((/\btotal\b/i.test(q) || /\bhow much\b.*\bspen[dt]\b/i.test(q) || /\boverall\b/i.test(q)) && /\b(spen[dt]|expenses?)\b/i.test(q) && !/\bon\b/i.test(q)) {
    const m = extractNumber("Total expenses");
    if (m) return `Total expenses: ${m}`;
  }

  if ((/\btotal\b/i.test(q) || /\bhow much\b/i.test(q)) && /\bincome\b/i.test(q) && !/\bfrom\b/i.test(q) && !/\bnet\b/i.test(q)) {
    const m = extractNumber("Total income");
    if (m) return `Total income: ${m}`;
  }

  if (/\bnet\b/i.test(q) && /\b(total|income|amount|worth|sum|balance)\b/i.test(q)) {
    const m = extractNumber("Net total");
    if (m) return `Net total: ${m}`;
  }

  if (/\baverage\b/i.test(q) && /\b(transaction|amount|txn|spend|spending)\b/i.test(q)) {
    const m = extractNumber("Average transaction");
    if (m) return `Average transaction: ${m}`;
  }

  if (/\bhow many (transaction|row|entry|line)/i.test(q)) {
    const m = facts.match(/Total transactions:\s*(\d+)/i);
    if (m) return `${m[1]} transactions in this statement.`;
  }

  // Top / bottom N
  const topMatch = q.match(/top\s*(\d+)\s*(spending|expense)?\s*categor/i);
  if (topMatch) {
    const sec = extractSection("TOP SPENDING CATEGORIES");
    if (sec) return sec.split("\n").slice(0, parseInt(topMatch[1])).join("\n");
  }

  const bottomMatch = q.match(/bottom\s*(\d+)\s*(spending|expense)?\s*categor/i);
  if (bottomMatch) {
    const sec = extractSection("BOTTOM 10 SPENDING CATEGORIES");
    if (sec) return sec.split("\n").slice(0, parseInt(bottomMatch[1])).join("\n");
  }

  if (/\b(all\s+)?(my\s+)?(list\s+)?categor(y|ies)\b/i.test(q) && !/top|spend|bottom/i.test(q)) {
    const sec = extractSection("CATEGORY BREAKDOWN");
    if (sec) return sec.split("\n").filter(l => l.includes(" txn, ")).join("\n");
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
