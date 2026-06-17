
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
  getPeriodSummaries,
  hasPeriodSummaries,
} from "./db.js";
import { isChromaReady, semanticSearchChunks } from "./chromaDb.js";
import { embedOne, topK } from "./embed.js";
import { formatMetrics } from "./periods.js";
import { getCurrencySymbol } from "./currency.js";

const FULL_CONTEXT_CHAR_BUDGET = 18000;

// Trend / multi-month / period questions are answered from the pre-built
// rolling summaries instead of raw rows — this is what lets the small model
// handle very large statements (lakhs of rows) within a 4GB budget.
const PERIOD_PATTERNS = [
  /\btrend\b/i, /\bover (the )?(last|past)\b/i, /\b(last|past)\s+\d+\s+months?\b/i,
  /\bquarter(ly)?\b/i, /\bq[1-4]\b/i, /\bhalf[- ]?year\b/i, /\bh[12]\b/i,
  /\b(this|last|past|whole|entire)\s+year\b/i, /\bannual\b/i, /\brolling\b/i,
  /\bmonth(ly)?\s+(summary|summaries|trend|breakdown|overview|comparison)\b/i,
  /\bsummar(y|ize|ise)\b/i, /\boverview\b/i, /\bcompare\b.*\bmonths?\b/i,
  /\b[369]\s+months?\b/i, /\b12\s+months?\b/i, /\bover\s+time\b/i,
  /\bhow (was|were|did|have|has)\b.*\b(month|months|quarter|year|spending|finances|saving)/i,
];
export function isPeriodQuestion(q) {
  return PERIOD_PATTERNS.some((p) => p.test(q));
}

const pmoney = (n) => (getCurrencySymbol() || "₹") + Math.abs(n).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

// When a period question resolves to ONE specific window (e.g. "last 6 months",
// "summarize the 3 months ending June 2024"), answer it deterministically with
// exact figures. Vague trend/compare questions (a series) return null → LLM.
export function periodExactAnswer(question) {
  if (!hasPeriodSummaries() || !isPeriodQuestion(question)) return null;
  const picks = pickPeriods(question, getPeriodSummaries());
  if (picks.length !== 1) return null;
  const p = picks[0];
  const m = p.metrics;
  const rows = [
    ["Spending", pmoney(m.expense)],
    ["Income", pmoney(m.income)],
    ["Net", `${m.net < 0 ? "-" : "+"}${pmoney(m.net)}`],
    ["Transactions", Number(m.count).toLocaleString("en-IN")],
    ...(m.topCategories || []).slice(0, 3).map((c, i) => [`Top category ${i + 1}`, `${c.name} — ${pmoney(c.amt)}`]),
  ];
  const head = `| Metric | Value |\n| --- | --- |\n` + rows.map((r) => `| ${r[0]} | ${r[1]} |`).join("\n");
  return `**Period summary — ${p.periodLabel} (${p.window}-month)**\n\n${head}`;
}

const MONTH_NUM = {
  january: "01", february: "02", march: "03", april: "04", may: "05", june: "06",
  july: "07", august: "08", september: "09", october: "10", november: "11", december: "12",
};

// Structured period selection: resolve window length + anchor/recency from the
// question, since "last 6 months" / "this year" can't be matched by embeddings.
function pickPeriods(question, all) {
  const q = question.toLowerCase();
  const anchors = [...new Set(all.map((s) => s.anchor))].sort();
  if (!anchors.length) return [];
  const latest = anchors[anchors.length - 1];

  // window length hint
  let win = null;
  if (/\b(12[\s-]*months?|year|annual|twelve|yearly)\b/.test(q)) win = 12;
  else if (/\b(9[\s-]*months?|nine)\b/.test(q)) win = 9;
  else if (/\b(6[\s-]*months?|half[- ]?year|six)\b/.test(q)) win = 6;
  else if (/\b(quarter(ly)?|3[\s-]*months?|q[1-4]|three)\b/.test(q)) win = 3;
  else if (/\bmonth(ly)?\b/.test(q) && !/\bmonths\b/.test(q)) win = 1;

  // explicit anchor: "Month YYYY", else a bare year (latest month in it)
  let anchor = null;
  const my = q.match(new RegExp(`(${Object.keys(MONTH_NUM).join("|")})\\s+(\\d{4})`));
  if (my) {
    const cand = `${my[2]}-${MONTH_NUM[my[1]]}`;
    anchor = anchors.includes(cand) ? cand : null;
  } else {
    const yr = q.match(/\b(20\d{2})\b/);
    if (yr) { const inYr = anchors.filter((a) => a.startsWith(yr[1])); if (inYr.length) anchor = inYr[inYr.length - 1]; }
  }
  if (!anchor) anchor = latest; // "last/past/recent" or unspecified → most recent

  // trend / compare → a month-by-month series (last 6 single-month summaries)
  if (/\b(trend|compare|over time|month by month|each month|progression|changed|fluctuat)\b/.test(q)) {
    const monthly = all.filter((s) => s.window === 1).sort((a, b) => (a.anchor < b.anchor ? -1 : 1));
    if (monthly.length) return monthly.slice(-6);
  }

  // window-specific summary at the chosen anchor (nearest available if missing)
  if (win) {
    let picks = all.filter((s) => s.window === win && s.anchor === anchor);
    if (!picks.length) {
      const wins = all.filter((s) => s.window === win).sort((a, b) => (a.anchor < b.anchor ? -1 : 1));
      if (wins.length) picks = [wins[wins.length - 1]];
    }
    return picks;
  }

  // no explicit window → the anchor's rollups (1/3/6/12 months ending there)
  return all.filter((s) => s.anchor === anchor && [1, 3, 6, 12].includes(s.window));
}

function buildPeriodPrompt(meta, summaries) {
  const sym = getCurrencySymbol() || "₹";
  const money = (n) => sym + Math.abs(n).toLocaleString("en-IN", { maximumFractionDigits: 0 });
  const isSeries = summaries.length > 1 && summaries.every((s) => s.window === 1);

  const parts = [
    "You are a bank-statement assistant. Answer ONLY from the exact figures below.",
    "Rules: quote the numbers exactly; plain text only — no emojis and no currency symbol other than the one shown; do NOT invent dates, causes, or details that are not shown; do NOT show calculations or internal labels like 'anchor'; reply in 1-3 short sentences (or a short list for a trend).",
    "",
  ];

  if (isSeries) {
    // Compact month-by-month table — easier for a small model than verbose blocks.
    parts.push("=== MONTH-BY-MONTH (exact) ===");
    for (const s of summaries) {
      const m = s.metrics;
      const topCat = m.topCategories?.[0]?.name || "";
      parts.push(`${s.periodLabel}: spent ${money(m.expense)}, income ${money(m.income)}, net ${m.net < 0 ? "-" : "+"}${money(m.net)}${topCat ? `, top: ${topCat}` : ""}`);
    }
    parts.push("=== END ===");
  } else {
    parts.push("=== PERIOD FIGURES (exact) ===");
    for (const s of summaries) {
      parts.push("");
      parts.push(formatMetrics(s, sym));
    }
    parts.push("=== END ===");
  }
  return parts.join("\n");
}

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

  // Period / trend questions → retrieve the few most relevant rolling summaries
  // (in-process cosine over SQLite-stored embeddings; no Chroma server needed).
  if (hasPeriodSummaries() && isPeriodQuestion(question)) {
    try {
      const all = getPeriodSummaries();
      let picks = pickPeriods(question, all);
      if (!picks.length) {
        const qv = await embedOne(question);
        picks = topK(qv, all, 5).filter((h) => h.score > 0).map((h) => h.item);
      }
      if (picks.length) return buildPeriodPrompt(meta, picks);
    } catch { /* fall through to raw retrieval */ }
  }

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

  parts.push("You are a friendly bank-statement assistant. Reply in 1-3 natural, conversational sentences and vary your wording. Always use the exact figures from the data — never invent, recompute, or change a number.");

  if (mode === "facts_only") {
    parts.push("");
    parts.push("=== FACTS TABLE (source of the exact figures) ===");
    parts.push(facts);
    parts.push("=== END FACTS ===");
    parts.push("");
    parts.push("RULES:");
    parts.push("- Take the exact numbers from the facts above — never change a figure.");
    parts.push("- Phrase the answer naturally in your own words; don't just paste the table line.");
    parts.push("- \"Biggest single expense\" means the \"Largest debit\" line, not a category total.");
    parts.push("- Keep it to 1-3 sentences.");
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
    parts.push("RULES: Use the FACTS TABLE for totals (never recompute). Reply in 1-3 natural sentences, keeping every figure exact.");
  }

  return parts.join("\n");
}
