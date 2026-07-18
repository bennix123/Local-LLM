# 🏦 Penny RAG Engine: Node/Electron to Native Swift + MLX Migration Manual

This manual provides an exhaustive, component-by-component migration blueprint for porting the **Penny/Local Bank Statement RAG Assistant** from its current Node.js/Electron/Express architecture to a **fully native iOS/macOS Swift + Apple MLX architecture** that is fully compliant with Apple's App Sandbox and App Store guidelines.

---

## 1. Core Structural Changes (Pahle Kya Tha vs. Abhi Kya Hoga)

### 1.1 App Shell & Window Management
*   **Pahle Kya Tha (`electron/main.js`)**: An Electron process that spun up a child process for a Node/Express server on port 3000, polled `/api/state` until ready, and then opened a chromium-based `BrowserWindow` loading `http://localhost:3000`.
*   **Abhi Kya Hoga (`SwiftUI App Entry`)**: A native Swift application lifecycle using SwiftUI's `@main` and App structures. The UI reads app state directly in-process; no child processes, no chromium runtime, and no local network ports are used.
*   **How it translates**:
    ```swift
    // Native Swift App Entry Point (App.swift)
    import SwiftUI

    @main
    struct PennyApp: App {
        @StateObject private var appState = AppState() // Replaces polling /api/state
        
        var body: some Scene {
            WindowGroup {
                MainContainerView()
                    .environmentObject(appState)
                    .frame(minWidth: 1000, minHeight: 700)
            }
            .windowStyle(.hiddenTitleBar)
        }
    }
    ```

### 1.2 Local Web Server (Express)
*   **Pahle Kya Tha (`server.js`)**: An Express.js server exposing REST endpoints (`/api/state`, `/api/upload`, `/api/chat`, etc.) and using `multer` to handle multipart statement uploads.
*   **Abhi Kya Hoga**: **Removed completely**. The SwiftUI interface triggers file ingestion, database queries, and inference engines directly via in-process method calls.

---

## 2. Ingestion & Document Parsing Layer

The ingestion layer extracts structured columns and unstructured chunks from statements (PDF, CSV, Excel).

### 2.1 PDF Ingestion
*   **Pahle Kya Tha (`src/ingest.js` using `pdf-parse`)**:
    ```javascript
    // JS Version
    import pdf from "pdf-parse";
    const data = await pdf(fileBuffer);
    const rawLines = data.text.split("\n").filter(l => l.trim());
    ```
*   **Abhi In Swift (using `PDFKit`)**:
    ```swift
    // Swift Version
    import PDFKit

    func parsePDF(url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        var lines: [String] = []
        
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string {
                let pageLines = text.components(separatedBy: .newlines)
                lines.append(contentsOf: pageLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            }
        }
        return lines
    }
    ```

### 2.2 CSV & Excel Ingestion
*   **Pahle/Current**: CSV is parsed via `papaparse` and Excel via `xlsx` (SheetJS) into JSON rows.
*   **Update Path**: Use macOS/iOS native `TabularData` for CSV. For Excel support, import `CoreXLSX` or read `.csv` exports.
    ```swift
    import TabularData

    func parseCSV(url: URL) throws -> [TransactionRecord] {
        let options = CSVReadingOptions(hasHeaderRow: true, delimiter: ",")
        let dataframe = try DataFrame(contentsOfCSVFile: url, options: options)
        
        var records: [TransactionRecord] = []
        for row in dataframe.rows {
            // Map dataframe columns to TransactionRecord struct
        }
        return records
    }
    ```

---

## 3. Database & Vector Search Layer

### 3.1 SQLite & FTS5
*   **Pahle Kya Tha (`src/db.js` using `node:sqlite`)**: Sets up a local SQLite database (`data/bank.db`) in WAL mode, with an FTS5 virtual table for keyword search.
*   **Abhi In Swift (using `GRDB`)**:
    ```swift
    import GRDB

    class DatabaseManager {
        let dbQueue: DatabaseQueue

        init(path: String) throws {
            var config = Configuration()
            config.prepareDatabase { db in
                try db.useWALMode() // WAL Mode matching original config
            }
            self.dbQueue = try DatabaseQueue(path: path, configuration: config)
            try setupTables()
        }

        private func setupTables() throws {
            try dbQueue.write { db in
                // Transactions table
                try db.create(table: "transactions", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("txn_date", .text).indexed()
                    t.column("descr", .text)
                    t.column("merchant", .text).indexed()
                    t.column("category", .text).indexed()
                    t.column("debit", .double)
                    t.column("credit", .double)
                    t.column("balance", .double)
                }

                // FTS5 Virtual Table for searching transactions
                try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transactions_fts USING fts5(
                    descr, merchant, category, content='transactions', content_rowid='id'
                );
                """)
            }
        }
    }
    ```

### 3.2 Vector Search & Cosine Similarity
*   **Pahle/Current**: Chunks are stored in ChromaDB or embedded locally via ONNX. Brute-force cosine matching retrieves indices.
*   **Update Path**: Native vector retrieval stores embeddings directly in a SQLite BLOB column and performs cosine calculations using Apple's highly-optimized hardware routines inside the **Accelerate framework**.
    ```swift
    import Accelerate

    func calculateCosineSimilarity(v1: [Float], v2: [Float]) -> Float {
        var dotProduct: Float = 0.0
        var normV1: Float = 0.0
        var normV2: Float = 0.0
        
        let length = vDSP_Length(v1.count)
        
        vDSP_dotpr(v1, 1, v2, 1, &dotProduct, length)
        vDSP_svesq(v1, 1, &normV1, length)
        vDSP_svesq(v2, 1, &normV2, length)
        
        return dotProduct / (sqrt(normV1) * sqrt(normV2))
    }
    ```

---

## 4. Local AI & Embedding Engine (The JIT Blocker Fix)

`node-llama-cpp` must be completely replaced to comply with App Store rules. 

### 4.1 LLM Loading & Inference Queue
*   **Pahle Kya Tha (`src/llm.js`)**: Loaded GGUF models dynamically via llama.cpp JIT compiling, using a Promise Queue to chain prompt calls sequentially.
*   **Abhi In Swift (using Apple `mlx-swift`)**:
    We use the Apple-native `mlx-swift` package which leverages Unified Memory and Metal Performance Shaders (MPS) natively.

    ```swift
    import MLX
    import MLXLMHelper

    class LocalLLMEngine: ObservableObject {
        private var model: LLMModel?
        private let serialQueue = DispatchQueue(label: "com.penny.inference") // Replaces promise queue

        func loadModel(named modelDir: String) async throws {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelURL = appSupport.appendingPathComponent("models/\(modelDir)")
            
            // MLX native loader
            let loadedModel = try await LLMModel.load(from: modelURL)
            DispatchQueue.main.async {
                self.model = loadedModel
            }
        }

        func ask(prompt: String, onToken: @escaping (String) -> Void) {
            serialQueue.async {
                guard let model = self.model else { return }
                
                Task {
                    do {
                        // Stream tokens via MLX generator loop
                        for try await token in model.generate(prompt: prompt, maxTokens: 512) {
                            DispatchQueue.main.async {
                                onToken(token)
                            }
                        }
                    } catch {
                        print("Inference error: \(error)")
                    }
                }
            }
        }
    }
    ```

---

## 5. RAG Logic, Period Summaries & Analytics

The core computational logic (`analytics.js`, `periods.js`, `stats.js`) translates directly from JavaScript arrays to Swift types.

### 5.1 Hierarchical Period Summaries
*   **Logic**: Instead of processing raw transactional rows, pre-aggregate historical intervals into rolling 1, 3, 6, 9, and 12-month summaries containing exact numerical metrics and qualitative LLM narratives.
*   **Swift Translation**:
    ```swift
    struct PeriodSummary: Codable {
        let periodKey: String // YYYY-MM
        let windowMonths: Int // 1, 3, 6, etc.
        let totalIncome: Double
        let totalSpending: Double
        let netSavings: Double
        let transactionCount: Int
        let topCategory: String
        let qualitativeNarrative: String // LLM generated summary
    }

    class PeriodSummarizer {
        func buildPeriods(records: [TransactionRecord]) -> [PeriodSummary] {
            // Analytical grouping logic ported directly from src/periods.js
            // Calculates rolling windows and compiles summary metrics
            return []
        }
    }
    ```

### 5.2 Deterministic Number Parser
*   **Pahle Kya Tha (`src/stats.js` -> `toNumber`)**:
    ```javascript
    function toNumber(raw) {
      if (!raw) return 0;
      let s = String(raw).trim().replace(/[₹$,()]/g, "");
      // Handles brackets for negative accounting numbers
      if (raw.includes("(") && raw.includes(")")) s = "-" + s;
      return parseFloat(s) || 0;
    }
    ```
*   **Abhi In Swift**:
    ```swift
    func parseNumber(from raw: String?) -> Double {
        guard let raw = raw, !raw.isEmpty else { return 0.0 }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "[₹$,]", with: "", options: .regularExpression)
        
        let isNegative = cleaned.hasPrefix("(") && cleaned.hasSuffix(")")
        if isNegative {
            cleaned = cleaned.replacingOccurrences(of: "[()]", with: "", options: .regularExpression)
        }
        
        let value = Double(cleaned) ?? 0.0
        return isNegative ? -value : value;
    }
    ```

---

## 6. User Interface Layer (Web View to SwiftUI)

The Web Single Page Application (HTML/CSS/JS) is ported to a modern, fluid macOS/iOS native SwiftUI dashboard.

*   **Pahle/Current**: `public/index.html` + `public/app.js` using cards and HTML streams.
*   **Abhi In Swift**:
    ```swift
    import SwiftUI

    struct MainDashboardView: View {
        @EnvironmentObject var appState: AppState
        @State private var chatMessage: String = ""

        var body: some View {
            HSplitView {
                // Left Panel: Ingestion & Stats Overview
                VStack(spacing: 20) {
                    if appState.isDocumentUploaded {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Statement Active: \(appState.fileName)")
                                .font(.headline)
                            Text("Total Income: \(appState.totalIncome, format: .currency(code: "INR"))")
                            Text("Total Spending: \(appState.totalSpending, format: .currency(code: "INR"))")
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                    } else {
                        Button("Upload Bank Statement") {
                            triggerFilePicker()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(width: 300)
                .padding()

                // Right Panel: AI Assistant Chat area
                VStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(appState.messages) { msg in
                                ChatMessageBubble(message: msg)
                            }
                        }
                        .padding()
                    }
                    
                    HStack {
                        TextField("Ask about your finances...", text: $chatMessage)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {
                            appState.sendMessage(chatMessage)
                            chatMessage = ""
                        }
                    }
                    .padding()
                }
            }
        }
        
        private func triggerFilePicker() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf, .commaSeparatedText]
            if panel.runModal() == .OK, let url = panel.url {
                appState.ingestFile(at: url)
            }
        }
    }
    ```

---

## 7. Migration Verification & Testing Plan

To ensure no regression in capabilities or calculation accuracy, validation must be performed at every stage of the migration:

1.  **Ingestion Verification**: Check that parsing HDFC/SBI statements via native `PDFKit` results in identical row arrays as the legacy JavaScript `pdf-parse` system.
2.  **Deterministic Match Checks**: Run queries in SwiftUI against the GRDB database layer and verify that computed values for `Largest Debit` and category balances exactly match the output of the Python test engine (`test_server.py`).
3.  **App Store Validation Test**: Run validation command tools on the compiled native `.app` output to verify no illegal JIT or unsigned executable entitlements are used:
    ```bash
    codesign -d --entitlements :- /path/to/Penny.app
    ```
