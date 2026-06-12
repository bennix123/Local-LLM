// Builds the system prompt (context) fed to the model for each question.
//
// Bank statements are usually small, and questions are often aggregate ones
// ("how much did I spend on food", "what's my biggest debit"). Pure top-K
// keyword retrieval can't answer totals. So: if the whole statement fits in a
// reasonable context budget, we feed EVERY row. Only for very large sheets do
// we fall back to FTS5 keyword retrieval of the most relevant rows.

import {
  getMeta,
  getAllChunks,
  getTotalContentLength,
  searchChunks,
} from "./db.js";

// ~4 chars/token; keep well under small models' context windows.
const FULL_CONTEXT_CHAR_BUDGET = 24000;

export function buildSystemPrompt(question) {
  const meta = getMeta();
  const totalLen = getTotalContentLength();

  let rows;
  let mode;
  if (totalLen <= FULL_CONTEXT_CHAR_BUDGET) {
    rows = getAllChunks();
    mode = "full";
  } else {
    rows = searchChunks(question, 30);
    mode = "search";
  }

  const header = [
    "You are a precise assistant that answers questions about the user's uploaded bank statement.",
    "Rules:",
    "- Use ONLY the statement data below. Do not invent transactions or numbers.",
    "- When asked for totals, sums, counts, or averages, compute them step by step from the rows and double-check the arithmetic.",
    "- Keep currency/number formatting as it appears in the data.",
    "- If the answer is not in the data, say you cannot find it in the statement.",
    "",
    `Statement file: ${meta.fileName || "unknown"}`,
    meta.columns.length ? `Columns: ${meta.columns.join(", ")}` : null,
    `Total rows in statement: ${meta.rowCount}`,
    mode === "search"
      ? `NOTE: The statement is large; below are only the rows most relevant to the question (not all ${meta.rowCount} rows). Totals may be incomplete.`
      : null,
    "",
    "=== STATEMENT DATA ===",
    rows.join("\n"),
    "=== END OF DATA ===",
  ]
    .filter((l) => l !== null)
    .join("\n");

  return header;
}
