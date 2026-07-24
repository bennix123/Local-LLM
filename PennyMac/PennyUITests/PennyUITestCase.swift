import XCTest
import AppKit

/// Base class for Penny UI tests: launches the app with the `--uitest` hooks
/// (see PennyApp/TestMode.swift) so tests never touch real user data, never
/// download model weights, and can import fixture statements without driving
/// the sandboxed NSOpenPanel.
class PennyUITestCase: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: repo paths (compile-time, so tests run from any cwd)

    /// …/Penny repo root — derived from PennyMac/PennyUITests/PennyUITestCase.swift.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PennyUITests
        .deletingLastPathComponent()   // PennyMac
        .deletingLastPathComponent()   // Penny

    static let fixturesDir = repoRoot.appendingPathComponent("finquery/contract/fixtures")
    static let testDataDir = repoRoot.appendingPathComponent("test-data")

    /// The sandboxed app's own tmp dir. The (unsandboxed) test runner copies
    /// fixtures here so the app is allowed to read them by plain path.
    static let appContainerTmp = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.localbankrag.app/Data/tmp", isDirectory: true)

    /// Copy a fixture PDF into the app container and return the in-container path.
    static func stageFixture(_ source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: appContainerTmp, withIntermediateDirectories: true)
        let dest = appContainerTmp.appendingPathComponent("uitest-\(source.lastPathComponent)")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    // MARK: launching

    /// Launch Penny with the UI-test hooks.
    /// - Parameters:
    ///   - modelReady: mark the model phase ready + stub chat's MLX fallback
    ///   - dashboard: skip onboarding/model-picker, open the main shell
    ///   - importFixture: fixture filename (from `fixturesDir` unless an
    ///     absolute-path URL is given via `importURL`) imported at launch
    @discardableResult
    func launchPenny(modelReady: Bool = true,
                     dashboard: Bool = false,
                     importFixture: String? = nil,
                     importURL: URL? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--uitest"]
        if modelReady { args.append("--uitest-model-ready") }
        if dashboard { args.append("--uitest-dashboard") }
        if let importURL {
            let staged = try Self.stageFixture(importURL)
            app.launchEnvironment["PENNY_UITEST_IMPORT"] = staged.path
        } else if let importFixture {
            let staged = try Self.stageFixture(Self.fixturesDir.appendingPathComponent(importFixture))
            app.launchEnvironment["PENNY_UITEST_IMPORT"] = staged.path
        }
        app.launchArguments = args
        app.launch()
        // macOS cooperative activation can leave a background-launched app's
        // window visible but NEVER key — key-event synthesis (typeText) then
        // times out waiting for focus. Activate explicitly and give Launch
        // Services a beat to hand over frontmost status.
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        lastLaunchedApp = app
        return app
    }

    /// The most recently launched app — used by `typeInto` to re-assert
    /// frontmost status right before synthesizing key events.
    private(set) var lastLaunchedApp: XCUIApplication?

    // MARK: waiting helpers

    /// Assert an element exists within `timeout`, then return it.
    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10,
                 _ message: String? = nil,
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      message ?? "Timed out waiting for \(element)", file: file, line: line)
        return element
    }

    /// Wait until `predicate` holds for `object` (polling via expectations).
    func waitUntil(_ predicate: NSPredicate, on object: Any, timeout: TimeInterval = 10,
                   file: StaticString = #filePath, line: UInt = #line) {
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: object)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, "Timed out waiting for \(predicate)", file: file, line: line)
    }

    /// First static text whose OWN label — or AX value, which is where SwiftUI
    /// surfaces some Texts' strings — contains `substring`.
    /// (`.matching`, not `.containing` — the latter filters on descendants and
    /// never matches leaf text elements.)
    func staticText(in app: XCUIApplication, containing substring: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", substring, substring)
        ).firstMatch
    }

    /// Wait for a control containing `substring` in its label or value, checking
    /// BOTH buttons and static texts: SwiftUI plain-style buttons often expose
    /// only a button element (no static-text child), and styled Texts sometimes
    /// surface their string as the AX value.
    @discardableResult
    func waitForControl(in app: XCUIApplication, containing substring: String,
                        timeout: TimeInterval = 10, _ message: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let p = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", substring, substring)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let b = app.buttons.matching(p).firstMatch
            if b.exists { return b }
            let t = app.staticTexts.matching(p).firstMatch
            if t.exists { return t }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        XCTFail(message ?? "No control containing '\(substring)' appeared within \(Int(timeout))s",
                file: file, line: line)
        return app.buttons.matching(p).firstMatch
    }

    /// Click `field`, type `text`, and verify it landed — macOS `typeText` can
    /// drop keystrokes while focus settles, so verify and retry.
    ///
    /// NEVER synthesize modifier-key chords here: a latched ⌘ from
    /// `typeKey(_:modifierFlags:)` turns typed letters into app shortcuts —
    /// "how…" became ⌘H and HID the app mid-suite, cascading into event and
    /// snapshot timeouts for every later test.
    func typeInto(_ field: XCUIElement, _ text: String,
                  file: StaticString = #filePath, line: UInt = #line) {
        // Deliberately RAW: click, brief settle, type, verify. This exact form
        // is proven to deliver keystrokes into SwiftUI TextFields here; extra
        // "robustness" (focus-predicate polling between click and typeText,
        // NSRunningApplication activation dances, ⌘A clears) each broke
        // delivery in a different way. Keep it simple; retry on mismatch.
        for _ in 0..<3 {
            field.click()
            usleep(400_000)
            field.typeText(text)
            usleep(250_000)   // let the binding catch up before verifying
            if (field.value as? String) == text { return }
            // partial/failed attempt: clear with plain backspaces and retry
            if let current = field.value as? String, !current.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                      count: current.count + 2))
            }
        }
        XCTAssertEqual(field.value as? String, text,
                       "typed text never landed intact after 3 attempts",
                       file: file, line: line)
    }
}
