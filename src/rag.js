
// Builds the system prompt for the LLM. Always combines:
//   1. Pre-extracted deterministic facts (exact numbers, no hallucination)
//   2. Semantically retrieved transaction rows from vector search
//   3. The user's question
//
// The LLM's job is to ARTICULATE the answer using the retrieved data.
// It should NEVER calculate — all math is in the facts.

import {
  getMeta,
  getAllChunks,
  getTotalContentLength,
  searchChunks,
} from "./db.js";
import { isChromaReady, semanticSearchChunks } from "./chromaDb.js";

const FULL_CONTEXT_CHAR_BUDGET = 18000;

export function extractRelevantFacts(question, facts) {
  if (!facts) return "";

  const searchTerms = [];
  const words = question.match(/[\p{L}\p{N}]+/gu) || [];
  const stopWords = /^(how|much|what|is|the|my|did|was|are|for|and|in|on|of|to|all|any|this|that|list|show|find|give|tell|me|can|you|please|have|has|been|from|with|your|total|spend|spent|transaction|expenses|expense|income|categories|category|biggest|largest|smallest|highest|lowest|average|many|there|does|breakdown|most|more|than|about|which|who|where|when|why|how|i|roast|summarize|explain|compare|my|am|didnt|didn't|don't|dont|im|i'm)\b/i;

  for (const w of words) {
    if (w.length >= 3 && !stopWords.test(w)) {
      searchTerms.push(w);
    }
  }

  const lines = facts.split("\n");
  const matches = [];

  for (const line of lines) {
    if (line.trim() === "" || line.startsWith("===")) continue;
    if (searchTerms.some((t) => line.toLowerCase().includes(t.toLowerCase()))) {
      matches.push(line);
    }
  }

  // Always include the financial overview numbers
  const overviewLines = [];
  let inOverview = false;
  for (const line of lines) {
    if (line.includes("=== FINANCIAL OVERVIEW ===")) { inOverview = true; continue; }
    if (inOverview && line.startsWith("===")) { inOverview = false; break; }
    if (inOverview && line.trim()) overviewLines.push(line);
  }

  const allMatches = [...new Set([...overviewLines, ...matches])];
  return allMatches.join("\n");
}

export async function buildSystemPrompt(question) {
  const meta = getMeta();
  const totalLen = getTotalContentLength();
  const facts = meta.summary || "";
  const relevantFacts = extractRelevantFacts(question, facts);

  let rows = [];
  if (totalLen <= FULL_CONTEXT_CHAR_BUDGET) {
    rows = getAllChunks();
  } else if (isChromaReady()) {
    rows = await semanticSearchChunks(question, 30);
  } else {
    rows = searchChunks(question, 30);
  }

  return buildPrompt(meta, question, relevantFacts, rows);
}

function buildPrompt(meta, question, facts, rows) {
  const parts = [];

  parts.push("You are a helpful bank statement assistant. You analyze financial data and respond conversationally.");

  if (/\b(roast|insult|make fun|drag)\b/i.test(question)) {
    parts.push("");
    parts.push("The user wants you to ROAST them based on their spending. Use the facts below to craft a funny, savage roast about their financial habits. Be witty and specific — reference actual numbers and categories.");
  }

  parts.push("");
  parts.push(`Statement: ${meta.fileName || "unknown"} — ${meta.rowCount} rows`);

  if (facts) {
    parts.push("");
    parts.push("=== KEY FACTS ===");
    parts.push(facts);
    parts.push("=== END FACTS ===");
  }

  if (rows.length > 0) {
    parts.push("");
    parts.push(`=== RELEVANT TRANSACTIONS (${rows.length}) ===`);
    parts.push(rows.join("\n"));
    parts.push("=== END TRANSACTIONS ===");
  }

  parts.push("");
  parts.push("RULES:");
  parts.push("- Answer in natural, conversational language. Do NOT just repeat the facts verbatim.");
  parts.push("- For numbers, use the exact figures from KEY FACTS — never calculate or estimate.");
  parts.push("- Keep answers concise: 2-4 lines for simple questions, longer only if listing items.");
  parts.push("- If a specific payee/category isn't found, honestly say it was not found — don't make things up.");
  parts.push("- Never say 'based on the data' or 'according to the facts' — just give the answer.");

  return parts.join("\n");
}
