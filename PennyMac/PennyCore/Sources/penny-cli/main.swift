import Foundation
import PennyCore

// penny-cli — terminal proof of the vertical slice:
//   load MLX model → (optional) read a PDF → one question → streamed on-device answer.
//
// Usage:
//   penny-cli [--model <hf-id>] [--pdf <path>] ["question"]

var args = Array(CommandLine.arguments.dropFirst())
var modelID = PennyLLM.sliceModelID
var pdfPath: String?

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

if let m = take("--model") { modelID = m }
if let p = take("--pdf") { pdfPath = p }
let issuerMode = args.firstIndex(of: "--issuer").map { args.remove(at: $0); return true } ?? false
let chatOnly = args.firstIndex(of: "--chat-only").map { args.remove(at: $0); return true } ?? false
let question = args.first ?? "What is the largest expense in this statement?"

// --issuer: just run the on-device issuer classifier and print the result.
if issuerMode {
    guard let pdfPath else { print("--issuer needs --pdf <path>"); exit(1) }
    let text = try StatementText.extract(from: URL(fileURLWithPath: pdfPath))
    print("[pdf] \(pdfPath): \(text.count) chars")
    print("[mlx] loading \(modelID) …")
    let llm = PennyLLM(modelID: modelID)
    try await llm.load { p in FileHandle.standardOutput.write(Data("\r[load] \(Int(p.fraction*100))%   ".utf8)) }
    print("\n[mlx] ready")
    let issuer = try await llm.detectIssuer(from: text)
    print("[issuer] -> \(issuer.map { "\"\($0)\"" } ?? "nil")")
    exit(0)
}

let statement: String
if let pdfPath {
    statement = try StatementText.extract(from: URL(fileURLWithPath: pdfPath))
    print("[pdf] \(pdfPath): \(statement.count) chars extracted")
} else {
    statement = """
    --- page 1 ---
    Date        Description              Debit      Credit     Balance
    2026-06-01  OPENING BALANCE                                 52,400.00
    2026-06-03  BigBasket Groceries      2,150.00               50,250.00
    2026-06-07  Uber Rides                 640.00               49,610.00
    2026-06-12  SALARY ACME PVT LTD                 85,000.00  134,610.00
    2026-06-15  Rent June               30,000.00              104,610.00
    2026-06-21  BigBasket Groceries      1,890.00              102,720.00
    2026-06-28  Netflix                    649.00              102,071.00
    """
    print("[pdf] no --pdf given — using built-in sample statement")
}

let llm = PennyLLM(modelID: modelID)

// --chat-only: exercise the app's real chat path — PennyLLM.ask, which prefers
// Apple's on-device model (no MLX preload, no weights download, no Metal) — and
// time streaming latency (first-token vs total). This is the faithful end-to-end
// test of the streaming path without pulling gigabytes of MLX weights.
if chatOnly {
    print("\n[Q] \(question)")
    print("[A] ", terminator: "")
    let start = Date()
    var ttft: Double? = nil
    let answer = try await llm.ask(question: question, statementText: statement, maxTokens: 512) { piece in
        if ttft == nil { ttft = Date().timeIntervalSince(start) * 1000 }
        FileHandle.standardOutput.write(Data(piece.utf8))
    }
    let total = Date().timeIntervalSince(start) * 1000
    print(String(format: "\n\n[timing] first-token = %.0f ms · total = %.0f ms · %d chars",
                 ttft ?? -1, total, answer.count))
    exit(0)
}

print("[mlx] loading \(modelID) (first run downloads the weights) …")
try await llm.load { p in
    FileHandle.standardOutput.write(Data("\r[load] \(Int(p.fraction * 100))%   ".utf8))
}
print("\n[mlx] ready")

print("\n[Q] \(question)")
print("[A] ", terminator: "")
let answer = try await llm.ask(question: question, statementText: statement) { piece in
    FileHandle.standardOutput.write(Data(piece.utf8))
}
print("\n\n[done] \(answer.count) chars generated on-device via MLX")
