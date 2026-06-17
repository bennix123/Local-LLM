
// Contextual Retrieval (Anthropic 2024)
// Uses the local LLM to generate a 2-3 sentence summary for each chunk
// before embedding. This gives the embedding model richer semantic signal.
// Runs once at ingestion — not at query time.

import { chat, isReady } from "./llm.js";

export async function contextualizeChunks(chunks, meta) {
  if (!isReady()) {
    console.warn("[contextualize] No model loaded — skipping contextualization");
    return chunks;
  }

  const statementInfo = buildStatementContext(meta);
  const contextualized = [];

  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i];
    try {
      const summary = await generateChunkSummary(chunk, statementInfo, i, chunks.length);
      contextualized.push(`${summary}\n${chunk}`);
    } catch (err) {
      console.warn(`[contextualize] Failed for chunk ${i}: ${err.message}`);
      contextualized.push(chunk);
    }

    if (i % 50 === 0 && i > 0) {
      console.log(`[contextualize] Processed ${i}/${chunks.length} chunks`);
    }
  }

  return contextualized;
}

async function generateChunkSummary(chunk, statementInfo, index, total) {
  const prompt = `You are analyzing a bank statement to improve search retrieval.

STATEMENT CONTEXT:
${statementInfo}

CHUNK TO SUMMARIZE (transaction ${index + 1} of ${total}):
${chunk}

Write a 2-sentence summary that describes this specific transaction. Include:
- Who the payment was to/from
- What it was for (category if available)
- The amount and date
- How it relates to the overall spending pattern

Answer ONLY with the 2-sentence summary. No introduction, no bullet points.`;

  const summary = await new Promise((resolve, reject) => {
    let result = "";
    const timeout = setTimeout(() => reject(new Error("timeout")), 30000);

    chat(prompt, "Summarize this transaction", (text) => {
      result += text;
    }).then(() => {
      clearTimeout(timeout);
      resolve(result.trim());
    }).catch((err) => {
      clearTimeout(timeout);
      reject(err);
    });
  });

  return `[Context] ${summary}`;
}

function buildStatementContext(meta) {
  const parts = [];
  if (meta.fileName) parts.push(`Statement: ${meta.fileName}`);
  if (meta.rowCount) parts.push(`${meta.rowCount} transactions`);
  if (meta.summary) {
    const overview = meta.summary.split("\n").slice(0, 8).join(" ");
    parts.push(`Overview: ${overview.substring(0, 300)}`);
  }
  return parts.join(" | ");
}
