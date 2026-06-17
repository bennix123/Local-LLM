
// Analytics bridge — deterministic SQL queries for intent router.
// Every calculation runs in SQLite. The LLM never touches numbers.

import {
  txOverview, txKeyword, txKeywordByMonth, txMonthSpend,
  txMonthlySpend, txYearMonthly, txCategorySpend,
  txCategoryMonth, txLargestDebit, txLargestCredit,
  txSmallestDebit, txTopDebits, txCategoryBreakdown,
  txRecent, txCurrentBalance, txTopPayees,
  txSubscriptions, txReceivedFromPeople, txPage,
} from "../src/db.js";

const S = () => "₹";

export function handleOverview() {
  const o = txOverview();
  const net = (o.credit || 0) - (o.debit || 0);
  return {
    answer: `${o.count} transactions. Spent: ${S()}${(o.debit||0).toFixed(2)}, Received: ${S()}${(o.credit||0).toFixed(2)}, Net: ${S()}${net.toFixed(2)}.`,
    data: o,
  };
}

export function handleMonthlySpend() {
  const rows = txMonthlySpend();
  const list = rows.map(r => `${r.ym}: ${S()}${(r.debit||0).toFixed(2)}`);
  return { answer: `Monthly spending:\n${list.join("\n")}`, data: rows };
}

export function handleLeastSpendMonth() {
  const rows = txMonthlySpend();
  if (!rows.length) return { answer: "No data.", data: null };
  const least = rows[rows.length - 1];
  return { answer: `Least spending: ${least.ym} — ${S()}${(least.debit||0).toFixed(2)}.`, data: least };
}

export function handleMostSpendMonth() {
  const rows = txMonthlySpend();
  if (!rows.length) return { answer: "No data.", data: null };
  const most = rows[0];
  return { answer: `Most spending: ${most.ym} — ${S()}${(most.debit||0).toFixed(2)}.`, data: most };
}

export function handleTopMerchants(n = 10) {
  const rows = txTopPayees(n);
  const list = rows.map((r, i) => `${i + 1}. ${r.payee}: ₹${Number(r.spend||0).toFixed(2)} (${r.count} txns)`);
  return { answer: `Top ${n} merchants:\n${list.join("\n")}`, data: rows };
}

export function handleCategoryBreakdown() {
  const rows = txCategoryBreakdown(10);
  const list = rows.map(r => `${r.category}: ${S()}${r.total.toFixed(2)} (${r.count} txns)`);
  return { answer: `Category breakdown:\n${list.join("\n")}`, data: rows };
}

export function handleLargestExpense() {
  const row = txLargestDebit();
  if (!row) return { answer: "No expenses.", data: null };
  return { answer: `Largest expense: ${S()}${Math.abs(row.amount).toFixed(2)} to ${row.payee || row.description} on ${row.date}.`, data: row };
}

export function handleSmallestExpense() {
  const row = txSmallestDebit();
  if (!row) return { answer: "No debits found.", data: null };
  return { answer: `Smallest debit: ₹${Number(Math.abs(row.amount)).toFixed(2)} to ${row.payee || row.description} on ${row.date}.`, data: row };
}

export function handleMonthSpend(ym) {
  const row = txMonthSpend(ym);
  if (!row || row.count === 0) return { answer: `No spending data for ${ym}.`, data: null };
  return { answer: `Spent ₹${Number(row.debit||0).toFixed(2)} in ${ym} across ${row.count} transactions.`, data: row };
}

export function handleLargestIncome() {
  const row = txLargestCredit();
  if (!row) return { answer: "No income.", data: null };
  return { answer: `Largest income: ₹${Number(row.amount).toFixed(2)} from ${row.payee || row.description} on ${row.date}.`, data: row };
}

export function handleTopExpenses(n = 5) {
  const rows = txTopDebits(n);
  const list = rows.map((r, i) => `${i + 1}. ${r.date}: ${S()}${Math.abs(r.amount).toFixed(2)} — ${r.description}`);
  return { answer: `Top ${n} expenses:\n${list.join("\n")}`, data: rows };
}

export function handleCurrentBalance() {
  const row = txCurrentBalance();
  if (!row || row.balance == null) return { answer: "No balance data.", data: null };
  return { answer: `Current balance: ₹${Number(row.balance).toFixed(2)}.`, data: row };
}

import { hybridSearch } from "../src/retrieval.js";

export async function handleEntityLookup(keyword, question = "") {
  const results = await hybridSearch(question || keyword, keyword);
  const s = results.sql;

  if (!s || s.count === 0) {
    return { answer: "\"" + keyword + "\" not found in this statement.", data: null };
  }

  const q = (question || keyword).toLowerCase();
  const askingSpend = /\b(spend|spent|pay|paid|debit|expense|cost)\b/i.test(q);
  const askingEarn = /\b(earn|earned|receive|received|credit|income|got|made)\b/i.test(q);

  let answer = s.count + " transactions for \"" + keyword + "\"";
  if (askingEarn && !askingSpend) {
    answer += " — received: ₹" + (s.credit || 0).toFixed(2) + ".";
  } else if (askingSpend && !askingEarn) {
    answer += " — spent: ₹" + (s.debit || 0).toFixed(2) + ".";
  } else {
    if (s.debit > 0) answer += " — spent ₹" + s.debit.toFixed(2);
    if (s.debit > 0 && s.credit > 0) answer += ",";
    if (s.credit > 0) answer += " received ₹" + s.credit.toFixed(2);
    answer += ".";
  }

  return { answer, data: results };
}


export function handleReceivedFromPeople() {
  const rows = txReceivedFromPeople();
  if (!rows.length) return { answer: "No transfers from people.", data: null };
  const list = rows.map(r => `${r.payee || "Unknown"}: ${S()}${(r.total_spend||0).toFixed(2)} (${r.txn_count} txns)`);
  return { answer: `Received from people:\n${list.join("\n")}`, data: rows };
}

export function handleSubscriptions() {
  const rows = txSubscriptions();
  if (!rows.length) return { answer: "No subscriptions.", data: null };
  const list = rows.map(r => `${r.payee || "Unknown"}: ${S()}${(r.total_spend||0).toFixed(2)} (${r.txn_count} txns)`);
  return { answer: `Subscriptions:\n${list.join("\n")}`, data: rows };
}

export function handleRecentTransactions(n = 10) {
  const rows = txRecent(n);
  const list = rows.map(r => `${r.date}: ${S()}${Math.abs(r.amount).toFixed(2)} — ${r.description}`);
  return { answer: `Recent:\n${list.join("\n")}`, data: rows };
}
