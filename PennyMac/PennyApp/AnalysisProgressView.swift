import SwiftUI
import PennyTxnStore

// Progressive-analysis UI: a professional staged progress card that replaces the
// bare spinner, plus a toast stack for batch-completion messages. Both observe
// AppModel's `analysis` / `toasts` and refresh automatically as batches land.

/// A transient message shown in the toast stack.
struct ToastMessage: Identifiable, Equatable {
    enum Kind: Equatable { case progress, success, warning }
    let id = UUID()
    let text: String
    let kind: Kind

    var icon: String {
        switch kind {
        case .progress: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch kind {
        case .progress: return Theme.sky
        case .success: return Theme.limeD
        case .warning: return Theme.peach
        }
    }
}

/// The staged loader. Shown while `app.isImporting` for a multi-statement run;
/// the single-file path keeps the existing lightweight spinner.
struct AnalysisProgressView: View {
    @EnvironmentObject var app: AppModel

    private var p: AnalysisProgress { app.analysis }
    private var titles: [String] { StatementBatchPlanner.stageTitles(batchesTotal: p.batchesTotal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Analyzing your statements")
                    .font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(p.percent)%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.limeD)
            }

            // Overall percentage bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(0.5)).frame(height: 8)
                    Capsule().fill(Theme.lime)
                        .frame(width: max(8, geo.size.width * p.fraction), height: 8)
                        .animation(.easeInOut(duration: 0.35), value: p.fraction)
                }
            }
            .frame(height: 8)

            // Staged checklist (Reading → Extracting → Analyzing 1–2/3–4/5–6 → Insights).
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                    stageRow(title: title, state: state(forStep: i + 1))
                }
            }

            if p.batchesTotal > 0 {
                Text("Step \(min(p.stepIndex, p.stepCount)) of \(p.stepCount) · \(p.batchesDone)/\(p.batchesTotal) batches — you can start reviewing data as it appears.")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .padding(20)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    private enum StepState { case done, active, pending }
    private func state(forStep step: Int) -> StepState {
        if p.stage == .completed { return .done }
        if step < p.stepIndex { return .done }
        if step == p.stepIndex { return .active }
        return .pending
    }

    @ViewBuilder private func stageRow(title: String, state: StepState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.limeD)
            case .active:
                ProgressView().controlSize(.mini)
            case .pending:
                Image(systemName: "circle").foregroundStyle(Theme.line)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(state == .pending ? Theme.dim : Theme.ink)
                .fontWeight(state == .active ? .semibold : .regular)
            Spacer(minLength: 0)
        }
    }
}

/// Bottom-trailing toast stack. Auto-dismisses (AppModel schedules removal);
/// tap to dismiss early.
struct ToastStack: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(app.toasts) { toast in
                HStack(spacing: 10) {
                    Image(systemName: toast.icon).foregroundStyle(toast.tint)
                    Text(toast.text).font(.subheadline).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 360, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(toast.tint.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .onTapGesture { app.dismissToast(toast.id) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!app.toasts.isEmpty)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.toasts)
    }
}
