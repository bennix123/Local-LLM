import XCTest
@testable import Penny

/// Hosted smoke test — proves the PennyTests bundle injects into the app.
/// The real app-layer suites (AppModel summaries, markdown parser, issuer
/// detection) live alongside this file.
@MainActor
final class AppSmokeTests: XCTestCase {
    func testAppModelInitializes() {
        let model = AppModel()
        XCTAssertEqual(model.docs.count, 0)
        XCTAssertEqual(model.summary.count, 0)
    }
}
