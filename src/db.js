// Local persistence using Node's built-in SQLite (node:sqlite).
// No native compilation needed — works out of the box on macOS & Windows
// (requires Node >= 22.5). FTS5 is compiled in, so we get fast keyword search.

import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DB_PATH = path.join(__dirname, "..", "data", "bank.db");

let db;

export function initDb() {
  if (db) return db;
  // Ensure the data directory exists (DatabaseSync won't create parent dirs).
  fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
  db = new DatabaseSync(DB_PATH);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec(`
    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT
    );
  `);
  // FTS5 table: one row per parsed line/transaction. We keep row_index in an
  // unindexed column so we can reconstruct order and feed the full sheet.
  db.exec(`
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
      content,
      row_index UNINDEXED
    );
  `);
  return db;
}

/** Replace the entire stored document with a fresh set of text chunks. */
export function replaceDocument({ fileName, columns, rowCount, chunks, summary }) {
  db.exec("DELETE FROM chunks;");
  db.exec("DELETE FROM meta;");

  const setMeta = db.prepare("INSERT INTO meta (key, value) VALUES (?, ?);");
  setMeta.run("fileName", fileName);
  setMeta.run("columns", JSON.stringify(columns || []));
  setMeta.run("rowCount", String(rowCount ?? chunks.length));
  setMeta.run("summary", summary || "");

  const insert = db.prepare(
    "INSERT INTO chunks (content, row_index) VALUES (?, ?);"
  );
  // node:sqlite has no explicit transaction helper; wrap manually for speed.
  db.exec("BEGIN;");
  try {
    chunks.forEach((text, i) => insert.run(text, i));
    db.exec("COMMIT;");
  } catch (e) {
    db.exec("ROLLBACK;");
    throw e;
  }
}

export function clearDocument() {
  db.exec("DELETE FROM chunks;");
  db.exec("DELETE FROM meta;");
}

export function getMeta() {
  const rows = db.prepare("SELECT key, value FROM meta;").all();
  const out = {};
  for (const r of rows) out[r.key] = r.value;
  return {
    fileName: out.fileName || null,
    columns: out.columns ? JSON.parse(out.columns) : [],
    rowCount: out.rowCount ? Number(out.rowCount) : 0,
    summary: out.summary || "",
  };
}

export function getAllChunks() {
  return db
    .prepare("SELECT content FROM chunks ORDER BY row_index ASC;")
    .all()
    .map((r) => r.content);
}

export function getTotalContentLength() {
  const row = db
    .prepare("SELECT COALESCE(SUM(LENGTH(content)), 0) AS total FROM chunks;")
    .get();
  return Number(row.total) || 0;
}

/** Keyword search via FTS5. Returns up to `limit` matching lines, best first. */
export function searchChunks(query, limit = 12) {
  const terms = (query.match(/[\p{L}\p{N}]+/gu) || [])
    .filter((t) => t.length > 1)
    .map((t) => `"${t}"`);
  if (terms.length === 0) return [];
  const matchExpr = terms.join(" OR ");
  try {
    return db
      .prepare(
        `SELECT content FROM chunks
         WHERE chunks MATCH ?
         ORDER BY rank
         LIMIT ?;`
      )
      .all(matchExpr, limit)
      .map((r) => r.content);
  } catch {
    return [];
  }
}

export function hasDocument() {
  const row = db.prepare("SELECT COUNT(*) AS n FROM chunks;").get();
  return Number(row.n) > 0;
}
