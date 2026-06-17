// Generate a 1000-question test set (PDF + CSV) with correct answers computed
// from the loaded dataset, and export the dataset itself to CSV.
//   node gen-1000.js
import fs from "node:fs";
import PDFDocument from "pdfkit";
import {
  initDb, getMeta, getRecords, getMonthSummaries, getPeriodSummaries, yearMonthSummaries,
  txOverview, txKeyword, txCategorySpend, txKeywordMonth, txCategoryMonth, getMonthSummary,
  txLargestDebit, txLargestCredit, txSmallestDebit,
} from "./src/db.js";
import { monthLabel } from "./src/aggregate.js";

initDb();
const meta = getMeta();
const M = (n) => "Rs. " + Math.abs(Number(n || 0)).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const num = (n) => Number(n).toLocaleString("en-IN");
const months = getMonthSummaries().map((m) => m.ym);
const periods = getPeriodSummaries();
const MN = { "01": "January", "02": "February", "03": "March", "04": "April", "05": "May", "06": "June", "07": "July", "08": "August", "09": "September", "10": "October", "11": "November", "12": "December" };
const mName = (ym) => `${MN[ym.split("-")[1]]} ${ym.split("-")[0]}`;

const Q = []; // {section, q, a}
const add = (section, q, a) => Q.push({ section, q, a });

// 1. Overview
const o = txOverview();
add("Overview", "What is my total spending overall?", `${M(o.debit)} across ${num(o.debit && o.debitCount)} debit transactions.`);
add("Overview", "What is my total income?", `${M(o.credit)}.`);
add("Overview", "What is my net total?", `${o.credit - o.debit < 0 ? "-" : "+"}${M(o.credit - o.debit)}.`);
add("Overview", "How many transactions are there in total?", `${num(o.count)} transactions.`);
add("Overview", "How many UPI transactions did I make?", `${num(o.upi)} of ${num(o.count)}.`);
const lg = txLargestDebit(), sm = txSmallestDebit(), bc = txLargestCredit();
add("Overview", "What was my largest single expense?", `${M(lg.amount)} to ${lg.payee} on ${lg.date}.`);
add("Overview", "What was my largest single credit?", `${M(bc.amount)} from ${bc.payee} on ${bc.date}.`);
add("Overview", "What is the smallest amount I ever spent?", `${M(sm.amount)} to ${sm.payee} on ${sm.date}.`);
add("Overview", "What is my total salary credited?", `${M(txKeyword(["salary"]).credit)}.`);
add("Overview", "How much interest did I earn?", `${M(txKeyword(["interest"]).credit)}.`);

// 2. Merchants
const MERCHANTS = ["Swiggy", "Zomato", "Dominos", "KFC", "CCD", "Blinkit", "Zepto", "BigBasket", "DMart", "Reliance Fresh", "Amazon", "Flipkart", "Myntra", "Ajio", "Meesho", "Netflix", "Spotify", "PVR", "BookMyShow", "Hotstar", "Jio", "Airtel", "Excitel", "BSES", "Uber", "Rapido", "Indian Oil", "Fastag", "Apollo", "Pharmeasy", "Reliance Fresh", "Zerodha", "Groww", "LIC", "CRED"];
const merchOk = [];
for (const name of MERCHANTS) {
  const a = txKeyword([name.toLowerCase()]);
  if (a.count > 0) { add("Merchants", `How much did I spend on ${name}?`, `${M(a.debit)} across ${num(a.count)} transactions.`); merchOk.push(name); }
}

// 3. Categories
const CATS = ["Groceries", "Transport", "Food & Dining", "Shopping", "Utilities", "Entertainment", "Healthcare", "Investment & Insurance"];
for (const c of CATS) { const x = txCategorySpend(c); if (x.count > 0) add("Categories", `How much did I spend on ${c}?`, `${M(x.debit)} across ${num(x.count)} transactions.`); }

// 4. People
for (const p of ["Devendra Kumar", "Nikhil", "Rahul Sharma", "Priya Singh", "Amit Kumar", "Neha Gupta", "Vikram"]) {
  const a = txKeyword([p.toLowerCase()]); if (a.debit > 0) add("People", `How much did I send to ${p}?`, `${M(a.debit)}.`);
}

// 5. Monthly spending
for (const ym of months) { const m = getMonthSummary(ym); add("Monthly", `How much did I spend in ${mName(ym)}?`, `${M(m.spending)} across ${num(m.count)} transactions.`); }

// 6. Year breakdowns
for (const yr of [...new Set(months.map((m) => m.slice(0, 4)))]) {
  const rows = yearMonthSummaries(yr); const tot = rows.reduce((s, r) => s + r.spending, 0);
  add("Year breakdown", `Give me month-wise expenditure for ${yr}.`, `Total spending ${M(tot)} across ${rows.length} months in ${yr}.`);
}

// 7. Rolling period summaries (3/6/9/12-month)
for (const p of periods.filter((x) => [3, 6, 9, 12].includes(x.window))) {
  add("Period summaries", `Summarize the ${p.window} months ending ${mName(p.anchor)}.`,
    `Spending ${M(p.metrics.expense)}, income ${M(p.metrics.income)}, net ${p.metrics.net < 0 ? "-" : "+"}${M(p.metrics.net)} over ${p.periodLabel}.`);
}

// 8. Category × month (fills out the set with precise combos)
for (const c of CATS) for (const ym of months) {
  if (Q.length >= 1400) break;
  const x = txCategoryMonth(c, ym); if (x && x.count > 0) add("Category by month", `How much did I spend on ${c} in ${mName(ym)}?`, `${M(x.debit)} across ${num(x.count)} transactions.`);
}

// 9. Merchant × month (fills to 1000+)
outer: for (const name of merchOk) for (const ym of months) {
  if (Q.length >= 1100) break outer;
  const a = txKeywordMonth([name.toLowerCase()], ym); if (a && a.count > 0) add("Merchant by month", `How much did I spend on ${name} in ${mName(ym)}?`, `${M(a.debit)} across ${num(a.count)} transactions.`);
}

// cap to 1000, keeping section variety (the lists above are already ordered by variety)
const SET = Q.slice(0, 1000);

// ── write CSV ───────────────────────────────────────────────────────────────
const csvCell = (s) => `"${String(s).replace(/"/g, '""')}"`;
const csv = ["No,Section,Question,Answer", ...SET.map((x, i) => [i + 1, csvCell(x.section), csvCell(x.q), csvCell(x.a)].join(","))].join("\r\n");
fs.writeFileSync("TEST-1000.csv", "﻿" + csv); // BOM for Excel

// ── write PDF ────────────────────────────────────────────────────────────────
const doc = new PDFDocument({ size: "A4", margins: { top: 50, bottom: 50, left: 50, right: 50 } });
const pdfStream = fs.createWriteStream("TEST-1000.pdf");
doc.pipe(pdfStream);
doc.fontSize(20).font("Helvetica-Bold").text("Local LLM Bank Assistant — 1000-Question Test Set");
doc.moveDown(0.3).fontSize(10).font("Helvetica").fillColor("#444")
  .text(`Dataset: ${meta.fileName} · ${num(o.count)} transactions · ${mName(months[0])}–${mName(months[months.length - 1])} · INR (Rs.)`)
  .text(`${SET.length} questions with correct answers, computed from the loaded data. Amounts in Indian Rupees.`);
doc.moveDown(0.5).moveTo(50, doc.y).lineTo(545, doc.y).strokeColor("#ccc").stroke().moveDown(0.4);
let curSec = "";
SET.forEach((x, i) => {
  if (doc.y > 770) doc.addPage();
  if (x.section !== curSec) { curSec = x.section; doc.moveDown(0.3).fontSize(12).font("Helvetica-Bold").fillColor("#1a3c6e").text(curSec).moveDown(0.2); }
  doc.fontSize(9.5).font("Helvetica-Bold").fillColor("#000").text(`Q${i + 1}. ${x.q}`);
  doc.fontSize(9.5).font("Helvetica").fillColor("#1a7f37").text(`Answer: ${x.a}`, { indent: 10 }).moveDown(0.25);
});
doc.end();

// ── export dataset CSV ───────────────────────────────────────────────────────
const recs = getRecords();
const dcsv = ["Date,Description,Category,Amount,Balance", ...recs.map((r) =>
  [r.Date, csvCell(r.Description), csvCell(r.Category || ""), r.Amount, r.Balance].join(","))].join("\r\n");
fs.writeFileSync("dataset_combined.csv", dcsv);

const bySec = {}; SET.forEach((x) => (bySec[x.section] = (bySec[x.section] || 0) + 1));
console.log(`TEST-1000.csv: ${SET.length} questions`);
console.log("by section:", JSON.stringify(bySec));
console.log(`dataset_combined.csv: ${recs.length.toLocaleString("en-IN")} transactions`);
// wait for the PDF stream to finish flushing before exiting
pdfStream.on("finish", () => { console.log("TEST-1000.pdf written."); process.exit(0); });
