// Local persistence using Node's built-in SQLite (node:sqlite).
// No native compilation needed — works out of the box on macOS & Windows
// (requires Node >= 22.5). FTS5 is compiled in, so we get fast keyword search.

import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DB_PATH = path.join(__dirname, "..", "data", "bank.db");

let db;

export function initDb() {
  if (db) return db;
  // Ensure the data directory exists (DatabaseSync won't create parent dirs).
  fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
  db = new DatabaseSync(DB_PATH);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec(`
    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT
    );
  `);
  // FTS5 table: one row per parsed line/transaction. We keep row_index in an
  // unindexed column so we can reconstruct order and feed the full sheet.
  db.exec(`
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
      content,
      row_index UNINDEXED
    );
  `);
  // Hierarchical period summaries (month + rolling 3/6/9/12-month rollups).
  // `embedding` is a JSON float array so vector search runs in-process (no
  // Chroma server) — required for the offline/iPhone target.
  db.exec(`
    CREATE TABLE IF NOT EXISTS period_summaries (
      id           TEXT PRIMARY KEY,
      anchor       TEXT,
      window       INTEGER,
      period_label TEXT,
      start_date   TEXT,
      end_date     TEXT,
      metrics      TEXT,
      narrative    TEXT,
      embedding    TEXT
    );
  `);
  // On-device prompt cache (Redis fallback). Survives offline.
  db.exec(`
    CREATE TABLE IF NOT EXISTS prompt_cache (
      key   TEXT PRIMARY KEY,
      value TEXT
    );
  `);
  // Structured transactions table — the scalable store. Aggregation runs as
  // indexed SQL (SUM/GROUP BY) so memory stays flat at lakhs of rows, instead
  // of parsing a giant JSON blob per request.
  db.exec(`
    CREATE TABLE IF NOT EXISTS transactions (
      id          INTEGER PRIMARY KEY,
      date        TEXT,
      ym          TEXT,
      description TEXT,
      payee       TEXT,
      category    TEXT,
      amount      REAL,
      balance     REAL,
      is_upi      INTEGER
    );
  `);
  db.exec("CREATE INDEX IF NOT EXISTS idx_tx_ym ON transactions(ym);");
  db.exec("CREATE INDEX IF NOT EXISTS idx_tx_amount ON transactions(amount);");
  db.exec("CREATE INDEX IF NOT EXISTS idx_tx_category ON transactions(category);");
  // Materialized per-(month,year) summary. Recomputed whenever that month's
  // transactions change, so reads/rollups never re-scan raw rows.
  db.exec(`
    CREATE TABLE IF NOT EXISTS month_summaries (
      ym         TEXT PRIMARY KEY,
      income     REAL,
      spending   REAL,
      net        REAL,
      count      INTEGER,
      upi        INTEGER,
      categories TEXT,
      payees     TEXT,
      largest    TEXT
    );
  `);
  return db;
}

/** Replace the entire stored document with a fresh set of text chunks. */
export function replaceDocument({ fileName, columns, rowCount, chunks, summary, records, currency }) {
  db.exec("DELETE FROM chunks;");
  db.exec("DELETE FROM meta;");

  const setMeta = db.prepare("INSERT INTO meta (key, value) VALUES (?, ?);");
  setMeta.run("fileName", fileName);
  setMeta.run("columns", JSON.stringify(columns || []));
  setMeta.run("rowCount", String(rowCount ?? chunks.length));
  setMeta.run("summary", summary || "");
  setMeta.run("records", JSON.stringify(records || []));
  setMeta.run("currency", currency || "");

  const insert = db.prepare(
    "INSERT INTO chunks (content, row_index) VALUES (?, ?);"
  );
  // node:sqlite has no explicit transaction helper; wrap manually for speed.
  db.exec("BEGIN;");
  try {
    chunks.forEach((text, i) => insert.run(text, i));
    db.exec("COMMIT;");
  } catch (e) {
    db.exec("ROLLBACK;");
    throw e;
  }
}

export function clearDocument() {
  db.exec("DELETE FROM chunks;");
  db.exec("DELETE FROM meta;");
}

export function getMeta() {
  const rows = db.prepare("SELECT key, value FROM meta;").all();
  const out = {};
  for (const r of rows) out[r.key] = r.value;
  return {
    fileName: out.fileName || null,
    columns: out.columns ? JSON.parse(out.columns) : [],
    rowCount: out.rowCount ? Number(out.rowCount) : 0,
    summary: out.summary || "",
    currency: out.currency || "",
  };
}

export function getAllChunks() {
  return db
    .prepare("SELECT content FROM chunks ORDER BY row_index ASC;")
    .all()
    .map((r) => r.content);
}

// ── Transactions table (scalable store + SQL aggregation) ───────────────────

export function replaceTransactions(records) {
  db.exec("DELETE FROM transactions;");
  const ins = db.prepare(
    "INSERT INTO transactions (date, ym, description, payee, category, amount, balance, is_upi) VALUES (?,?,?,?,?,?,?,?)"
  );
  db.exec("BEGIN;");
  try {
    for (const r of records) {
      const amt = parseFloat(String(r.Amount).replace(/[^0-9.\-]/g, "")) || 0;
      const desc = r.Description || "";
      const bal = r.Balance != null && r.Balance !== "" ? parseFloat(r.Balance) : null;
      ins.run(r.Date || "", String(r.Date || "").slice(0, 7), desc, desc.split(" - ")[0].trim(),
        r.Category || "Other / Transfers", amt, Number.isNaN(bal) ? null : bal, /upi/i.test(desc) ? 1 : 0);
    }
    db.exec("COMMIT;");
  } catch (e) { db.exec("ROLLBACK;"); throw e; }
  recomputeAllMonths();
}

export function hasTransactions() {
  return Number(db.prepare("SELECT COUNT(*) AS n FROM transactions;").get().n) > 0;
}

/** All transactions as record objects (for batch build / tests; not per-request). */
export function getRecords() {
  if (hasTransactions()) {
    return db.prepare("SELECT date, description, category, amount, balance FROM transactions ORDER BY id;").all().map((r) => ({
      Date: r.date, Description: r.description, Category: r.category,
      Amount: (r.amount >= 0 ? "+" : "") + Number(r.amount).toFixed(2),
      Balance: r.balance != null ? Number(r.balance).toFixed(2) : "",
    }));
  }
  const row = db.prepare("SELECT value FROM meta WHERE key = 'records';").get();
  if (!row || !row.value) return [];
  try { return JSON.parse(row.value); } catch { return []; }
}

// ── SQL aggregation (indexed; constant memory regardless of row count) ───────

export function txOverview() {
  return db.prepare(`SELECT
    COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS debit,
    COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS credit,
    COUNT(*) AS count,
    COALESCE(SUM(is_upi),0) AS upi,
    COALESCE(SUM(CASE WHEN amount<0 THEN 1 ELSE 0 END),0) AS debitCount
    FROM transactions;`).get();
}
function likeClause(keywords) {
  return { where: keywords.map(() => "lower(description) LIKE ?").join(" OR "), params: keywords.map((k) => `%${String(k).toLowerCase()}%`) };
}
export function txKeyword(keywords) {
  const { where, params } = likeClause(keywords);
  return db.prepare(`SELECT COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS debit,
    COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS credit, COUNT(*) AS count
    FROM transactions WHERE ${where};`).get(...params);
}
export function txKeywordByMonth(keywords) {
  const { where, params } = likeClause(keywords);
  return db.prepare(`SELECT ym, COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS debit,
    COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS credit, COUNT(*) AS count
    FROM transactions WHERE ${where} GROUP BY ym ORDER BY ym;`).all(...params);
}
export function txMonthSpend(ym) {
  return db.prepare("SELECT COALESCE(SUM(-amount),0) AS debit, COUNT(*) AS count FROM transactions WHERE ym=? AND amount<0;").get(ym);
}
export function txMonthlySpend() {
  return db.prepare("SELECT ym, COALESCE(SUM(-amount),0) AS debit FROM transactions WHERE amount<0 GROUP BY ym ORDER BY debit DESC;").all();
}
export function txYearMonthly(year) {
  return db.prepare(`SELECT ym,
    COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS debit,
    COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS credit,
    COUNT(*) AS count
    FROM transactions WHERE ym LIKE ? GROUP BY ym ORDER BY ym;`).all(`${year}-%`);
}
export function txCategorySpend(cat) {
  return db.prepare("SELECT COALESCE(SUM(-amount),0) AS debit, COUNT(*) AS count FROM transactions WHERE category=? AND amount<0;").get(cat);
}
export function txKeywordMonth(keywords, ym) {
  const { where, params } = likeClause(keywords);
  return db.prepare(`SELECT COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS debit,
    COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS credit, COUNT(*) AS count
    FROM transactions WHERE ym=? AND (${where});`).get(ym, ...params);
}
export function txCategoryMonth(cat, ym) {
  return db.prepare("SELECT COALESCE(SUM(-amount),0) AS debit, COUNT(*) AS count FROM transactions WHERE ym=? AND category=? AND amount<0;").get(ym, cat);
}
export function txLargestDebit() { return db.prepare("SELECT * FROM transactions WHERE amount<0 ORDER BY amount ASC LIMIT 1;").get(); }
export function txLargestCredit() { return db.prepare("SELECT * FROM transactions WHERE amount>0 ORDER BY amount DESC LIMIT 1;").get(); }
export function txSmallestDebit() { return db.prepare("SELECT * FROM transactions WHERE amount<0 ORDER BY amount DESC LIMIT 1;").get(); }
export function txTopDebits(n) { return db.prepare("SELECT * FROM transactions WHERE amount<0 ORDER BY amount ASC LIMIT ?;").all(n); }
export function txCategoryBreakdown(limit = 8) {
  return db.prepare("SELECT category, SUM(-amount) AS spend, COUNT(*) AS count FROM transactions WHERE amount<0 GROUP BY category ORDER BY spend DESC LIMIT ?;").all(limit);
}
export function txRecent(n = 12) {
  return db.prepare("SELECT date, payee, category, amount FROM transactions ORDER BY date DESC, id DESC LIMIT ?;").all(n);
}
export function txCurrentBalance() {
  const r = db.prepare("SELECT balance FROM transactions WHERE balance IS NOT NULL ORDER BY date DESC, id DESC LIMIT 1;").get();
  return r ? r.balance : null;
}
export function txPage({ offset = 0, limit = 50, q = "" } = {}) {
  let where = "", params = [];
  if (q && q.trim()) { where = "WHERE lower(description) LIKE ?"; params = [`%${q.toLowerCase()}%`]; }
  const total = db.prepare(`SELECT COUNT(*) AS n FROM transactions ${where};`).get(...params).n;
  const rows = db.prepare(`SELECT date, payee, category, amount, balance FROM transactions ${where} ORDER BY date DESC, id DESC LIMIT ? OFFSET ?;`).all(...params, limit, offset);
  return { total, rows };
}
export function txTopPayees(limit = 6) {
  return db.prepare("SELECT payee, SUM(-amount) AS spend, COUNT(*) AS count FROM transactions WHERE amount<0 GROUP BY payee ORDER BY spend DESC LIMIT ?;").all(limit);
}
const SUBS_KEYS = ["netflix", "spotify", "hotstar", "prime", "disney", "youtube", "jio", "airtel", "excitel", "vodafone", "audible", "icloud", "google one"];
export function txSubscriptions() {
  const where = SUBS_KEYS.map(() => "lower(description) LIKE ?").join(" OR ");
  return db.prepare(`SELECT payee, SUM(-amount) AS total, COUNT(*) AS count, MAX(date) AS last
    FROM transactions WHERE amount<0 AND (${where}) GROUP BY payee ORDER BY total DESC LIMIT 12;`)
    .all(...SUBS_KEYS.map((k) => `%${k}%`));
}
export function txReceivedFromPeople() {
  return db.prepare(`SELECT COALESCE(SUM(amount),0) AS credit, COUNT(*) AS count FROM transactions
    WHERE amount>0 AND lower(description) NOT LIKE '%salary%' AND lower(description) NOT LIKE '%interest%'
    AND description NOT LIKE '%REV%' AND lower(description) NOT LIKE '%abhishek kumar%';`).get();
}

// ── Materialized month summaries (recomputed on data change) ─────────────────

/** Recompute and upsert the summary for one month (YYYY-MM). */
export function recomputeMonth(ym) {
  const m = db.prepare(`SELECT
    COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS income,
    COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS spending,
    COUNT(*) AS count, COALESCE(SUM(is_upi),0) AS upi
    FROM transactions WHERE ym=?;`).get(ym);
  if (!m || m.count === 0) { db.prepare("DELETE FROM month_summaries WHERE ym=?;").run(ym); return; }
  const cats = db.prepare("SELECT category, SUM(-amount) AS spend FROM transactions WHERE ym=? AND amount<0 GROUP BY category;").all(ym);
  const catMap = {}; for (const c of cats) catMap[c.category] = Math.round(c.spend * 100) / 100;
  const payees = db.prepare("SELECT payee, SUM(ABS(amount)) AS vol FROM transactions WHERE ym=? GROUP BY payee ORDER BY vol DESC LIMIT 20;").all(ym)
    .map((p) => ({ name: p.payee, vol: Math.round(p.vol * 100) / 100 }));
  const lg = db.prepare("SELECT amount, payee, date FROM transactions WHERE ym=? ORDER BY ABS(amount) DESC LIMIT 1;").get(ym);
  db.prepare(`INSERT OR REPLACE INTO month_summaries (ym,income,spending,net,count,upi,categories,payees,largest)
    VALUES (?,?,?,?,?,?,?,?,?);`).run(ym, m.income, m.spending, Math.round((m.income - m.spending) * 100) / 100,
    m.count, m.upi, JSON.stringify(catMap), JSON.stringify(payees), JSON.stringify(lg || null));
}

/** Rebuild every month summary (used after a full transactions reload). */
export function recomputeAllMonths() {
  const yms = db.prepare("SELECT DISTINCT ym FROM transactions ORDER BY ym;").all().map((r) => r.ym);
  db.exec("DELETE FROM month_summaries;");
  for (const ym of yms) recomputeMonth(ym);
  return yms.length;
}

function parseMonthRow(r) {
  return { ym: r.ym, income: r.income, spending: r.spending, net: r.net, count: r.count, upi: r.upi,
    categories: JSON.parse(r.categories || "{}"), payees: JSON.parse(r.payees || "[]"), largest: JSON.parse(r.largest || "null") };
}
export function getMonthSummaries() { return db.prepare("SELECT * FROM month_summaries ORDER BY ym;").all().map(parseMonthRow); }
export function getMonthSummary(ym) { const r = db.prepare("SELECT * FROM month_summaries WHERE ym=?;").get(ym); return r ? parseMonthRow(r) : null; }
export function yearMonthSummaries(year) { return db.prepare("SELECT * FROM month_summaries WHERE ym LIKE ? ORDER BY ym;").all(`${year}-%`).map(parseMonthRow); }
export function hasMonthSummaries() { return Number(db.prepare("SELECT COUNT(*) AS n FROM month_summaries;").get().n) > 0; }

/** Replace one month's transactions and recompute that month's summary. */
export function updateMonthData(ym, records) {
  db.prepare("DELETE FROM transactions WHERE ym=?;").run(ym);
  const ins = db.prepare("INSERT INTO transactions (date, ym, description, payee, category, amount, balance, is_upi) VALUES (?,?,?,?,?,?,?,?)");
  db.exec("BEGIN;");
  try {
    for (const r of records) {
      const amt = parseFloat(String(r.Amount).replace(/[^0-9.\-]/g, "")) || 0;
      const desc = r.Description || "";
      const bal = r.Balance != null && r.Balance !== "" ? parseFloat(r.Balance) : null;
      ins.run(r.Date || "", String(r.Date || "").slice(0, 7), desc, desc.split(" - ")[0].trim(),
        r.Category || "Other / Transfers", amt, Number.isNaN(bal) ? null : bal, /upi/i.test(desc) ? 1 : 0);
    }
    db.exec("COMMIT;");
  } catch (e) { db.exec("ROLLBACK;"); throw e; }
  recomputeMonth(ym);
}

// ── Period summaries (hierarchical, with in-process embeddings) ─────────────

export function replacePeriodSummaries(items) {
  db.exec("DELETE FROM period_summaries;");
  const ins = db.prepare(
    `INSERT INTO period_summaries (id, anchor, window, period_label, start_date, end_date, metrics, narrative, embedding)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);`
  );
  db.exec("BEGIN;");
  try {
    for (const it of items) {
      ins.run(
        it.id, it.anchor, it.window, it.periodLabel, it.start, it.end,
        JSON.stringify(it.metrics || {}),
        it.narrative || "",
        it.embedding ? JSON.stringify(it.embedding) : null
      );
    }
    db.exec("COMMIT;");
  } catch (e) {
    db.exec("ROLLBACK;");
    throw e;
  }
}

export function getPeriodSummaries() {
  return db.prepare("SELECT * FROM period_summaries;").all().map((r) => ({
    id: r.id, anchor: r.anchor, window: r.window, periodLabel: r.period_label,
    start: r.start_date, end: r.end_date,
    metrics: r.metrics ? JSON.parse(r.metrics) : {},
    narrative: r.narrative || "",
    embedding: r.embedding ? JSON.parse(r.embedding) : null,
  }));
}

export function hasPeriodSummaries() {
  return Number(db.prepare("SELECT COUNT(*) AS n FROM period_summaries;").get().n) > 0;
}

// ── SQLite prompt cache (offline fallback for the Redis prompt cache) ───────

export function promptCacheGet(key) {
  const row = db.prepare("SELECT value FROM prompt_cache WHERE key = ?;").get(key);
  return row ? row.value : null;
}

export function promptCacheSet(key, value) {
  db.prepare("INSERT OR REPLACE INTO prompt_cache (key, value) VALUES (?, ?);").run(key, value);
}

export function getTotalContentLength() {
  const row = db
    .prepare("SELECT COALESCE(SUM(LENGTH(content)), 0) AS total FROM chunks;")
    .get();
  return Number(row.total) || 0;
}

/** Keyword search via FTS5. Returns up to `limit` matching lines, best first. */
export function searchChunks(query, limit = 12) {
  const terms = (query.match(/[\p{L}\p{N}]+/gu) || [])
    .filter((t) => t.length > 1)
    .map((t) => `"${t}"`);
  if (terms.length === 0) return [];
  const matchExpr = terms.join(" OR ");
  try {
    return db
      .prepare(
        `SELECT content FROM chunks
         WHERE chunks MATCH ?
         ORDER BY rank
         LIMIT ?;`
      )
      .all(matchExpr, limit)
      .map((r) => r.content);
  } catch {
    return [];
  }
}

export function hasDocument() {
  const row = db.prepare("SELECT COUNT(*) AS n FROM chunks;").get();
  return Number(row.n) > 0;
}

// ── Added for Q&A support ──────────────────────────────────────────
export function txFirstTransaction() {
  return db.prepare("SELECT * FROM transactions ORDER BY id ASC LIMIT 1;").get();
}
export function txLastTransaction() {
  return db.prepare("SELECT * FROM transactions ORDER BY id DESC LIMIT 1;").get();
}
export function txRefLookup(ref) {
  return db.prepare("SELECT * FROM transactions WHERE description LIKE ?;").get(`%${ref}%`);
}
export function txCreditCount() {
  const r = db.prepare("SELECT COUNT(*) AS count FROM transactions WHERE amount>0;").get();
  return r ? r.count : 0;
}
export function txDebitCount() {
  const r = db.prepare("SELECT COUNT(*) AS count FROM transactions WHERE amount<0;").get();
  return r ? r.count : 0;
}
export function txHighestBalanceDate() {
  return db.prepare("SELECT date, balance FROM transactions ORDER BY balance DESC LIMIT 1;").get();
}
export function txLowestBalanceDate() {
  return db.prepare("SELECT date, balance FROM transactions WHERE balance>0 ORDER BY balance ASC LIMIT 1;").get();
}
export function txHighestCreditMonth() {
  return db.prepare("SELECT ym, SUM(amount) AS credit FROM transactions WHERE amount>0 GROUP BY ym ORDER BY credit DESC LIMIT 1;").get();
}
export function txHighestDebitMonth() {
  return db.prepare("SELECT ym, SUM(-amount) AS debit FROM transactions WHERE amount<0 GROUP BY ym ORDER BY debit DESC LIMIT 1;").get();
}
export function txBusiestDay() {
  return db.prepare("SELECT date, COUNT(*) AS count FROM transactions GROUP BY date ORDER BY count DESC LIMIT 1;").get();
}
export function txMonthCreditsDebits(ym) {
  return db.prepare("SELECT COALESCE(SUM(CASE WHEN amount>0 THEN amount END),0) AS credit, COALESCE(SUM(CASE WHEN amount<0 THEN -amount END),0) AS debit, COUNT(*) AS count FROM transactions WHERE ym=?;").get(ym);
}
export function txCountInMonth(ym) {
  const r = db.prepare("SELECT COUNT(*) AS count FROM transactions WHERE ym=?;").get(ym);
  return r ? r.count : 0;
}
export function txOverviewCounts() {
  return db.prepare("SELECT COUNT(*) AS total, COALESCE(SUM(CASE WHEN amount>0 THEN 1 END),0) AS credits, COALESCE(SUM(CASE WHEN amount<0 THEN 1 END),0) AS debits FROM transactions;").get();
}
