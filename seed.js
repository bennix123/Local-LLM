
// Seed script: generates 500 realistic bank transactions, stores them in
// SQLite, computes summaries, and pushes summary embeddings to ChromaDB.
//
// Usage:  node seed.js

import { initChromaDb, isChromaReady, clearChromaDocument, replaceChromaDocument, replaceChromaDocumentContextual } from "./src/chromaDb.js";
import { initDb, replaceDocument, clearDocument, hasDocument, getMeta } from "./src/db.js";
import { computeStatsSummary } from "./src/stats.js";
import { contextualizeChunks } from "./src/context.js";
import { detectCurrency } from "./src/currency.js";

// ── Data generation ──────────────────────────────────────────────────────

const CATEGORIES = [
  "Groceries", "Shopping", "Dining", "Transport", "Utilities",
  "Rent", "Entertainment", "Healthcare", "Insurance", "Education",
  "Travel", "Salary", "Freelance", "Investment", "Transfer",
  "Subscription", "Fuel", "Clothing", "Electronics", "Home Improvement",
];

const PAYEES = {
  Groceries: [
    "Whole Foods Market", "Trader Joe's", "Kroger #142", "Safeway",
    "Costco Wholesale", "Walmart Grocery", "Aldi", "Publix",
    "Local Farmers Market", "Instacart",
  ],
  Shopping: [
    "Amazon.com", "Target", "Walmart", "eBay", "Best Buy",
    "Home Depot #2551", "Lowe's", "IKEA", "Macy's", "Nordstrom",
  ],
  Dining: [
    "DoorDash", "Uber Eats", "Starbucks #8842", "Chipotle",
    "McDonald's", "Subway", "Olive Garden", "Local Bistro",
    "Pizza Hut", "Panera Bread",
  ],
  Transport: [
    "Uber", "Lyft", "Metro Transit", "Gas Station #42",
    "Parking Garage", "Amtrak", "Delta Airlines", "Budget Car Rental",
  ],
  Utilities: [
    "AT&T Wireless", "Comcast", "Duke Energy", "Water Co.",
    "Verizon", "T-Mobile", "PG&E", "Spectrum",
  ],
  Rent: ["Shoreline Apartments", "Greenfield Properties"],
  Entertainment: [
    "Netflix", "Spotify", "AMC Theaters", "Ticketmaster",
    "Nintendo eShop", "Apple App Store", "HBO Max", "Disney+",
  ],
  Healthcare: [
    "CVS Pharmacy", "Walgreens", "Kaiser Permanente",
    "Dental Clinic", "Optometry Plus", "Urgent Care",
  ],
  Insurance: ["GEICO", "State Farm", "MetLife", "Blue Cross"],
  Education: [
    "Coursera", "Udemy", "Skillshare", "University Bookstore",
    "Chegg", "LinkedIn Learning",
  ],
  Travel: [
    "Airbnb", "Marriott Hotel", "Expedia", "Booking.com",
    "Hilton Hotels", "Southwest Airlines",
  ],
  Salary: ["Acme Corp Payroll", "TechStart Inc", "InnoSoft HR"],
  Freelance: ["Upwork Client", "Fiverr Payment", "Direct Client"],
  Investment: [
    "Schwab Brokerage", "Vanguard Mutual Fund", "Robinhood",
    "Fidelity",
  ],
  Transfer: ["Internal Transfer", "Zelle", "Venmo", "Bank of America"],
  Subscription: [
    "Netflix", "Spotify", "Amazon Prime", "Disney+",
    "HBO Max", "Apple iCloud", "Google One", "X Premium",
  ],
  Fuel: ["Shell", "BP", "Exxon", "Chevron", "7-Eleven Gas"],
  Clothing: ["Macy's", "Nordstrom", "Zara", "H&M", "Nike Store", "Gap"],
  Electronics: ["Best Buy", "Apple Store", "Micro Center", "B&H Photo"],
  "Home Improvement": [
    "Home Depot #2551", "Lowe's", "Ace Hardware", "Sherwin-Williams",
  ],
};

const DESCRIPTIONS = {
  Groceries: [
    "Weekly grocery run", "Produce & dairy", "Snacks & drinks",
    "Meal prep supplies", "Organic groceries", "Pantry restock",
  ],
  Dining: [
    "Lunch meeting", "Dinner with friends", "Morning coffee",
    "Weekend brunch", "Takeout dinner", "Quick bite",
  ],
  Shopping: [
    "Household supplies", "Gift purchase", "Online order",
    "Electronics accessory", "Home decor", "Books",
  ],
  Transport: [
    "Commute", "Ride to airport", "Monthly pass", "Gas fill-up",
  ],
};

function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function randomAmount(min, max) {
  return (Math.random() * (max - min) + min).toFixed(2);
}

function randomDate(year, month) {
  const day = Math.floor(Math.random() * 28) + 1;
  const m = String(month).padStart(2, "0");
  const d = String(day).padStart(2, "0");
  return `${year}-${m}-${d}`;
}

function generateTransactions(count = 500) {
  const records = [];
  let balance = 5000;

  for (let i = 0; i < count; i++) {
    const month = Math.ceil((i / count) * 5) + 0; // months 1-5
    const day = Math.floor(Math.random() * 28) + 1;
    const m = String(month).padStart(2, "0");
    const d = String(day).padStart(2, "0");
    const date = `2025-${m}-${d}`;

    const isIncome = Math.random() < 0.08; // ~8% are income transactions

    let category, payee, amount, type;

    if (isIncome) {
      type = "Credit";
      category = pick(["Salary", "Freelance", "Investment", "Transfer"]);
      payee = pick(PAYEES[category]);
      amount = parseFloat(randomAmount(500, 5000));
    } else {
      type = "Debit";
      category = pick([
        "Groceries", "Shopping", "Dining", "Transport", "Utilities",
        "Rent", "Entertainment", "Healthcare", "Insurance", "Education",
        "Travel", "Fuel", "Clothing", "Electronics", "Home Improvement",
        "Subscription",
      ]);

      if (category === "Rent") amount = parseFloat(randomAmount(1200, 2500));
      else if (category === "Utilities") amount = parseFloat(randomAmount(50, 300));
      else if (category === "Insurance") amount = parseFloat(randomAmount(80, 400));
      else if (category === "Fuel") amount = parseFloat(randomAmount(30, 100));
      else if (category === "Dining") amount = parseFloat(randomAmount(5, 120));
      else if (category === "Groceries") amount = parseFloat(randomAmount(20, 300));
      else if (category === "Shopping") amount = parseFloat(randomAmount(10, 500));
      else if (category === "Electronics") amount = parseFloat(randomAmount(50, 1200));
      else if (category === "Travel") amount = parseFloat(randomAmount(100, 1500));
      else if (category === "Healthcare") amount = parseFloat(randomAmount(15, 500));
      else if (category === "Education") amount = parseFloat(randomAmount(30, 200));
      else if (category === "Entertainment") amount = parseFloat(randomAmount(8, 100));
      else if (category === "Clothing") amount = parseFloat(randomAmount(20, 200));
      else if (category === "Transport") amount = parseFloat(randomAmount(5, 80));
      else if (category === "Home Improvement") amount = parseFloat(randomAmount(15, 600));
      else if (category === "Subscription") amount = parseFloat(randomAmount(5, 20));
      else amount = parseFloat(randomAmount(5, 200));

      payee = pick(PAYEES[category]);
    }

    balance += type === "Credit" ? amount : -amount;

    records.push({
      Date: date,
      Description: `${payee} - ${pick(DESCRIPTIONS[category] || ["Transaction"])}`,
      Category: category,
      Amount: type === "Credit" ? `+$${amount.toFixed(2)}` : `-$${amount.toFixed(2)}`,
      Type: type,
      Balance: `$${balance.toFixed(2)}`,
    });
  }

  records.sort((a, b) => a.Date.localeCompare(b.Date));
  return records;
}

// ── Chunk formatting ─────────────────────────────────────────────────────

function recordsToChunks(records) {
  const columns = Object.keys(records[0]);
  return records.map((row, i) => {
    const parts = columns
      .map((col) => `${col}: ${row[col]}`)
      .join("; ");
    return `Row ${i + 1} | ${parts}`;
  });
}

// ── Summary generation helpers ───────────────────────────────────────────

function generateSummaries(records, statsSummary) {
  const summaries = [];

  // 1. Overall summary
  summaries.push({
    id: "summary:overall",
    text: `Overall Bank Statement Summary:\n${statsSummary}`,
    type: "overall",
  });

  // 2. Per-category summaries
  const byCategory = new Map();
  const byCategoryCount = new Map();
  for (const r of records) {
    const cat = r.Category;
    const amt = parseFloat(r.Amount);
    byCategory.set(cat, (byCategory.get(cat) || 0) + amt);
    byCategoryCount.set(cat, (byCategoryCount.get(cat) || 0) + 1);
  }
  for (const [cat, total] of byCategory) {
    const count = byCategoryCount.get(cat);
    const avg = (total / count).toFixed(2);
    summaries.push({
      id: `summary:category:${cat}`,
      text: `Category "${cat}": ${count} transactions, total ${total.toFixed(2)}, average ${avg} per transaction. ${
        total >= 0
          ? `Net income of ${total.toFixed(2)} from this category.`
          : `Net spending of ${Math.abs(total).toFixed(2)} on this category.`
      }`,
      type: "category",
      category: cat,
    });
  }

  // 3. Per-month summaries
  const byMonth = new Map();
  const byMonthCount = new Map();
  for (const r of records) {
    const month = r.Date.substring(0, 7);
    const amt = parseFloat(r.Amount);
    byMonth.set(month, (byMonth.get(month) || 0) + amt);
    byMonthCount.set(month, (byMonthCount.get(month) || 0) + 1);
  }
  for (const [month, total] of byMonth) {
    const count = byMonthCount.get(month);
    summaries.push({
      id: `summary:month:${month}`,
      text: `Month "${month}": ${count} transactions, net total ${total.toFixed(2)}. ${
        total >= 0 ? "Net positive month." : "Net negative month — more spent than earned."
      }`,
      type: "month",
      month,
    });
  }

  // 4. Income vs Expenses summary
  let totalIncome = 0, totalExpenses = 0;
  for (const r of records) {
    const amt = parseFloat(r.Amount);
    if (amt > 0) totalIncome += amt;
    else totalExpenses += Math.abs(amt);
  }
  summaries.push({
    id: "summary:income_vs_expenses",
    text: `Income vs Expenses: Total income ${totalIncome.toFixed(2)}, total expenses ${totalExpenses.toFixed(2)}. Net: ${(totalIncome - totalExpenses).toFixed(2)}. Savings rate: ${((totalIncome - totalExpenses) / totalIncome * 100).toFixed(1)}% of income.`,
    type: "financial",
  });

  // 5. Top spending categories
  const sortedCats = [...byCategory.entries()]
    .filter(([, v]) => v < 0)
    .sort((a, b) => a[1] - b[1])
    .slice(0, 10);
  const topCatsText = sortedCats
    .map(([cat, total], i) => `  ${i + 1}. ${cat}: ${Math.abs(total).toFixed(2)}`)
    .join("\n");
  summaries.push({
    id: "summary:top_spending",
    text: `Top 10 Spending Categories:\n${topCatsText}`,
    type: "ranking",
  });

  // 6. Largest transactions
  const largest = records
    .map((r) => ({ desc: r.Description, amt: parseFloat(r.Amount), date: r.Date }))
    .sort((a, b) => Math.abs(b.amt) - Math.abs(a.amt))
    .slice(0, 10);
  const largestText = largest
    .map((t, i) => `  ${i + 1}. ${t.date} | ${t.desc} | ${t.amt.toFixed(2)}`)
    .join("\n");
  summaries.push({
    id: "summary:largest_transactions",
    text: `10 Largest Transactions by Absolute Value:\n${largestText}`,
    type: "ranking",
  });

  // 7. Category-payee breakdown summaries
  const byPayee = new Map();
  for (const r of records) {
    const desc = r.Description.split(" - ")[0];
    const amt = parseFloat(r.Amount);
    if (!byPayee.has(desc)) byPayee.set(desc, { count: 0, total: 0 });
    const entry = byPayee.get(desc);
    entry.count++;
    entry.total += amt;
  }
  const topPayees = [...byPayee.entries()]
    .sort((a, b) => Math.abs(b[1].total) - Math.abs(a[1].total))
    .slice(0, 20);
  const payeeText = topPayees
    .map(
      ([name, data]) =>
        `  ${name}: ${data.count} transactions, total ${data.total.toFixed(2)}`
    )
    .join("\n");
  summaries.push({
    id: "summary:top_payees",
    text: `Top 20 Payees by Total Amount:\n${payeeText}`,
    type: "ranking",
  });

  return summaries;
}

// ── Main ─────────────────────────────────────────────────────────────────

console.log("Generating 500 bank transactions...");
const records = generateTransactions(500);
console.log(`Generated ${records.length} transactions.`);

const columns = Object.keys(records[0]);
const chunks = recordsToChunks(records);
console.log(`Formatted into ${chunks.length} chunks.`);

// Compute stats summary
detectCurrency(records);
const statsSummary = computeStatsSummary(columns, records);
console.log("\nStats Summary:\n" + (statsSummary ? statsSummary.substring(0, 500) + "..." : "none"));

// Generate multi-faceted summaries for vector DB
const summaries = generateSummaries(records, statsSummary);
console.log(`\nGenerated ${summaries.length} summary embeddings to push:\n`);
summaries.forEach((s) => console.log(`  [${s.type}] ${s.id} (${s.text.length} chars)`));

// ── Store in SQLite ───────────────────────────────────────────────────────

console.log("\n--- SQLite ---");
initDb();
clearDocument();
replaceDocument({
  fileName: "seed_500_transactions.csv",
  columns,
  rowCount: records.length,
  chunks,
  summary: statsSummary || "",
});
console.log(`Stored ${chunks.length} chunks in SQLite.`);
console.log(`Has document: ${hasDocument()}`);

// ── Store summaries in ChromaDB ───────────────────────────────────────────

console.log("\n--- ChromaDB ---");
await initChromaDb();

if (isChromaReady()) {
  await clearChromaDocument();

  // Store raw transaction chunks
  console.log(`Pushing ${chunks.length} raw transaction chunks...`);
  await replaceChromaDocument(chunks, { fileName: "seed_500_transactions.csv" });

  // Contextualize and store enriched chunks (Anthropic Contextual Retrieval)
  console.log(`Contextualizing and pushing ${chunks.length} contextual chunks...`);
  const ctxChunks = contextualizeChunks(chunks, getMeta());
  await replaceChromaDocumentContextual(ctxChunks, { fileName: "seed_500_transactions.csv" });
  console.log("Contextual retrieval index built.\n");
} else {
  console.log("ChromaDB not available — skipping vector push.");
}

console.log("\nDone. 500 transactions in SQLite + summaries in ChromaDB.");
process.exit(0);
