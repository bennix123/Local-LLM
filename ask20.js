// Fire the user's 20 questions at the live /api/chat and grade each answer
// against the audited ground truth. Reports the answer source (deterministic
// vs LLM/cache) so we can see which layer handled each.
import Redis from "ioredis";

const BASE = "http://localhost:3000";

const Q = [
  ["What is my total spending for the entire statement period?", ["328309"]],
  ["How much did I spend on food delivery (Swiggy, Zomato, Blinkit)?", ["5221"]],
  ["How much did I spend on groceries (Grofers/Blinkit)?", ["4898", "708"]],
  ["What is my total spending on metro and travel?", ["860", "₹86"]],
  ["How much did I pay to CRED in total?", ["8642", "8,642"]],
  ["How much did I spend on internet (Excitel Broadband)?", ["1649", "1,649"]],
  ["How much did I spend on mobile recharge (Jio)?", ["621"]],
  ["How much did I spend on entertainment like PVR INOX?", ["690"]],
  ["What are my top 5 highest spending transactions?", ["30000", "30,000", "devendra"]],
  ["What is the smallest amount I ever spent?", ["0.24"]],
  ["What is my total salary credited during this period?", ["254416", "2,54,416"]],
  ["What is my closing balance at the end of February 2025?", ["10.86"]],
  ["How much interest did I earn on my account?", ["39"]],
  ["Did I receive any money from other people? If yes, how much total?", ["received", "₹"]],
  ["Which month did I spend the most money?", ["january"]],
  ["Which month did I spend the least money?", ["september"]],
  ["How much did I spend in December 2024 specifically?", ["48215", "48,215", "48216", "48,216"]],
  ["How much did Devendra Kumar receive from me every month?", ["205000", "2,05,000", "25000", "30000"]],
  ["How much total did I send to Nikhil across all months?", ["42000", "42,000"]],
  ["How many transactions did I make using UPI in total?", ["282"]],
];

const norm = (s) => s.toLowerCase().replace(/,/g, "");
async function chat(q) {
  const r = await fetch(BASE + "/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: q }) });
  return { src: r.headers.get("X-Answer") || r.headers.get("X-Cache") || "LLM", text: (await r.text()).trim() };
}

(async () => {
  try { const c = new Redis("redis://localhost:6379"); const k = await c.keys("bank:*"); if (k.length) await c.del(...k); c.disconnect(); } catch {}
  let pass = 0; const fails = [];
  for (let i = 0; i < Q.length; i++) {
    const [q, expects] = Q[i];
    const a = await chat(q);
    const n = norm(a.text);
    const ok = expects.some((e) => n.includes(norm(e)));
    if (ok) pass++; else fails.push(i + 1);
    const flat = a.text.replace(/\n/g, " ⏎ ").slice(0, 110);
    console.log(`${ok ? "✅" : "❌"} ${String(i + 1).padStart(2)}. [${a.src.padEnd(13)}] ${flat}`);
  }
  console.log(`\n=== ${pass}/${Q.length} matched ground truth ===`);
  if (fails.length) console.log(`Review questions: ${fails.join(", ")}`);
  process.exit(0);
})();
