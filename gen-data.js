// Synthetic Indian-style bank transactions for the period-summary demo.
// Produces records in the same shape the parser emits:
//   { Date: "YYYY-MM-DD", Description: "PAYEE - UPI-...", Category, Amount: "+/-N.NN", Balance }
// Exports generateSyntheticRecords(); also runnable to print a quick summary.

const PAYEES = {
  "Salary": ["MONTHLY SALARY-TECHCORP"],
  "Rent": ["LANDLORD RENT"],
  "Groceries": ["BLINKIT", "ZEPTO", "BIGBASKET", "DMART", "RELIANCE FRESH"],
  "Food & Dining": ["SWIGGY", "ZOMATO", "DOMINOS", "KFC INDIA", "CCD", "LOCAL DHABA"],
  "Transport": ["UBER", "OLA CABS", "DELHI METRO", "RAPIDO", "INDIAN OIL FUEL", "FASTAG TOLL"],
  "Shopping": ["AMAZON IN", "FLIPKART", "MYNTRA", "AJIO", "MEESHO"],
  "Utilities": ["JIO RECHARGE", "AIRTEL", "EXCITEL BROADBAND", "BSES ELECTRICITY", "INDANE GAS"],
  "Entertainment": ["NETFLIX", "SPOTIFY", "PVR INOX", "BOOKMYSHOW", "HOTSTAR"],
  "Healthcare": ["APOLLO PHARMACY", "1MG", "PHARMEASY", "MAX HOSPITAL"],
  "Investment & Insurance": ["ZERODHA", "GROWW SIP", "LIC PREMIUM", "HDFC MUTUAL FUND"],
  "Credit Card": ["CRED"],
  "Other / Transfers": ["RAHUL SHARMA", "PRIYA SINGH", "AMIT KUMAR", "NEHA GUPTA", "VIKRAM"],
};

// Relative frequency weights for day-to-day debits.
const DAILY_WEIGHTS = [
  ["Food & Dining", 30], ["Transport", 22], ["Groceries", 14], ["Shopping", 9],
  ["Entertainment", 6], ["Healthcare", 5], ["Other / Transfers", 14],
];
const AMT_RANGE = {
  "Food & Dining": [60, 700], "Transport": [20, 600], "Groceries": [150, 2500],
  "Shopping": [200, 8000], "Entertainment": [99, 1500], "Healthcare": [80, 3000],
  "Other / Transfers": [100, 15000], "Utilities": [199, 1500],
};

let seed = 12345;
function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
const pick = (a) => a[Math.floor(rnd() * a.length)];
const amt = (lo, hi) => Math.round((rnd() * (hi - lo) + lo) * 100) / 100;
function weighted(pairs) {
  const tot = pairs.reduce((s, [, w]) => s + w, 0);
  let r = rnd() * tot;
  for (const [k, w] of pairs) { if ((r -= w) <= 0) return k; }
  return pairs[0][0];
}

function monthsBetween(startISO, endISO) {
  const [sy, sm] = startISO.split("-").map(Number);
  const [ey, em] = endISO.split("-").map(Number);
  const out = [];
  let y = sy, m = sm;
  while (y < ey || (y === ey && m <= em)) {
    out.push(`${y}-${String(m).padStart(2, "0")}`);
    m++; if (m > 12) { m = 1; y++; }
  }
  return out;
}

let refCounter = 400000000000;
function rec(date, category, payee, signedAmt, balance) {
  const ref = String(refCounter++);
  const sign = signedAmt < 0 ? "" : "+";
  return {
    Date: date,
    Description: `${payee} - UPI-${payee}-${ref}-PAYMENT`,
    Category: category,
    Amount: `${sign}${signedAmt.toFixed(2)}`,
    Balance: balance.toFixed(2),
  };
}

export function generateSyntheticRecords(startISO = "2022-09", endISO = "2024-08", opening = 50000, perDayMin = 20, perDayMax = 40) {
  const months = monthsBetween(startISO, endISO);
  const all = [];
  let balance = opening;
  for (const ym of months) {
    const [y, m] = ym.split("-").map(Number);
    const daysInMonth = new Date(y, m, 0).getDate();
    const monthRows = [];

    // Recurring: salary (day 1), rent (day 3), SIP (day 5), utilities (days 8-18)
    const salary = amt(60000, 90000);
    monthRows.push({ day: 1, category: "Salary", payee: PAYEES.Salary[0], amount: salary });
    monthRows.push({ day: 3, category: "Rent", payee: PAYEES.Rent[0], amount: -amt(15000, 26000) });
    monthRows.push({ day: 5, category: "Investment & Insurance", payee: pick(PAYEES["Investment & Insurance"]), amount: -amt(2000, 12000) });
    for (const u of ["JIO RECHARGE", "EXCITEL BROADBAND", "BSES ELECTRICITY"]) {
      monthRows.push({ day: 8 + Math.floor(rnd() * 10), category: "Utilities", payee: u, amount: -amt(...AMT_RANGE.Utilities) });
    }
    monthRows.push({ day: 7 + Math.floor(rnd() * 14), category: "Credit Card", payee: "CRED", amount: -amt(3000, 40000) });

    // Daily discretionary spend
    for (let d = 1; d <= daysInMonth; d++) {
      const n = perDayMin + Math.floor(rnd() * (perDayMax - perDayMin + 1));
      for (let i = 0; i < n; i++) {
        const cat = weighted(DAILY_WEIGHTS);
        const [lo, hi] = AMT_RANGE[cat];
        monthRows.push({ day: d, category: cat, payee: pick(PAYEES[cat]), amount: -amt(lo, hi) });
      }
    }
    // occasional incoming transfers
    for (let i = 0; i < 3 + Math.floor(rnd() * 4); i++) {
      monthRows.push({ day: 1 + Math.floor(rnd() * daysInMonth), category: "Other / Transfers", payee: pick(PAYEES["Other / Transfers"]), amount: amt(500, 9000) });
    }

    monthRows.sort((a, b) => a.day - b.day);
    for (const r of monthRows) {
      balance += r.amount;
      const date = `${ym}-${String(r.day).padStart(2, "0")}`;
      all.push(rec(date, r.category, r.payee, r.amount, balance));
    }
  }
  return all;
}

// CLI: quick stats
if (process.argv[1] && process.argv[1].replace(/\\/g, "/").includes("gen-data.js")) {
  const recs = generateSyntheticRecords();
  const months = new Set(recs.map((r) => r.Date.slice(0, 7)));
  console.log(`generated ${recs.length} synthetic txns across ${months.size} months (${recs[0].Date} .. ${recs[recs.length - 1].Date})`);
  console.log("avg/month:", Math.round(recs.length / months.size));
  console.log("sample:", JSON.stringify(recs.slice(0, 2), null, 2));
}
