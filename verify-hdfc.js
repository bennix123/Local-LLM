// End-to-end: parse the HDFC PDF via the real ingest pipeline, store it
// (SQLite + facts + Chroma), then compute ground-truth answers for the 20
// questions directly from the structured records — printing matched
// transactions so the sums can be audited, not just trusted.
//
//   CHROMA_PORT=8001 node verify-hdfc.js          (parse + ground truth, no store)
//   CHROMA_PORT=8001 node verify-hdfc.js store     (also write to SQLite + Chroma)

import fs from "node:fs";
import { parseFile } from "./src/ingest.js";
import { computeStatsSummary } from "./src/stats.js";
import { initDb, replaceDocument } from "./src/db.js";
import { getCurrencyCode } from "./src/currency.js";
import { initChromaDb, isChromaReady, replaceChromaDocument } from "./src/chromaDb.js";
import { aggregateByKeywords, topTransactions, smallestDebit, recAmount, recMonth, monthLabel, payeeOf } from "./src/aggregate.js";

const PDF = process.env.PDF_PATH || "C:/Users/Hp/Downloads/Acct Statement_XX2635_04032025.pdf";
const DO_STORE = process.argv[2] === "store";

const buf = fs.readFileSync(PDF);
const parsed = await parseFile("Acct Statement_XX2635_04032025.pdf", buf);
const records = parsed.records;
const summary = computeStatsSummary(parsed.columns, parsed.records);

const fmt = (n) => "₹" + n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const agg = (kw) => aggregateByKeywords(records, kw);

console.log(`Parsed ${records.length} records | columns: ${parsed.columns.join(", ")}`);
const totDebit = records.filter((r) => recAmount(r) < 0).reduce((s, r) => s + Math.abs(recAmount(r)), 0);
const totCredit = records.filter((r) => recAmount(r) > 0).reduce((s, r) => s + recAmount(r), 0);
console.log(`Total debit ${fmt(totDebit)} | total credit ${fmt(totCredit)} | closing ${records[records.length-1]?.Balance}`);
console.log("=".repeat(70));

function show(label, kw, { perMonth = false, credit = false } = {}) {
  const a = agg(kw);
  const val = credit ? a.credit : a.debit;
  console.log(`\n[${label}]  keywords=${JSON.stringify(kw)}`);
  console.log(`  ${credit ? "credited" : "spent"}: ${fmt(val)}  (count ${a.count}, debit ${fmt(a.debit)}, credit ${fmt(a.credit)})`);
  if (perMonth) {
    for (const [m, mm] of [...a.byMonth.entries()].sort()) {
      console.log(`    ${monthLabel(m)}: ${fmt(credit ? mm.credit : mm.debit)} (${mm.count} txn)`);
    }
  }
  // audit: list up to 8 matched
  a.matched.slice(0, 8).forEach((r) => console.log(`      ${r.Date} ${r.Amount.padStart(11)} | ${payeeOf(r)}`));
  if (a.matched.length > 8) console.log(`      ... +${a.matched.length - 8} more`);
  return a;
}

// Q1 total spending
console.log(`\nQ1 total spending = ${fmt(totDebit)}`);
// Q2 food delivery
show("Q2 food delivery", ["swiggy", "zomato", "blinkit"]);
// Q3 groceries
show("Q3 groceries", ["grofers", "blinkit"]);
// Q4 metro & travel
show("Q4 metro/travel", ["metro", "rapido", "irctc", "uber", "ola", "redbus"]);
// Q5 CRED
show("Q5 CRED", ["cred"]);
// Q6 internet Excitel
show("Q6 Excitel", ["excitel"]);
// Q7 Jio
show("Q7 Jio", ["jio"]);
// Q8 PVR
show("Q8 PVR", ["pvr"]);
// Q9 top 5 transactions
console.log(`\nQ9 top 5 transactions:`);
topTransactions(records, 5).forEach((r, i) => console.log(`  ${i+1}. ${r.Date} ${fmt(recAmount(r))} | ${payeeOf(r)}`));
// Q10 smallest
const sm = smallestDebit(records);
console.log(`\nQ10 smallest debit = ${fmt(recAmount(sm))} | ${payeeOf(sm)} (${sm.Date})`);
// Q11 salary
show("Q11 salary", ["salary"], { credit: true, perMonth: true });
// Q12 closing balance
console.log(`\nQ12 closing balance = ₹${records[records.length-1]?.Balance}`);
// Q13 interest
show("Q13 interest", ["interest", "int.pd", "credit interest"], { credit: true });
// Q14 received from people (credits excluding salary/interest)
const credits = records.filter((r) => recAmount(r) > 0);
const fromPeople = credits.filter((r) => !/salary|interest/i.test(r.Description));
console.log(`\nQ14 received (non-salary/interest credits): ${fmt(fromPeople.reduce((s,r)=>s+recAmount(r),0))} (${fromPeople.length} txn)`);
fromPeople.slice(0,12).forEach((r)=>console.log(`      ${r.Date} ${r.Amount.padStart(11)} | ${payeeOf(r)}`));
// Q15/16 month most/least spend, Q17 December
const byMonth = new Map();
for (const r of records) { const m=recMonth(r); const n=recAmount(r); const mm=byMonth.get(m)||{debit:0,credit:0}; if(n<0)mm.debit+=Math.abs(n); else mm.credit+=n; byMonth.set(m,mm); }
const monthsSorted = [...byMonth.entries()].sort((a,b)=>b[1].debit-a[1].debit);
console.log(`\nQ15 most-spend month = ${monthLabel(monthsSorted[0][0])} (${fmt(monthsSorted[0][1].debit)})`);
console.log(`Q16 least-spend month = ${monthLabel(monthsSorted[monthsSorted.length-1][0])} (${fmt(monthsSorted[monthsSorted.length-1][1].debit)})`);
console.log(`Q17 December 2024 spend = ${fmt(byMonth.get("2024-12")?.debit||0)}`);
console.log(`  all months:`); [...byMonth.entries()].sort().forEach(([m,mm])=>console.log(`    ${monthLabel(m)}: debit ${fmt(mm.debit)}, credit ${fmt(mm.credit)}`));
// Q18 Devendra per month
show("Q18 Devendra per month", ["devendra"], { perMonth: true });
// Q19 Nikhil total
show("Q19 Nikhil", ["nikhil"]);
// Q20 UPI count
const upi = records.filter((r) => /upi/i.test(r.Description));
console.log(`\nQ20 UPI transactions = ${upi.length} of ${records.length}`);

if (DO_STORE) {
  console.log("\n" + "=".repeat(70) + "\nStoring to SQLite + Chroma...");
  initDb();
  replaceDocument({ fileName: "Acct Statement_XX2635_04032025.pdf", columns: parsed.columns, rowCount: parsed.rowCount, chunks: parsed.chunks, summary, records, currency: getCurrencyCode() });
  await initChromaDb();
  if (isChromaReady()) { await replaceChromaDocument(parsed.chunks, { fileName: "Acct Statement_XX2635_04032025.pdf" }); console.log("Chroma re-embedded."); }
  else console.log("Chroma not ready — skipped.");
  console.log("Stored.");
}
process.exit(0);
