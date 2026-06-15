// iPhone "atmosphere" simulator for the embedded LLM.
//
// iOS doesn't fail allocations under pressure — its jetsam daemon KILLS any app
// whose memory footprint exceeds the device's per-app budget. So this harness:
//   1. Loads the model with phone-like constraints (few CPU threads, no mmap so
//      every weight counts as dirty memory like iOS phys_footprint).
//   2. Samples RSS every 50ms and tracks the PEAK.
//   3. If a --cap is given, it acts like jetsam: the instant RSS crosses the cap,
//      it prints "JETSAM KILL" and exits (mimicking iOS terminating the app).
//   4. Runs a representative bank-statement Q&A and reports tokens/sec.
//
// Usage:
//   node iphone-sim.js <modelPath> [--ctx 4096] [--threads 4] [--cap-mb 2048] [--mmap]

import os from "node:os";
import { getLlama, LlamaChatSession } from "node-llama-cpp";

const args = process.argv.slice(2);
const modelPath = args[0];
const opt = (name, def) => {
  const i = args.indexOf("--" + name);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--")
    ? args[i + 1]
    : def;
};
const has = (name) => args.includes("--" + name);

const CTX = parseInt(opt("ctx", "4096"), 10);
const THREADS = parseInt(opt("threads", "4"), 10);
const CAP_MB = parseInt(opt("cap-mb", "0"), 10); // 0 = no jetsam cap (measure only)
const USE_MMAP = has("mmap"); // default OFF → conservative dirty-memory estimate

const MB = (b) => (b / 1024 / 1024).toFixed(0);
const GB = (b) => (b / 1024 / 1024 / 1024).toFixed(2);

let peak = 0;
let killed = false;
const capBytes = CAP_MB * 1024 * 1024;
const sampler = setInterval(() => {
  const rss = process.memoryUsage().rss;
  if (rss > peak) peak = rss;
  if (capBytes && rss > capBytes && !killed) {
    killed = true;
    clearInterval(sampler);
    console.log(
      `\n💀 JETSAM KILL — RSS ${MB(rss)}MB exceeded the iOS app budget of ${CAP_MB}MB.`
    );
    console.log(`   On this iPhone the OS would terminate the app here.`);
    process.exit(137);
  }
}, 50);
sampler.unref?.();

// Build a representative bank-statement context (~40 transactions + facts),
// mirroring what the real app feeds the model.
function buildContext() {
  const merchants = [
    "WHOLE FOODS", "SHELL FUEL", "NETFLIX", "STARBUCKS", "AMAZON",
    "UBER", "ELECTRIC BILL", "RENT", "SALARY ACME", "SPOTIFY",
  ];
  const rows = [];
  let bal = 5000;
  for (let i = 0; i < 40; i++) {
    const m = merchants[i % merchants.length];
    const amt = (((i * 37) % 200) + 5.5).toFixed(2);
    bal -= Number(amt);
    rows.push(
      `Row ${i + 1} | Date: 2026-05-${String((i % 28) + 1).padStart(2, "0")}; Description: ${m}; Debit: ${amt}; Balance: ${bal.toFixed(2)}`
    );
  }
  return (
    "You are a precise bank-statement assistant. Use ONLY the data below; trust the PRE-COMPUTED FACTS for any totals. Be concise.\n\n" +
    "=== PRE-COMPUTED FACTS ===\nTotal rows: 40\nColumn \"Debit\": sum=4123.50, max=199.50, min=5.50\n=== END FACTS ===\n\n" +
    "=== STATEMENT ROWS ===\n" + rows.join("\n") + "\n=== END ROWS ==="
  );
}

async function main() {
  console.log(`\n=== iPhone Simulation ===`);
  console.log(`Model      : ${modelPath.split(/[\\/]/).pop()}`);
  console.log(`Context    : ${CTX} tokens`);
  console.log(`Threads    : ${THREADS} (phone-class; this host has ${os.cpus().length})`);
  console.log(`mmap       : ${USE_MMAP ? "on" : "OFF (counting all weights as dirty RAM)"}`);
  console.log(`Jetsam cap : ${CAP_MB ? CAP_MB + "MB" : "none (measure peak only)"}`);
  console.log(`Host RAM   : ${GB(os.totalmem())}GB total\n`);

  const t0 = Date.now();
  const llama = await getLlama({ gpu: false, maxThreads: THREADS });
  const model = await llama.loadModel({ modelPath, useMmap: USE_MMAP });
  const afterLoad = process.memoryUsage().rss;
  console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] model loaded — RSS ${MB(afterLoad)}MB`);

  const context = await model.createContext({ contextSize: CTX, threads: THREADS });
  const seq = context.getSequence();
  const afterCtx = process.memoryUsage().rss;
  console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] context ready — RSS ${MB(afterCtx)}MB (KV cache +${MB(afterCtx - afterLoad)}MB)`);

  const session = new LlamaChatSession({ contextSequence: seq, systemPrompt: buildContext() });

  // First (cold) question — measure prefill + first-token latency.
  const q = "What is the total of all debit amounts, and which merchant was the single largest debit?";
  const tg = Date.now();
  let nTokens = 0;
  const answer = await session.prompt(q, {
    maxTokens: parseInt(opt("max", "64"), 10),
    temperature: 0.2,
    onTextChunk: () => { nTokens++; },
  });
  const genSec = (Date.now() - tg) / 1000;

  console.log(`\n[answer] ${answer.trim().slice(0, 200)}`);
  console.log(`\n=== RESULTS ===`);
  console.log(`Peak RSS        : ${MB(peak)} MB (${GB(peak)} GB)`);
  console.log(`Generation      : ${nTokens} chunks in ${genSec.toFixed(1)}s ≈ ${(nTokens / genSec).toFixed(1)} chunks/sec`);
  console.log(`Survived?       : ${killed ? "NO — jetsam killed it" : "YES"}`);

  // Verdict vs common iPhone per-app budgets.
  const budgets = { "4GB iPhone (~2.0GB app)": 2000, "6GB iPhone (~2.8GB app)": 2800, "8GB iPhone (~3.5GB app)": 3500 };
  console.log(`\n=== Fits iPhone app budget? (peak ${MB(peak)}MB) ===`);
  for (const [label, mb] of Object.entries(budgets)) {
    console.log(`  ${peak / 1024 / 1024 <= mb ? "✅ FITS  " : "❌ KILLED"} ${label}`);
  }
  process.exit(0);
}

main().catch((e) => {
  console.error("ERROR:", e.message);
  process.exit(1);
});
