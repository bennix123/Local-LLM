// 50-case RAG battery against the live server, graded vs ground truth computed
// directly from the stored records + period summaries.  node test-rag50.js
import { initDb, getRecords, getPeriodSummaries } from "./src/db.js";
import { aggregateByKeywords, recAmount, recMonth, topTransactions, smallestDebit } from "./src/aggregate.js";
import { categorize } from "./src/periods.js";

const BASE = "http://localhost:3000";
initDb();
const recs = getRecords();
const periods = getPeriodSummaries();

const debits = recs.filter((r) => recAmount(r) < 0);
const credits = recs.filter((r) => recAmount(r) > 0);
const sum = (a) => a.reduce((s, r) => s + Math.abs(recAmount(r)), 0);
const totDebit = sum(debits), totCredit = credits.reduce((s, r) => s + recAmount(r), 0);
const net = totCredit - totDebit;
const upi = recs.filter((r) => /upi/i.test(r.Description)).length;
const kw = (k) => aggregateByKeywords(recs, [k]).debit;
const catSum = (c) => sum(debits.filter((r) => categorize(r) === c));
const r0 = (n) => Math.round(n);
const forms = (n) => [String(r0(n)), Math.abs(n).toFixed(2), String(r0(Math.abs(n)))];

// period windows at latest anchor
const latest = [...new Set(periods.map((p) => p.anchor))].sort().pop();
const win = (w) => periods.find((p) => p.window === w && p.anchor === latest);
// monthly buckets
const monthSpend = new Map();
for (const r of debits) monthSpend.set(recMonth(r), (monthSpend.get(recMonth(r)) || 0) + Math.abs(recAmount(r)));
const monthsSorted = [...monthSpend.entries()].sort((a, b) => b[1] - a[1]);
const MNAME = { "01": "january", "02": "february", "03": "march", "04": "april", "05": "may", "06": "june", "07": "july", "08": "august", "09": "september", "10": "october", "11": "november", "12": "december" };
const monthName = (ym) => MNAME[ym.split("-")[1]];

const largest = topTransactions(recs, 1, "debit")[0];
const small = smallestDebit(recs);

// each case: [question, expectedSubstrings[]]
const merchants = [
  ["Swiggy", "swiggy"], ["Zomato", "zomato"], ["Blinkit", "blinkit"], ["Zepto", "zepto"],
  ["BigBasket", "bigbasket"], ["DMart", "dmart"], ["Amazon", "amazon"], ["Flipkart", "flipkart"],
  ["Myntra", "myntra"], ["Ajio", "ajio"], ["Netflix", "netflix"], ["Spotify", "spotify"],
  ["PVR", "pvr"], ["BookMyShow", "bookmyshow"], ["Jio", "jio"], ["Airtel", "airtel"],
  ["Excitel", "excitel"], ["CRED", "cred"], ["Uber", "uber"], ["Rapido", "rapido"],
  ["Zerodha", "zerodha"], ["Apollo", "apollo"],
];

const Q = [
  ["What is my total spending overall?", forms(totDebit)],
  ["What is my total income?", forms(totCredit)],
  ["What is my net total?", forms(net)],
  ["How many transactions are there in total?", [String(recs.length)]],
  ["What is my average transaction?", forms(net / recs.length)],
  ["How many UPI transactions did I make?", [String(upi)]],
  ...merchants.map(([name, k]) => [`How much did I spend on ${name}?`, forms(kw(k))]),
  ["What is my total salary credited?", forms(aggregateByKeywords(recs, ["salary"]).credit)],
  ["How much interest did I earn?", forms(aggregateByKeywords(recs, ["interest"]).credit)],
  ["What was my largest single expense?", forms(Math.abs(recAmount(largest)))],
  ["What is the smallest amount I ever spent?", forms(Math.abs(recAmount(small)))],
  ["How much did I spend on Rent?", forms(kw("rent"))],
  ["How much did I invest in Groww?", forms(kw("groww"))],
  ["How much did I send to Devendra Kumar?", forms(kw("devendra"))],
  ["How much did I send to Nikhil?", forms(kw("nikhil"))],
  ["How much did I send to Rahul Sharma?", forms(kw("rahul sharma"))],
  ["How much did I send to Priya Singh?", forms(kw("priya singh"))],
  ["How much did I spend on groceries?", forms(catSum("Groceries"))],
  ["How much did I spend on transport?", forms(catSum("Transport"))],
  ["How much did I spend on entertainment?", forms(catSum("Entertainment"))],
  ["How much did I spend on healthcare?", forms(catSum("Healthcare"))],
  ["Summarize my spending over the last 3 months.", forms(win(3).metrics.expense)],
  ["Summarize my spending over the last 6 months.", forms(win(6).metrics.expense)],
  ["Summarize my spending over the last 9 months.", forms(win(9).metrics.expense)],
  ["What did I spend in the last 12 months?", forms(win(12).metrics.expense)],
  ["How much did I spend in December 2024?", forms(monthSpend.get("2024-12"))],
  ["How much did I spend in May 2023?", forms(monthSpend.get("2023-05"))],
  ["Which month did I spend the most money?", [monthName(monthsSorted[0][0])]],
  ["Which month did I spend the least money?", [monthName(monthsSorted[monthsSorted.length - 1][0])]],
];

const norm = (s) => s.toLowerCase().replace(/,/g, "").replace(/\s+/g, " ");
async function chat(q) {
  const r = await fetch(BASE + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: q }) });
  return { src: r.headers.get("X-Answer") || "LLM", text: (await r.text()).trim() };
}

console.log(`Dataset: ${recs.length} records, ${periods.length} summaries | ${Q.length} test cases\n`);
let pass = 0; const fails = [];
const sec = {};
for (let i = 0; i < Q.length; i++) {
  const [q, exp] = Q[i];
  const a = await chat(q);
  const n = norm(a.text);
  const ok = exp.some((e) => n.includes(norm(String(e))));
  if (ok) pass++; else fails.push(`${String(i + 1).padStart(2)}. ${q}\n     expected one of [${exp.join(" | ")}]\n     got: ${a.text.replace(/\n/g, " ").slice(0, 120)}`);
  console.log(`${ok ? "✅" : "❌"} ${String(i + 1).padStart(2)}. [${a.src.padEnd(12)}] ${a.text.replace(/\n/g, " ").slice(0, 80)}`);
}
console.log(`\n=== ${pass}/${Q.length} matched ground truth ===`);
if (fails.length) { console.log("\nFAILURES:"); fails.forEach((f) => console.log("  " + f)); }
process.exit(0);
