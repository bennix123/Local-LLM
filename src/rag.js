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

// ~4 chars/token. Kept under the 8192-token context (leaving room for the
// facts block, the question, and the answer). Aggregate questions are still
// answered correctly from the PRE-COMPUTED FACTS even in search mode.
const FULL_CONTEXT_CHAR_BUDGET = 18000;

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
    "You are a precise assistant that answers questions about the user's bank statement.",
    "The full statement data is included below in this prompt. You DO have access to it.",
    "Never say you lack access to the data or the file — the data is right here.",
    "",
    "Rules:",
    "- Answer using ONLY the data below. Do not invent transactions, dates, or numbers.",
    "- For any total, sum, count, min, max, or average, USE THE PRE-COMPUTED FACTS section. Those figures are exact — trust them over doing your own mental math.",
    "- Keep currency/number formatting as it appears in the data.",
    "- Be concise. Give the answer directly. Do NOT repeat yourself or restate the same sentence.",
    "- If something genuinely is not in the data, say so in one short sentence.",
    "",
    `Statement file: ${meta.fileName || "unknown"}`,
    meta.columns.length ? `Columns: ${meta.columns.join(", ")}` : null,
    "",
    meta.summary ? "=== PRE-COMPUTED FACTS (authoritative; use these for any math) ===" : null,
    meta.summary || null,
    meta.summary ? "=== END OF FACTS ===\n" : null,
    mode === "search"
      ? `NOTE: The statement is large; the rows below are only those most relevant to the question (not all ${meta.rowCount}). Use the PRE-COMPUTED FACTS above for any totals.`
      : null,
    "=== STATEMENT ROWS ===",
    rows.join("\n"),
    "=== END OF ROWS ===",
  ]
    .filter((l) => l !== null)
    .join("\n");

  return header;
}
