
// Contextual Retrieval (Anthropic technique, Sep 2024)
// Prepends statement-level context to each chunk before embedding so every
// chunk is independently meaningful and semantically retrievable.
//
// A chunk like "Amazon: -$45.99" becomes:
// "Statement seed_500_transactions.csv | 500 txns | Jan-May 2025 |
//  total expenses $152K | avg transaction -$72.79 | Category Shopping |
//  Amazon: -$45.99"
//
// This improves semantic search retrieval by making each chunk carry the
// broader financial context, similar to Anthropic's SEC filing example.

import { getMeta, getAllChunks, getTotalContentLength } from "./db.js";

function buildStatementContext(meta) {
  const parts = [];
  parts.push(`Statement: ${meta.fileName || "bank_statement"}`);

  if (meta.summary) {
    const facts = meta.summary;

    const totalMatch = facts.match(/Total transactions:\s*(\d+)/i);
    if (totalMatch) parts.push(`${totalMatch[1]} transactions`);

    const dateMatch = facts.match(/(\d{4}-\d{2}):.*(\d{4}-\d{2}):/s);
    if (!dateMatch) {
      const firstDate = facts.match(/^(\d{4}-\d{2}):/m);
      const allDates = [...facts.matchAll(/^(\d{4}-\d{2}):/gm)];
      if (allDates.length >= 2) {
        parts.push(`${allDates[0][1]} to ${allDates[allDates.length - 1][1]}`);
      } else if (firstDate) {
        parts.push(`period ending ${firstDate[1]}`);
      }
    }

    const expenseMatch = facts.match(/Total expenses:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (expenseMatch) parts.push(`total expenses ${expenseMatch[1]}`);

    const incomeMatch = facts.match(/Total income:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (incomeMatch) parts.push(`total income ${incomeMatch[1]}`);

    const avgMatch = facts.match(/Average transaction:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (avgMatch) parts.push(`avg transaction ${avgMatch[1]}`);

    const netMatch = facts.match(/Net total:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (netMatch) parts.push(`net ${netMatch[1]}`);

    const balanceMatch = facts.match(/Current balance:\s*(-?\$-?[\d,]+\.\d{2})/i);
    if (balanceMatch) parts.push(`ending balance ${balanceMatch[1]}`);
  }

  return parts.join(" | ");
}

function extractCategory(line) {
  const m = line.match(/Category:\s*([^;]+)/i);
  return m ? m[1].trim() : null;
}

function extractPayee(line) {
  const m = line.match(/Description:\s*([^-;]+)/i);
  return m ? m[1].trim() : null;
}

function extractAmount(line) {
  const m = line.match(/Amount:\s*([+-]?[\d,.]+)/i);
  return m ? m[1].trim() : null;
}

export function contextualizeChunk(chunk, statementContext) {
  const category = extractCategory(chunk);
  const payee = extractPayee(chunk);
  const amount = extractAmount(chunk);

  const parts = [statementContext];

  if (category) parts.push(`Category: ${category}`);
  if (payee) parts.push(`Payee: ${payee}`);
  if (amount) parts.push(`Amount: ${amount}`);

  parts.push(chunk);

  return parts.join(" | ");
}

export function contextualizeChunks(chunks, meta) {
  const ctx = buildStatementContext(meta);
  return chunks.map((chunk) => contextualizeChunk(chunk, ctx));
}

export function contextualizeSummary(facts, sectionLabel) {
  const ctx = buildStatementContext({ summary: facts });
  const sectionMap = {};

  const lines = facts.split("\n");
  let currentSection = "";

  for (const line of lines) {
    if (line.startsWith("=== ") && line.endsWith(" ===")) {
      currentSection = line.replace(/=== /g, "").replace(/ ===/g, "");
      continue;
    }
    if (line.trim() === "") continue;

    const contextLine = `${ctx} | [${currentSection}] ${line}`;
    if (!sectionMap[currentSection]) sectionMap[currentSection] = [];
    sectionMap[currentSection].push(contextLine);
  }

  const result = [];
  for (const [section, sectionLines] of Object.entries(sectionMap)) {
    result.push(`[${section}]`);
    sectionLines.forEach((l) => result.push(l));
  }

  return result.join("\n");
}
