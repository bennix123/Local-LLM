
// Deterministic aggregation for tabular bank statements.
//
// Strategy: Small LLMs are unreliable at arithmetic, so we pre-compute EVERY
// possible answer and feed them as a structured "FACTS TABLE" that the LLM
// simply reads from. The model's only job is to locate the right row in the
// table and repeat it verbatim — zero reasoning required.

export function toNumber(raw) {
  if (raw == null) return null;
  let s = String(raw).trim();
  if (s === "") return null;
  if (/\d[-/:]\d/.test(s)) return null;
  let negative = false;
  if (/^\(.*\)$/.test(s)) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (/^-/.test(s)) negative = true;
  s = s.replace(/[^0-9.]/g, "");
  if (s === "" || s === ".") return null;
  const n = Number(s);
  if (Number.isNaN(n)) return null;
  return negative ? -n : n;
}

function fmt(n) {
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}

function findCol(columns, patterns) {
  for (const p of patterns) {
    const col = columns.find((c) => new RegExp(p, "i").test(c));
    if (col) return col;
  }
  return null;
}

function classifyNumericColumns(columns, records) {
  const numeric = [];
  for (const col of columns) {
    let numericCount = 0, nonEmpty = 0;
    for (const r of records) {
      const v = r[col];
      if (v == null || String(v).trim() === "") continue;
      nonEmpty++;
      if (toNumber(v) !== null) numericCount++;
    }
    if (nonEmpty > 0 && numericCount / nonEmpty >= 0.6) numeric.push(col);
  }
  return numeric;
}

export function computeStatsSummary(columns, records) {
  if (!columns?.length || !records?.length) return null;

  const numericCols = classifyNumericColumns(columns, records);
  if (numericCols.length === 0) return null;

  const descCol = findCol(columns, ["description", "payee", "merchant", "name", "narrative", "details", "memo"]) ||
    columns.find((c) => !numericCols.includes(c)) ||
    columns[0];

  const amountCol = findCol(columns, ["amount", "sum", "value", "total", "debit", "credit"]) ||
    numericCols[0];

  const dateCol = findCol(columns, ["date", "time", "posted", "trans_date", "transaction_date"]);

  const categoryCol = findCol(columns, ["category", "type", "tag", "group", "class"]);

  const typeCol = findCol(columns, ["type", "transaction_type", "txn_type", "dr_cr", "debit_credit"]);

  const lines = [];

  // ── 1. OVERVIEW ─────────────────────────────────────────────────
  let totalIncome = 0, totalExpense = 0;
  let countIncome = 0, countExpense = 0;
  let maxCredit = 0, maxCreditRow = -1, maxCreditAmt = 0;
  let maxDebit = 0, maxDebitRow = -1, maxDebitAmt = 0;

  for (let i = 0; i < records.length; i++) {
    const n = toNumber(records[i][amountCol]);
    if (n === null) continue;
    if (n > 0) {
      totalIncome += n;
      countIncome++;
      if (n > maxCredit) { maxCredit = n; maxCreditRow = i; maxCreditAmt = n; }
    } else {
      totalExpense += n;
      countExpense++;
      const absN = Math.abs(n);
      if (absN > maxDebit) { maxDebit = absN; maxDebitRow = i; maxDebitAmt = n; }
    }
  }

  const netTotal = totalIncome + totalExpense;
  const label = (i) => descCol && records[i] ? String(records[i][descCol]).trim().split(" - ")[0] : `Row ${i + 1}`;

  lines.push("=== FINANCIAL OVERVIEW ===");
  lines.push(`Total transactions: ${records.length}`);
  lines.push(`Total income: $${fmt(totalIncome)} (${countIncome} credits)`);
  lines.push(`Total expenses: -$${fmt(Math.abs(totalExpense))} (${countExpense} debits)`);
  lines.push(`Net total: $${fmt(netTotal)}`);
  lines.push(`Average transaction: $${fmt(netTotal / records.length)}`);
  lines.push(`Largest credit: $${fmt(maxCreditAmt)} from ${label(maxCreditRow)}`);
  lines.push(`Largest debit: -$${fmt(maxDebit)} to ${label(maxDebitRow)}`);
  lines.push("");

  // ── 2. CATEGORY BREAKDOWN ────────────────────────────────────────
  if (categoryCol) {
    const byCat = new Map();
    const byCatIncome = new Map();
    const byCatExpense = new Map();
    for (const r of records) {
      const cat = String(r[categoryCol] || "Uncategorized").trim();
      const n = toNumber(r[amountCol]);
      if (n === null) continue;
      if (!byCat.has(cat)) { byCat.set(cat, 0); byCatIncome.set(cat, 0); byCatExpense.set(cat, 0); }
      byCat.set(cat, byCat.get(cat) + 1);
      if (n > 0) byCatIncome.set(cat, byCatIncome.get(cat) + n);
      else byCatExpense.set(cat, byCatExpense.get(cat) + Math.abs(n));
    }

    const ranked = [...byCat.entries()].sort((a, b) => {
      const aTotal = Math.abs(byCatIncome.get(a[0]) || 0) + Math.abs(byCatExpense.get(a[0]) || 0);
      const bTotal = Math.abs(byCatIncome.get(b[0]) || 0) + Math.abs(byCatExpense.get(b[0]) || 0);
      return bTotal - aTotal;
    });

    lines.push("=== CATEGORY BREAKDOWN (sorted by total volume) ===");
    for (const [cat, count] of ranked) {
      const income = byCatIncome.get(cat) || 0;
      const expense = byCatExpense.get(cat) || 0;
      const parts = [`${count} txn`];
      if (income > 0) parts.push(`earned $${fmt(income)}`);
      if (expense > 0) parts.push(`spent $${fmt(expense)}`);
      lines.push(`${cat}: ${parts.join(", ")}`);
    }
    lines.push("");
  }

  // ── 3. TOP EXPENSE CATEGORIES ────────────────────────────────────
  if (categoryCol) {
    const expenseCats = [];
    for (const r of records) {
      const n = toNumber(r[amountCol]);
      if (n !== null && n < 0) {
        const cat = String(r[categoryCol] || "Uncategorized").trim();
        const existing = expenseCats.find((e) => e.cat === cat);
        if (existing) existing.total += Math.abs(n);
        else expenseCats.push({ cat, total: Math.abs(n) });
      }
    }
    expenseCats.sort((a, b) => b.total - a.total);
    if (expenseCats.length > 0) {
      lines.push("=== TOP SPENDING CATEGORIES ===");
      expenseCats.slice(0, 10).forEach((e, i) => {
        lines.push(`${i + 1}. ${e.cat}: $${fmt(e.total)}`);
      });
      lines.push("");
    }
  }

  // ── 4. MONTHLY BREAKDOWN ─────────────────────────────────────────
  if (dateCol) {
    const byMonth = new Map();
    for (const r of records) {
      const dateStr = String(r[dateCol] || "").trim();
      const month = dateStr.length >= 7 ? dateStr.substring(0, 7) : dateStr;
      if (!month) continue;
      const n = toNumber(r[amountCol]);
      if (n === null) continue;
      if (!byMonth.has(month)) byMonth.set(month, { income: 0, expense: 0, count: 0 });
      const m = byMonth.get(month);
      m.count++;
      if (n > 0) m.income += n;
      else m.expense += Math.abs(n);
    }

    if (byMonth.size > 0) {
      lines.push("=== MONTHLY BREAKDOWN ===");
      for (const [month, data] of [...byMonth.entries()].sort()) {
        const net = data.income - data.expense;
        const sign = net >= 0 ? "+" : "";
        lines.push(`${month}: ${data.count} txns, income $${fmt(data.income)}, expenses $${fmt(data.expense)}, net ${sign}$${fmt(net)}`);
      }
      lines.push("");
    }
  }

  // ── 5. TOP PAYEES ────────────────────────────────────────────────
  if (descCol) {
    const byPayee = new Map();
    for (const r of records) {
      const payee = String(r[descCol] || "").trim().split(" - ")[0];
      const n = toNumber(r[amountCol]);
      if (n === null) continue;
      if (!byPayee.has(payee)) byPayee.set(payee, { gross: 0, count: 0 });
      const p = byPayee.get(payee);
      p.gross += Math.abs(n);
      p.count++;
    }
    const sorted = [...byPayee.entries()].sort((a, b) => b[1].gross - a[1].gross).slice(0, 20);
    if (sorted.length > 0) {
      lines.push("=== TOP 20 PAYEES BY TOTAL VOLUME ===");
      sorted.forEach(([name, data], i) => {
        lines.push(`${i + 1}. ${name}: ${data.count} txns, total $${fmt(data.gross)}`);
      });
      lines.push("");
    }
  }

  // ── 6. LARGEST INDIVIDUAL TRANSACTIONS ───────────────────────────
  const byAbs = records
    .map((r, i) => ({ i, amt: toNumber(r[amountCol]), desc: String(r[descCol] || r[amountCol] || "").trim(), date: dateCol ? String(r[dateCol] || "").trim() : "" }))
    .filter((t) => t.amt !== null)
    .sort((a, b) => Math.abs(b.amt) - Math.abs(a.amt))
    .slice(0, 10);

  if (byAbs.length > 0) {
    lines.push("=== TOP 10 LARGEST TRANSACTIONS ===");
    byAbs.forEach((t, i) => {
      const sign = t.amt >= 0 ? "+" : "-";
      lines.push(`${i + 1}. ${t.date} | ${t.desc.split(" - ")[0]} | ${sign}$${fmt(Math.abs(t.amt))}`);
    });
    lines.push("");
  }

  // ── 7. RECENT TRANSACTIONS ───────────────────────────────────────
  const recent = records.slice(-10).map((r) => {
    const amt = toNumber(r[amountCol]);
    const desc = descCol ? String(r[descCol] || "").trim().split(" - ")[0] : "";
    const date = dateCol ? String(r[dateCol] || "").trim() : "";
    const sign = amt !== null && amt >= 0 ? "+" : "-";
    return `${date} | ${desc} | ${sign}$${fmt(Math.abs(amt || 0))}`;
  });
  lines.push("=== LAST 10 TRANSACTIONS ===");
  recent.forEach((r) => lines.push(r));
  lines.push("");

  return lines.join("\n");
}
