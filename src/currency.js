
// Currency detection and formatting — adapts to any bank statement format.
// Detects ₹, $, €, £, ¥, Rs, INR, or falls back to raw numbers.

const CURRENCY_PATTERNS = [
  { symbol: "₹", code: "INR", regex: /[₹]/u },
  { symbol: "$", code: "USD", regex: /\$/ },
  { symbol: "€", code: "EUR", regex: /[€€]/u },
  { symbol: "£", code: "GBP", regex: /£/ },
  { symbol: "¥", code: "JPY", regex: /[¥￥]/u },
  { symbol: "Rs.", code: "INR", regex: /\bRs\.?\s/i },
  { symbol: "INR", code: "INR", regex: /\bINR\b/i },
  { symbol: "GBP", code: "GBP", regex: /\bGBP\b/i },
  { symbol: "USD", code: "USD", regex: /\bUSD\b/i },
  { symbol: "EUR", code: "EUR", regex: /\bEUR\b/i },
  { symbol: "AED", code: "AED", regex: /\bAED\b/i },
  { symbol: "OMR ", code: "OMR", regex: /\bOMR\b/i },
  { symbol: "KWD ", code: "KWD", regex: /\bKWD\b/i },
  { symbol: "BHD ", code: "BHD", regex: /\bBHD\b/i },
  { symbol: "JOD ", code: "JOD", regex: /\bJOD\b/i },
  { symbol: "IQD ", code: "IQD", regex: /\bIQD\b/i },
];

let detected = null;

export function detectCurrency(records) {
  if (detected) return detected;

  const columns = records.length ? Object.keys(records[0]) : [];

  // Check column headers first — Indian banks often have "Amount (INR)" etc.
  for (const col of columns) {
    for (const pattern of CURRENCY_PATTERNS) {
      if (pattern.regex.test(col)) {
        detected = pattern;
        return detected;
      }
    }
  }

  // Check cell values for currency symbols
  let inrCount = 0, usdCount = 0, eurCount = 0, gbpCount = 0, omrCount = 0;
  for (const record of records.slice(0, 100)) {
    for (const col of columns) {
      const val = String(record[col] || "");
      if (/[₹]/u.test(val)) inrCount++;
      else if (/\$/.test(val)) usdCount++;
      else if (/[€€]/u.test(val)) eurCount++;
      else if (/£/.test(val)) gbpCount++;
      else if (/\bOMR\b/i.test(val)) omrCount++;
    }
  }

  if (inrCount > 0) detected = CURRENCY_PATTERNS[0];  // ₹
  else if (usdCount > 0) detected = CURRENCY_PATTERNS[1]; // $
  else if (eurCount > 0) detected = CURRENCY_PATTERNS[2]; // €
  else if (gbpCount > 0) detected = CURRENCY_PATTERNS[3]; // £
  else if (omrCount > 0) detected = CURRENCY_PATTERNS[8]; // OMR
  else detected = { symbol: "", code: "RAW", regex: null }; // Clean fallback: no symbol

  return detected;
}

export function detectCurrencyFromText(text) {
  const low = (text || "").toLowerCase();
  if (
    low.includes("ifsc") ||
    low.includes("micr") ||
    low.includes("state bank") ||
    low.includes("hdfc") ||
    low.includes("icici") ||
    low.includes("₹") ||
    low.includes("rs.")
  ) {
    return setCurrency("INR");
  }
  if (
    low.includes("barclays") ||
    low.includes("sort code") ||
    low.includes("£")
  ) {
    return setCurrency("GBP");
  }
  if (
    low.includes("oman") ||
    low.includes("muscat") ||
    low.includes("omr")
  ) {
    return setCurrency("OMR");
  }
  if (
    low.includes("chase") ||
    low.includes("routing") ||
    low.includes("$")
  ) {
    return setCurrency("USD");
  }
  return null;
}


export function setCurrency(code) {
  const p = CURRENCY_PATTERNS.find((x) => x.code === code);
  if (p) detected = p;
  return detected;
}

export function getCurrencySymbol() {
  return detected ? detected.symbol : "";
}

export function getCurrencyCode() {
  return detected ? detected.code : "UNKNOWN";
}

export function getDecimalPlaces() {
  const code = getCurrencyCode();
  return ["OMR", "KWD", "BHD", "JOD", "IQD"].includes(code) ? 3 : 2;
}

export function fmtAmount(n) {
  const sym = getCurrencySymbol();
  const decimals = getDecimalPlaces();
  const val = Number.isInteger(n) ? String(n) : n.toFixed(decimals);
  if (n < 0) return `-${sym}${Math.abs(n).toFixed(Number.isInteger(n) ? 0 : decimals)}`;
  return `${sym}${val}`;
}

export function fmtAmountLabel(n) {
  const sym = getCurrencySymbol();
  const decimals = getDecimalPlaces();
  const abs = Math.abs(n);
  const val = Number.isInteger(abs) ? String(abs) : abs.toFixed(decimals);
  if (n >= 0) return `${sym}${val}`;
  return `-${sym}${val}`;
}

export function resetCurrency() {
  detected = null;
}

