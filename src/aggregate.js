// Precise deterministic aggregation over structured transaction records.
// Used by the chat layer to answer entity/merchant/keyword questions exactly,
// instead of relying on a small LLM to sum dozens of transactions.

import { fmtAmountLabel } from "./currency.js";

export const recAmount = (r) => {
  const n = parseFloat(String(r.Amount).replace(/[^0-9.\-]/g, ""));
  return Number.isNaN(n) ? 0 : n;
};
export const recMonth = (r) => String(r.Date || "").slice(0, 7);
const norm = (s) => String(s || "").toLowerCase();
const cfmt = (n) => fmtAmountLabel(n);

const MONTH_NAMES = {
  "01": "January", "02": "February", "03": "March", "04": "April",
  "05": "May", "06": "June", "07": "July", "08": "August",
  "09": "September", "10": "October", "11": "November", "12": "December",
};
export function monthLabel(key) {
  const [y, m] = key.split("-");
  return MONTH_NAMES[m] ? `${MONTH_NAMES[m]} ${y}` : key;
}

// Sum all records whose Description matches ANY keyword (case-insensitive substring).
export function aggregateByKeywords(records, keywords) {
  const ks = keywords.map((k) => norm(k).trim()).filter((k) => k.length > 1);
  let debit = 0, credit = 0, count = 0;
  const byMonth = new Map();
  const matched = [];
  for (const r of records) {
    const hay = norm(r.Description);
    if (ks.some((k) => hay.includes(k))) {
      const n = recAmount(r);
      count++;
      if (n < 0) debit += Math.abs(n); else credit += n;
      const m = recMonth(r);
      const mm = byMonth.get(m) || { debit: 0, credit: 0, count: 0 };
      if (n < 0) mm.debit += Math.abs(n); else mm.credit += n;
      mm.count++;
      byMonth.set(m, mm);
      matched.push(r);
    }
  }
  return { debit, credit, net: credit - debit, count, byMonth, matched, cfmt };
}

export function topTransactions(records, n = 5, sign = "any") {
  let list = records.slice();
  if (sign === "debit") list = list.filter((r) => recAmount(r) < 0);
  if (sign === "credit") list = list.filter((r) => recAmount(r) > 0);
  return list
    .sort((a, b) => Math.abs(recAmount(b)) - Math.abs(recAmount(a)))
    .slice(0, n);
}

export function smallestDebit(records) {
  const debits = records.filter((r) => recAmount(r) < 0);
  if (!debits.length) return null;
  return debits.sort((a, b) => Math.abs(recAmount(a)) - Math.abs(recAmount(b)))[0];
}

export function payeeOf(r) {
  return String(r.Description || "").split(" - ")[0].trim();
}
