import Foundation

/// Durable, resumable storage for MLX model weights — the fix for three chronic
/// download failures:
///
///   1. **Re-downloading models that already exist.** Installed models live in
///      one owned directory with a completion marker, checked before any network
///      call. Weights previously fetched into the legacy HuggingFace caches
///      (either layout) are ADOPTED into the store instead of re-downloaded.
///   2. **No pause / no resume.** Every file downloads to `<name>.part` and
///      resumes with an HTTP `Range` request from the byte where it stopped —
///      after a pause, an app quit, a crash, or a month away. Progress is the
///      byte-exact sum of finished files + partials, never a heuristic over
///      CFNetwork temp files.
///   3. **Amnesia across launches.** The filesystem IS the registry: the
///      manifest records what a complete install looks like; the marker records
///      that it was verified. `status(for:)` answers instantly and honestly.
///
/// Layout, per model repo (e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit"):
///
///     <Application Support>/PennyModels/mlx-community--Llama-3.2-3B-Instruct-4bit/
///         manifest.json      file list + sizes (fetched once, reused forever)
///         PENNY_COMPLETE     marker: every manifest file verified on disk
///         config.json …      the model files themselves
///         model.safetensors.part   an interrupted download, resumable
///
/// The finished directory is handed straight to MLX's directory loader — the
/// Hub library is out of the download path entirely.
public actor ModelStore {

    public static let shared = ModelStore()

    public struct DownloadProgress: Sendable {
        public let bytes: Int64
        public let total: Int64
        public var fraction: Double { total > 0 ? Double(bytes) / Double(total) : 0 }
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Some bytes are on disk (an interrupted or paused download) — resumable.
        case partial(bytes: Int64, total: Int64)
        case installed
    }

    public enum StoreError: LocalizedError {
        case manifestUnavailable(String)
        case sizeMismatch(file: String, expected: Int64, got: Int64)
        case httpError(file: String, status: Int)
        public var errorDescription: String? {
            switch self {
            case .manifestUnavailable(let repo):
                return "Couldn't fetch the file list for \(repo). Check your connection and try again."
            case .sizeMismatch(let f, let e, let g):
                return "Download of \(f) came out the wrong size (\(g) of \(e) bytes) — resume to retry."
            case .httpError(let f, let s):
                return "Server error \(s) while downloading \(f)."
            }
        }
    }

    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable {
            let path: String
            let size: Int64
        }
        let files: [File]
        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    private let session: URLSession
    private let baseDir: URL

    /// `baseDir` override is for tests; production uses Application Support,
    /// which is durable (unlike Caches, which the OS may purge multi-GB files
    /// from — the silent "why is it downloading again" failure).
    public init(baseDir: URL? = nil, session: URLSession = .shared) {
        self.session = session
        if let baseDir {
            self.baseDir = baseDir
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            self.baseDir = support.appendingPathComponent("PennyModels")
        }
    }

    public nonisolated static func escaped(_ repo: String) -> String {
        repo.replacingOccurrences(of: "/", with: "--")
    }

    public func directory(for repo: String) -> URL {
        baseDir.appendingPathComponent(Self.escaped(repo))
    }

    private func markerURL(_ repo: String) -> URL {
        directory(for: repo).appendingPathComponent("PENNY_COMPLETE")
    }

    private func manifestURL(_ repo: String) -> URL {
        directory(for: repo).appendingPathComponent("manifest.json")
    }

    // MARK: - status

    /// The model's directory when (and only when) every manifest file is present
    /// at its full size. Cheap — a stat per file, no network.
    public func directoryIfInstalled(for repo: String) -> URL? {
        guard case .installed = status(for: repo) else { return nil }
        return directory(for: repo)
    }

    public func status(for repo: String) -> Status {
        let fm = FileManager.default
        let dir = directory(for: repo)
        guard let manifest = loadManifest(repo) else {
            // No manifest yet — nothing was ever started (adoption writes one).
            return .notInstalled
        }
        var onDisk: Int64 = 0
        var complete = true
        for f in manifest.files {
            let final = dir.appendingPathComponent(f.path)
            if let size = fileSize(final), size >= f.size {
                onDisk += f.size
            } else {
                complete = false
                onDisk += fileSize(dir.appendingPathComponent(f.path + ".part")) ?? 0
            }
        }
        if complete {
            // Self-heal the marker (e.g. after adoption or a crash post-verify).
            if !fm.fileExists(atPath: markerURL(repo).path) {
                fm.createFile(atPath: markerURL(repo).path, contents: Data())
            }
            return .installed
        }
        return .partial(bytes: onDisk, total: manifest.totalBytes)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
    }

    // MARK: - manifest

    private func loadManifest(_ repo: String) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(repo)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func saveManifest(_ manifest: Manifest, repo: String) throws {
        try FileManager.default.createDirectory(at: directory(for: repo),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(repo), options: .atomic)
    }

    /// The HF tree entry we care about. Everything that isn't a plain file (or
    /// is git plumbing) is skipped.
    private struct TreeEntry: Codable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// Fetch (or reuse) the repo's file list. A stored manifest wins — model
    /// repos are immutable for our purposes, and reusing it means a paused
    /// download can resume even while offline-listed.
    private func ensureManifest(repo: String) async throws -> Manifest {
        if let m = loadManifest(repo) { return m }
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let entries = try? JSONDecoder().decode([TreeEntry].self, from: data) else {
            throw StoreError.manifestUnavailable(repo)
        }
        let files = entries
            .filter { $0.type == "file" && !$0.path.hasPrefix(".") }
            .map { Manifest.File(path: $0.path, size: $0.size ?? 0) }
        guard !files.isEmpty else { throw StoreError.manifestUnavailable(repo) }
        let manifest = Manifest(files: files)
        try saveManifest(manifest, repo: repo)
        return manifest
    }

    // MARK: - download (resumable)

    /// Download every missing file, resuming partials byte-exactly. Cancellation
    /// (a pause, a quit) leaves `.part` files in place; the next call continues
    /// from those bytes with an HTTP Range request — after any length of time.
    /// Returns the completed model directory.
    @discardableResult
    public func download(repo: String,
                         onProgress: (@Sendable (DownloadProgress) -> Void)? = nil)
    async throws -> URL {
        let manifest = try await ensureManifest(repo: repo)
        let dir = directory(for: repo)
        let total = manifest.totalBytes

        // Bytes already settled in finished files — the progress baseline.
        var doneBytes: Int64 = 0
        var pending: [Manifest.File] = []
        for f in manifest.files {
            if let size = fileSize(dir.appendingPathComponent(f.path)), size >= f.size {
                doneBytes += f.size
            } else {
                pending.append(f)
            }
        }
        onProgress?(DownloadProgress(bytes: doneBytes + pendingPartialBytes(pending, dir: dir),
                                     total: total))

        for f in pending {
            try Task.checkCancellation()
            try await downloadFile(f, repo: repo, settled: doneBytes, total: total,
                                   onProgress: onProgress)
            doneBytes += f.size
        }

        // Everything verified — stamp the marker.
        FileManager.default.createFile(atPath: markerURL(repo).path, contents: Data())
        onProgress?(DownloadProgress(bytes: total, total: total))
        return dir
    }

    private func pendingPartialBytes(_ files: [Manifest.File], dir: URL) -> Int64 {
        files.reduce(0) { $0 + (fileSize(dir.appendingPathComponent($1.path + ".part")) ?? 0) }
    }

    private func downloadFile(_ f: Manifest.File, repo: String,
                              settled: Int64, total: Int64,
                              onProgress: (@Sendable (DownloadProgress) -> Void)?)
    async throws {
        let fm = FileManager.default
        let dir = directory(for: repo)
        let final = dir.appendingPathComponent(f.path)
        let part = dir.appendingPathComponent(f.path + ".part")
        try fm.createDirectory(at: final.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var offset = fileSize(part) ?? 0
        if offset > f.size {   // corrupt partial (size changed?) — restart the file
            try? fm.removeItem(at: part)
            offset = 0
        }

        if offset < f.size {
            let encoded = f.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.path
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!
            var request = URLRequest(url: url)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StoreError.httpError(file: f.path, status: -1)
            }
            switch http.statusCode {
            case 206: break                                   // resuming where we left off
            case 200:                                         // server ignored the Range → full body
                try? fm.removeItem(at: part)
                offset = 0
            default:
                throw StoreError.httpError(file: f.path, status: http.statusCode)
            }

            if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()

            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            var written = offset
            var lastReport = Date()
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {                  // flush + report every ~1 MB
                    try Task.checkCancellation()              // pause/quit leaves the .part intact
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > 0.3 {
                        lastReport = Date()
                        onProgress?(DownloadProgress(bytes: settled + written, total: total))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
        }

        let got = fileSize(part) ?? 0
        guard got == f.size else {
            throw StoreError.sizeMismatch(file: f.path, expected: f.size, got: got)
        }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
        onProgress?(DownloadProgress(bytes: settled + f.size, total: total))
    }

    // MARK: - legacy-cache adoption

    /// If this repo's weights already exist in a legacy HuggingFace location —
    /// swift-transformers' `Documents/huggingface/models/<repo>` snapshot layout
    /// or a `models--org--name/snapshots/<rev>` hub cache — move/copy them into
    /// the store so they're recognized as installed instead of re-downloaded.
    /// Returns true when an adoption produced a complete install.
    @discardableResult
    public func adoptLegacyCaches(for repo: String) -> Bool {
        if case .installed = status(for: repo) { return true }
        let fm = FileManager.default
        for candidate in Self.legacyCandidates(for: repo) {
            guard fm.fileExists(atPath: candidate.appendingPathComponent("config.json").path),
                  let items = try? fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil),
                  items.contains(where: { $0.pathExtension == "safetensors" }) else { continue }
            let dir = directory(for: repo)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var files: [Manifest.File] = []
            var ok = true
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") || name == "manifest.json" || name == "PENNY_COMPLETE" { continue }
                let dest = dir.appendingPathComponent(name)
                if fileSize(dest) == nil {
                    // Hub-cache snapshot entries are symlinks into blobs/ —
                    // resolve to the real bytes. Move (same-volume rename) so
                    // adopting a 4.5 GB model needs no double disk; fall back
                    // to copy across volumes. The abandoned legacy entry keeps
                    // only a dangling link, which is fine — the store owns the
                    // weights from here on.
                    let source = item.resolvingSymlinksInPath()
                    do {
                        do { try fm.moveItem(at: source, to: dest) }
                        catch { try fm.copyItem(at: source, to: dest) }
                    } catch { ok = false; break }
                }
                if let size = fileSize(dest) { files.append(Manifest.File(path: name, size: size)) }
            }
            guard ok, files.contains(where: { $0.path.hasSuffix(".safetensors") }),
                  files.contains(where: { $0.path == "config.json" }) else { continue }
            try? saveManifest(Manifest(files: files), repo: repo)
            fm.createFile(atPath: markerURL(repo).path, contents: Data())
            if case .installed = status(for: repo) { return true }
        }
        return false
    }

    /// Every place earlier Penny builds (or the headless server) may have left
    /// this repo's weights.
    nonisolated static func legacyCandidates(for repo: String) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        // swift-transformers downloadBase: plain files under Documents/huggingface.
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            out.append(docs.appendingPathComponent("huggingface/models/\(repo)"))
        }
        // Hub-cache layout: models--org--name/snapshots/<revision>/ (symlinked).
        let escaped = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let env = ProcessInfo.processInfo.environment
        var hubs: [URL] = []
        if let p = env["HF_HUB_CACHE"] { hubs.append(URL(fileURLWithPath: p)) }
        if let p = env["HF_HOME"] { hubs.append(URL(fileURLWithPath: p).appendingPathComponent("hub")) }
        hubs.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub"))
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            hubs.append(caches.appendingPathComponent("huggingface/hub"))
        }
        for hub in hubs {
            let snapshots = hub.appendingPathComponent(escaped).appendingPathComponent("snapshots")
            if let revs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
                out.append(contentsOf: revs)
            }
        }
        return out
    }
}
