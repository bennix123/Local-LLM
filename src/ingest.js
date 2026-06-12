// Parse an uploaded bank statement into plain-text "rows" that we store in
// SQLite. Supports CSV, Excel (.xlsx/.xls) and text-based PDF statements.
//
// Each returned chunk is one human-readable line so that (a) FTS5 keyword
// search works well and (b) when the whole sheet fits in the model's context
// we can feed every transaction verbatim for accurate totals/aggregates.

import Papa from "papaparse";
import * as XLSX from "xlsx";
// Import the implementation directly to avoid pdf-parse's index.js debug block
// (which tries to read a bundled sample PDF on require).
import pdfParse from "pdf-parse/lib/pdf-parse.js";

const MAX_ROWS = 20000; // safety cap

function rowToLine(rowObj, columns, index) {
  const parts = columns
    .map((col) => {
      const val = rowObj[col];
      if (val === undefined || val === null || String(val).trim() === "")
        return null;
      return `${col}: ${String(val).trim()}`;
    })
    .filter(Boolean);
  return `Row ${index + 1} | ${parts.join("; ")}`;
}

function tabularToChunks(records) {
  if (!records.length) return { columns: [], rowCount: 0, chunks: [] };
  const columns = Object.keys(records[0]);
  const rows = records.slice(0, MAX_ROWS);
  const chunks = rows.map((r, i) => rowToLine(r, columns, i));
  return { columns, rowCount: rows.length, chunks };
}

export function parseCsv(buffer) {
  const text = buffer.toString("utf8");
  const result = Papa.parse(text, {
    header: true,
    skipEmptyLines: "greedy",
    transformHeader: (h) => h.trim(),
  });
  // Drop fully-empty parsed objects.
  const records = (result.data || []).filter((r) =>
    Object.values(r).some((v) => String(v ?? "").trim() !== "")
  );
  return tabularToChunks(records);
}

export function parseXlsx(buffer) {
  const wb = XLSX.read(buffer, { type: "buffer" });
  const firstSheetName = wb.SheetNames[0];
  const ws = wb.Sheets[firstSheetName];
  // defval ensures every column key is present even when a cell is blank.
  const records = XLSX.utils.sheet_to_json(ws, { defval: "", raw: false });
  const cleaned = records.filter((r) =>
    Object.values(r).some((v) => String(v ?? "").trim() !== "")
  );
  return tabularToChunks(cleaned);
}

export async function parsePdf(buffer) {
  const data = await pdfParse(buffer);
  const lines = (data.text || "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  const chunks = lines.slice(0, MAX_ROWS);
  return { columns: [], rowCount: chunks.length, chunks };
}

/** Dispatch on file extension. Returns { columns, rowCount, chunks }. */
export async function parseFile(fileName, buffer) {
  const ext = fileName.toLowerCase().split(".").pop();
  switch (ext) {
    case "csv":
    case "txt":
      return parseCsv(buffer);
    case "xlsx":
    case "xls":
      return parseXlsx(buffer);
    case "pdf":
      return parsePdf(buffer);
    default:
      throw new Error(
        `Unsupported file type ".${ext}". Upload a CSV, XLSX, or PDF bank statement.`
      );
  }
}
