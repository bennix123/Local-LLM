
// SBI XLSX Statement Post-Processor
// SBI Excel exports have complex layouts with merged headers.
// This remaps generic SheetJS columns to proper field names.

import { setCurrency } from "./currency.js";

export function remapSBIXlsx(records) {
  if (!records.length) return records;
  
  const cols = Object.keys(records[0]);

  // SBI signature: column names contain the bank name
  const isSBI = cols.some(c => c.includes("STATE BANK OF INDIA") || c.includes("SBI"));
  if (!isSBI) return records;

  setCurrency("INR"); // Force INR for SBI bank statements

  // Skip header rows (account info, statement period, column headers)
  const cleaned = [];
  let headerSkipped = false;
  
  for (const row of records) {
    const vals = Object.values(row).map(v => String(v || "").trim());
    const rowText = vals.join(" ");
    
    // Skip account info header rows
    if (rowText.includes("Account Holder") || 
        rowText.includes("Statement Period") ||
        rowText.includes("PERSONAL BANKING") ||
        rowText.includes("IFSC:") ||
        rowText.includes("Address:") ||
        rowText.includes("PAN:") ||
        rowText.includes("Nominee:") ||
        rowText.includes("Opening Balance")) {
      continue;
    }
    
    // Skip the column header row
    if (rowText.includes("Date") && rowText.includes("Narration") && rowText.includes("Withdrawal")) {
      headerSkipped = true;
      continue;
    }
    
    // Check if this is a transaction row (first value looks like a date)
    const firstVal = vals[0] || "";
    if (!/^\d{2}\/\d{2}\/\d{4}$/.test(firstVal)) continue;
    
    // Map columns based on position
    // SBI format: Date | Narration | Ref No | Value Date | Withdrawal | Deposit | Closing Balance | Type
    const date = vals[0] || "";
    const narration = vals[1] || "";
    const refNo = vals[2] || "";
    const valueDate = vals[3] || "";
    const withdrawal = vals[4] ? parseFloat(vals[4].replace(/,/g, "")) : 0;
    const deposit = vals[5] ? parseFloat(vals[5].replace(/,/g, "")) : 0;
    const balance = vals[6] ? parseFloat(vals[6].replace(/,/g, "")) : 0;
    const type = (vals[7] || "").toLowerCase();
    
    const amount = type.includes("credit") ? deposit : (withdrawal > 0 ? -withdrawal : deposit);
    
    cleaned.push({
      Date: date,
      Description: narration,
      Amount: amount.toFixed(2),
      Balance: balance > 0 ? balance.toFixed(2) : "",
    });
  }
  
  return cleaned;
}
