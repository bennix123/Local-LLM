import XCTest

/// Guards the 7-step onboarding wizard end-to-end against regressions in step
/// routing and gating: the full welcome → name → how-it-works → accounts →
/// upload → processing → insights walk (including the "Skip — show demo"
/// theatre auto-advancing into the demo insights and "Take me to Penny →"
/// landing on the dashboard shell), per-step "← back" navigation, the two
/// welcome-screen exits ("skip → choose model" and "I have an account", whose
/// destination depends on whether the model is ready), the accounts step's
/// default current+credit selection with its count pill and the
/// "Continue to upload →" button disabling at zero selections, and coming-soon
/// account cards staying non-selectable. Runs entirely under `--uitest`
/// (nothing persists, no model download); no test ever clicks "Use this model".
final class OnboardingUITests: PennyUITestCase {

    // MARK: - helpers

    /// Click a plain-text SwiftUI button. SwiftUI text buttons usually surface
    /// as AX buttons labelled with their text, but some styles flatten to bare
    /// static texts — try `buttons` first, fall back to `staticTexts`.
    private func click(_ label: String, in app: XCUIApplication,
                       timeout: TimeInterval = 10,
                       file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: timeout) {
            button.click()
            return
        }
        let text = app.staticTexts[label].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 2),
                      "Found neither a button nor a static text labelled '\(label)'",
                      file: file, line: line)
        text.click()
    }

    /// A step-4 account-type card. Its AX label concatenates icon + name +
    /// subtitle, so match by containment; fall back to the bare name text.
    private func accountCard(named name: String, in app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "label CONTAINS %@", name)
        let button = app.buttons.matching(pred).firstMatch
        if button.exists { return button }
        return app.staticTexts[name].firstMatch
    }

    private func clickAccountCard(_ name: String, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let card = accountCard(named: name, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "Step-4 account card '\(name)' never appeared", file: file, line: line)
        card.click()
    }

    /// The "N accounts selected" pill on the step-4 rail (a single concatenated Text).
    private func selectionPill(_ count: Int, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["\(count) accounts selected"].firstMatch
    }

    /// The dashboard shell counts as visible once either the sidebar's
    /// "PENNY'S BRAIN" card or the chat input field exists.
    private func assertDashboardShell(_ app: XCUIApplication, timeout: TimeInterval = 10,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let brain = app.staticTexts["PENNY'S BRAIN"].firstMatch
        let input = app.textFields["chat.input"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !brain.exists, !input.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(brain.exists || input.exists,
                      "Dashboard shell never appeared: neither the \"PENNY'S BRAIN\" sidebar card nor the chat.input field exists",
                      file: file, line: line)
    }

    /// Drive welcome → name → how-it-works → accounts (no name typed).
    private func advanceToAccountsStep(_ app: XCUIApplication) {
        click("Let's set up →", in: app)
        click("Nice to meet you →", in: app)
        click("Got it, let's go →", in: app)
        waitFor(app.staticTexts["Step 4 of 6"].firstMatch, "Accounts step (4) never appeared")
    }

    // MARK: - 1. full walk

    func testFullWalkWelcomeToDashboardViaDemo() throws {
        let app = try launchPenny(modelReady: true)

        // S1 welcome — always the landing screen.
        waitFor(app.staticTexts["Step 1 of 6"].firstMatch,
                "App must launch onto onboarding step 1 (welcome)")
        click("Let's set up →", in: app)

        // S2 name — progress advances, field has the "Alex" placeholder, typing sticks.
        waitFor(app.staticTexts["Step 2 of 6"].firstMatch,
                "Name step should show 'Step 2 of 6' in the progress bar")
        let nameField = waitFor(app.textFields.firstMatch,
                                "Name step should show its single text field")
        XCTAssertEqual(nameField.placeholderValue, "Alex",
                       "Name field placeholder should be 'Alex'")
        typeInto(nameField, "Casey")
        XCTAssertEqual(nameField.value as? String, "Casey",
                       "Typed name should land in the name field")
        click("Nice to meet you →", in: app)

        // S3 how-it-works — all four step cards visible.
        waitFor(app.staticTexts["Step 3 of 6"].firstMatch,
                "How-it-works step should show 'Step 3 of 6'")
        for title in ["Download the AI model", "Drop in your files",
                      "I read everything locally", "Stays on this Mac"] {
            waitFor(app.staticTexts[title].firstMatch, timeout: 5,
                    "How-it-works card '\(title)' should be visible")
        }
        click("Got it, let's go →", in: app)

        // S4 accounts — current + credit preselected.
        waitFor(selectionPill(2, in: app),
                "Default selection should be current + credit → '2 accounts selected'")
        clickAccountCard("Current account", in: app)
        waitFor(selectionPill(1, in: app),
                "Deselecting Current account should drop the pill to '1 accounts selected'")
        clickAccountCard("Credit card", in: app)
        waitFor(selectionPill(0, in: app),
                "Deselecting Credit card should drop the pill to '0 accounts selected'")

        // Continue must be disabled at zero selections — and must not navigate.
        let continueButton = app.buttons["Continue to upload →"].firstMatch
        if continueButton.exists {
            XCTAssertFalse(continueButton.isEnabled,
                           "'Continue to upload →' must be disabled with 0 accounts selected")
        }
        let continueControl = continueButton.exists
            ? continueButton : app.staticTexts["Continue to upload →"].firstMatch
        if continueControl.exists, continueControl.isHittable {
            continueControl.click()
        }
        XCTAssertTrue(selectionPill(0, in: app).waitForExistence(timeout: 2),
                      "Clicking the disabled Continue must stay on the accounts step")
        XCTAssertFalse(app.staticTexts["Drag files here"].firstMatch.exists,
                       "The upload dropzone must not appear while Continue is disabled")

        // Re-select one account and continue.
        clickAccountCard("Current account", in: app)
        waitFor(selectionPill(1, in: app),
                "Re-selecting Current account should show '1 accounts selected'")
        click("Continue to upload →", in: app)

        // S5 upload — rail shows the selected kind, dropzone visible.
        waitFor(app.staticTexts["Step 5 of 6"].firstMatch,
                "Upload step should show 'Step 5 of 6'")
        waitFor(app.staticTexts["Your accounts"].firstMatch,
                "Upload step should show the 'Your accounts' rail heading")
        waitFor(app.staticTexts["Current account"].firstMatch,
                "The selected account kind should be named on the upload step")
        // The dropzone is a plain-style Button with a composite label — SwiftUI
        // may fold "Drag files here" into the button's label instead of exposing
        // a separate static text, so match either element kind.
        let dropzone = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Drag files here")).firstMatch
        waitFor(dropzone, "The 'Drag files here' dropzone should be visible")
        click("Skip — show demo", in: app)

        // S6 processing theatre (~5.4 s + 0.8 s hold, then auto-advance).
        waitFor(staticText(in: app, containing: "Reading your"),
                "Processing step should show the 'Reading your files...' headline")
        waitFor(app.staticTexts["TRANSACTIONS PARSED"].firstMatch,
                "Processing step should show the TRANSACTIONS PARSED counter caption")

        // S7 insights — demo thoughts (no real files were uploaded).
        waitFor(app.staticTexts["3 zombie subs spotted 🧟"].firstMatch, timeout: 12,
                "Processing should auto-advance (~6.5 s) into the demo insights step")
        click("Take me to Penny →", in: app)

        // Dashboard: model is ready, so finishOnboarding lands on the shell.
        assertDashboardShell(app)
    }

    // MARK: - 2. back navigation

    func testBackNavigationRetreatsExactlyOneStep() throws {
        let app = try launchPenny(modelReady: true)

        // 1 → 2 → back → 1
        waitFor(app.staticTexts["Step 1 of 6"].firstMatch, "Should launch on welcome")
        click("Let's set up →", in: app)
        waitFor(app.staticTexts["Step 2 of 6"].firstMatch, "Should be on the name step")
        click("← back", in: app)
        waitFor(app.staticTexts["Step 1 of 6"].firstMatch,
                "'← back' from the name step should return to welcome (step 1)")

        // 2 → 3 → back → 2
        click("Let's set up →", in: app)
        waitFor(app.staticTexts["Step 2 of 6"].firstMatch, "Should be back on the name step")
        click("Nice to meet you →", in: app)
        waitFor(app.staticTexts["Step 3 of 6"].firstMatch, "Should be on how-it-works")
        click("← back", in: app)
        waitFor(app.staticTexts["Step 2 of 6"].firstMatch,
                "'← back' from how-it-works should return to the name step (2)")

        // 3 → 4 → back → 3
        click("Nice to meet you →", in: app)
        waitFor(app.staticTexts["Step 3 of 6"].firstMatch, "Should be back on how-it-works")
        click("Got it, let's go →", in: app)
        waitFor(app.staticTexts["Step 4 of 6"].firstMatch, "Should be on the accounts step")
        click("← back", in: app)
        waitFor(app.staticTexts["Step 3 of 6"].firstMatch,
                "'← back' from accounts should return to how-it-works (3)")
    }

    // MARK: - 3. welcome "skip → choose model"

    func testSkipFromWelcomeLandsOnModelPicker() throws {
        // modelReady:false — safe as long as nothing clicks "Use this model".
        let app = try launchPenny(modelReady: false)

        waitFor(app.staticTexts["Step 1 of 6"].firstMatch, "Should launch on welcome")
        click("skip → choose model", in: app)
        waitFor(app.staticTexts["Choose your AI model"].firstMatch,
                "'skip → choose model' should land on the model picker")
        XCTAssertFalse(app.staticTexts["Step 1 of 6"].firstMatch.exists,
                       "Onboarding progress chrome should be gone on the model picker")
        // Deliberately no interaction with "Use this model": it would download real weights.
    }

    // MARK: - 4. welcome "I have an account"

    func testHaveAccountWithoutModelLandsOnModelPicker() throws {
        let app = try launchPenny(modelReady: false)

        click("I have an account", in: app)
        waitFor(app.staticTexts["Choose your AI model"].firstMatch,
                "'I have an account' with no model ready must route to the model picker")
        // Deliberately no interaction with "Use this model" (real multi-GB download).
    }

    func testHaveAccountWithModelReadyLandsOnDashboard() throws {
        let app = try launchPenny(modelReady: true)

        click("I have an account", in: app)
        assertDashboardShell(app)
    }

    // MARK: - 5. coming-soon cards

    func testComingSoonAccountCardIsNotSelectable() throws {
        let app = try launchPenny(modelReady: true)
        advanceToAccountsStep(app)

        waitFor(selectionPill(2, in: app),
                "Accounts step should start at '2 accounts selected'")
        // The grid is a LazyVGrid inside a ScrollView: the INVESTMENTS section
        // (where the coming-soon cards live) is below the fold and lazily
        // non-existent until scrolled into view.
        // The badge lives INSIDE the (disabled) card Button's flattened label,
        // and the card sits below the fold of the lazy grid — scroll, then match
        // buttons or texts.
        let badgePred = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    "COMING SOON", "COMING SOON")
        if !app.buttons.matching(badgePred).firstMatch.exists,
           !app.staticTexts.matching(badgePred).firstMatch.exists {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        }
        waitForControl(in: app, containing: "COMING SOON", timeout: 5,
                       "At least one COMING SOON badge should be visible on the accounts grid")

        let stocks = accountCard(named: "Stocks & shares", in: app)
        XCTAssertTrue(stocks.waitForExistence(timeout: 5),
                      "The 'Stocks & shares' teaser card should exist")
        if stocks.elementType == .button {
            XCTAssertFalse(stocks.isEnabled,
                           "The coming-soon 'Stocks & shares' card must be disabled")
        }

        // Bring it into view if the grid clipped it, then try to click it.
        if !stocks.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -260)
        }
        if !stocks.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 520)
        }
        if stocks.isHittable {
            stocks.click()
        }
        // Give any (incorrect) selection change a moment to land, then check.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(selectionPill(2, in: app).exists,
                      "Clicking a coming-soon card must leave the pill at '2 accounts selected'")
        XCTAssertFalse(selectionPill(3, in: app).exists,
                       "A coming-soon card must never join the selection (no '3 accounts selected')")
    }
}
