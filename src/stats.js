// Deterministic aggregation for tabular bank statements.
//
// Small local LLMs are unreliable at arithmetic over many rows (they skip rows,
// miscalculate, or loop). So we compute the real figures here, in code, and feed
// them to the model as authoritative "facts". The model then just *reports*
// numbers instead of trying to add them up itself.

/** Parse a messy money/number string -> Number, or null if not numeric. */
export function toNumber(raw) {
  if (raw == null) return null;
  let s = String(raw).trim();
  if (s === "") return null;
  // Looks like a date/time (e.g. 2026-05-01, 05/12/2026, 12:30) — not a number.
  if (/\d[-/:]\d/.test(s)) return null;
  let negative = false;
  // Accountancy style: (123.45) means -123.45
  if (/^\(.*\)$/.test(s)) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (/^-/.test(s)) negative = true;
  // Strip currency symbols, thousands separators, spaces, letters.
  s = s.replace(/[^0-9.]/g, "");
  if (s === "" || s === ".") return null;
  // Reject things that were clearly dates (e.g. 2026.05.01 collapsed oddly).
  const n = Number(s);
  if (Number.isNaN(n)) return null;
  return negative ? -n : n;
}

function fmt(n) {
  // Keep 2 decimals for money-like values, trim trailing for integers.
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}

/**
 * @param {string[]} columns
 * @param {Array<Object>} records  raw parsed rows (objects keyed by column)
 * @returns {string|null} a human/LLM readable summary block, or null if there's
 *   nothing numeric to summarize (e.g. a scanned PDF with no columns).
 */
export function computeStatsSummary(columns, records) {
  if (!columns?.length || !records?.length) return null;

  // Classify columns as numeric vs text.
  const numericCols = [];
  const textCols = [];
  for (const col of columns) {
    let numeric = 0;
    let nonEmpty = 0;
    for (const r of records) {
      const v = r[col];
      if (v == null || String(v).trim() === "") continue;
      nonEmpty++;
      if (toNumber(v) !== null) numeric++;
    }
    if (nonEmpty > 0 && numeric / nonEmpty >= 0.6) numericCols.push(col);
    else if (nonEmpty > 0) textCols.push(col);
  }

  if (numericCols.length === 0) return null;

  // Pick a "description" column for labeling extremes: the text column with the
  // longest average content (usually the merchant/description field).
  let descCol = null;
  let bestLen = -1;
  for (const col of textCols) {
    let total = 0;
    let count = 0;
    for (const r of records) {
      const v = r[col];
      if (v != null && String(v).trim() !== "") {
        total += String(v).length;
        count++;
      }
    }
    const avg = count ? total / count : 0;
    if (avg > bestLen) {
      bestLen = avg;
      descCol = col;
    }
  }

  const lines = [];
  lines.push(`Total rows: ${records.length}`);

  for (const col of numericCols) {
    let sum = 0;
    let count = 0;
    let min = Infinity;
    let max = -Infinity;
    let minRow = -1;
    let maxRow = -1;
    records.forEach((r, i) => {
      const n = toNumber(r[col]);
      if (n === null) return;
      count++;
      sum += n;
      if (n < min) {
        min = n;
        minRow = i;
      }
      if (n > max) {
        max = n;
        maxRow = i;
      }
    });
    if (count === 0) continue;

    const label = (i) =>
      descCol && records[i] && records[i][descCol]
        ? ` (Row ${i + 1}: ${String(records[i][descCol]).trim()})`
        : ` (Row ${i + 1})`;

    lines.push(
      `Column "${col}": count=${count}, sum=${fmt(sum)}, ` +
        `min=${fmt(min)}${label(minRow)}, max=${fmt(max)}${label(maxRow)}, ` +
        `average=${fmt(sum / count)}`
    );
  }

  // Per-payee/description breakdown so the model can answer filtered sums like
  // "how much did I spend at <merchant>" without doing multi-row math itself.
  const spendCol =
    numericCols.find((c) =>
      /debit|withdraw|amount|spent|charge|paid|expense/i.test(c)
    ) ||
    numericCols.find(
      (c) => !/balance|credit|deposit|income|date|time/i.test(c)
    ) ||
    null;

  if (descCol && spendCol) {
    const groups = new Map();
    for (const r of records) {
      const n = toNumber(r[spendCol]);
      if (n === null) continue;
      const key = String(r[descCol] ?? "").trim() || "(blank)";
      groups.set(key, (groups.get(key) || 0) + n);
    }
    const top = [...groups.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 20);
    if (top.length) {
      lines.push("");
      lines.push(
        `Total "${spendCol}" grouped by "${descCol}" (each payee's combined total):`
      );
      for (const [key, total] of top) lines.push(`- ${key}: ${fmt(total)}`);
    }
  }

  return lines.join("\n");
}
