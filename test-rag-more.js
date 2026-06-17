// Extended RAG battery: more merchants/months/windows, edge cases, phrasing
// robustness, and a numeric-fidelity stress test.  node test-rag-more.js
import { initDb, getRecords, getPeriodSummaries } from "./src/db.js";
import { aggregateByKeywords, recAmount, recMonth } from "./src/aggregate.js";

const BASE = "http://localhost:3000";
initDb();
const recs = getRecords();
const periods = getPeriodSummaries();
const debits = recs.filter((r) => recAmount(r) < 0);
const kw = (...k) => aggregateByKeywords(recs, k).debit;
const r0 = (n) => Math.round(n);
const forms = (n) => [String(r0(n)), Math.abs(n).toFixed(2)];
const winAt = (w, anchor) => periods.find((p) => p.window === w && p.anchor === anchor);
const monthSpend = new Map();
for (const r of debits) monthSpend.set(recMonth(r), (monthSpend.get(recMonth(r)) || 0) + Math.abs(recAmount(r)));

const norm = (s) => s.toLowerCase().replace(/,/g, "").replace(/\s+/g, " ");
async function chat(q) {
  const r = await fetch(BASE + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: q }) });
  return { src: r.headers.get("X-Answer") || "LLM", text: (await r.text()).trim() };
}

// ── A. more merchants/entities ──────────────────────────────────────────────
const moreMerchants = [
  ["Dominos", "dominos"], ["KFC", "kfc"], ["Meesho", "meesho"], ["Hotstar", "hotstar"],
  ["Indian Oil", "indian oil"], ["Fastag", "fastag"], ["BSES", "bses"],
  ["LIC", "lic"], ["Pharmeasy", "pharmeasy"], ["Reliance Fresh", "reliance fresh"],
  ["Amit Kumar", "amit kumar"], ["Neha Gupta", "neha gupta"], ["Vikram", "vikram"],
];
// genuinely absent in the data → must say "not found", not invent a number
const absent = ["Indane", "Tesla", "Starbucks", "Walmart", "Gambling", "Cryptocurrency"];
// ── E. phrasing robustness (same fact, 4 ways → CRED total) ─────────────────
const credExp = forms(kw("cred"));
const phrasing = [
  "How much did I pay to CRED in total?", "total CRED payments?",
  "what did I pay CRED?", "my CRED spending",
];

const cases = [];
const T = (q, exp, sec) => cases.push({ q, exp, sec });

for (const [name, k] of moreMerchants) T(`How much did I spend on ${name}?`, forms(kw(k)), "merchant");

// B. months across the timeline
for (const ym of ["2022-09", "2023-01", "2023-06", "2023-12", "2024-04", "2024-08", "2025-01"]) {
  const [y, m] = ym.split("-");
  const mn = { "01": "January", "04": "April", "06": "June", "08": "August", "09": "September", "12": "December" }[m];
  T(`How much did I spend in ${mn} ${y}?`, forms(monthSpend.get(ym)), "month");
}

// C. windows at specific anchors
T("Summarize the 6 months ending August 2024.", forms(winAt(6, "2024-08").metrics.expense), "window");
T("Give me a 3-month overview ending June 2024.", forms(winAt(3, "2024-06").metrics.expense), "window");
T("What did I spend in the 12 months ending December 2024?", forms(winAt(12, "2024-12").metrics.expense), "window");
T("Summarize the 9 months ending March 2024.", forms(winAt(9, "2024-03").metrics.expense), "window");

// D. multi-merchant
T("How much did I spend on Swiggy and Zomato?", forms(kw("swiggy", "zomato")), "multi");
T("Combined spending on Uber and Rapido?", forms(kw("uber", "rapido")), "multi");

// F. edge cases (absent entities → should NOT invent a number)
for (const x of absent) {
  T(`How much did I spend on ${x}?`, ["not found", "no ", "isn't", "not in", "no record", "0", "didn't", "does not", "no transaction", "not contain", "not show", "not provide", "not indicate"], "edge");
}

// E. phrasing robustness
for (const q of phrasing) T(q, credExp, "phrasing");

// ── run ─────────────────────────────────────────────────────────────────────
console.log(`Extended battery: ${cases.length} cases\n`);
const bySec = {}; let pass = 0; const fails = [];
for (let i = 0; i < cases.length; i++) {
  const { q, exp, sec } = cases[i];
  const a = await chat(q);
  const n = norm(a.text);
  const ok = exp.some((e) => n.includes(norm(String(e))));
  bySec[sec] = bySec[sec] || { p: 0, t: 0 }; bySec[sec].t++; if (ok) { bySec[sec].p++; pass++; } else fails.push(`[${sec}] ${q}\n     exp [${exp.slice(0, 3).join(" | ")}...]  got: ${a.text.replace(/\n/g, " ").slice(0, 100)}`);
  console.log(`${ok ? "✅" : "❌"} ${String(i + 1).padStart(2)}. [${sec.padEnd(8)}] ${a.text.replace(/\n/g, " ").slice(0, 78)}`);
}

// ── numeric fidelity stress: repeat large-figure Qs, count exact reproductions ─
console.log("\n── Numeric fidelity (each asked 3×; exact = grounded figure reproduced) ──");
const fid = [["Amazon", kw("amazon")], ["Flipkart", kw("flipkart")], ["Myntra", kw("myntra")], ["Jio", kw("jio")], ["Apollo", kw("apollo")]];
let exact = 0, total = 0;
for (const [name, val] of fid) {
  const want = val.toFixed(2).replace(/\.00$/, "");
  let hits = 0;
  for (let k = 0; k < 3; k++) {
    const a = await chat(`How much did I spend on ${name}?`);
    const got = norm(a.text);
    if (got.includes(norm(String(r0(val)))) || got.includes(norm(val.toFixed(2)))) hits++;
    total++;
  }
  exact += hits;
  console.log(`  ${name} (₹${r0(val)}): ${hits}/3 exact`);
}

console.log("\n=== BY SECTION ===");
for (const [s, v] of Object.entries(bySec)) console.log(`  ${s}: ${v.p}/${v.t}`);
console.log(`\n=== CASES: ${pass}/${cases.length} | FIDELITY: ${exact}/${total} exact ===`);
if (fails.length) { console.log("\nFAILURES:"); fails.forEach((f) => console.log("  " + f)); }
process.exit(0);
