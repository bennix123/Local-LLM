// Position-aware HDFC statement parser.
// Recovers x/y coordinates via pdf-parse's bundled pdfjs (pagerender hook),
// reconstructs visual lines, buckets items into columns by x, and groups them
// into transactions (handling multi-line wrapped narrations).
//
//   node parse-hdfc.js          -> parse + self-check (counts, balance continuity)
//   node parse-hdfc.js diag     -> dump positioned lines
//   node parse-hdfc.js summary  -> dump the statement-summary tail lines

import fs from "node:fs";
import pdfParse from "pdf-parse/lib/pdf-parse.js";

const PDF_PATH = process.env.PDF_PATH || "C:/Users/Hp/Downloads/Acct Statement_XX2635_04032025.pdf";
const MODE = process.argv[2] || "parse";

// Column x-boundaries (from the diag output).
// Date sits at x≈34, narration starts at x≈68. Boundary must fall in that gap
// (narration occasionally starts as low as x=68, so 70 is too high).
const COL = { dateMax: 55, narrMax: 289, refMax: 362, valMax: 405, wdrMax: 491, depMax: 564 };
const DATE_RE = /^\d{2}\/\d{2}\/\d{2}$/;

const items = [];
async function pagerender(pageData) {
  const tc = await pageData.getTextContent({ normalizeWhitespace: true, disableCombineTextItems: false });
  const page = pageData.pageNumber;
  for (const it of tc.items) {
    if (it.str == null) continue;
    items.push({ page, x: it.transform[4], y: it.transform[5], str: it.str });
  }
  return "";
}

function buildLines() {
  const byPage = new Map();
  for (const it of items) {
    if (!byPage.has(it.page)) byPage.set(it.page, []);
    byPage.get(it.page).push(it);
  }
  const lines = [];
  for (const page of [...byPage.keys()].sort((a, b) => a - b)) {
    const pageItems = byPage.get(page).sort((a, b) => b.y - a.y || a.x - b.x);
    let cur = null;
    for (const it of pageItems) {
      if (!cur || Math.abs(it.y - cur.y) > 3) { cur = { page, y: it.y, items: [] }; lines.push(cur); }
      cur.items.push(it);
    }
  }
  for (const ln of lines) ln.items.sort((a, b) => a.x - b.x);
  return lines;
}

function bucket(ln) {
  const b = { date: [], narr: [], ref: [], val: [], wdr: [], dep: [], bal: [] };
  for (const it of ln.items) {
    const x = it.x;
    if (x < COL.dateMax) b.date.push(it);
    else if (x < COL.narrMax) b.narr.push(it);
    else if (x < COL.refMax) b.ref.push(it);
    else if (x < COL.valMax) b.val.push(it);
    else if (x < COL.wdrMax) b.wdr.push(it);
    else if (x < COL.depMax) b.dep.push(it);
    else b.bal.push(it);
  }
  return b;
}

const txt = (arr) => arr.map((i) => i.str).join("").trim();
const numOf = (arr) => {
  const s = txt(arr).replace(/,/g, "");
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  return parseFloat(s);
};

function parseTransactions(lines) {
  const records = [];
  let cur = null;
  const flush = () => { if (cur) records.push(cur); cur = null; };

  for (const ln of lines) {
    const b = bucket(ln);
    const dateStr = txt(b.date);
    const isTxnStart = DATE_RE.test(dateStr);

    if (isTxnStart) {
      flush();
      const wdr = numOf(b.wdr);
      const dep = numOf(b.dep);
      const bal = numOf(b.bal);
      cur = {
        Date: dateStr,
        Narration: txt(b.narr),
        Ref: txt(b.ref),
        ValueDate: txt(b.val),
        withdrawal: wdr,
        deposit: dep,
        Balance: bal,
      };
    } else {
      // pure-narration continuation: items only in the narration band, no date/amounts
      const onlyNarr = b.date.length === 0 && b.ref.length === 0 && b.val.length === 0 &&
        b.wdr.length === 0 && b.dep.length === 0 && b.bal.length === 0 && b.narr.length > 0;
      if (cur && onlyNarr) cur.Narration += txt(b.narr);
    }
  }
  flush();
  return records;
}

function derivePayee(narr) {
  const parts = narr.split("-");
  if (/^UPI/i.test(parts[0])) return (parts[1] || "").replace(/\s+/g, " ").trim();
  const tptIdx = parts.findIndex((p) => /^(TPT|NEFT|IMPS|ME DC|ACH|MMT|RTGS)$/i.test(p.trim()));
  if (tptIdx >= 0 && parts[tptIdx + 1]) return parts[tptIdx + 1].replace(/\s+/g, " ").trim();
  return (parts[0] || "").replace(/\s+/g, " ").trim();
}

// Convert to the standard record shape stats.js / ingest expect.
export function toStandardRecords(records) {
  return records.map((r) => {
    const signed = r.withdrawal != null ? -r.withdrawal : r.deposit != null ? r.deposit : 0;
    const payee = derivePayee(r.Narration);
    return {
      Date: r.Date,
      Description: `${payee} - ${r.Narration}`,
      Narration: r.Narration,
      Amount: signed >= 0 ? `+${signed.toFixed(2)}` : signed.toFixed(2),
      Balance: r.Balance != null ? r.Balance.toFixed(2) : "",
    };
  });
}

export async function parseHdfc(pdfPath = PDF_PATH) {
  items.length = 0;
  await pdfParse(fs.readFileSync(pdfPath), { pagerender });
  const lines = buildLines();
  const raw = parseTransactions(lines);
  return { raw, lines };
}

// ── CLI ───────────────────────────────────────────────────────────────────
const isCli = process.argv[1] && process.argv[1].replace(/\\/g, "/").includes("parse-hdfc.js");
if (!isCli) { /* imported as a module: skip CLI */ }
else {
const { raw, lines } = await parseHdfc();

if (MODE === "diag") {
  for (const ln of lines.slice(0, 55)) {
    console.log(`p${ln.page} y=${Math.round(ln.y)} | ` + ln.items.map((i) => `[x=${Math.round(i.x)}]${i.str}`).join("  "));
  }
  process.exit(0);
}
if (MODE === "summary") {
  for (const ln of lines.slice(-45)) {
    console.log(`p${ln.page} y=${Math.round(ln.y)} | ` + ln.items.map((i) => i.str).join(" | "));
  }
  process.exit(0);
}

// parse + self-check
let totWdr = 0, totDep = 0, nWdr = 0, nDep = 0, breaks = 0, firstBreak = null;
let prevBal = null;
for (let i = 0; i < raw.length; i++) {
  const r = raw[i];
  if (r.withdrawal != null) { totWdr += r.withdrawal; nWdr++; }
  if (r.deposit != null) { totDep += r.deposit; nDep++; }
  // balance continuity: prevBal + dep - wdr ≈ bal
  if (prevBal != null && r.Balance != null) {
    const expected = prevBal + (r.deposit || 0) - (r.withdrawal || 0);
    if (Math.abs(expected - r.Balance) > 0.05) {
      breaks++;
      if (firstBreak == null) firstBreak = { i, date: r.Date, prevBal, dep: r.deposit, wdr: r.withdrawal, bal: r.Balance, expected };
    }
  }
  if (r.Balance != null) prevBal = r.Balance;
}
const fmt = (n) => n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
console.log(`transactions parsed: ${raw.length}`);
console.log(`date range: ${raw[0]?.Date}  ->  ${raw[raw.length - 1]?.Date}`);
console.log(`withdrawals: ${nWdr} totaling ₹${fmt(totWdr)}`);
console.log(`deposits:    ${nDep} totaling ₹${fmt(totDep)}`);
console.log(`net: ₹${fmt(totDep - totWdr)}`);
console.log(`first balance: ₹${fmt(raw[0]?.Balance ?? 0)}   last balance: ₹${fmt(raw[raw.length - 1]?.Balance ?? 0)}`);
console.log(`balance-continuity breaks: ${breaks}`);
if (firstBreak) console.log(`  first break:`, JSON.stringify(firstBreak));
console.log(`\n--- first 3 standardized records ---`);
console.log(JSON.stringify(toStandardRecords(raw).slice(0, 3), null, 2));
process.exit(0);
}
