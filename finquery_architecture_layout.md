# 🏛️ Architecture Layout: FinQuery Core Services

This document maps out the architecture and design of the core financial querying modules (`txn_store` and `nl_sql_engine`) built and updated in the last 24 hours.

---

## 🗺️ Architectural Structure

The core services are split into a two-layer system: a **Deterministic Data Layer** for parsing and handling ledger interactions, and a **Smart Text-to-SQL Layer** for translating natural language queries safely.

```mermaid
graph TD
    subgraph Client ["Client Interface / API Layer"]
        API["Express/Python Server API Endpoints"]
    end

    subgraph Layer2 ["Smart Translation Layer"]
        NLSQL["nl_sql_engine.py<br/>(Text-to-SQL, Rule-based Engine)"]
    end

    subgraph Layer1 ["Deterministic Data Layer (txn_store)"]
        DISP["dispatcher.py<br/>(Intent Dispatcher)"]
        QRY["queries.py<br/>(SQL Query Helpers)"]
        PARS["parsers.py<br/>(PDF/CSV Statement Parser)"]
        DB["db.py<br/>(SQLite Interface)"]
        FMT["formatters.py<br/>(INR/Period formatting)"]
    end

    subgraph DataStore ["Database Layer"]
        SQLDB[("live_txn.db (SQLite)")]
    end

    %% Flows
    API -->|"NL Queries"| NLSQL
    API -->|"Ingest Statements"| PARS
    
    NLSQL -->|"Execute Generated SQL"| SQLDB
    
    DISP --> QRY
    QRY --> DB
    PARS --> DB
    DB --> SQLDB
    
    classDef layer1 fill:#f9f,stroke:#333,stroke-width:2px;
    classDef layer2 fill:#bbf,stroke:#333,stroke-width:2px;
    classDef datastore fill:#dfd,stroke:#333,stroke-width:2px;
    
    class DB,PARS,QRY,DISP,FMT layer1;
    class NLSQL layer2;
    class SQLDB datastore;
```

---

## 🔄 Sequence: Flow of a Query

```mermaid
sequenceDiagram
    autonumber
    actor Client as Client / API
    participant NL as nl_sql_engine.py
    participant Txn as txn_store (dispatcher)
    participant DB as SQLite Database

    rect rgb(240, 248, 255)
        note right of NL: Strict Ledger Query (Text-to-SQL Flow)
        Client->>NL: "What is my largest transaction in June?"
        NL->>NL: Step 1: Detect intent & match columns
        NL->>NL: Step 2: Generate Safe SQL Query
        NL->>DB: Step 3: Run generated SQL query
        DB-->>NL: Query Results (exact rows/amount)
        NL-->>Client: Step 4: Format and Explain (Strict ledger values)
    end
```

---

## 📦 Service Breakdown & Functionality

### 1. **Modular In-Memory Transaction Store (`txn_store/`)**
A modular subpackage managing parsing, deterministic calculations, formatting, and DB interaction.
* **[db.py](file:///c:/Users/akash/OneDrive/Desktop/thegradnew/finquery/backend/src/services/txn_store/db.py)**: SQLite database setup and transaction connection lifecycle.
* **[parsers.py](file:///c:/Users/akash/OneDrive/Desktop/thegradnew/finquery/backend/src/services/txn_store/parsers.py)**: Statement parsers for bank statements (Barclays, PNB, Wrenfield, generic PDFs) using regex and spatial text boundaries.
* **[queries.py](file:///c:/Users/akash/OneDrive/Desktop/thegradnew/finquery/backend/src/services/txn_store/queries.py)**: Standard SQL analytics queries (monthly trends, merchant aggregation, extreme debit/credit spikes, subscriptions).
* **[dispatcher.py](file:///c:/Users/akash/OneDrive/Desktop/thegradnew/finquery/backend/src/services/txn_store/dispatcher.py)**: Matches natural language queries directly to predefined analytical python functions when strict output rules are required.
* **[formatters.py](file:///c:/Users/akash/OneDrive/Desktop/thegradnew/finquery/backend/src/services/txn_store/formatters.py)**: Formatting utilities for localized currencies, tables, percentages, and normalized monthly date periods.

### 2. **Rule-Based Text-to-SQL Translator (`nl_sql_engine.py`)**
* **Strict Safety Rails**: Zero hallucination design. Avoids generative LLM math by translating statements directly into secure SQL parameters.
* **Metadata Extraction**: Automatically parses bank profiles, IFSC, Swift, account holders, and start/end dates from PDF text boundaries and upserts them to the `account_profile` table.
* **Core Loop**: Matches tokenized intents -> translates to parameterized SQL statements -> executes locally on SQLite -> constructs natural explanations based *strictly* on returned SQL values.
