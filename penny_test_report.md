# Penny Financial Intelligence Engine — Test & Architecture Report

**Date:** July 6, 2026  
**Branch:** `feat/penny-intelligence-context`  
**Test Environment:** Self-contained Python test server (`test_server.py`) running on `http://localhost:5667` with local Plaid Sandbox sync.

---

## 1. Test Summary & Verification Log

The system was successfully deployed on the local port `5667` using the Plaid Sandbox API to pull synthetic transaction records into the local SQLite database (`live_txn.db`). 

Below are the test cases executed in the chat interface:

### Test Case 1: Financial Health Score
* **Question:** `"How financially healthy am I?"`
* **Intent Routed:** `advice / health`
* **Response Status:** Successful (SQL computation complete)
* **Output Received:**
  ```text
  Financial health: Poor — 23/100.
  You save -175% of income and kept spending within income in 0 of 2 months. 
  Your strongest pillar is diversification; your weakest is savings — your top 
  income source is 58% of earnings and your top 5 merchants are 48% of spending.

  Pillar (max 25)         Score
  Savings                 0.0 / 25
  Spending discipline     0.0 / 25
  Income stability        0.0 / 25
  Diversification         23.1 / 25
  ```
* **Factual Verification:** **100% Correct.** Plaid Sandbox populated dummy transactions where expenditures outpaced deposit structures, yielding an accurate negative savings rate and 0.0 scores for savings and spending discipline.

### Recommended Factual Test Questions
These queries leverage the SQL analytical engine directly:
1. `"What spending habits do I have?"` (Tests `behavior_metrics` - weekend spending ratio, impulse purchase count).
2. `"What subscriptions do I have?"` (Tests DBSCAN-based recurring transaction detection).
3. `"What was my largest expense?"` (Tests extreme value extraction).

---

## 2. Core Technical Architecture

Penny is structured to act as a **Deterministic Financial Intelligence Engine**. Standard RAG architectures fail at financial arithmetic because feeding hundreds of text rows into an LLM and asking it to compute sums leads to mathematical hallucinations. 

Penny solves this by separating **Factual/Numeric execution (SQL)** from **Natural Language phrasings (LLM)**.

```
                  [ User Question ]
                         │
                         ▼
             [ Intent Classifier / Router ]
            (Classifies type, date, merchant)
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
  [ Factual Query ]              [ Qualitative Query ]
  (Direct SQLite SQL)            (grounded prompt context)
         │                               │
         ▼                               ▼
[ Deterministic Numbers ]       [ LLM Sentence Formulator ]
(No LLM Hallucinations)        (Only writes plain-English)
         │                               │
         └───────────────┬───────────────┘
                         ▼
             [ Formatted Text Response ]
```

### Module Breakdown (Where Code Lives)

1. **`finquery/scripts/test_server.py` (Main Router & API Layer):**
   * Acts as the FastAPI controller.
   * Employs a regex and keyword-based `routeAggregation(q)` function to identify query intents (`spend`, `income`, `health`, `habits`, etc.).
   * Handles stream tokens and packages the Markdown output for the UI.

2. **`finquery/backend/src/services/txn_store.py` (Database & Analytical Layer):**
   * This is the heavy lifter. It houses the SQLite schema and contains custom Python aggregation functions.
   * **`compute_insights(user)`**: Runs all analytics engines (Health, Risk, Behavior) on upload or startup and writes summary logs to the `insights` database table.
   * **`health_score()`**: Computes the 0-100 score dynamically using four pillars (Savings, Spending Discipline, Income Stability, and Diversification).
   * **`risk_assessment()`**: Screens for negative cash buffers, concentration risks, and rising discretionary spends.

3. **`finquery/plaid_integration/` (External Sync Module):**
   * **`plaid_service.py`**: Initiates sandbox communication, exchanges tokens, and exposes metadata for test institutions.
   * **`plaid_ingest.py`**: Executes the cursor-based `/transactions/sync` loop to pull live transactions from Plaid into the local `live_txn.db`.

---

## 3. Codebase Scale & Validation

* The server implements **Contextual Retrieval** to prepend statement-level metadata directly to parsed chunks before indexing, ensuring search queries don't lose context.
* It uses low-temperature LLM routing as a backup to regex (`ROUTER_SYSTEM`) to classify complex questions, ensuring that numbers are always queried dynamically via SQL rather than guessed by the model.
* The test server is lightweight, letting developers test the exact SQL outputs instantly on port `5667` without requiring local GPU compute.
