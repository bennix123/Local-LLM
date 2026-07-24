import XCTest

/// Guards the mandatory "Choose your AI model" screen (ModelPickerView): the full
/// 4-entry MLX catalog (names, HF repo ids, size/RAM tags, notes), the header and
/// the "must choose a model" footer, machine-adaptive RAM-fit warnings computed
/// from THIS Mac's physical memory with the same formula as AppModel.deviceRAMGB,
/// the "← back to start" return path to the onboarding welcome, and the ready-state
/// fast path — with `--uitest-model-ready` the pre-selected default (Llama 3.2 3B)
/// must show "in use ✓" / "In use ✓ · Continue →" and continue straight to the
/// dashboard shell with no download UI. SAFETY: these tests only ever click the
/// ready-state continue button; "Use this model" on a non-ready card would start
/// a real multi-GB weights download, so no test clicks it, ever.
final class ModelPickerUITests: PennyUITestCase {

    // MARK: - Catalog mirror

    /// UI tests run in a separate process and can't import PennyCore, so the
    /// catalog is mirrored here. Must stay in sync with
    /// PennyCore/Sources/PennyCore/PennyLLM.swift `PennyLLM.catalog`.
    private struct CatalogModel {
        let name: String
        let id: String
        let size: String
        let minRAMGB: Int
        let note: String
    }

    private static let catalog: [CatalogModel] = [
        .init(name: "Llama 3.1 8B", id: "mlx-community/Llama-3.1-8B-Instruct-4bit",
              size: "4.5 GB", minRAMGB: 16, note: "Best reasoning · recommended"),
        .init(name: "Qwen 2.5 7B", id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
              size: "4.3 GB", minRAMGB: 16, note: "Strong all-rounder"),
        .init(name: "Llama 3.2 3B", id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
              size: "1.8 GB", minRAMGB: 8, note: "Balanced · low memory"),
        .init(name: "Qwen 2.5 3B", id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
              size: "1.7 GB", minRAMGB: 8, note: "Fast · lightest"),
    ]

    /// `PennyLLM.sliceModelID` — the pre-selected default the app boots with.
    private static let defaultModelName = "Llama 3.2 3B"

    /// Same formula as `AppModel.deviceRAMGB`, evaluated in the TEST process.
    /// The test runner and the app run on the same Mac, so the values must agree.
    private static let deviceRAMGB =
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

    // MARK: - UI strings (verbatim from the SwiftUI sources)

    private static let headerText = "Choose your AI model"
    private static let subheaderLead = "A required first step"
    private static let footerNote = "You must choose a model before opening the app."
    private static let welcomeCTA = "Let's set up →"
    private static let skipToPicker = "skip → choose model"
    private static let backToStart = "← back to start"
    private static let useModelLabel = "Use this model"       // NEVER clicked (real download)
    private static let readyButtonLabel = "In use ✓ · Continue →"
    private static let readyBadge = "in use ✓"
    private static let dashboardMarker = "PENNY'S BRAIN"      // sidebar brain panel = dashboard shell

    // MARK: - Helpers

    /// Number of elements whose label is exactly `label`. SwiftUI sometimes exposes
    /// a plain-style Button as a button, sometimes only its inner text — and when it
    /// exposes both, each query sees the same cards, so `max` (not the sum) is right.
    private func exactCount(_ app: XCUIApplication, _ label: String) -> Int {
        let p = NSPredicate(format: "label == %@ OR value == %@", label, label)
        return max(app.buttons.matching(p).count, app.staticTexts.matching(p).count)
    }

    private func containsCount(_ app: XCUIApplication, _ substring: String) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", substring, substring)).count
    }

    /// Click a control by exact label — button role preferred, static-text fallback.
    private func clickControl(_ app: XCUIApplication, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.click()
            return
        }
        let text = app.staticTexts[label].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 2),
                      "No button or text control labelled '\(label)' to click",
                      file: file, line: line)
        text.click()
    }

    /// Launch → onboarding welcome → "skip → choose model" → model picker, and wait
    /// until all four catalog cards are rendered so count-based asserts are stable.
    @discardableResult
    private func openModelPicker(modelReady: Bool,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> XCUIApplication {
        let app = try launchPenny(modelReady: modelReady, dashboard: false)
        waitForControl(in: app, containing: Self.welcomeCTA,
                       timeout: 10,
                       "Onboarding welcome ('\(Self.welcomeCTA)') never appeared after launch",
                       file: file, line: line)
        clickControl(app, Self.skipToPicker, file: file, line: line)
        waitForControl(in: app, containing: Self.headerText,
                       timeout: 10,
                       "Model picker header ('\(Self.headerText)') never appeared after '\(Self.skipToPicker)'",
                       file: file, line: line)
        for m in Self.catalog {
            waitFor(app.staticTexts[m.name].firstMatch, timeout: 5,
                    "Catalog card '\(m.name)' missing from the model picker grid",
                    file: file, line: line)
        }
        return app
    }

    // MARK: - 1. Catalog, header, footer

    func testPickerShowsFullCatalogHeaderAndFooter() throws {
        let app = try openModelPicker(modelReady: true)

        for m in Self.catalog {
            XCTAssertEqual(exactCount(app, m.name), 1,
                           "Model name '\(m.name)' should appear on exactly one card")
            XCTAssertTrue(app.staticTexts[m.id].firstMatch.exists,
                          "HF repo id '\(m.id)' should be shown on the \(m.name) card")
            XCTAssertEqual(exactCount(app, m.size), 1,
                           "Size tag '\(m.size)' should appear on exactly one card (\(m.name))")
            XCTAssertTrue(app.staticTexts[m.note].firstMatch.exists,
                          "Note '\(m.note)' should be shown on the \(m.name) card")
        }

        // RAM-requirement tags: two 16 GB-tier cards, two 8 GB-tier cards.
        XCTAssertEqual(exactCount(app, "≥16 GB RAM"), 2,
                       "Both 8B/7B cards should carry the '≥16 GB RAM' tag")
        XCTAssertEqual(exactCount(app, "≥8 GB RAM"), 2,
                       "Both 3B cards should carry the '≥8 GB RAM' tag")

        XCTAssertTrue(staticText(in: app, containing: Self.subheaderLead).exists,
                      "Picker subheader ('\(Self.subheaderLead) …') should be visible")
        XCTAssertTrue(app.staticTexts[Self.footerNote].firstMatch.exists,
                      "Footer note '\(Self.footerNote)' should be visible")
        XCTAssertTrue(app.staticTexts[Self.backToStart].firstMatch.exists
                        || app.buttons[Self.backToStart].firstMatch.exists,
                      "'\(Self.backToStart)' control should be visible in the footer")
    }

    // MARK: - 2. RAM-fit warnings match THIS machine

    func testRAMFitWarningsMatchThisMachine() throws {
        let ram = Self.deviceRAMGB
        let app = try openModelPicker(modelReady: true)

        // Cards sharing a minRAMGB tier render the identical warning string, so a
        // per-tier count IS a per-card check: it must equal the number of cards in
        // the tier when this Mac is under the floor, and zero when it meets it.
        let tiers = Dictionary(grouping: Self.catalog, by: \.minRAMGB)
        for (minRAM, models) in tiers.sorted(by: { $0.key < $1.key }) {
            let warning = "Needs ≥\(minRAM) GB — this Mac has \(ram) GB"
            let found = containsCount(app, warning)
            let names = models.map(\.name).joined(separator: ", ")
            if ram < minRAM {
                XCTAssertEqual(found, models.count,
                    "This Mac (\(ram) GB) is under the \(minRAM) GB floor: all \(models.count) cards in that tier (\(names)) must show '⚠️ \(warning)…' — found \(found)")
            } else {
                XCTAssertEqual(found, 0,
                    "This Mac (\(ram) GB) meets the \(minRAM) GB floor: no card in that tier (\(names)) may show a '⚠️ Needs ≥\(minRAM) GB' warning — found \(found)")
            }
        }

        // Total warning count across the grid == number of models that don't fit.
        let expectedTotal = Self.catalog.filter { ram < $0.minRAMGB }.count
        XCTAssertEqual(containsCount(app, "Needs ≥"), expectedTotal,
                       "Exactly \(expectedTotal) of \(Self.catalog.count) catalog models exceed this Mac's \(ram) GB, so exactly that many '⚠️ Needs ≥' warnings may exist")
        if expectedTotal > 0 {
            XCTAssertTrue(staticText(in: app, containing: "May run slowly or run out of memory").exists,
                          "RAM warning should carry the 'May run slowly or run out of memory' consequence text")
        }
    }

    // MARK: - 3. Back to start

    func testBackToStartReturnsToOnboardingWelcome() throws {
        let app = try openModelPicker(modelReady: true)

        clickControl(app, Self.backToStart)
        waitForControl(in: app, containing: Self.welcomeCTA, timeout: 10,
                       "'\(Self.welcomeCTA)' should reappear after '\(Self.backToStart)'")
        XCTAssertFalse(staticText(in: app, containing: Self.headerText).exists,
                       "Model picker header should be gone after returning to onboarding")
        XCTAssertFalse(app.staticTexts[Self.footerNote].firstMatch.exists,
                       "Model picker footer should be gone after returning to onboarding")

        // Round trip: the skip path must still work after going back.
        clickControl(app, Self.skipToPicker)
        waitFor(staticText(in: app, containing: Self.headerText),
                "Model picker should be reachable again after back-to-start → skip")
    }

    // MARK: - 4. Ready default model continues without any download

    func testReadyDefaultModelContinuesToDashboardWithoutDownload() throws {
        let app = try openModelPicker(modelReady: true)

        // The pre-selected default card is in the ready state — and only it.
        let badge = app.staticTexts[Self.readyBadge].firstMatch
        waitFor(badge, timeout: 5,
                "'\(Self.readyBadge)' badge missing — the default model (\(Self.defaultModelName)) must be ready in a --uitest-model-ready launch")
        XCTAssertEqual(exactCount(app, Self.readyBadge), 1,
                       "Exactly one card may carry the '\(Self.readyBadge)' badge")
        XCTAssertEqual(exactCount(app, Self.readyButtonLabel), 1,
                       "Exactly one card may offer '\(Self.readyButtonLabel)'")
        XCTAssertEqual(exactCount(app, Self.useModelLabel), Self.catalog.count - 1,
                       "The \(Self.catalog.count - 1) non-selected cards should still offer '\(Self.useModelLabel)'")

        // The badge must sit on the DEFAULT model's card: same title row (the name
        // and badge share one HStack) and within one card-width to its right. A
        // badge on a neighbouring column would sit left of the name (Δx < 0); one
        // on another row would miss the Δy bound.
        let name = app.staticTexts[Self.defaultModelName].firstMatch
        XCTAssertTrue(name.exists, "'\(Self.defaultModelName)' card title missing")
        let dy = abs(badge.frame.midY - name.frame.midY)
        XCTAssertLessThan(dy, 10,
                          "'\(Self.readyBadge)' should sit in \(Self.defaultModelName)'s title row (Δy = \(dy)pt)")
        let dx = badge.frame.minX - name.frame.minX
        XCTAssertTrue(dx > 0 && dx < 420,
                      "'\(Self.readyBadge)' should sit inside the \(Self.defaultModelName) card, right of its name (Δx = \(dx)pt)")

        // SAFETY GATE: only the ready-state button may ever be clicked. If it is
        // missing, abort (continueAfterFailure = false) rather than touch any
        // 'Use this model' button — that would start a real multi-GB download.
        let continueButton = app.buttons[Self.readyButtonLabel].firstMatch
        let continueText = app.staticTexts[Self.readyButtonLabel].firstMatch
        XCTAssertTrue(continueButton.exists || continueText.exists,
                      "Ready continue button not found — aborting instead of clicking anything else")
        (continueButton.exists ? continueButton : continueText).click()

        // Ready model ⇒ straight to the dashboard shell, fast, with no download UI.
        waitFor(app.staticTexts[Self.dashboardMarker].firstMatch, timeout: 5,
                "Dashboard shell ('\(Self.dashboardMarker)') should appear within 5s of continuing with the ready model — no download may occur")
        XCTAssertFalse(staticText(in: app, containing: "downloading weights").exists,
                       "No download progress may appear when continuing with a ready model")
        XCTAssertFalse(staticText(in: app, containing: "connecting…").exists,
                       "No load status ('connecting…') may appear when continuing with a ready model")
        XCTAssertFalse(staticText(in: app, containing: Self.headerText).exists,
                       "Model picker should be dismissed once the dashboard is shown")
        waitForControl(in: app, containing: Self.defaultModelName, timeout: 5,
                       "Sidebar brain panel should name the in-use model (\(Self.defaultModelName))")
    }

    // MARK: - 5. Not-ready launch shows no ready state (read-only — nothing clicked)

    func testModelNotReadyLaunchShowsNoReadyState() throws {
        // SAFETY: purely observational — no card button is ever clicked here.
        let app = try openModelPicker(modelReady: false)

        XCTAssertEqual(exactCount(app, Self.readyBadge), 0,
                       "No card may claim '\(Self.readyBadge)' when the model phase is idle")
        XCTAssertEqual(exactCount(app, Self.readyButtonLabel), 0,
                       "No card may offer '\(Self.readyButtonLabel)' when the model phase is idle")
        XCTAssertEqual(exactCount(app, Self.useModelLabel), Self.catalog.count,
                       "All \(Self.catalog.count) cards should offer '\(Self.useModelLabel)' when nothing is loaded")
        XCTAssertTrue(app.staticTexts[Self.footerNote].firstMatch.exists,
                      "Footer note should still remind that a model is mandatory")
    }
}
