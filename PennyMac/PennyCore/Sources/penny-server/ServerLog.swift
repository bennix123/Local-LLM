import Foundation

// ServerLog — the backend log file for penny-server.
//
// Every chat question, every response (whichever engine produced it), and the
// key backend events (startup, uploads, model load, errors) are appended as
// timestamped lines. Each line is also echoed to stderr so a terminal run
// still shows live activity.
//
// File: $PENNY_LOG_FILE if set, else ~/Library/Logs/penny-server/penny-server.log
//
// An actor so concurrent requests can't interleave half-written lines. Callers
// that need strict ordering within one request (question before its answer)
// `await write(...)`; fire-and-forget callers use the nonisolated `log(...)`.

actor ServerLog {
    static let shared = ServerLog()

    nonisolated let fileURL: URL
    private var handle: FileHandle?
    private let stamp: ISO8601DateFormatter

    private init() {
        if let override = ProcessInfo.processInfo.environment["PENNY_LOG_FILE"],
           !override.isEmpty {
            fileURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/penny-server", isDirectory: true)
                .appendingPathComponent("penny-server.log")
        }
        stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        // Log in IST regardless of the machine's timezone.
        stamp.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
    }

    /// Append one timestamped entry; multi-line messages are indented so the
    /// whole entry stays visually grouped under its timestamp.
    func write(_ tag: String, _ message: String) {
        let body = message.replacingOccurrences(of: "\n", with: "\n    ")
        let line = "[\(stamp.string(from: Date()))] [\(tag)] \(body)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        if let h = ensureHandle() {
            do { try h.write(contentsOf: data) } catch { self.handle = nil }
        }
    }

    /// Fire-and-forget variant for non-async call sites (bootstrap, engine tasks).
    nonisolated func log(_ tag: String, _ message: String) {
        Task { await self.write(tag, message) }
    }

    // Opened lazily so a missing/unwritable directory degrades to stderr-only
    // logging instead of killing the server.
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
