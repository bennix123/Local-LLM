
// Bank statement parser — supports CSV, Excel, and PDF.
// Auto-normalizes Indian bank columns (Narration/Dr/Cr/₹) to standard format.

import Papa from "papaparse";
import * as XLSX from "xlsx";
import pdfParse from "pdf-parse/lib/pdf-parse.js";
import { detectCurrency, resetCurrency } from "./currency.js";

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

export async function parsePdf(buffer) {
  const data = await pdfParse(buffer);
  const lines = (data.text || "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  const chunks = lines.slice(0, MAX_ROWS);
  return { columns: [], rowCount: chunks.length, chunks, records: [] };
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
