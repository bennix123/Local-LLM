// ColumnMappingSheet — the "help me map this" fallback UI (Fix 2), macOS.
//
// Shown when a CSV won't auto-parse: preview the columns and let the user say
// which is the date, the amount, the description. On confirm, the canonical
// builder parses it exactly like a recognized format. No guessing, no wrong
// rows — the user resolves the ambiguity once.
import SwiftUI
import PennyTxnStore

struct ColumnMappingSheet: View {
    @EnvironmentObject var app: AppModel
    let pending: AppModel.PendingMapping
    @State private var mapping: [String: Int]

    init(pending: AppModel.PendingMapping) {
        self.pending = pending
        _mapping = State(initialValue: pending.analysis.suggested)
    }

    private var headers: [String] { pending.analysis.headers }
    private var complete: Bool { CSVMapper.isComplete(mapping) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    assignments
                }
                .padding(18)
            }
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 560, height: 560)
        .background(Theme.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Map this statement").font(Theme.serif(17, .heavy)).foregroundStyle(Theme.ink)
            Text("Penny couldn't auto-read \(pending.name). Tell it which column is which.")
                .font(Theme.font(11, .medium)).foregroundStyle(Theme.dim)
        }
        .padding(18)
    }

    // A small grid preview of the header + a few data rows.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREVIEW").font(Theme.mono(9, .bold)).foregroundStyle(Theme.dim)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    gridRow(headers, bold: true)
                    ForEach(Array(pending.analysis.sampleRows.enumerated()), id: \.offset) { _, row in
                        gridRow(row, bold: false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
        }
    }

    private func gridRow(_ cells: [String], bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<headers.count, id: \.self) { i in
                Text(i < cells.count ? cells[i] : "")
                    .font(bold ? Theme.font(11, .bold) : Theme.mono(10, .medium))
                    .foregroundStyle(bold ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
            }
        }
        .background(bold ? Theme.card : Theme.bg)
    }

    // One picker per assignable role.
    private var assignments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COLUMNS").font(Theme.mono(9, .bold)).foregroundStyle(Theme.dim)
            ForEach(CSVMapper.assignableRoles, id: \.self) { role in
                HStack {
                    Text(CSVMapper.displayName(role))
                        .font(Theme.font(12, .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: binding(for: role)) {
                        Text("— none —").tag(-1)
                        ForEach(0..<headers.count, id: \.self) { i in
                            Text(headers[i].isEmpty ? "Column \(i + 1)" : headers[i]).tag(i)
                        }
                    }
                    .labelsHidden()
                }
            }
            if !complete {
                Label("Pick at least a Date column and one money column (Amount, or Money out / Money in).",
                      systemImage: "info.circle")
                    .font(Theme.font(10.5, .medium)).foregroundStyle(Theme.dim)
            }
        }
    }

    private func binding(for role: String) -> Binding<Int> {
        Binding(get: { mapping[role] ?? -1 },
                set: { mapping[role] = $0 < 0 ? nil : $0 })
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { app.cancelMapping() }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
            Spacer()
            Button {
                app.confirmMapping(mapping)
            } label: {
                Text("Use these columns").font(Theme.font(12, .bold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(complete ? Theme.lime : Theme.card,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.ink, lineWidth: 1.5))
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .disabled(!complete)
        }
        .padding(18)
    }
}
