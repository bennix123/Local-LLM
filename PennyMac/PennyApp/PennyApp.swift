import SwiftUI

@main
struct PennyApp: App {
    var body: some Scene {
        WindowGroup {
            PennyRootView()
        }
        .windowResizability(.contentSize)
    }
}
