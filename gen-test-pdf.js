// Generate a client-facing PDF test bank: ~200 questions with correct answers,
// computed from the currently-loaded dataset's ground truth (so they match what
// the assistant returns).  Output: TEST-QUESTIONS.pdf
import fs from "node:fs";
import PDFDocument from "pdfkit";
import { initDb, getRecords, getPeriodSummaries, getMeta } from "./src/db.js";
import { aggregateByKeywords, recAmount, recMonth, topTransactions, smallestDebit } from "./src/aggregate.js";
import { categorize } from "./src/periods.js";

initDb();
const recs = getRecords();
const periods = getPeriodSummaries();
const meta = getMeta();
const debits = recs.filter((r) => recAmount(r) < 0);
const credits = recs.filter((r) => recAmount(r) > 0);
const sumAbs = (a) => a.reduce((s, r) => s + Math.abs(recAmount(r)), 0);
const M = (n) => "Rs. " + Math.abs(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const kw = (...k) => aggregateByKeywords(recs, k);
const r0 = (n) => Math.round(n);

const MN = { "01": "January", "02": "February", "03": "March", "04": "April", "05": "May", "06": "June", "07": "July", "08": "August", "09": "September", "10": "October", "11": "November", "12": "December" };
const monthName = (ym) => `${MN[ym.split("-")[1]]} ${ym.split("-")[0]}`;

const months = [...new Set(recs.map(recMonth))].sort();
const monthSpend = new Map();
for (const r of debits) monthSpend.set(recMonth(r), (monthSpend.get(recMonth(r)) || 0) + Math.abs(recAmount(r)));

const totDebit = sumAbs(debits), totCredit = credits.reduce((s, r) => s + recAmount(r), 0);
const net = totCredit - totDebit;
const upi = recs.filter((r) => /upi/i.test(r.Description)).length;
const largest = topTransactions(recs, 1, "debit")[0];
const bigCredit = topTransactions(recs, 1, "credit")[0];
const small = smallestDebit(recs);

// ── build sections ──────────────────────────────────────────────────────────
const sections = [];
const add = (title, items) => sections.push({ title, items });

add("1. Overview & Totals", [
  ["What is my total spending overall?", `${M(totDebit)} across ${debits.length.toLocaleString("en-IN")} debit transactions.`],
  ["What is my total income?", `${M(totCredit)} across ${credits.length.toLocaleString("en-IN")} credits.`],
  ["What is my net total?", `${net < 0 ? "-" : "+"}${M(net)} (income minus spending).`],
  ["How many transactions are there in total?", `${recs.length.toLocaleString("en-IN")} transactions.`],
  ["How many UPI transactions did I make?", `${upi.toLocaleString("en-IN")} of ${recs.length.toLocaleString("en-IN")} transactions.`],
  ["What is my average transaction?", `${M(net / recs.length)} (net per transaction).`],
  ["What was my largest single expense?", `${M(recAmount(largest))} to ${largest.Description.split(" - ")[0]} on ${largest.Date}.`],
  ["What was my largest single credit?", `${M(recAmount(bigCredit))} from ${bigCredit.Description.split(" - ")[0]} on ${bigCredit.Date}.`],
  ["What is the smallest amount I ever spent?", `${M(recAmount(small))} to ${small.Description.split(" - ")[0]} on ${small.Date}.`],
]);

// merchants
const merchantList = [
  "Swiggy", "Zomato", "Dominos", "KFC", "CCD", "Blinkit", "Zepto", "BigBasket", "DMart", "Reliance Fresh",
  "Amazon", "Flipkart", "Myntra", "Ajio", "Meesho", "Netflix", "Spotify", "PVR", "BookMyShow", "Hotstar",
  "Jio", "Airtel", "Excitel", "BSES", "Uber", "Ola Cabs", "Rapido", "Indian Oil", "Fastag", "Apollo",
  "1MG", "Pharmeasy", "Max Hospital", "Zerodha", "Groww", "LIC", "HDFC Mutual Fund", "CRED",
];
const merchItems = [];
for (const name of merchantList) {
  const a = kw(name.toLowerCase());
  if (a.count > 0) merchItems.push([`How much did I spend on ${name}?`, `${M(a.debit)} across ${a.count} transactions.`]);
}
add("2. Spending by Merchant", merchItems);

// categories
const cats = ["Groceries", "Transport", "Food & Dining", "Shopping", "Utilities", "Entertainment", "Healthcare", "Investment & Insurance"];
const catItems = [];
for (const c of cats) {
  const md = debits.filter((r) => categorize(r) === c);
  if (md.length) catItems.push([`How much did I spend on ${c.toLowerCase()}?`, `${M(sumAbs(md))} across ${md.length} transactions.`]);
}
add("3. Spending by Category", catItems);

// monthly
add("4. Monthly Spending", months.map((ym) => [`How much did I spend in ${monthName(ym)}?`, `${M(monthSpend.get(ym) || 0)} that month.`]));

// people
const people = ["Devendra Kumar", "Nikhil", "Rahul Sharma", "Priya Singh", "Amit Kumar", "Neha Gupta", "Vikram"];
const peopleItems = [];
for (const p of people) {
  const a = kw(p.toLowerCase());
  if (a.debit > 0) peopleItems.push([`How much did I send to ${p}?`, `${M(a.debit)} across ${a.matched.filter((r) => recAmount(r) < 0).length} payments.`]);
}
add("5. People & Transfers", peopleItems);

// recurring/special
add("6. Salary, Interest & Recurring", [
  ["What is my total salary credited?", `${M(aggregateByKeywords(recs, ["salary"]).credit)}.`],
  ["How much interest did I earn?", `${M(aggregateByKeywords(recs, ["interest"]).credit)}.`],
  ["How much did I pay in rent?", `${M(kw("rent").debit)}.`],
  ["How much did I invest in Groww?", `${M(kw("groww").debit)}.`],
  ["How much did I invest through Zerodha?", `${M(kw("zerodha").debit)}.`],
  ["How much did I pay to CRED?", `${M(kw("cred").debit)}.`],
]);

// rolling period summaries
const periodItems = [];
const winLabel = { 3: "3", 6: "6", 9: "9", 12: "12" };
const pool = periods.filter((p) => [3, 6, 9, 12].includes(p.window)).sort((a, b) => (a.anchor < b.anchor ? 1 : -1));
const CAP = 78;
const step = Math.max(1, Math.floor(pool.length / CAP));
for (let i = 0; i < pool.length && periodItems.length < CAP; i += step) {
  const p = pool[i];
  periodItems.push([`Summarize the ${winLabel[p.window]} months ending ${monthName(p.anchor)}.`,
    `Spending ${M(p.metrics.expense)}, income ${M(p.metrics.income)}, net ${p.metrics.net < 0 ? "-" : "+"}${M(p.metrics.net)} over ${p.periodLabel}.`]);
}
add("7. Rolling Period Summaries (3 / 6 / 9 / 12 months)", periodItems);

// extremes
const ms = [...monthSpend.entries()].sort((a, b) => b[1] - a[1]);
add("8. Monthly Extremes", [
  ["Which month did I spend the most money?", `${monthName(ms[0][0])} — ${M(ms[0][1])}.`],
  ["Which month did I spend the least money?", `${monthName(ms[ms.length - 1][0])} — ${M(ms[ms.length - 1][1])}.`],
]);

// edge
add("9. Edge Cases (assistant should report 'not found', not a number)", [
  ["How much did I spend on Tesla?", "Not found — no such transactions in the statement."],
  ["How much did I spend on Starbucks?", "Not found — no such transactions."],
  ["How much did I spend on Walmart?", "Not found — no such transactions."],
  ["How much did I spend on Gambling?", "Not found — no such transactions."],
  ["How much did I spend on Cryptocurrency?", "Not found — no such transactions."],
  ["How much did I spend on Indane?", "Not found — no such transactions."],
  ["How much did I spend on Bitcoin?", "Not found — no such transactions."],
  ["How much did I spend on rent in 1999?", "Not found / no data for that period."],
]);

// phrasing variations (same facts, different wording)
const cred = kw("cred").debit, amz = kw("amazon").debit;
add("10. Phrasing Variations", [
  ["total CRED payments?", `${M(cred)}.`],
  ["what did I pay CRED?", `${M(cred)}.`],
  ["my CRED spending", `${M(cred)}.`],
  ["how much to Amazon?", `${M(amz)}.`],
  ["Amazon total", `${M(amz)}.`],
  ["spending at Amazon", `${M(amz)}.`],
  ["What's my overall spend?", `${M(totDebit)}.`],
  ["total expenses", `${M(totDebit)}.`],
  ["how much money came in?", `${M(totCredit)} (total income).`],
  ["number of UPI payments", `${upi.toLocaleString("en-IN")}.`],
]);

// multi-merchant
add("11. Combined / Multi-merchant", [
  ["How much did I spend on Swiggy and Zomato?", `${M(kw("swiggy", "zomato").debit)} combined.`],
  ["Combined spending on Uber and Rapido?", `${M(kw("uber", "rapido").debit)}.`],
  ["Total on Blinkit, Zepto and BigBasket?", `${M(kw("blinkit", "zepto", "bigbasket").debit)}.`],
  ["Spending on Netflix and Spotify together?", `${M(kw("netflix", "spotify").debit)}.`],
]);

const totalQ = sections.reduce((s, x) => s + x.items.length, 0);

// ── render PDF ────────────────────────────────────────────────────────────
const OUT = "TEST-QUESTIONS.pdf";
const doc = new PDFDocument({ size: "A4", margins: { top: 56, bottom: 56, left: 56, right: 56 } });
doc.pipe(fs.createWriteStream(OUT));

doc.fontSize(20).font("Helvetica-Bold").text("Local LLM Bank Assistant");
doc.fontSize(14).font("Helvetica").text("Test Question Bank — Questions & Correct Answers");
doc.moveDown(0.6);
doc.fontSize(10).fillColor("#444")
  .text(`Dataset under test: ${meta.fileName || "loaded statement"}`)
  .text(`${recs.length.toLocaleString("en-IN")} transactions  •  ${monthName(months[0])} – ${monthName(months[months.length - 1])}  •  currency INR`)
  .text(`Totals — spending ${M(totDebit)}  |  income ${M(totCredit)}  |  ${totalQ} test questions`);
doc.moveDown(0.6);
doc.fillColor("#000").fontSize(10).font("Helvetica")
  .text("How to use: open the app, make sure this dataset is loaded, and ask each question in the chat. Compare the assistant's answer to the 'Answer' below. Every question in this bank is answered instantly and exactly (no model needed) — the figures should match to the rupee; only the surrounding wording may differ. Amounts shown as 'Rs.' are Indian Rupees (the app displays the same value with the Rs. symbol).", { align: "left" });
doc.moveDown(0.5);
doc.moveTo(56, doc.y).lineTo(539, doc.y).strokeColor("#ccc").stroke();
doc.moveDown(0.5);

let n = 0;
for (const sec of sections) {
  if (doc.y > 720) doc.addPage();
  doc.moveDown(0.4);
  doc.fontSize(13).font("Helvetica-Bold").fillColor("#1a3c6e").text(sec.title);
  doc.moveDown(0.3);
  for (const [q, a] of sec.items) {
    n++;
    if (doc.y > 740) doc.addPage();
    doc.fontSize(10.5).font("Helvetica-Bold").fillColor("#000").text(`Q${n}. ${q}`);
    doc.fontSize(10.5).font("Helvetica").fillColor("#1a7f37").text(`Answer: ${a}`, { indent: 12 });
    doc.moveDown(0.35);
  }
}

doc.end();
console.log(`Wrote ${OUT} with ${totalQ} questions across ${sections.length} sections.`);
