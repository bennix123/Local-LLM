// Comprehensive RAG battery (100+ cases). Ground truth is computed directly
// from SQLite via db.js; answers come from the live /api/chat endpoint. Reports
// pass/fail by section and which path served each answer (deterministic/router/llm).
//   node battery100.js
import {
  initDb, txOverview, txKeyword, txKeywordMonth, txCategoryMonth, txCurrentBalance, txLargestDebit,
  txLargestCredit, txSmallestDebit, txTopDebits, txCategorySpend,
  getMonthSummary, getMonthSummaries, yearMonthSummaries,
} from "./src/db.js";

const BASE = "http://localhost:3000";
initDb();

const MN = { "01": "January", "02": "February", "03": "March", "04": "April", "05": "May", "06": "June", "07": "July", "08": "August", "09": "September", "10": "October", "11": "November", "12": "December" };
const r0 = (n) => Math.round(n);
// Accept either the rounded integer or the 2-dp figure, with/without commas.
const forms = (n) => [String(r0(n)), Math.abs(n).toFixed(2)];
const norm = (s) => s.toLowerCase().replace(/,/g, "").replace(/\s+/g, " ");

async function chat(q) {
  const r = await fetch(BASE + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: q }) });
  return { src: r.headers.get("X-Answer") || "llm", text: (await r.text()).trim() };
}

const o = txOverview();
const months = getMonthSummaries();
const cases = [];
const T = (q, exp, sec) => cases.push({ q, exp: Array.isArray(exp) ? exp : [exp], sec });

// ── 1. Merchants / people (entity) — multiple phrasings ─────────────────────
const merchants = ["amazon", "flipkart", "myntra", "swiggy", "zomato", "dominos", "blinkit", "zepto", "dmart", "bigbasket", "meesho", "ajio", "netflix", "spotify", "rahul sharma", "priya singh", "amit kumar", "neha gupta", "vikram", "pharmeasy"];
for (const m of merchants) {
  const v = txKeyword([m]).debit;
  if (v > 0) T(`How much did I spend on ${m}?`, forms(v), "merchant");
}
// phrasing variants for one merchant (router stress)
const sw = txKeyword(["swiggy"]).debit;
for (const q of ["total swiggy payments", "what did I pay swiggy", "how much money went to swiggy", "my swiggy spending"]) T(q, forms(sw), "phrasing");

// ── 2. Months (whole-month spend) across the timeline ───────────────────────
for (const ym of ["2022-09", "2022-12", "2023-01", "2023-06", "2023-12", "2024-01", "2024-04", "2024-08", "2025-01"]) {
  const m = getMonthSummary(ym);
  if (m && m.count > 0) T(`How much did I spend in ${MN[ym.slice(5)]} ${ym.slice(0, 4)}?`, forms(m.spending), "month");
}

// ── 3. Categories ───────────────────────────────────────────────────────────
for (const cat of ["Groceries", "Transport", "Food & Dining", "Shopping", "Healthcare", "Entertainment"]) {
  const c = txCategorySpend(cat);
  if (c.count > 0) T(`How much did I spend on ${cat.toLowerCase()}?`, forms(c.debit), "category");
}

// ── 4. Global totals / overview ─────────────────────────────────────────────
T("what is my total spending?", forms(o.debit), "total");
T("total income?", forms(o.credit), "total");
T("how many transactions do I have?", [String(o.count), num(o.count)], "total");
T("how many upi payments?", [String(o.upi), num(o.upi)], "total");
T("give me an overall summary", forms(o.debit), "overview");
T("net position?", forms(o.credit - o.debit), "overview");

// ── 5. Balance ──────────────────────────────────────────────────────────────
const bal = txCurrentBalance();
if (bal != null) {
  for (const q of ["what is my balance", "current balance?", "whats sitting in my account", "how much money do I have left"]) T(q, forms(bal), "balance");
}

// ── 6. Largest / smallest / top-N ───────────────────────────────────────────
const ld = txLargestDebit(), lc = txLargestCredit(), sd = txSmallestDebit();
if (ld) T("what is my biggest single expense?", forms(ld.amount), "extremes");
if (ld) T("whats my largest purchase ever", forms(ld.amount), "extremes");
if (lc) T("what is my largest credit?", forms(lc.amount), "extremes");
if (sd) T("what is my smallest expense?", forms(sd.amount), "extremes");
const top5 = txTopDebits(5);
if (top5.length) T("show me my top 5 largest expenses", forms(top5[0].amount), "extremes");

// ── 7. Salary / interest / received-from-people ─────────────────────────────
const sal = txKeyword(["salary"]).credit;
if (sal > 0) T("how much salary did I get?", forms(sal), "income");
const intr = txKeyword(["interest"]).credit;
if (intr > 0) T("how much interest did I earn?", forms(intr), "income");

// ── 8. Coverage / month-wise / year-breakdown ───────────────────────────────
T("which months do you have data for?", [String(months.length), "data coverage", MN[months[0].ym.slice(5)].toLowerCase()], "coverage");
T("list the months you have data of", ["data coverage", "2023", "2024"], "coverage");
T("show me month wise breakdown", [MN[months[0].ym.slice(5)].toLowerCase(), "monthly breakdown"], "monthwise");
const y2024 = yearMonthSummaries("2024");
if (y2024.length) T("break it down per month for 2024", forms(y2024[0].spending), "yearbreak");

// ── 9. Absent entities → must NOT invent a figure ───────────────────────────
for (const x of ["Tesla", "Starbucks", "Walmart", "Gambling", "Netflix Premium Platinum"]) {
  T(`How much did I spend on ${x}?`, ["not found", "no ", "isn't", "not in", "no record", "0", "didn't", "does not", "no transaction", "not contain", "not show", "not provide", "couldn't", "could not"], "absent");
}

// ── 10. Phrasing robustness across several merchants (router/merchant-catch) ──
for (const m of ["amazon", "flipkart", "zomato", "netflix", "dmart"]) {
  const v = txKeyword([m]).debit;
  if (v <= 0) continue;
  T(`total ${m} payments`, forms(v), "phrasing");
  T(`my ${m} spending`, forms(v), "phrasing");
  T(`what did I pay ${m}`, forms(v), "phrasing");
}

// ── 11. Entity within a specific month ──────────────────────────────────────
for (const [m, ym] of [["amazon", "2024-06"], ["swiggy", "2023-12"], ["flipkart", "2024-01"], ["zomato", "2024-08"], ["dmart", "2023-06"]]) {
  const a = txKeywordMonth([m], ym);
  if (a && a.count > 0) T(`how much did I spend on ${m} in ${MN[ym.slice(5)]} ${ym.slice(0, 4)}?`, forms(a.debit), "entity-month");
}

// ── 12. Category within a specific month ────────────────────────────────────
for (const [cat, ym] of [["Groceries", "2024-04"], ["Food & Dining", "2023-12"], ["Shopping", "2024-08"], ["Transport", "2023-06"]]) {
  const c = txCategoryMonth(cat, ym);
  if (c && c.count > 0) T(`how much did I spend on ${cat.toLowerCase()} in ${MN[ym.slice(5)]} ${ym.slice(0, 4)}?`, forms(c.debit), "cat-month");
}

// ── 13. All remaining months (full coverage of whole-month spend) ───────────
for (const mo of months) {
  if (mo.count > 0) T(`spending in ${MN[mo.ym.slice(5)]} ${mo.ym.slice(0, 4)}`, forms(mo.spending), "allmonths");
}

// ── 14. Top-N variants ──────────────────────────────────────────────────────
const t3 = txTopDebits(3), t10 = txTopDebits(10);
if (t3.length) T("top 3 expenses", forms(t3[0].amount), "topn");
if (t10.length) T("show my top 10 biggest transactions", forms(t10[0].amount), "topn");

// ── 15. More absent entities ────────────────────────────────────────────────
for (const x of ["Bitcoin", "Casino", "McDonalds India Deluxe", "Ferrari"]) {
  T(`How much did I spend on ${x}?`, ["not found", "no ", "isn't", "not in", "no record", "0", "didn't", "does not", "no transaction", "not contain", "not show", "couldn't", "could not"], "absent");
}

function num(n) { return Number(n).toLocaleString("en-IN"); }

// ── run ─────────────────────────────────────────────────────────────────────
console.log(`Battery: ${cases.length} cases\n`);
const bySec = {}, bySrc = {}; let pass = 0; const fails = [];
for (let i = 0; i < cases.length; i++) {
  const { q, exp, sec } = cases[i];
  let a;
  try { a = await chat(q); } catch (e) { a = { src: "ERR", text: String(e.message) }; }
  const n = norm(a.text);
  const ok = exp.some((e) => n.includes(norm(String(e))));
  bySec[sec] = bySec[sec] || { p: 0, t: 0 }; bySec[sec].t++; if (ok) bySec[sec].p++;
  bySrc[a.src] = bySrc[a.src] || { p: 0, t: 0 }; bySrc[a.src].t++; if (ok) bySrc[a.src].p++;
  if (ok) pass++; else fails.push(`[${sec}/${a.src}] ${q}\n     exp [${exp.slice(0, 2).join(" | ")}]  got: ${a.text.replace(/\n/g, " ").slice(0, 110)}`);
  console.log(`${ok ? "✅" : "❌"} ${String(i + 1).padStart(3)}. [${sec.padEnd(9)}|${(a.src || "").padEnd(13)}] ${a.text.replace(/\n/g, " ").slice(0, 64)}`);
}

console.log("\n=== BY SECTION ===");
for (const [s, v] of Object.entries(bySec)) console.log(`  ${s.padEnd(11)} ${v.p}/${v.t}`);
console.log("\n=== BY PATH ===");
for (const [s, v] of Object.entries(bySrc)) console.log(`  ${s.padEnd(13)} ${v.p}/${v.t}`);
console.log(`\n=== TOTAL: ${pass}/${cases.length} (${(100 * pass / cases.length).toFixed(1)}%) ===`);
if (fails.length) { console.log("\nFAILURES:"); fails.forEach((f) => console.log("  " + f)); }
process.exit(0);
