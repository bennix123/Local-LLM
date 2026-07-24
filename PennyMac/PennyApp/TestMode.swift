import Foundation

/// Launch-argument hooks for XCUITest runs — every flag is inert in a normal
/// launch, so shipping behaviour is untouched.
///
/// Why these exist:
/// - The app is sandboxed, so UI tests can't reliably drive the out-of-process
///   NSOpenPanel (powerbox). `PENNY_UITEST_IMPORT` imports a statement directly.
/// - A real model load downloads multi-GB weights; `--uitest-model-ready` marks
///   the model phase ready and stubs generation so chat's MLX path is testable.
/// - The Debug build shares its sandbox container (bundle id) with the installed
///   app, so in test mode nothing may persist: user name stays in-memory and
///   chat history is written to a per-process temp file instead.
enum TestMode {
    /// Master switch — all other hooks require it. The env form exists for
    /// HOSTED unit tests (PennyTests): Xcode launches the host app with the
    /// scheme's test environment, not custom launch arguments, and those tests
    /// must also never persist into the real container.
    static let active = ProcessInfo.processInfo.arguments.contains("--uitest")
        || ProcessInfo.processInfo.environment["PENNY_UITEST"] == "1"

    /// Pretend the selected model is downloaded + loaded; `send()` answers the
    /// MLX fallback path with a deterministic stub instead of running MLX.
    /// The env form serves HOSTED tests (scheme test environment — no launch
    /// arguments), so stress tests can exercise the fallback without a model.
    static let modelReady = active && (
        ProcessInfo.processInfo.arguments.contains("--uitest-model-ready")
        || ProcessInfo.processInfo.environment["PENNY_UITEST_MODEL_READY"] == "1")

    /// Skip straight to the dashboard (with `modelReady`), for shell/chat tests
    /// that don't re-walk onboarding.
    static let startAtDashboard = active && ProcessInfo.processInfo.arguments.contains("--uitest-dashboard")

    /// Absolute path of a statement PDF to import on launch (the UI test runner
    /// copies the fixture somewhere this sandboxed process can read — its own
    /// container tmp — and passes the path here).
    static let importPath: String? = {
        guard active else { return nil }
        return ProcessInfo.processInfo.environment["PENNY_UITEST_IMPORT"]
    }()

    /// The canned reply used for chat's model fallback when `modelReady` is on.
    static let stubReplyPrefix = "PENNY-STUB-REPLY"

    /// Freeze the decorative repeat-forever animations (pulsing dots, floating
    /// mascot, typing shimmer) during UI tests: XCUITest waits for the app to
    /// quiesce before every synthesized event and snapshot, and an app that
    /// animates forever never quiesces — events and queries then time out.
    static var freezeAnimations: Bool { active }
}
