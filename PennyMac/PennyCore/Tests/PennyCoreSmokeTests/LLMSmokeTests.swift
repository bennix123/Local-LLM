// LLMSmokeTests.swift — Real-model integration smoke for PennyLLM. Guards the one thing the
// unit suites cannot: that already-downloaded MLX weights actually load through the
// #huggingFaceLoadModelContainer path (HubClient cache resolution -> tokenizer -> Metal) and
// that PennyLLM.ask() streams a non-empty, statement-grounded answer token-by-token. The test
// NEVER downloads: it scans every HuggingFace hub cache root an unsandboxed test process can
// reach (env HF_HUB_CACHE / HF_HOME, ~/.cache/huggingface/hub, ~/Library/Caches/huggingface/hub,
// and the sandboxed app container for com.localbankrag.app) for a complete >500 MB snapshot of
// any catalog model, pins the hub to that root via setenv(HF_HUB_CACHE) and points HF_ENDPOINT
// at an unroutable localhost port so swift-huggingface's offline fallback
// (cachedSnapshotPathForLocalFilesOnly) is forced — a stale `main` ref upstream can never
// trigger a multi-GB re-download mid-test. With no weights on disk the test skips, so plain
// `swift test` stays fast and network-free.

import XCTest
import Foundation
import PennyCore

final class LLMSmokeTests: XCTestCase {

    // MARK: - Cache detection

    private struct CachedModel {
        let entry: PennyLLM.CatalogEntry
        let hubRoot: URL      // the ".../huggingface/hub" directory to pin via HF_HUB_CACHE
        let snapshotDir: URL  // resolved snapshots/<commit> directory
        let bytes: Int64      // total on-disk bytes under models--<org>--<name>
    }

    private static let minimumSubstantialBytes: Int64 = 500 * 1024 * 1024  // >500 MB = real weights

    /// Hub cache roots in the same priority order swift-huggingface's
    /// CacheLocationProvider.environment uses, plus the sandboxed app container the Penny app
    /// itself downloads into (unreachable via defaults from an unsandboxed test process, but
    /// reachable once we pin HF_HUB_CACHE to it).
    private static func candidateHubRoots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var roots: [URL] = []
        if let hubCache = env["HF_HUB_CACHE"] {
            roots.append(URL(fileURLWithPath: NSString(string: hubCache).expandingTildeInPath))
        }
        if let hfHome = env["HF_HOME"] {
            roots.append(
                URL(fileURLWithPath: NSString(string: hfHome).expandingTildeInPath)
                    .appendingPathComponent("hub"))
        }
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))                // unsandboxed default
        roots.append(home.appendingPathComponent("Library/Caches/huggingface/hub"))        // sandboxed default shape
        roots.append(home.appendingPathComponent(                                          // Penny app container
            "Library/Containers/com.localbankrag.app/Data/Library/Caches/huggingface/hub"))

        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// A snapshot is usable offline iff refs/main resolves to an existing snapshots/<commit>
    /// dir whose config.json and at least one *.safetensors resolve to real bytes (snapshot
    /// entries are symlinks into blobs/ — fileExists follows them, so dangling links fail).
    private static func completeSnapshot(for modelID: String, in hubRoot: URL) -> URL? {
        let fm = FileManager.default
        let repoDir = hubRoot.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"))
        let refsMain = repoDir.appendingPathComponent("refs/main")
        guard let commit = (try? String(contentsOf: refsMain, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !commit.isEmpty
        else { return nil }

        let snapshot = repoDir.appendingPathComponent("snapshots").appendingPathComponent(commit)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: snapshot.path, isDirectory: &isDir), isDir.boolValue,
            fm.fileExists(atPath: snapshot.appendingPathComponent("config.json").path)
        else { return nil }

        let hasWeights = ((try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? [])
            .contains { name in
                name.hasSuffix(".safetensors")
                    && fm.fileExists(atPath: snapshot.appendingPathComponent(name).path)
            }
        return hasWeights ? snapshot : nil
    }

    /// Total bytes of regular files under the models--… dir (blobs live here; the enumerator
    /// does not follow symlinks, so weights are counted exactly once).
    private static func onDiskBytes(ofRepoFor modelID: String, in hubRoot: URL) -> Int64 {
        let repoDir = hubRoot.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"))
        guard let enumerator = FileManager.default.enumerator(
            at: repoDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [])
        else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Smallest cached catalog model (fastest load) across all reachable hub roots, or nil.
    private static func firstCachedCatalogModel() -> CachedModel? {
        let bySize = PennyLLM.catalog.enumerated().sorted {
            ($0.element.minRAMGB, $0.offset) < ($1.element.minRAMGB, $1.offset)
        }.map(\.element)
        for entry in bySize {
            for root in candidateHubRoots() {
                guard let snapshot = completeSnapshot(for: entry.id, in: root) else { continue }
                let bytes = onDiskBytes(ofRepoFor: entry.id, in: root)
                if bytes > minimumSubstantialBytes {
                    return CachedModel(entry: entry, hubRoot: root, snapshotDir: snapshot, bytes: bytes)
                }
            }
        }
        return nil
    }

    // MARK: - Streaming collector

    private final class TokenCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ piece: String) {
            lock.lock(); storage.append(piece); lock.unlock()
        }
        var pieces: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Metal shader availability

    /// MLX aborts the process (not a catchable throw) when the Cmlx Metal shader
    /// bundle is absent. Xcode builds `mlx-swift_Cmlx.bundle` next to its products
    /// and into hosting apps; plain `swift test` (SPM CLI) never runs the Metal
    /// toolchain — so without the bundle we must skip, not attempt a load.
    private static var metalShadersAvailable: Bool {
        let testBundle = Bundle(for: LLMSmokeTests.self).bundleURL
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle"),
            testBundle.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle"),
            testBundle.deletingLastPathComponent().appendingPathComponent("mlx-swift_Cmlx.bundle"),
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - The smoke test

    /// Load an already-cached MLX model and answer one grounded question over a 5-line fake
    /// statement. Skips (never fails, never downloads) when no suitable weights are on disk.
    func testGroundedGenerationStreamsNonEmptyAnswerFromCachedModel() async throws {
        guard Self.metalShadersAvailable else {
            throw XCTSkip("""
                mlx-swift_Cmlx.bundle (MLX Metal shaders) not present — SPM CLI builds can't \
                load MLX. Run via Xcode instead: \
                xcodebuild test -scheme Penny -only-testing:PennyTests
                """)
        }
        guard let cached = Self.firstCachedCatalogModel() else {
            let roots = Self.candidateHubRoots().map(\.path).joined(separator: "\n  ")
            throw XCTSkip("""
                No cached MLX weights (>500 MB complete snapshot) for any PennyLLM catalog model \
                in any reachable HuggingFace hub cache root — refusing to download. Roots checked:
                  \(roots)
                Run the Penny app once to download a model, or `export HF_HUB_CACHE=<hub dir>`.
                """)
        }

        // Pin the hub to the root where we found the weights BEFORE anything in this process
        // touches PennyCore's hub. swift-huggingface reads HF_HUB_CACHE (highest priority) via
        // ProcessInfo at HubCache.default's first access — and HubCache.default is a `static
        // let`, resolved exactly once per process, which is why this test performs env setup
        // itself instead of relying on ambient state, and why this target must not gain other
        // tests that touch the hub first. This also makes app-container-only weights reachable.
        setenv("HF_HUB_CACHE", cached.hubRoot.path, 1)
        // Force the offline path: point the hub API at an unroutable local port so the
        // revision listing fails instantly and swift-huggingface falls back to
        // cachedSnapshotPathForLocalFilesOnly (refs/main -> snapshots/<commit>). Guarantees
        // this test can never start a network download, even if upstream `main` moved.
        setenv("HF_ENDPOINT", "http://127.0.0.1:9", 1)

        let llm = PennyLLM(modelID: cached.entry.id)
        let loadedBefore = await llm.isLoaded
        XCTAssertFalse(loadedBefore, "Fresh PennyLLM must report isLoaded == false before load()")

        let loadStart = Date()
        try await llm.load()  // tens of seconds is normal: weights -> Metal
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let loadedAfter = await llm.isLoaded
        XCTAssertTrue(
            loadedAfter,
            "isLoaded must be true after load() succeeded (\(cached.entry.id) from \(cached.hubRoot.path))")

        // 5-line fake statement; the closing balance figure is deliberately distinctive.
        let statement = """
            FIRST GRANITE BANK — Current Account Statement, March 2026
            Date       Description                 Money Out   Money In   Balance
            03/03/2026 CARD PAYMENT COFFEE#12          4.50               6,120.73
            14/03/2026 FASTER PAYMENT SALARY                    1,724.50  7,845.23
            Closing balance: 7,845.23
            """

        let collector = TokenCollector()
        let askStart = Date()
        let answer = try await llm.ask(
            question: "What is the closing balance?",
            statementText: statement,
            maxTokens: 64
        ) { piece in
            collector.append(piece)
        }
        let askSeconds = Date().timeIntervalSince(askStart)

        let pieces = collector.pieces
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertFalse(
            pieces.isEmpty,
            "Streaming callback never fired — ask() produced no chunks "
                + "(model \(cached.entry.id), load \(String(format: "%.1f", loadSeconds))s, "
                + "ask \(String(format: "%.1f", askSeconds))s)")
        XCTAssertFalse(
            trimmed.isEmpty,
            "ask() returned an empty/whitespace answer despite \(pieces.count) streamed chunk(s)")
        XCTAssertEqual(
            pieces.joined(), answer,
            "Concatenated streamed chunks must equal the returned answer — "
                + "the stream dropped or duplicated tokens")

        // Grounding: the closing balance is printed verbatim in the statement, the system
        // prompt orders exact quoting, and generation runs at temperature 0.3 — the figure
        // (with or without the thousands separator) must appear in the answer.
        let normalized = answer.replacingOccurrences(of: ",", with: "")
        XCTAssertTrue(
            normalized.contains("7845.23"),
            "Answer is not grounded in the statement: expected the closing balance 7,845.23 "
                + "to be quoted. Model \(cached.entry.id) answered: \"\(trimmed)\"")
    }
}
