// ColumnMappingSheetIOS — the "help me map this" fallback UI (Fix 2), iOS.
//
// Shown when a CSV won't auto-parse: the user assigns each role a column, then
// the canonical builder parses it exactly like a recognized format.
import SwiftUI
import PennyTxnStore

struct ColumnMappingSheetIOS: View {
    @EnvironmentObject var model: IOSModel
    let pending: IOSModel.PendingMapping
    @State private var mapping: [String: Int]

    init(pending: IOSModel.PendingMapping) {
        self.pending = pending
        _mapping = State(initialValue: pending.analysis.suggested)
    }

    private var headers: [String] { pending.analysis.headers }
    private var complete: Bool { CSVMapper.isComplete(mapping) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Penny couldn't auto-read \(pending.name). Tell it which column is which.")
                        .font(T.body(13)).foregroundStyle(T.dim)
                }
                Section("Preview") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            previewRow(headers, bold: true)
                            ForEach(Array(pending.analysis.sampleRows.enumerated()), id: \.offset) { _, r in
                                previewRow(r, bold: false)
                            }
                        }
                    }
                }
                Section("Columns") {
                    ForEach(CSVMapper.assignableRoles, id: \.self) { role in
                        Picker(CSVMapper.displayName(role), selection: binding(for: role)) {
                            Text("— none —").tag(-1)
                            ForEach(0..<headers.count, id: \.self) { i in
                                Text(headers[i].isEmpty ? "Column \(i + 1)" : headers[i]).tag(i)
                            }
                        }
                    }
                }
                if !complete {
                    Section {
                        Label("Pick a Date column and one money column (Amount, or Money out / Money in).",
                              systemImage: "info.circle")
                            .font(T.body(12)).foregroundStyle(T.dim)
                    }
                }
            }
            .navigationTitle("Map statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { model.cancelMapping() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") { model.confirmMapping(mapping) }.disabled(!complete)
                }
            }
        }
    }

    private func previewRow(_ cells: [String], bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<headers.count, id: \.self) { i in
                Text(i < cells.count ? cells[i] : "")
                    .font(bold ? T.body(11, .bold) : T.mono(10))
                    .foregroundStyle(bold ? T.ink : T.dim)
                    .lineLimit(1).frame(width: 100, alignment: .leading)
            }
        }
    }

    private func binding(for role: String) -> Binding<Int> {
        Binding(get: { mapping[role] ?? -1 },
                set: { mapping[role] = $0 < 0 ? nil : $0 })
    }
}
