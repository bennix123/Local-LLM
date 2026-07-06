
// SBI Bank PDF Statement Parser
// Parses State Bank of India PDF statements into structured transactions.
// Handles: DD/MM/YYYY dates, Indian comma formats, Dr/Cr notation, multi-page headers

export function parseSBIPdfFile(text) {
  // Detect SBI format
  if (!text.includes("STATE BANK OF INDIA") && !text.includes("PERSONAL BANKING"))
    return null;

  const lines = text.split(/\r?\n/).map(l => l.trim()).filter(l => l.length > 0);
  const records = [];
  const columns = ["Date", "Description", "Amount", "Balance"];

  let headerFound = false;
  let skipUntil = "";

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Skip header and summary lines
    if (!headerFound) {
      if (line.includes("Date") && line.includes("Withdrawal") && line.includes("Deposit")) {
        headerFound = true;
      }
      continue;
    }

    // Skip repeated header rows (page breaks)
    if (line.includes("Date") && line.includes("Withdrawal") && line.includes("Closing")) {
      continue;
    }

    // Transaction line must start with a date: DD/MM/YYYY
    const dateMatch = line.match(/^(\d{2}\/\d{2}\/\d{4})/);
    if (!dateMatch) continue;

    const date = dateMatch[1];

    // Extract narration — everything between date and the first reference number
    // Narration starts after date, ends before Chq./Ref. No.
    const afterDate = line.substring(10).trim();

    // Extract reference number — typically a long digit sequence
    const refMatch = afterDate.match(/(\d{11,13})/);
    const refNo = refMatch ? refMatch[1] : "";

    // Split line into tokens to find amounts at the end
    const tokens = line.split(/\s+/);
    
    // The last 3 tokens should be: withdrawal/deposit, deposit/withdrawal, closing_balance
    // Or: withdrawal, deposit, closing_balance
    // But we need to handle the Indian number format with commas

    // Find all number-like tokens starting from the END of the line
    // SBI format: ...narration... ref_no date withdrawal deposit balance
    // Amounts are the last ~3 tokens. Reference numbers are 11+ digits.
    const numberTokens = [];
    for (let j = tokens.length - 1; j >= 0; j--) {
      const t = tokens[j];
      if (/^[\d,]+\.?\d*$/.test(t)) {
        // Skip if it looks like a reference number (too long) or date
        const val = parseFloat(t.replace(/,/g, ""));
        if (val < 100000000) {  // Skip >10 crore (reference numbers)
          numberTokens.unshift(t);
        }
      }
      if (numberTokens.length >= 3) break;
    }

    let withdrawal = 0;
    let deposit = 0;
    let balance = 0;

    if (numberTokens.length >= 2) {
      balance = parseIndianNumber(numberTokens[numberTokens.length - 1]);
      
      if (afterDate.includes(" CR") || afterDate.includes("CREDIT") || afterDate.includes("SALARY CR") || afterDate.includes("INTEREST CREDIT")) {
        deposit = parseIndianNumber(numberTokens[numberTokens.length - 2]);
      } else {
        withdrawal = parseIndianNumber(numberTokens[numberTokens.length - 2]);
      }
    }

    // Extract narration (everything after date, before the amounts)
    let narration = afterDate;
    // Remove the reference number
    if (refNo) narration = narration.replace(refNo, "").trim();
    // Remove the value date (next DD/MM/YYYY after narration)
    narration = narration.replace(/\d{2}\/\d{2}\/\d{4}/, "").trim();
    // Remove trailing number tokens
    for (const t of numberTokens) {
      narration = narration.replace(new RegExp("\\s*" + t + "\\s*$"), " ").trim();
      narration = narration.replace(new RegExp("\\s*" + t + "$"), "").trim();
    }
    // Clean up
    narration = narration.replace(/\s+/g, " ").trim();

    // Determine amount sign
    let amount = 0;
    if (withdrawal > 0) {
      amount = -withdrawal;
    } else if (deposit > 0) {
      amount = deposit;
    }

    records.push({
      Date: date,
      Description: narration || afterDate.substring(0, 50),
      Amount: amount.toFixed(2),
      Balance: balance > 0 ? balance.toFixed(2) : "",
    });
  }

  return {
    columns,
    records,
    rowCount: records.length,
    chunks: records.map((r, i) => 
      `Row ${i + 1} | Date: ${r.Date}; Description: ${r.Description}; Amount: ${r.Amount}${r.Balance ? "; Balance: " + r.Balance : ""}`
    ),
  };
}

function parseIndianNumber(str) {
  if (!str) return 0;
  // Remove commas (Indian format: 1,23,456.78 → 123456.78)
  return parseFloat(str.replace(/,/g, "")) || 0;
}
