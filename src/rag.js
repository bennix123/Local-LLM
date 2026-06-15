
// Builds the system prompt fed to the LLM for each question.
//
// AGGREGATE mode: feeds only the pre-computed facts table. LLM copies the
//   relevant line verbatim — zero reasoning, zero hallucination risk.
// FULL mode: all rows fit in context — feeds everything.
// SEMANTIC/SEARCH mode: runs vector/keyword retrieval for specific lookups.

import {
  getMeta,
  getAllChunks,
  getTotalContentLength,
  searchChunks,
} from "./db.js";
import { isChromaReady, semanticSearchChunks } from "./chromaDb.js";

const FULL_CONTEXT_CHAR_BUDGET = 18000;

const AGGREGATE_PATTERNS = [
  /\bhow much\b/i, /\btotal\b/i, /\boverall\b/i, /\bsum\b/i,
  /\bnet\b/i, /\bspent on\b/i, /\bspending\b/i, /\bcategor(y|ies)\b/i,
  /\bbreakdown\b/i, /\b(most|biggest|largest|highest|smallest|lowest)\b/i,
  /\btop\s*\d+/i, /\baverage\b/i, /\bincome\b/i, /\bexpenses?\b/i,
  /\bsave\b/i, /\bsavings\b/i, /\bmonth(ly)?\b/i,
  /\bwhat (is|was|are|were)\b/i, /\bhow many\b/i,
];

function isAggregateQuestion(question) {
  return AGGREGATE_PATTERNS.some((p) => p.test(question));
}

export async function buildSystemPrompt(question) {
  const meta = getMeta();
  const totalLen = getTotalContentLength();
  const isAgg = isAggregateQuestion(question);

  let rows, mode;

  if (totalLen <= FULL_CONTEXT_CHAR_BUDGET) {
    rows = getAllChunks();
    mode = "full";
  } else if (isAgg) {
    mode = "facts_only";
    rows = [];
  } else if (isChromaReady()) {
    rows = await semanticSearchChunks(question, 30);
    mode = "semantic";
  } else {
    rows = searchChunks(question, 30);
    mode = "search";
  }

  return buildPrompt(meta, mode, rows);
}

function buildPrompt(meta, mode, rows) {
  const facts = meta.summary || "";
  const parts = [];

  parts.push("You are a bank statement assistant. Keep answers SHORT — 1 to 3 lines. Never ramble. Never explain reasoning. Never say \"based on the data\". Give the answer directly.");

  if (mode === "facts_only") {
    parts.push("");
    parts.push("=== FACTS TABLE (copy the exact line that answers the question) ===");
    parts.push(facts);
    parts.push("=== END FACTS ===");
    parts.push("");
    parts.push("RULES:");
    parts.push("- Copy the answer exactly from the facts above. Never change a number.");
    parts.push("- \"Biggest single expense\" means the \"Largest debit\" line, not a category total.");
    parts.push("- Answer in 1-2 lines only. Do not add commentary.");
  } else {
    parts.push("");
    parts.push(`Statement: ${meta.fileName || "unknown"} — ${meta.rowCount} rows`);

    if (facts) {
      parts.push("");
      parts.push("=== FACTS TABLE (for totals use these, not manual math) ===");
      parts.push(facts);
      parts.push("=== END FACTS ===");
    }

    if (rows.length > 0) {
      parts.push("");
      parts.push(`=== ${mode === "full" ? "ALL" : "RELEVANT"} TRANSACTIONS (${rows.length} rows) ===`);
      parts.push(rows.join("\n"));
      parts.push("=== END TRANSACTIONS ===");
    }

    parts.push("");
    parts.push("RULES: For totals use facts. For itemized listings use rows. 1-3 lines max.");
  }

  return parts.join("\n");
}
