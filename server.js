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
  replaceTransactions,
  hasTransactions,
  txOverview,
  txKeyword,
  txKeywordByMonth,
  txMonthSpend,
  txMonthlySpend,
  txYearMonthly,
  txCategorySpend,
  txKeywordMonth,
  txCategoryMonth,
  txLargestDebit,
  txLargestCredit,
  txSmallestDebit,
  txTopDebits,
  txReceivedFromPeople,
  txCategoryBreakdown,
  txRecent,
  txCurrentBalance,
  txTopPayees,
  txSubscriptions,
  txPage,
  hasMonthSummaries,
  getMonthSummary,
  getMonthSummaries,
  yearMonthSummaries,
} from "./src/db.js";
import { rebuildPeriods, updateMonthAndRebuild } from "./src/summaries.js";
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
import { fmtAmountLabel, getCurrencyCode, setCurrency, getCurrencySymbol } from "./src/currency.js";
import { categorize } from "./src/periods.js";
import {
  listDownloadedModels,
  downloadModel,
  loadModel,
  getLoadedModelId,
  isReady,
  chat,
  routeIntent,
} from "./src/llm.js";
import { buildSystemPrompt, isPeriodQuestion, periodExactAnswer } from "./src/rag.js";
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
    const records = (parsed.records || []).map((r) => ({ ...r, Category: r.Category || categorize(r) }));
    const summary = computeStatsSummary(parsed.columns, records);
    replaceDocument({
      fileName: originalname,
      columns: parsed.columns,
      rowCount: parsed.rowCount,
      chunks: parsed.chunks,
      summary,
      records: [], // stored in the transactions table instead of a JSON blob
      currency: getCurrencyCode(),
    });
    replaceTransactions(records);

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

// Dashboard data — everything the post-upload overview needs, in one shot.
app.get("/api/dashboard", (req, res) => {
  if (!hasTransactions()) return res.json({ ready: false });
  const meta = getMeta();
  const o = txOverview();
  const months = getMonthSummaries();
  const lg = txLargestDebit(), sm = txSmallestDebit();
  res.json({
    ready: true,
    fileName: meta.fileName,
    currency: getCurrencySymbol() || "₹",
    totals: { income: o.credit, spending: o.debit, net: o.credit - o.debit, count: o.count, upi: o.upi },
    balance: txCurrentBalance(),
    categories: txCategoryBreakdown(8).map((c) => ({ name: c.category, amount: c.spend, count: c.count })),
    recent: txRecent(12).map((r) => ({ date: r.date, payee: r.payee, category: r.category, amount: r.amount })),
    months: months.map((m) => ({ ym: m.ym, income: m.income, spending: m.spending, net: m.net, count: m.count })),
    topPayees: txTopPayees(6).map((p) => ({ name: p.payee, amount: p.spend, count: p.count })),
    subscriptions: txSubscriptions().map((s) => ({ name: s.payee, total: s.total, count: s.count, last: s.last })),
    largest: lg ? { amount: lg.amount, payee: lg.payee, date: lg.date } : null,
    smallest: sm ? { amount: sm.amount, payee: sm.payee, date: sm.date } : null,
  });
});

// Paged + searchable raw transactions (for the "Your data" tab).
app.get("/api/transactions", (req, res) => {
  if (!hasTransactions()) return res.json({ total: 0, rows: [] });
  const offset = Math.max(0, parseInt(req.query.offset, 10) || 0);
  const limit = Math.min(200, Math.max(1, parseInt(req.query.limit, 10) || 50));
  res.json(txPage({ offset, limit, q: String(req.query.q || "") }));
});

// Re-put one month's transactions → recompute that month's summary + rollups.
app.post("/api/update-month", async (req, res) => {
  const { ym, records } = req.body || {};
  if (!ym || !Array.isArray(records)) return res.status(400).json({ error: "Provide { ym: 'YYYY-MM', records: [...] }" });
  try {
    const r = await updateMonthAndRebuild(ym, records);
    res.json({ ok: true, ...r, summary: getMonthSummary(ym) });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
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
const money = (n) => getCurrencySymbol() + Math.abs(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

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

// SQL-backed exact answers — constant memory at any row count (lakhs+).
// Answers are returned as Markdown (heading + table) for readable rendering.
const MN_NUM = { january: "01", february: "02", march: "03", april: "04", may: "05", june: "06", july: "07", august: "08", september: "09", october: "10", november: "11", december: "12" };
const cap1 = (s) => s[0].toUpperCase() + s.slice(1).toLowerCase();
const num = (n) => Number(n).toLocaleString("en-IN");
const mdTable = (headers, rows) =>
  `| ${headers.join(" | ")} |\n| ${headers.map(() => "---").join(" | ")} |\n` + rows.map((r) => `| ${r.join(" | ")} |`).join("\n");
const factTable = (title, rows) => `**${title}**\n\n${mdTable(["Field", "Value"], rows)}`;
const CAT_Q = [
  [/grocer/i, "Groceries"], [/\btransport|commut/i, "Transport"],
  [/food|dining|restaurant/i, "Food & Dining"], [/shopping/i, "Shopping"],
  [/utilit|\bbills?\b/i, "Utilities"], [/entertain/i, "Entertainment"],
  [/health|medical/i, "Healthcare"], [/invest|insurance/i, "Investment & Insurance"],
];

function preciseAnswer(question) {
  if (!hasTransactions()) return null;
  const q = question.toLowerCase();
  const perMonth = /\b(every month|per month|each month|monthly|month wise|month-wise|by month)\b/i.test(question);

  // Global total spending (no specific merchant)
  if (/\b(spend|spending|spent|expenses?)\b/i.test(q) && /\b(total|overall|altogether|entire|in all|in total)\b/i.test(q)) {
    const ents = extractEntityKeywords(question);
    if (!ents.some((e) => txKeyword([e]).count > 0)) {
      const o = txOverview();
      return factTable("Total spending", [["Total spent", money(o.debit)], ["Debit transactions", num(o.debitCount)]]);
    }
  }

  // Spending on an entity OR category within a specific month
  if (/\b(spen[dt]|spending|pay|paid|cost|how much)\b/i.test(q)) {
    const mm = question.match(new RegExp(`\\b(${Object.keys(MN_NUM).join("|")})\\s+(\\d{4})\\b`, "i"));
    if (mm) {
      const ym = `${mm[2]}-${MN_NUM[mm[1].toLowerCase()]}`;
      const when = `${cap1(mm[1])} ${mm[2]}`;
      for (const [re, cat] of CAT_Q) {
        if (re.test(q)) { const c = txCategoryMonth(cat, ym); if (c && c.count > 0) return factTable(`${cat} — ${when}`, [["Spent", money(c.debit)], ["Transactions", num(c.count)]]); }
      }
      const kws = extractEntityKeywords(question.replace(mm[0], " ").replace(/\bin\b/gi, " "));
      if (kws.length) { const a = txKeywordMonth(kws, ym); if (a && a.count > 0) return factTable(`${kws.join(", ")} — ${when}`, [["Spent", money(a.debit)], ["Transactions", num(a.count)]]); }
    }
  }

  // Spending in a specific month (whole month)
  if (/\b(spen[dt]|spending|expense|cost)\b/i.test(q)) {
    const mm = question.match(new RegExp(`\\b(${Object.keys(MN_NUM).join("|")})\\s+(\\d{4})\\b`, "i"));
    if (mm) {
      const m = getMonthSummary(`${mm[2]}-${MN_NUM[mm[1].toLowerCase()]}`); // materialized summary
      if (m && m.count > 0) return factTable(`Spending — ${cap1(mm[1])} ${mm[2]}`, [["Spent", money(m.spending)], ["Transactions", num(m.count)]]);
    }
  }

  // UPI count
  if (/\bupi\b/i.test(q) && /\b(how many|number of|count|total number|how much)\b/i.test(q)) {
    const o = txOverview();
    return factTable("UPI transactions", [["UPI payments", num(o.upi)], ["Total transactions", num(o.count)]]);
  }

  // Smallest single expense
  if (/\b(smallest|least|lowest|minimum|tiniest)\b/i.test(q) && /\b(amount|spent|spend|transaction|expense|purchase)\b/i.test(q) && !/categor|month/i.test(q)) {
    const s = txSmallestDebit();
    if (s) return factTable("Smallest expense", [["Amount", money(s.amount)], ["Payee", s.payee], ["Date", s.date]]);
  }

  // Top-N largest expenses
  const topN = q.match(/top\s*(\d+)/i);
  if (topN && /\b(transactions?|purchases?|expenses?|spending|spent|spend|payments?)\b/i.test(q) && !/categor/i.test(q)) {
    const n = Math.min(20, Math.max(1, parseInt(topN[1])));
    const rows = txTopDebits(n).map((r, i) => [i + 1, money(r.amount), r.payee, r.date]);
    return `**Top ${n} largest expenses**\n\n${mdTable(["#", "Amount", "Payee", "Date"], rows)}`;
  }
  if (/\b(biggest|largest|highest)\b/i.test(q) && /\b(single\s+)?(transaction|purchase|expense|payment|debit)\b/i.test(q) && !/categor|month|income|credit|deposit/i.test(q)) {
    const t = txLargestDebit();
    if (t) return factTable("Largest single expense", [["Amount", money(t.amount)], ["Payee", t.payee], ["Date", t.date]]);
  }
  if (/\b(biggest|largest|highest)\b/i.test(q) && /\b(income|credit|deposit|salary|received)\b/i.test(q)) {
    const t = txLargestCredit();
    if (t) return factTable("Largest single credit", [["Amount", money(t.amount)], ["From", t.payee], ["Date", t.date]]);
  }

  // Salary
  if (/\bsalary\b/i.test(q)) {
    const a = txKeyword(["salary"]);
    if (a.credit > 0) {
      if (perMonth) {
        const rows = txKeywordByMonth(["salary"]).filter((r) => r.credit > 0).map((r) => [monthLabel(r.ym), money(r.credit)]);
        rows.push(["**Total**", `**${money(a.credit)}**`]);
        return `**Salary credited by month**\n\n${mdTable(["Month", "Amount"], rows)}`;
      }
      return factTable("Salary credited", [["Total salary", money(a.credit)]]);
    }
  }

  // Interest earned
  if (/\binterest\b/i.test(q)) {
    const a = txKeyword(["interest"]);
    if (a.credit > 0) return factTable("Interest earned", [["Total interest", money(a.credit)]]);
  }

  // Money received from people
  if (/\b(receive|received|got|credited)\b/i.test(q) && /\b(people|others|other people|someone|anyone|friends|else|individuals)\b/i.test(q)) {
    const p = txReceivedFromPeople();
    return factTable("Received from others (excl. salary & interest)", [["Total received", money(p.credit)], ["Credits", num(p.count)]]);
  }

  // Which month most / least spending (from materialized month summaries)
  if (/\bmonth\b/i.test(q) && /\b(most|highest|maximum|max|biggest)\b/i.test(q) && /\b(spen|expense)/i.test(q)) {
    const ms = getMonthSummaries();
    if (ms.length) { const t = [...ms].sort((a, b) => b.spending - a.spending)[0]; return factTable("Highest-spending month", [["Month", monthLabel(t.ym)], ["Spent", money(t.spending)]]); }
  }
  if (/\bmonth\b/i.test(q) && /\b(least|lowest|minimum|min|smallest)\b/i.test(q) && /\b(spen|expense)/i.test(q)) {
    const ms = getMonthSummaries();
    if (ms.length) { const t = [...ms].sort((a, b) => a.spending - b.spending)[0]; return factTable("Lowest-spending month", [["Month", monthLabel(t.ym)], ["Spent", money(t.spending)]]); }
  }

  // Entity / merchant aggregation
  if (/\b(spen[dt]|spending|pay|paid|send|sent|transfer|how much|total|cost|charge)\b/i.test(q)) {
    const keywords = extractEntityKeywords(question);
    if (keywords.length) {
      const a = txKeyword(keywords);
      if (a.count > 0) {
        const credit = /from me\b/i.test(question)
          ? false
          : /\b(received|got|credited|came from|income from)\b/i.test(question) && !/\b(spen[dt]|pay|paid|send|sent)\b/i.test(question);
        const label = keywords.join(", ");
        if (perMonth) {
          const rows = txKeywordByMonth(keywords).map((r) => [monthLabel(r.ym), money(credit ? r.credit : r.debit), num(r.count)]);
          rows.push(["**Total**", `**${money(credit ? a.credit : a.debit)}**`, `**${num(a.count)}**`]);
          return `**${credit ? "Received from" : "Paid to"} ${label} — by month**\n\n${mdTable(["Month", "Amount", "Txns"], rows)}`;
        }
        return factTable(`${credit ? "Received from" : "Spent on"} ${label}`, [[credit ? "Received" : "Spent", money(credit ? a.credit : a.debit)], ["Transactions", num(a.count)]]);
      }
    }
  }

  // Spending by category (after entity, so "food delivery (Swiggy...)" still wins)
  if (/\b(spen[dt]|spending|expense|cost|how much)\b/i.test(q)) {
    for (const [re, cat] of CAT_Q) {
      if (!re.test(q)) continue;
      const c = txCategorySpend(cat);
      if (c.count > 0) return factTable(`Spending — ${cat}`, [["Spent", money(c.debit)], ["Transactions", num(c.count)]]);
    }
  }

  return null;
}

// Month-by-month breakdown for a whole year (e.g. "month-wise expenditure 2024")
// — served straight from the materialized month summaries.
function yearBreakdown(question) {
  if (!hasMonthSummaries()) return null;
  const q = question.toLowerCase();
  const yr = question.match(/\b(20\d{2})\b/);
  const monthly = /\bmonth(ly)?\b|month[- ]?wise|each month|per month|every month|month by month|breakdown/i.test(q);
  if (!yr || !monthly) return null;
  if (new RegExp(`\\b(${Object.keys(MN_NUM).join("|")})\\b`, "i").test(q)) return null; // specific month → other handler
  const rows = yearMonthSummaries(yr[1]);
  if (!rows.length) return null;
  let ti = 0, ts = 0, tn = 0;
  const body = rows.map((r) => {
    ti += r.income; ts += r.spending; tn += r.count;
    const net = r.income - r.spending;
    return [monthLabel(r.ym), money(r.income), money(r.spending), `${net < 0 ? "-" : "+"}${money(net)}`, num(r.count)];
  });
  body.push(["**Total**", `**${money(ti)}**`, `**${money(ts)}**`, `**${(ti - ts < 0 ? "-" : "+") + money(ti - ts)}**`, `**${num(tn)}**`]);
  return `**Monthly breakdown — ${yr[1]}**\n\n${mdTable(["Month", "Income", "Spending", "Net", "Txns"], body)}`;
}

// Every-month breakdown when no year is given (e.g. "tell me the month wise").
// Served straight from the materialized month summaries — never the LLM.
function allMonthsBreakdown(question) {
  if (!hasMonthSummaries()) return null;
  const q = question.toLowerCase();
  const monthly = /month[- ]?wise|each month|per month|every month|month by month|\bmonthly\b|by month/i.test(q);
  if (!monthly) return null;
  if (/\b(20\d{2})\b/.test(q)) return null; // year given → yearBreakdown handles it
  if (new RegExp(`\\b(${Object.keys(MN_NUM).join("|")})\\b`, "i").test(q)) return null; // specific month → other handler
  const rows = getMonthSummaries();
  if (!rows.length) return null;
  let ti = 0, ts = 0, tn = 0;
  const body = rows.map((r) => {
    ti += r.income; ts += r.spending; tn += r.count;
    const net = r.income - r.spending;
    return [monthLabel(r.ym), money(r.income), money(r.spending), `${net < 0 ? "-" : "+"}${money(net)}`, num(r.count)];
  });
  body.push(["**Total**", `**${money(ti)}**`, `**${money(ts)}**`, `**${(ti - ts < 0 ? "-" : "+") + money(ti - ts)}**`, `**${num(tn)}**`]);
  return `**Monthly breakdown — all months**\n\n${mdTable(["Month", "Income", "Spending", "Net", "Txns"], body)}`;
}

// "Which months / years do you have data for?" — lists available months by year.
function monthsAvailable(question) {
  if (!hasMonthSummaries()) return null;
  const q = question.toLowerCase();
  const asksList = /\b(list|which|what|how many|available|range|covered?|do you have|you have)\b/i.test(q);
  const aboutMonths = /\b(months?|years?|periods?|data)\b/i.test(q);
  if (!asksList || !aboutMonths) return null;
  // Don't steal income/spending breakdown queries — those want amounts.
  if (/\b(spen[dt]|spending|income|expense|salary|paid|earn)\b/i.test(q)) return null;
  const ms = getMonthSummaries();
  if (!ms.length) return null;
  const byYear = {};
  for (const r of ms) { const y = r.ym.slice(0, 4); (byYear[y] ||= []).push(r); }
  const years = Object.keys(byYear).sort();
  const body = [];
  for (const y of years) {
    const rows = byYear[y];
    const names = rows.map((r) => monthLabel(r.ym).split(" ")[0]).join(", ");
    const cnt = rows.reduce((s, r) => s + r.count, 0);
    body.push([y, num(rows.length), names, num(cnt)]);
  }
  const totMonths = ms.length, totTx = ms.reduce((s, r) => s + r.count, 0);
  body.push([`**Total**`, `**${num(totMonths)}**`, "", `**${num(totTx)}**`]);
  return `**Data coverage — ${monthLabel(ms[0].ym)} to ${monthLabel(ms[ms.length - 1].ym)}**\n\n${mdTable(["Year", "Months", "Which months", "Txns"], body)}`;
}

// Overall summary / overview / "how much data" — totals + full month-year table.
// Pure SQL aggregation, never the LLM (a small model invents huge wrong figures).
function overviewSummary(question) {
  if (!hasMonthSummaries()) return null;
  const q = question.toLowerCase();
  if (!/\b(summary|overview|snapshot|full picture|how much data|overall|net (loss|gain|position)|total (transactions?|amount)|all (calculations?|the data))\b/i.test(q)) return null;
  if (extractEntityKeywords(question).some((e) => txKeyword([e]).count > 0)) return null; // entity-specific → other handler
  const o = txOverview();
  const bal = txCurrentBalance();
  const net = o.credit - o.debit;
  const totals = [
    ["Transactions", num(o.count)],
    ["Total income (credits)", money(o.credit)],
    ["Total spending (debits)", money(o.debit)],
    ["Net", `${net < 0 ? "-" : "+"}${money(net)}`],
    ["UPI payments", num(o.upi)],
  ];
  if (bal != null) totals.push(["Closing balance", money(bal)]);
  let out = factTable("Overall summary", totals);
  const ms = getMonthSummaries();
  if (ms.length) {
    let ti = 0, ts = 0, tn = 0;
    const body = ms.map((r) => {
      ti += r.income; ts += r.spending; tn += r.count;
      const n = r.income - r.spending;
      return [monthLabel(r.ym), money(r.income), money(r.spending), `${n < 0 ? "-" : "+"}${money(n)}`, num(r.count)];
    });
    body.push(["**Total**", `**${money(ti)}**`, `**${money(ts)}**`, `**${(ti - ts < 0 ? "-" : "+") + money(ti - ts)}**`, `**${num(tn)}**`]);
    out += `\n\n**Month-by-month**\n\n${mdTable(["Month", "Income", "Spending", "Net", "Txns"], body)}`;
  }
  return out;
}

// Deterministic spending snapshot (top categories) — prepended to advice
// answers so the user always sees correct, comma-formatted figures while the
// LLM supplies only the qualitative reasoning.
function spendingSnapshot() {
  if (!hasTransactions()) return null;
  const cats = txCategoryBreakdown(8);
  if (!cats.length) return null;
  const o = txOverview();
  const rows = cats.map((c, i) => [i + 1, c.category, money(c.spend), num(c.count)]);
  return `**Your top spending categories** (total spent ${money(o.debit)})\n\n${mdTable(["#", "Category", "Spent", "Txns"], rows)}`;
}

// Number-free grounding for advice answers: the model gets only ranked NAMES
// (categories + merchants), never figures — so it literally cannot mis-copy a
// number. The exact figures are shown separately in the snapshot table.
function adviceContext() {
  if (!hasTransactions()) return null;
  const cats = txCategoryBreakdown(8).map((c) => c.category);
  const payees = txTopPayees(8).map((p) => p.payee);
  if (!cats.length) return null;
  return `You are a friendly personal-finance assistant. The user's spending categories, highest to lowest, are: ${cats.join(", ")}. Their most-paid merchants are: ${payees.join(", ")}.

Give short, practical, qualitative money-saving advice based on these. IMPORTANT: do NOT state any rupee amounts, numbers, or percentages of totals — the exact figures are already shown to the user in a table. Refer to categories and merchants by name only. Keep it to 3-5 sentences.`;
}

// Option B dispatcher: turn the LLM's structured intent into a deterministic
// SQL-backed table. The model chose the intent; every NUMBER here comes from
// SQL, never the model. Returns markdown, or null if it can't be served exactly
// (caller then falls through to the grounded prose LLM).
function dispatchIntent(intent, question) {
  if (!intent || !hasTransactions()) return null;
  const t = intent.type;
  const ym = /^\d{4}-\d{2}$/.test(intent.month || "") ? intent.month : null;
  const when = ym ? `${cap1(Object.keys(MN_NUM).find((k) => MN_NUM[k] === ym.slice(5)) || "")} ${ym.slice(0, 4)}` : null;

  switch (t) {
    case "overview":
      return overviewSummary("overview summary");
    case "coverage":
      return monthsAvailable("which months do you have data");
    case "month_breakdown":
      return allMonthsBreakdown("month wise");
    case "year_breakdown":
      return /^\d{4}$/.test(intent.year || "") ? yearBreakdown(`month wise ${intent.year}`) : null;

    case "spend_total": {
      const o = txOverview();
      return factTable("Total spending", [["Total spent", money(o.debit)], ["Debit transactions", num(o.debitCount)]]);
    }
    case "income_total": {
      const o = txOverview();
      return factTable("Total income", [["Total received", money(o.credit)], ["Transactions", num(o.count)]]);
    }
    case "balance": {
      const b = txCurrentBalance();
      return b == null ? null : factTable("Closing balance", [["Balance", money(b)]]);
    }
    case "upi_count": {
      const o = txOverview();
      return factTable("UPI transactions", [["UPI payments", num(o.upi)], ["Total transactions", num(o.count)]]);
    }
    case "largest_expense": {
      const r = txLargestDebit();
      return r ? factTable("Largest single expense", [["Amount", money(r.amount)], ["Payee", r.payee], ["Date", r.date]]) : null;
    }
    case "largest_income": {
      const r = txLargestCredit();
      return r ? factTable("Largest single credit", [["Amount", money(r.amount)], ["From", r.payee], ["Date", r.date]]) : null;
    }
    case "smallest_expense": {
      const r = txSmallestDebit();
      return r ? factTable("Smallest expense", [["Amount", money(r.amount)], ["Payee", r.payee], ["Date", r.date]]) : null;
    }
    case "top_expenses": {
      const n = Math.min(20, Math.max(1, intent.n || 5));
      const rows = txTopDebits(n).map((r, i) => [i + 1, money(r.amount), r.payee, r.date]);
      return `**Top ${n} largest expenses**\n\n${mdTable(["#", "Amount", "Payee", "Date"], rows)}`;
    }
    case "salary": {
      const a = txKeyword(["salary"]);
      return a.credit > 0 ? factTable("Salary credited", [["Total salary", money(a.credit)]]) : null;
    }
    case "interest": {
      const a = txKeyword(["interest"]);
      return a.credit > 0 ? factTable("Interest earned", [["Total interest", money(a.credit)]]) : null;
    }
    case "received_from_people": {
      const p = txReceivedFromPeople();
      return factTable("Received from others (excl. salary & interest)", [["Total received", money(p.credit)], ["Credits", num(p.count)]]);
    }
    case "top_payees": {
      const rows = txTopPayees(8).map((r, i) => [i + 1, r.payee, money(r.spend), num(r.count)]);
      return `**Top payees by spend**\n\n${mdTable(["#", "Payee", "Spent", "Txns"], rows)}`;
    }
    case "subscriptions": {
      const subs = txSubscriptions();
      if (!subs || !subs.length) return null;
      const rows = subs.map((s) => [s.payee, money(s.total), num(s.count), s.last]);
      return `**Recurring subscriptions**\n\n${mdTable(["Service", "Spent", "Txns", "Last"], rows)}`;
    }
    case "category": {
      const cat = intent.category;
      if (!cat) return null;
      if (ym) { const c = txCategoryMonth(cat, ym); return c && c.count > 0 ? factTable(`${cat} — ${when}`, [["Spent", money(c.debit)], ["Transactions", num(c.count)]]) : null; }
      const c = txCategorySpend(cat);
      return c.count > 0 ? factTable(`Spending — ${cat}`, [["Spent", money(c.debit)], ["Transactions", num(c.count)]]) : null;
    }
    case "entity": {
      const kw = (intent.entity || "").trim();
      if (!kw) return null;
      const credit = intent.direction === "credit";
      if (ym) {
        const a = txKeywordMonth([kw], ym);
        return a && a.count > 0 ? factTable(`${kw} — ${when}`, [[credit ? "Received" : "Spent", money(credit ? a.credit : a.debit)], ["Transactions", num(a.count)]]) : null;
      }
      const a = txKeyword([kw]);
      return a.count > 0 ? factTable(`${credit ? "Received from" : "Spent on"} ${kw}`, [[credit ? "Received" : "Spent", money(credit ? a.credit : a.debit)], ["Transactions", num(a.count)]]) : null;
    }
    default:
      return null; // advice / unknown → grounded prose LLM
  }
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

  // Exact-figure questions are answered DIRECTLY from the deterministic layer —
  // 100% numeric fidelity, instant, and no model needed (a small LLM can slip a
  // digit when copying large numbers). Only period/trend and open-ended
  // questions go to the LLM.
  // Routing: year monthly-breakdown → period (single window) → other facts.
  // Vague trend/compare and open-ended questions fall through to the LLM.
  const exact = yearBreakdown(message) || allMonthsBreakdown(message) || monthsAvailable(message) || overviewSummary(message) ||
    (isPeriodQuestion(message) ? periodExactAnswer(message) : deterministicAnswer(message, meta));
  if (exact) {
    res.writeHead(200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache",
      "X-Answer": "deterministic",
    });
    res.write(exact);
    return res.end();
  }

  // Option B — LLM as router. When the fast regex layer didn't catch the
  // phrasing, the model classifies the question into a structured intent and
  // SQL produces every number (the model never emits figures). Factual intents
  // become deterministic tables; "advice"/"unknown" go to the grounded prose
  // LLM below — that's where the model actually earns its keep.
  let intentType = null;
  if (isReady()) {
    try {
      const intent = await routeIntent(message);
      intentType = intent?.type || null;
      if (intent && intent.type !== "advice" && intent.type !== "unknown") {
        const routed = dispatchIntent(intent, message);
        if (routed) {
          res.writeHead(200, {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "no-cache",
            "X-Answer": "router",
          });
          res.write(routed);
          return res.end();
        }
      }
    } catch { /* fall through to grounded prose */ }
  }

  // Period/trend + open-ended → LLM (LFM2 2.6B), grounded by the retrieved
  // summaries / facts built in buildSystemPrompt.
  if (!isReady())
    return res.status(400).json({ error: "No model loaded yet." });

  res.writeHead(200, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-cache",
    "X-Answer": "llm",
  });

  try {
    let systemPrompt = await buildSystemPrompt(message);
    // For advice/opinion questions, show the real figures in a table FIRST, then
    // let the model reason qualitatively — it must NOT state its own numbers
    // (a small model mis-copies and mislabels large figures).
    if (intentType === "advice") {
      const snap = spendingSnapshot();
      const ctx = adviceContext();
      if (snap && ctx) {
        res.write(snap + "\n\n");
        systemPrompt = ctx; // number-free grounding: nothing for the model to mis-copy
      }
    }
    await chat(systemPrompt, message, (chunk) => {
      // Sanitize stray currency glyphs the small model sometimes emits (₺/₿/$…) → ₹
      res.write(chunk.replace(/[$¥€£₿₾₺₻₼₽₦₩₪₫₥﷼]/g, "₹"));
    });
    res.end();
  } catch (err) {
    res.write(`\n[error] ${err.message}`);
    res.end();
  }
});

app.listen(PORT, () => {
  console.log(`\n  Local LLM Bank Assistant running:  http://localhost:${PORT}\n`);
});
