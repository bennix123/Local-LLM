// Build the dataset + materialized summary layer at scale.
//   1. Combine synthetic history + the real HDFC tail
//   2. Store transactions (indexed table) — this auto-recomputes every month
//      summary (recomputeAllMonths runs inside replaceTransactions)
//   3. Compose rolling 1/3/6/9/12-month period summaries FROM the month
//      summaries (exact, no raw re-scan) and embed them in-process
//
// Env: PERDAY_MIN / PERDAY_MAX  (synthetic volume per day)
//   CHROMA_PORT=8001 PERDAY_MIN=130 PERDAY_MAX=150 node build-periods.js

import fs from "node:fs";
import { initDb, replaceDocument, replaceTransactions, getMonthSummaries } from "./src/db.js";
import { computeStatsSummary } from "./src/stats.js";
import { setCurrency, getCurrencyCode } from "./src/currency.js";
import { parseFile } from "./src/ingest.js";
import { generateSyntheticRecords } from "./gen-data.js";
import { categorize } from "./src/periods.js";
import { rebuildPeriods } from "./src/summaries.js";

const PERDAY_MIN = parseInt(process.env.PERDAY_MIN, 10) || 20;
const PERDAY_MAX = parseInt(process.env.PERDAY_MAX, 10) || 40;

initDb();
const t0 = Date.now();

// 1. combine synthetic + real (parse the real HDFC PDF for its 303 rows)
const PDF = process.env.PDF_PATH || "C:/Users/Hp/Downloads/Acct Statement_XX2635_04032025.pdf";
let real = [];
try { real = (await parseFile("Acct Statement_XX2635_04032025.pdf", fs.readFileSync(PDF))).records || []; }
catch (e) { console.warn(`(real HDFC PDF not read: ${e.message})`); }
setCurrency("INR");
const synth = generateSyntheticRecords("2022-09", "2024-08", 50000, PERDAY_MIN, PERDAY_MAX);
const combined = [...synth, ...real]
  .map((r) => ({ ...r, Category: r.Category || categorize(r) }))
  .sort((a, b) => (a.Date < b.Date ? -1 : a.Date > b.Date ? 1 : 0));
console.log(`Combined ${combined.length.toLocaleString("en-IN")} records (${synth.length.toLocaleString("en-IN")} synthetic + ${real.length} real HDFC)`);

// 2. store transactions (auto-recomputes all month summaries) + facts + chunks
const columns = ["Date", "Description", "Category", "Amount", "Balance"];
const chunks = combined.map((r, i) => `Row ${i + 1} | Date: ${r.Date}; Description: ${r.Description}; Category: ${r.Category}; Amount: ${r.Amount}; Balance: ${r.Balance}`);
const summary = computeStatsSummary(columns, combined);
replaceTransactions(combined);
replaceDocument({ fileName: "combined_lakh.csv", columns, rowCount: combined.length, chunks, summary, records: [], currency: getCurrencyCode() });
console.log(`Stored ${combined.length.toLocaleString("en-IN")} transactions; ${getMonthSummaries().length} month summaries computed (${((Date.now() - t0) / 1000).toFixed(0)}s).`);

// 3. compose + embed rolling period summaries from the month summaries
const n = await rebuildPeriods();
console.log(`Composed ${n} period summaries from month summaries. Total build ${((Date.now() - t0) / 1000).toFixed(0)}s.`);
process.exit(0);
