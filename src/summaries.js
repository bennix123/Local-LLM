// Orchestrates the materialized-summary layer:
//   month summaries (per-month, in SQLite)  →  rolling period summaries (composed)
// Rebuilds are cheap because period rollups compose from the ~N month rows, not
// from raw transactions. Re-embedding the ~120 summaries takes a few seconds.

import { getMonthSummaries, replacePeriodSummaries, recomputeMonth, updateMonthData } from "./db.js";
import { buildPeriodsFromMonths, formatMetrics } from "./periods.js";
import { embed } from "./embed.js";

// Recompose all rolling period summaries from the current month summaries.
export async function rebuildPeriods() {
  const months = getMonthSummaries();
  const periods = buildPeriodsFromMonths(months);
  if (periods.length) {
    const vecs = await embed(periods.map((p) => formatMetrics(p)));
    periods.forEach((p, i) => { p.narrative = ""; p.embedding = vecs[i]; });
  }
  replacePeriodSummaries(periods);
  return periods.length;
}

// Re-put one month's data → recompute that month → recompose period rollups.
export async function updateMonthAndRebuild(ym, records) {
  updateMonthData(ym, records); // replaces tx for ym + recomputes month summary
  const n = await rebuildPeriods();
  return { ym, periods: n };
}
