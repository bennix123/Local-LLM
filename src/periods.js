// Hierarchical period summaries for scaling a small LLM to large statements.
//
// Instead of feeding lakhs of raw rows to the 2.6B model, we pre-aggregate
// transactions into per-(month-year) buckets, build ROLLING windows
// (trailing 1/3/6/9/12 months anchored at each month), compute deterministic
// metrics for each, and (elsewhere) attach an LLM-written narrative. At query
// time we retrieve the few relevant summaries instead of the raw data.
//
// This module is pure data-shaping — no LLM, no I/O.

import { recAmount, recMonth, monthLabel } from "./aggregate.js";

export const WINDOWS = [1, 3, 6, 9, 12];

// Lightweight keyword categorizer (used when a record has no Category field,
// e.g. parsed bank statements). Synthetic data may carry its own Category.
const CAT_RULES = [
  [/salary|payroll/i, "Salary"],
  [/\brent\b|properties|landlord|greenfield|shoreline/i, "Rent"],
  [/swiggy|zomato|restaurant|\bcafe\b|food|dominos|mcdonald|kfc|pizza|bistro|dhaba/i, "Food & Dining"],
  [/blinkit|grofers|bigbasket|dmart|d-mart|grocery|kirana|reliance fresh|zepto|instamart/i, "Groceries"],
  [/metro|uber|\bola\b|rapido|irctc|petrol|fuel|\bhpcl?\b|\bioc\b|\bbpcl\b|parking|toll|fastag|railway|redbus/i, "Transport"],
  [/amazon|flipkart|myntra|ajio|meesho|nykaa|\bshop|mall|store|retail/i, "Shopping"],
  [/excitel|\bjio\b|airtel|\bvi\b|vodafone|electricity|broadband|recharge|\bgas\b|water|\bdth\b|utilit/i, "Utilities"],
  [/pvr|inox|netflix|spotify|bookmyshow|hotstar|prime video|youtube|game|cinema/i, "Entertainment"],
  [/pharmacy|apollo|hospital|medical|chemist|clinic|diagnost|\bmed\b|health/i, "Healthcare"],
  [/zerodha|groww|\bsip\b|mutual|invest|nps\b|insurance|\blic\b|policy|premium/i, "Investment & Insurance"],
  [/\bcred\b|credit card|card payment|cc payment/i, "Credit Card"],
  [/interest paid|int\.pd|interest/i, "Interest"],
];

export function categorize(record) {
  if (record.Category && String(record.Category).trim()) return String(record.Category).trim();
  const desc = String(record.Description || "");
  for (const [re, cat] of CAT_RULES) if (re.test(desc)) return cat;
  return "Other / Transfers";
}

export function payeeOf(record) {
  return String(record.Description || "").split(" - ")[0].trim() || "Unknown";
}

// Sorted unique "YYYY-MM" months present in the data.
export function listMonths(records) {
  return [...new Set(records.map(recMonth).filter(Boolean))].sort();
}

// Aggregate a set of records into a metrics object.
function aggregate(records) {
  let income = 0, expense = 0, count = 0;
  const byCat = new Map(); // category -> spend (out)
  const byPayee = new Map(); // payee -> gross volume
  let max = null;
  for (const r of records) {
    const n = recAmount(r);
    count++;
    if (n >= 0) income += n;
    else {
      expense += Math.abs(n);
      const c = categorize(r);
      byCat.set(c, (byCat.get(c) || 0) + Math.abs(n));
    }
    const p = payeeOf(r);
    byPayee.set(p, (byPayee.get(p) || 0) + Math.abs(n));
    if (!max || Math.abs(n) > Math.abs(recAmount(max))) max = r;
  }
  const top = (m, k) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, k).map(([name, amt]) => ({ name, amt: Math.round(amt * 100) / 100 }));
  return {
    income: Math.round(income * 100) / 100,
    expense: Math.round(expense * 100) / 100,
    net: Math.round((income - expense) * 100) / 100,
    count,
    topCategories: top(byCat, 5),
    topPayees: top(byPayee, 5),
    largest: max ? { payee: payeeOf(max), amount: recAmount(max), date: max.Date } : null,
  };
}

// Build rolling period records: for every month (anchor), produce a record for
// each window length that has enough preceding history.
export function buildPeriodRecords(records, windows = WINDOWS) {
  const months = listMonths(records);
  const byMonth = new Map(months.map((m) => [m, []]));
  for (const r of records) {
    const m = recMonth(r);
    if (byMonth.has(m)) byMonth.get(m).push(r);
  }
  const out = [];
  for (let i = 0; i < months.length; i++) {
    for (const w of windows) {
      if (i - w + 1 < 0) continue; // not enough history for this window yet
      const span = months.slice(i - w + 1, i + 1);
      const recs = span.flatMap((m) => byMonth.get(m));
      if (!recs.length) continue;
      const label = w === 1 ? monthLabel(span[0]) : `${monthLabel(span[0])} – ${monthLabel(span[span.length - 1])}`;
      out.push({
        id: `${months[i]}_${w}mo`,
        anchor: months[i],
        window: w,
        periodLabel: label,
        start: span[0],
        end: span[span.length - 1],
        months: span,
        metrics: aggregate(recs),
      });
    }
  }
  return out;
}

// Compose rolling period records from per-month summaries (exact for
// income/spending/net/count/categories; payees approximated from monthly top-20).
// This is what makes updates cheap: change one month → recompose, no raw scan.
export function buildPeriodsFromMonths(monthSummaries, windows = WINDOWS) {
  const months = monthSummaries.map((m) => m.ym).sort();
  const byYm = new Map(monthSummaries.map((m) => [m.ym, m]));
  const top = (map) => [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([name, amt]) => ({ name, amt: Math.round(amt * 100) / 100 }));
  const out = [];
  for (let i = 0; i < months.length; i++) {
    for (const w of windows) {
      if (i - w + 1 < 0) continue;
      const span = months.slice(i - w + 1, i + 1);
      let income = 0, spending = 0, count = 0, largest = null;
      const catMap = new Map(), payeeMap = new Map();
      for (const ym of span) {
        const m = byYm.get(ym);
        income += m.income; spending += m.spending; count += m.count;
        for (const [c, v] of Object.entries(m.categories)) catMap.set(c, (catMap.get(c) || 0) + v);
        for (const p of m.payees) payeeMap.set(p.name, (payeeMap.get(p.name) || 0) + p.vol);
        if (m.largest && (!largest || Math.abs(m.largest.amount) > Math.abs(largest.amount))) largest = m.largest;
      }
      const label = w === 1 ? monthLabel(span[0]) : `${monthLabel(span[0])} – ${monthLabel(span[span.length - 1])}`;
      out.push({
        id: `${months[i]}_${w}mo`, anchor: months[i], window: w, periodLabel: label,
        start: span[0], end: span[span.length - 1], months: span,
        metrics: {
          income: Math.round(income * 100) / 100, expense: Math.round(spending * 100) / 100,
          net: Math.round((income - spending) * 100) / 100, count,
          topCategories: top(catMap), topPayees: top(payeeMap),
          largest: largest ? { payee: largest.payee, amount: largest.amount, date: largest.date } : null,
        },
      });
    }
  }
  return out;
}

// Compact, embeddable text of the metrics (also handy in prompts).
export function formatMetrics(rec, sym = "₹") {
  const m = rec.metrics;
  const money = (n) => `${sym}${Math.abs(n).toLocaleString("en-IN", { maximumFractionDigits: 2 })}`;
  const cats = m.topCategories.map((c) => `${c.name} ${money(c.amt)}`).join(", ");
  const payees = m.topPayees.slice(0, 3).map((p) => `${p.name} ${money(p.amt)}`).join(", ");
  return [
    `Period: ${rec.periodLabel} (${rec.window}-month${rec.window > 1 ? " rolling" : ""})`,
    `Income: ${money(m.income)} | Spending: ${money(m.expense)} | Net: ${m.net < 0 ? "-" : "+"}${money(m.net)} | Transactions: ${m.count}`,
    `Top categories: ${cats || "n/a"}`,
    `Top payees: ${payees || "n/a"}`,
    m.largest ? `Largest transaction: ${money(m.largest.amount)} ${m.largest.amount < 0 ? "to" : "from"} ${m.largest.payee} (${m.largest.date})` : "",
  ].filter(Boolean).join("\n");
}

// Prompt for the LLM to turn metrics into a short natural-language narrative.
export function narrativePrompt(rec, sym = "₹") {
  const system =
    "You write a concise financial summary for one period of a bank statement. " +
    "Use ONLY the figures provided; never invent numbers. 2-4 sentences, natural and specific. " +
    "Mention total spending, income/net, and the standout categories or payees.";
  const user = `Write the summary for this period.\n\n${formatMetrics(rec, sym)}`;
  return { system, user };
}
