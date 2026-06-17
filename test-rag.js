// End-to-end RAG test against the live server, graded vs ground truth computed
// directly from the stored records + period summaries.
//   node test-rag.js
import { initDb, getRecords, getPeriodSummaries } from "./src/db.js";
import { aggregateByKeywords, recAmount, topTransactions, smallestDebit } from "./src/aggregate.js";

const BASE = "http://localhost:3000";
initDb();
const recs = getRecords();
const periods = getPeriodSummaries();

// ── ground truth (independent of the server's answer path) ──────────────────
const debits = recs.filter((r) => recAmount(r) < 0);
const credits = recs.filter((r) => recAmount(r) > 0);
const totDebit = debits.reduce((s, r) => s + Math.abs(recAmount(r)), 0);
const totCredit = credits.reduce((s, r) => s + recAmount(r), 0);
const upi = recs.filter((r) => /upi/i.test(r.Description)).length;
const salary = aggregateByKeywords(recs, ["salary"]).credit;
const cred = aggregateByKeywords(recs, ["cred"]).debit;
const swiggy = aggregateByKeywords(recs, ["swiggy"]).debit;
const amazon = aggregateByKeywords(recs, ["amazon"]).debit;
const netflix = aggregateByKeywords(recs, ["netflix"]).debit;
const largest = topTransactions(recs, 1, "debit")[0];
const small = smallestDebit(recs);

const win = (w, anchor) => periods.find((p) => p.window === w && p.anchor === anchor);
const latest = [...new Set(periods.map((p) => p.anchor))].sort().pop();
const w6 = win(6, latest), w12 = win(12, latest), w3 = win(3, latest);
const dec = win(1, "2024-12");

const r0 = (n) => Math.round(n);
// expected substrings (comma-stripped). Accept rounded and 2-dp forms.
const forms = (n) => [String(r0(n)), n.toFixed(2)];

const Q = [
  ["What is my total spending overall?", forms(totDebit)],
  ["What is my total income?", forms(totCredit)],
  ["How many transactions did I make using UPI?", [String(upi)]],
  ["What is my total salary credited?", forms(salary)],
  ["How much did I pay to CRED in total?", forms(cred)],
  ["How much did I spend on Swiggy?", forms(swiggy)],
  ["How much did I spend on Amazon?", forms(amazon)],
  ["How much did I spend on Netflix?", forms(netflix)],
  ["What was my largest single expense?", forms(Math.abs(recAmount(largest)))],
  ["What is the smallest amount I ever spent?", forms(Math.abs(recAmount(small)))],
  ["Summarize my spending over the last 6 months.", w6 ? forms(w6.metrics.expense) : ["?"]],
  ["What did I spend in the last 12 months?", w12 ? forms(w12.metrics.expense) : ["?"]],
  ["Give me a 3-month overview.", w3 ? forms(w3.metrics.expense) : ["?"]],
  ["How much did I spend in December 2024?", dec ? forms(dec.metrics.expense) : ["?"]],
];

const norm = (s) => s.toLowerCase().replace(/,/g, "").replace(/\s+/g, " ");
async function chat(q) {
  const r = await fetch(BASE + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: q }) });
  return { src: r.headers.get("X-Answer") || "LLM", text: (await r.text()).trim() };
}

console.log(`Dataset: ${recs.length} records, ${periods.length} period summaries`);
console.log(`Ground truth: spend ₹${r0(totDebit)} | income ₹${r0(totCredit)} | UPI ${upi} | salary ₹${r0(salary)} | CRED ₹${r0(cred)}\n`);

let pass = 0; const fails = [];
for (let i = 0; i < Q.length; i++) {
  const [q, exp] = Q[i];
  const a = await chat(q);
  const n = norm(a.text);
  const ok = exp.some((e) => n.includes(norm(e)));
  if (ok) pass++; else fails.push(`${i + 1}. ${q}\n     expected one of [${exp.join(", ")}]\n     got: ${a.text.replace(/\n/g, " ").slice(0, 130)}`);
  console.log(`${ok ? "✅" : "❌"} ${String(i + 1).padStart(2)}. [${a.src.padEnd(12)}] ${a.text.replace(/\n/g, " ").slice(0, 95)}`);
}
console.log(`\n=== ${pass}/${Q.length} matched ground truth ===`);
if (fails.length) { console.log("\nFAILURES:"); fails.forEach((f) => console.log("  " + f)); }
process.exit(0);
