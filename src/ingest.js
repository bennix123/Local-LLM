
// Bank statement parser — supports CSV, Excel, and PDF.
// Auto-normalizes Indian bank columns (Narration/Dr/Cr/₹) to standard format.

import Papa from "papaparse";
import * as XLSX from "xlsx";
import pdfParse from "pdf-parse/lib/pdf-parse.js";
import { detectCurrency, resetCurrency, setCurrency } from "./currency.js";

const MAX_ROWS = 20000;

const COLUMN_MAP = {
  date: [/date/i, /txn\s*date/i, /value\s*date/i, /posting\s*date/i, /transaction\s*date/i, /posted\s*on/i],
  description: [/description/i, /particulars?/i, /narration/i, /remarks/i, /details/i, /memo/i, /narrative/i, /payee/i, /name/i, /merchant/i],
  amount: [/amount/i, /value/i, /^amt$/i, /sum/i, /total/i],
  debit: [/debit/i, /withdrawal/i, /dr/i, /paid\s*out/i, /outflow/i],
  credit: [/credit/i, /deposit/i, /cr/i, /paid\s*in/i, /inflow/i, /income/i],
  category: [/category/i, /type/i, /tag/i, /class/i, /group/i, /mode/i],
  balance: [/balance/i, /closing\s*balance/i, /available\s*balance/i, /running\s*balance/i, /remaining/i],
};

function normalizeColumn(col) {
  for (const [standard, patterns] of Object.entries(COLUMN_MAP)) {
    for (const re of patterns) {
      if (re.test(col)) {
        if (standard === "debit" || standard === "credit") {
          return { type: "amount_split", side: standard, original: col };
        }
        return standard;
      }
    }
  }
  return col;
}

function normalizeRecords(records) {
  if (!records.length) return records;

  const colMap = {};
  let debitCol = null, creditCol = null;
  for (const col of Object.keys(records[0])) {
    const norm = normalizeColumn(col);
    if (typeof norm === "object" && norm.type === "amount_split") {
      colMap[col] = norm;
      if (norm.side === "debit") debitCol = col;
      if (norm.side === "credit") creditCol = col;
    } else {
      colMap[col] = norm;
    }
  }

  return records.map((row) => {
    const newRow = {};
    for (const [col, val] of Object.entries(row)) {
      const mapped = colMap[col];
      if (typeof mapped === "object" && mapped.type === "amount_split") continue;
      newRow[mapped] = val;
    }

    if (debitCol || creditCol) {
      const debit = debitCol ? String(row[debitCol] || "").trim() : "";
      const credit = creditCol ? String(row[creditCol] || "").trim() : "";
      if (debit) newRow.Amount = `-${debit}`;
      else if (credit) newRow.Amount = `+${credit}`;
    }
    return newRow;
  });
}

function rowToLine(rowObj, columns, index) {
  const parts = columns
    .map((col) => {
      const val = rowObj[col];
      if (val === undefined || val === null || String(val).trim() === "") return null;
      return `${col}: ${String(val).trim()}`;
    })
    .filter(Boolean);
  return `Row ${index + 1} | ${parts.join("; ")}`;
}

function tabularToChunks(records) {
  if (!records.length) return { columns: [], rowCount: 0, chunks: [], records: [] };
  const columns = Object.keys(records[0]);
  const rows = records.slice(0, MAX_ROWS);
  const chunks = rows.map((r, i) => rowToLine(r, columns, i));
  return { columns, rowCount: rows.length, chunks, records: rows };
}

export function parseCsv(buffer) {
  const text = buffer.toString("utf8");
  const result = Papa.parse(text, {
    header: true,
    skipEmptyLines: "greedy",
    transformHeader: (h) => h.trim(),
  });
  const records = (result.data || []).filter((r) =>
    Object.values(r).some((v) => String(v ?? "").trim() !== "")
  );
  return tabularToChunks(normalizeRecords(records));
}

export function parseXlsx(buffer) {
  const wb = XLSX.read(buffer, { type: "buffer" });
  const firstSheetName = wb.SheetNames[0];
  const ws = wb.Sheets[firstSheetName];
  const records = XLSX.utils.sheet_to_json(ws, { defval: "", raw: false });
  const cleaned = records.filter((r) =>
    Object.values(r).some((v) => String(v ?? "").trim() !== "")
  );
  return tabularToChunks(normalizeRecords(cleaned));
}

// ── Position-aware PDF table parsing (HDFC-style statements) ───────────────
// pdf-parse's plain text mashes columns together. We instead recover x/y
// coordinates via the pagerender hook, reconstruct visual lines, bucket items
// into columns by x, and group them into transactions (handling multi-line
// wrapped narrations). Falls back to a plain line dump for unknown layouts.

const HDFC_COL = { dateMax: 55, narrMax: 289, refMax: 362, valMax: 405, wdrMax: 491, depMax: 564 };
const PDF_DATE_RE = /^\d{2}\/\d{2}\/\d{2}$/;

async function extractPdfItems(buffer) {
  const items = [];
  await pdfParse(buffer, {
    pagerender: async (pageData) => {
      const tc = await pageData.getTextContent({ normalizeWhitespace: true, disableCombineTextItems: false });
      const page = pageData.pageNumber;
      for (const it of tc.items) {
        if (it.str == null) continue;
        items.push({ page, x: it.transform[4], y: it.transform[5], str: it.str });
      }
      return "";
    },
  });
  return items;
}

function itemsToLines(items) {
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

function looksLikeHdfc(lines) {
  return lines.some((ln) => {
    const s = ln.items.map((i) => i.str).join(" ");
    return /Withdrawal Amt/i.test(s) && /Deposit Amt/i.test(s) && /Closing Balance/i.test(s);
  });
}

function bucketLine(ln) {
  const b = { date: [], narr: [], ref: [], val: [], wdr: [], dep: [], bal: [] };
  for (const it of ln.items) {
    const x = it.x;
    if (x < HDFC_COL.dateMax) b.date.push(it);
    else if (x < HDFC_COL.narrMax) b.narr.push(it);
    else if (x < HDFC_COL.refMax) b.ref.push(it);
    else if (x < HDFC_COL.valMax) b.val.push(it);
    else if (x < HDFC_COL.wdrMax) b.wdr.push(it);
    else if (x < HDFC_COL.depMax) b.dep.push(it);
    else b.bal.push(it);
  }
  return b;
}

const colText = (arr) => arr.map((i) => i.str).join("").trim();
const colNum = (arr) => {
  const s = colText(arr).replace(/,/g, "");
  return /^\d+(\.\d+)?$/.test(s) ? parseFloat(s) : null;
};

function parseHdfcTransactions(lines) {
  const out = [];
  let cur = null;
  const flush = () => { if (cur) out.push(cur); cur = null; };
  for (const ln of lines) {
    const b = bucketLine(ln);
    const dateStr = colText(b.date);
    if (PDF_DATE_RE.test(dateStr)) {
      flush();
      cur = { Date: dateStr, Narration: colText(b.narr), withdrawal: colNum(b.wdr), deposit: colNum(b.dep), Balance: colNum(b.bal) };
    } else {
      const onlyNarr = b.date.length === 0 && b.ref.length === 0 && b.val.length === 0 &&
        b.wdr.length === 0 && b.dep.length === 0 && b.bal.length === 0 && b.narr.length > 0;
      if (cur && onlyNarr) cur.Narration += colText(b.narr);
    }
  }
  flush();
  return out;
}

function pdfPayee(narr) {
  const parts = narr.split("-");
  if (/^UPI/i.test(parts[0])) return (parts[1] || "").replace(/\s+/g, " ").trim();
  const i = parts.findIndex((p) => /^(TPT|NEFT|IMPS|ME DC|ACH|MMT|RTGS)$/i.test(p.trim()));
  if (i >= 0 && parts[i + 1]) return parts[i + 1].replace(/\s+/g, " ").trim();
  return (parts[0] || "").replace(/\s+/g, " ").trim();
}

function isoFromDdMmYy(d) {
  const m = d.match(/^(\d{2})\/(\d{2})\/(\d{2})$/);
  return m ? `20${m[3]}-${m[2]}-${m[1]}` : d;
}

export async function parsePdf(buffer) {
  const items = await extractPdfItems(buffer);
  const lines = itemsToLines(items);

  if (looksLikeHdfc(lines)) {
    // The account header states the currency (e.g. "Currency : INR"); honor it,
    // since the parsed amounts carry no symbol of their own.
    const allText = lines.map((l) => l.items.map((i) => i.str).join(" ")).join(" ");
    if (/\bINR\b|Currency\s*:?\s*INR|\bRs\.?\b/i.test(allText)) setCurrency("INR");

    const raw = parseHdfcTransactions(lines);
    if (raw.length >= 5) {
      const records = raw.map((r) => {
        const signed = r.withdrawal != null ? -r.withdrawal : r.deposit != null ? r.deposit : 0;
        const narr = r.Narration.replace(/\s+/g, " ").trim();
        return {
          Date: isoFromDdMmYy(r.Date),
          Description: `${pdfPayee(narr)} - ${narr}`,
          Amount: signed >= 0 ? `+${signed.toFixed(2)}` : signed.toFixed(2),
          Balance: r.Balance != null ? r.Balance.toFixed(2) : "",
        };
      });
      return tabularToChunks(records);
    }
  }

  // Fallback: try SBI bank PDF format (plain text, not tabular like HDFC)
  const plainText = lines
    .map((ln) => ln.items.map((i) => i.str).join(" ").trim())
    .join("\n");

  if (plainText.includes("STATE BANK OF INDIA")) {
    resetCurrency();
    setCurrency("INR"); // Force INR for SBI bank statements
    const { parseSBIPdfFile } = await import("./parse-sbi.js");
    const sbiResult = parseSBIPdfFile(plainText);
    if (sbiResult && sbiResult.records.length >= 5) {
      return tabularToChunks(sbiResult.records);
    }
  }

  // Fallback: plain text lines (unknown layout / non-tabular PDF).
  const textLines = lines
    .map((ln) => ln.items.map((i) => i.str).join(" ").trim())
    .filter((l) => l.length > 0)
    .slice(0, MAX_ROWS);
  return { columns: [], rowCount: textLines.length, chunks: textLines, records: [] };
}

export async function parseFile(fileName, buffer) {
  resetCurrency();
  const ext = fileName.toLowerCase().split(".").pop();
  let result;
  switch (ext) {
    case "csv": case "txt": result = parseCsv(buffer); break;
    case "xlsx": case "xls": result = parseXlsx(buffer); break;
    case "pdf": result = await parsePdf(buffer); break;
    default: throw new Error(`Unsupported file type ".${ext}". Upload CSV, XLSX, or PDF.`);
  }
  detectCurrency(result.records);
  return result;
}
