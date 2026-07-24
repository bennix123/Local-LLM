import XCTest
@testable import PennyTxnStore

/// Shared paths + helpers for the PennyTxnStore test suite.
/// Everything resolves from `#filePath`, so tests run from any working directory.
enum TestPaths {
    /// …/Penny (repo root), derived from this file's compile-time path:
    /// PennyMac/PennyCore/Tests/PennyTxnStoreTests/TestSupport.swift
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PennyTxnStoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // PennyCore
        .deletingLastPathComponent()   // PennyMac
        .deletingLastPathComponent()   // Penny

    static let contractDir = repoRoot.appendingPathComponent("finquery/contract")
    static let fixturesDir = contractDir.appendingPathComponent("fixtures")
    static let categoriesJSON = contractDir.appendingPathComponent("categories.json")
    static let bankProfilesDir = repoRoot
        .appendingPathComponent("finquery/backend/src/services/txn_store/bank_profiles")
    static let testDataDir = repoRoot.appendingPathComponent("test-data")

    /// A fresh throwaway SQLite path in the test temp dir.
    static func tempDBPath(_ label: String = "test") -> String {
        NSTemporaryDirectory() + "penny_txnstore_\(label)_\(getpid())_\(UUID().uuidString.prefix(8)).db"
    }

    /// Standard ingester wired to the contract's categories + bank profiles.
    static func makeIngester() throws -> TxnIngester {
        try TxnIngester(categoriesJSONPath: categoriesJSON.path,
                        bankProfilesDir: bankProfilesDir.path)
    }
}

final class TestSupportSanityTests: XCTestCase {
    func testRepoLayoutResolvable() throws {
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: TestPaths.fixturesDir.path),
                      "fixtures dir missing at \(TestPaths.fixturesDir.path)")
        XCTAssertTrue(fm.fileExists(atPath: TestPaths.categoriesJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: TestPaths.bankProfilesDir.path))
        XCTAssertTrue(fm.fileExists(atPath: TestPaths.testDataDir.path))
    }
}
