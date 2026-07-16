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
let question = args.first ?? "What is the largest expense in this statement?"

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

print("[mlx] loading \(modelID) (first run downloads the weights) …")
let llm = PennyLLM(modelID: modelID)

try await llm.load { p in
    FileHandle.standardOutput.write(Data("\r[load] \(Int(p * 100))%   ".utf8))
}
print("\n[mlx] ready")

print("\n[Q] \(question)")
print("[A] ", terminator: "")
let answer = try await llm.ask(question: question, statementText: statement) { piece in
    FileHandle.standardOutput.write(Data(piece.utf8))
}
print("\n\n[done] \(answer.count) chars generated on-device via MLX")
