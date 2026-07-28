import SwiftUI

/// Top-level router — the SwiftUI analogue of `App.jsx`'s <Routes>.
/// onboarding → modelPicker (mandatory) → dashboard.
struct PennyRootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        Group {
            switch app.stage {
            case .onboarding:  OnboardingView()
            case .modelPicker: ModelPickerView()
            case .dashboard:   DashboardView()
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        // Progressive multi-statement analysis: a non-blocking staged card (the
        // rest of the UI stays interactive so users can review data as it lands),
        // plus the toast stack. Both auto-hide when idle.
        .overlay(alignment: .top) {
            if app.isImporting && app.analysis.batchesTotal > 1 {
                AnalysisProgressView()
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay { ToastStack() }
        .animation(.easeInOut(duration: 0.25), value: app.isImporting)
        .animation(.easeInOut(duration: 0.2), value: app.stage)
        .onAppear {
            TestWindowFix.applyIfTesting()
            AXAudit.runIfRequested()
        }
        // The whole design is a light, warm theme. Pin it to light so default
        // controls (e.g. the chat TextField's text) don't render white-on-cream
        // when the user's Mac is in Dark Mode.
        .preferredColorScheme(.light)
        // Inject the model LAST so it covers the routed content *and* both
        // overlays. Overlay content is a sibling of the modified view, not a
        // descendant — putting `.environmentObject` earlier leaves ToastStack /
        // AnalysisProgressView without `app` and traps at launch.
        .environmentObject(app)
    }
}

#Preview {
    PennyRootView()
}
