
// Intent Router — classifies every user question before it touches RAG.
// Critical rule: AGGREGATION and SUMMARY queries must NEVER hit vector search.
// Only SEMANTIC queries route to ChromaDB. Everything else goes to SQL.

export function classifyIntent(question) {
  const q = question.toLowerCase();

  const aggPatterns = [
    /which month/, /least spen[dt]/, /most spen[dt]/,
    /total.*spen[dt]/, /top.*(\d+)?.*(merchant|payee|spender)/,
    /average.*spen[dt]/, /highest (?:transaction|amount)/,
    /lowest (?:transaction|amount)/, /how much.*(?:spend|spent)/,
    /how much.*(?:earn|income)/, /net (?:total|amount|income)/,
    /(?:biggest|largest|smallest|least|most)\b/,
    /remaining balance/, /current balance/,
    /(?:spend|spent) (?:the )?(?:most|least)/,
    /category.*breakdown/, /monthly.*breakdown/,
    /breakdown.*(?:by|per) (?:month|category)/,
    /top\s*\d+/, /bottom\s*\d+/,
    /income.*(?:total|overall)/, /expenses?.*(?:total|overall)/,
    /how many (?:transaction|payment|credit|debit)/,
    /what (?:is|was|are).*(?:total|sum|average|balance)/,
  ];

  const lookupPatterns = [
    /did (?:i|we) pay/, /when did (?:i|we)/,
    /last.*(?:sent|paid|received|payment)/,
    /find.*transaction/, /show.*transaction/,
    /search for/, /look (?:up|for)/,
    /(?:list|show|find)\s+(?:me\s+)?(?:all\s+)?(?:my\s+)?(?:the\s+)?(?:transactions|payments)/,
    /transactions?\s+(?:from|to|with|for)\b/,
    /sent.*money/, /received.*from/,
  ];

  const summaryPatterns = [
    /summarize/, /summary of/, /overview of/,
    /summar(y|ise) (?:my|the) (?:month|spending|statement)/,
    /give me (?:a|an) (?:overview|summary)/,
  ];

  const semanticPatterns = [
    /roast/, /insult/, /make fun/, /drag me/,
    /what.*habits?/, /(?:unusual|strange|suspicious)\b/,
    /saving.*habit/, /spending.*(?:habit|pattern|behavior)/,
    /financial.*(?:health|advice|tip|suggest)/,
    /(?:am i|should i|how (?:can|do) i).*(?:save|budget|cut|reduce)/,
    /(?:bad|poor|terrible).*(?:spending|habit|decision)/,
    /analyze my/, /analyze.*spending/,
  ];

  if (aggPatterns.some(r => r.test(q)))    return { intent: "AGGREGATION", type: "sql" };
  if (lookupPatterns.some(r => r.test(q))) return { intent: "LOOKUP", type: "fts5" };
  if (summaryPatterns.some(r => r.test(q))) return { intent: "SUMMARY", type: "sql+llm" };
  if (semanticPatterns.some(r => r.test(q))) return { intent: "SEMANTIC", type: "chromadb+llm" };

  // Default: try SQL first, fall back to semantic
  return { intent: "AGGREGATION", type: "sql" };
}
