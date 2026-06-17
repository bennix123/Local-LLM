
// Hybrid Search Pipeline — ChromaDB (semantic) + SQLite FTS5 (BM25 keyword)
// with Reciprocal Rank Fusion (RRF) for merging.
//
// Strategy from Anthropic: run BOTH in parallel, merge via RRF,
// label each chunk with metadata, feed to LLM with strict formatting rules.

import { semanticSearchChunks } from "./chromaDb.js";
import { searchChunks } from "./db.js";
import { txKeyword, txKeywordByMonth } from "./db.js";

export async function hybridSearch(query, entity = null, limit = 20) {
  const [semanticResults, keywordResults, sqlAgg] = await Promise.all([
    semanticRetrieval(query, limit),
    keywordRetrieval(query, limit),
    entity ? sqlAggregation(entity) : Promise.resolve(null),
  ]);

  const merged = reciprocalRankFusion(semanticResults, keywordResults, limit);
  const labeled = labelChunks(merged, query);

  return {
    chunks: labeled,
    semantic: semanticResults,
    keyword: keywordResults,
    sql: sqlAgg,
    merged,
  };
}

async function semanticRetrieval(query, limit) {
  try {
    const raw = await semanticSearchChunks(query, limit);
    return (raw || [])
      .map(parseContextualChunk)
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function keywordRetrieval(query, limit) {
  try {
    const raw = searchChunks(query, limit);
    return (raw || [])
      .map(parseRawChunk)
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function sqlAggregation(entity) {
  try {
    const keywords = String(entity).split(/\s+/).filter(k => k.length > 1);
    const agg = txKeyword(keywords);
    if (agg && agg.count > 0) {
      return {
        entity,
        count: agg.count,
        debit: agg.debit || 0,
        credit: agg.credit || 0,
      };
    }
  } catch {}
  return null;
}

// RRF: score = sum(1 / (k + rank)) across both result lists
// k=60 is standard
function reciprocalRankFusion(semantic, keyword, limit, k = 60) {
  const scores = new Map();

  for (let i = 0; i < semantic.length; i++) {
    const id = `sem_${i}`;
    const score = 1 / (k + i + 1);
    scores.set(id, { chunk: semantic[i], score, source: "semantic" });
  }

  for (let i = 0; i < keyword.length; i++) {
    const id = `kw_${i}`;
    const score = 1 / (k + i + 1);
    if (scores.has(id)) {
      scores.get(id).score += score;
      scores.get(id).source = "both";
    } else {
      scores.set(id, { chunk: keyword[i], score, source: "keyword" });
    }
  }

  return [...scores.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}

// Label each chunk with structured metadata for the LLM prompt
function labelChunks(merged, query) {
  return merged.map((item, i) => {
    const c = item.chunk;
    const date = c.date || "?";
    const desc = (c.payee || c.description || "").substring(0, 50);
    const amt = c.amount != null ? `₹${Math.abs(c.amount).toFixed(2)}` : "";
    const cat = c.category || "";
    const type = c.type || (c.amount < 0 ? "debit" : c.amount > 0 ? "credit" : "");

    return {
      id: i + 1,
      source: item.source,
      date,
      description: desc,
      amount: amt,
      type,
      category: cat,
      score: item.score.toFixed(4),
    };
  });
}

function parseContextualChunk(text) {
  if (!text || typeof text !== "string") return null;
  const row = {};
  const m = text.match(/Payee:\s*([^|;]+)/i);
  if (m) row.payee = m[1].trim();
  const d = text.match(/Description:\s*([^;]+)/i);
  if (d) row.description = d[1].trim();
  const a = text.match(/Amount:\s*([+-]?[\d,]+\.?\d*)/i);
  if (a) row.amount = parseFloat(a[1].replace(/,/g, ""));
  const dt = text.match(/Date:\s*([^;]+)/i);
  if (dt) row.date = dt[1].trim();
  const ct = text.match(/Category:\s*([^;|]+)/i);
  if (ct) row.category = ct[1].trim();
  return row;
}

function parseRawChunk(text) {
  if (!text || typeof text !== "string") return null;
  const row = {};
  const d = text.match(/Description:\s*([^;]+)/i);
  if (d) row.description = d[1].trim();
  const a = text.match(/Amount:\s*([+-]?[\d,]+\.?\d*)/i);
  if (a) row.amount = parseFloat(a[1].replace(/,/g, ""));
  const dt = text.match(/Date:\s*([^;]+)/i);
  if (dt) row.date = dt[1].trim();
  const ct = text.match(/Category:\s*([^;]+)/i);
  if (ct) row.category = ct[1].trim();
  return row;
}

// Build a strict system prompt with retrieved chunks labeled by metadata
export function buildHybridPrompt(query, searchResults, sqlAgg) {
  const lines = [];

  // Strict system instructions
  lines.push(`You are an expert financial assistant. You answer questions about a bank statement using ONLY the retrieved data provided below.`);
  lines.push(``);
  lines.push(`RULES (follow exactly — violations produce incorrect answers):`);
  lines.push(`1. If the data below contains relevant information, answer the question directly.`);
  lines.push(`2. If the data below does NOT contain what the user asked for, say "This bank statement does not contain that information." Do NOT guess or make up data.`);
  lines.push(`3. Preserve EXACT numbers, dates, and amounts from the data. Never round ₹5000 to "about ₹5000" or "thousands of rupees".`);
  lines.push(`4. When listing transactions, include the date and exact amount.`);
  lines.push(`5. Never invent transaction descriptions, dates, amounts, or entity names.`);
  lines.push(`6. Respond in clear prose. 2-5 lines for simple queries, longer only for lists.`);
  lines.push(`7. Never say "based on the data provided" or "according to the facts" — just state the answer.`);
  lines.push(`8. Do NOT reproduce raw JSON, table markup, or source labels in your answer.`);
  lines.push(``);

  // SQL aggregation summary — THE authoritative source for numbers
  if (sqlAgg && sqlAgg.count > 0) {
    lines.push(`--- EXACT AGGREGATES (use these numbers, do not recalculate) ---`);
    lines.push(`Entity: "${sqlAgg.entity}"`);
    lines.push(`Transaction count: ${sqlAgg.count}`);
    if (sqlAgg.debit > 0) lines.push(`Total spent: ₹${sqlAgg.debit.toFixed(2)}`);
    if (sqlAgg.credit > 0) lines.push(`Total received: ₹${sqlAgg.credit.toFixed(2)}`);
    lines.push(``);
  }

  // Labeled retrieved chunks
  if (searchResults.chunks && searchResults.chunks.length > 0) {
    lines.push(`--- RETRIEVED TRANSACTIONS ---`);
    for (const c of searchResults.chunks) {
      const meta = [];
      if (c.date) meta.push(c.date);
      if (c.description) meta.push(c.description);
      if (c.amount) meta.push(`₹${Math.abs(parseFloat(c.amount.replace(/[₹,\s]/g, ""))).toFixed(2)}`);
      if (c.type) meta.push(`(${c.type})`);
      if (c.source) meta.push(`[source: ${c.source}]`);
      lines.push(meta.join(" — "));
    }
    lines.push(``);
  }

  lines.push(`---`);
  lines.push(`User question: ${query}`);
  lines.push(`Answer:`);

  return lines.join("\n");
}
