import Foundation

// PennyLog — the Penny app's backend log file (TestFlight builds included).
//
// Every statement import, categorization call, and chat question/response is
// appended as an IST-timestamped line. Lines are echoed to stderr so Xcode's
// console still shows them live during development.
//
// File: $PENNY_LOG_FILE if set, else <Library>/Logs/Penny/penny-app.log.
// The app is sandboxed, so <Library> resolves inside its container:
//   ~/Library/Containers/<bundle-id>/Data/Library/Logs/Penny/penny-app.log
//
// An actor so concurrent tasks can't interleave half-written lines. Lives in
// PennyTxnStore (not the app target) so both the app and the package's own
// code can log without touching the Xcode project file.

public actor PennyLog {
    public static let shared = PennyLog()

    public nonisolated let fileURL: URL
    private var handle: FileHandle?
    private let stamp: ISO8601DateFormatter

    private init() {
        if let override = ProcessInfo.processInfo.environment["PENNY_LOG_FILE"],
           !override.isEmpty {
            fileURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            fileURL = library
                .appendingPathComponent("Logs/Penny", isDirectory: true)
                .appendingPathComponent("penny-app.log")
        }
        stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        // Log in IST regardless of the machine's timezone.
        stamp.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
    }

    /// Append one timestamped entry; multi-line messages are indented so the
    /// whole entry stays visually grouped under its timestamp.
    public func write(_ tag: String, _ message: String) {
        let body = message.replacingOccurrences(of: "\n", with: "\n    ")
        let line = "[\(stamp.string(from: Date()))] [\(tag)] \(body)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        if let h = ensureHandle() {
            do { try h.write(contentsOf: data) } catch { self.handle = nil }
        }
    }

    /// Fire-and-forget variant for non-async call sites.
    public nonisolated func log(_ tag: String, _ message: String) {
        Task { await self.write(tag, message) }
    }

    // Opened lazily so a missing/unwritable directory degrades to stderr-only
    // logging instead of breaking the app.
    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
