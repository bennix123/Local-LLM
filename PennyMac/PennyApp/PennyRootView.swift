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
        .environmentObject(app)
        .frame(minWidth: 900, minHeight: 620)
        .animation(.easeInOut(duration: 0.2), value: app.stage)
        // The whole design is a light, warm theme. Pin it to light so default
        // controls (e.g. the chat TextField's text) don't render white-on-cream
        // when the user's Mac is in Dark Mode.
        .preferredColorScheme(.light)
    }
}

#Preview {
    PennyRootView()
}
