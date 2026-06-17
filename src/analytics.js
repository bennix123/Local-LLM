
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

  // Format answer from SQL aggregates
  let answer = "";
  if (results.sql && results.sql.count > 0) {
    answer += `Found ${results.sql.count} transactions for "${results.sql.entity}": `;
    if (results.sql.debit > 0) answer += `spent ₹${results.sql.debit.toFixed(2)}`;
    if (results.sql.debit > 0 && results.sql.credit > 0) answer += ", ";
    if (results.sql.credit > 0) answer += `received ₹${results.sql.credit.toFixed(2)}`;
    answer += ".";
  }

  // Add top semantic matches
  const semanticMatches = results.chunks?.filter(c => c.source === "semantic" || c.source === "both");
  if (semanticMatches && semanticMatches.length > 0) {
    answer += `\n\nTop matching transactions:`;
    for (const c of semanticMatches.slice(0, 5)) {
      answer += `\n  ${c.date} — ${c.description}: ${c.amount}`;
    }
  }

  if (!answer) {
    answer = `"${keyword}" not found in this statement.`;
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
