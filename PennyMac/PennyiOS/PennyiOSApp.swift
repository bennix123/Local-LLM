// Penny for iOS — same brain as the Mac app (PennyCore: deterministic parsers,
// FinanceRouter, on-device model), wearing the penny_final_1 mockup's design:
// cream ground, lime accent, serif display, chat at the centre of a 4-tab shell.
import SwiftUI

@main
struct PennyiOSApp: App {
    @StateObject private var model = IOSModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.onboarded && model.hasData {
                    RootTabs()
                } else {
                    OnboardingFlow()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.light)   // the cream/lime identity is light-committed
            .tint(T.limeDeep)
        }
    }
}
