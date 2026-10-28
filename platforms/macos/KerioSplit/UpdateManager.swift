import Foundation
import AppKit
import CryptoKit

/// Self-update from GitHub Releases: check, download (with progress + SHA-256 check), install, relaunch.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case readyToInstall
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let assetURL: URL
        let assetName: String
        let assetSize: Int64
        let sha256: String?
    }

    static let owner = "PeakPy"
    static let repo = "kerio-split"
    private static let lastCheckKey = "update.lastCheck"
    private static let autoCheckKey = "update.autoCheck"
    private static let skippedKey = "update.skippedVersion"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: Release?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastChecked: Date?
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey) }
    }

    private var downloadedPkg: URL?
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var autoTimer: Timer?

    let currentVersion: String

    var hasUpdate: Bool {
        switch phase {
        case .available, .downloading, .readyToInstall, .installing: return release != nil
        default: return false
        }
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    override init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        autoCheck = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        if let t = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date { lastChecked = t }
        super.init()
    }

    /// Checks shortly after launch (if the last check was over 6h ago) and then every 6h while running.
    func startAutoChecks() {
        guard autoTimer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoCheckIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.autoCheckIfDue()
        }
    }

    private func autoCheckIfDue() {
        guard autoCheck, !isWorking, phase != .readyToInstall else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 6 * 3600 { return }
        check(silent: true)
    }

    // MARK: - Check

    func check(silent: Bool = false) {
        guard !isWorking else { return }
        phase = .checking
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KerioSplit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    throw UpdateError.message(code == 404
                        ? "No published release found on GitHub."
                        : code == 403 ? "GitHub rate limit reached — try again later." : "GitHub returned HTTP \(code).")
                }
                let found = try Self.parse(data)
                await MainActor.run { self?.finishCheck(found, silent: silent) }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.lastChecked = Date()
                    // Silent background failures (offline, VPN toggling) must never surface as errors.
                    self.phase = silent ? .idle : .failed(Self.describe(error))
                }
            }
        }
    }

    private func finishCheck(_ found: Release?, silent: Bool) {
        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        guard let found, Self.isNewer(found.version, than: currentVersion) else {
            release = nil
            phase = .upToDate
            return
        }
        if silent, UserDefaults.standard.string(forKey: Self.skippedKey) == found.version {
            phase = .idle
            return
        }
        release = found
        if let cached = cachedPkg(for: found), FileManager.default.fileExists(atPath: cached.path) {
            downloadedPkg = cached
            phase = .readyToInstall
        } else {
            phase = .available
        }
    }

    func skipThisVersion() {
        if let v = release?.version { UserDefaults.standard.set(v, forKey: Self.skippedKey) }
        release = nil
        phase = .idle
    }

    // MARK: - Download

    func download() {
        guard let release, phase == .available || isFailed else { return }
        progress = 0
        phase = .downloading
        try? FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        self.session = session
        var req = URLRequest(url: release.assetURL)
        req.setValue("KerioSplit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        progress = 0
        phase = release == nil ? .idle : .available
    }

    private var isFailed: Bool {
        if case .failed = phase { return release != nil }
        return false
    }

    // MARK: - Install

    /// Runs the .pkg as root (one Mac password prompt) from a detached script, because the pkg's
    /// preinstall kills this app. The script then relaunches the new build for the logged-in user.
    func install() {
        guard let pkg = downloadedPkg, phase == .readyToInstall || isFailed else { return }
        phase = .installing
        let uid = getuid()
        let scriptURL = updatesDir.appendingPathComponent("apply-update.sh")
        let logPath = updatesDir.appendingPathComponent("install.log").path
        let script = """
        #!/bin/bash
        exec >>'\(logPath)' 2>&1
        echo "--- update $(date)"
        sleep 1
        /usr/sbin/installer -pkg '\(pkg.path)' -target / || { echo "installer failed"; exit 1; }
        sleep 1
        /bin/launchctl asuser \(uid) /usr/bin/open -a /Applications/KerioSplit.app || true
        rm -f '\(pkg.path)'
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed("Could not prepare installer: \(error.localizedDescription)")
            return
        }
        Task { @MainActor [weak self] in
            // Blocks on the macOS password dialog; must stay on the main thread like HelperService.
            let result = appleScriptAdmin(
                "/bin/bash '\(scriptURL.path)' >/dev/null 2>&1 </dev/null & disown; echo started"
            )
            guard let self else { return }
            if !result.ok {
                self.phase = .failed(result.text.isEmpty ? "Update was cancelled." : result.text)
            }
            // On success the pkg preinstall terminates this app; nothing more to do here.
        }
    }

    func openReleasePage() {
        guard let release else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    func dismissError() {
        if case .failed = phase { phase = release == nil ? .idle : (downloadedPkg == nil ? .available : .readyToInstall) }
    }

    // MARK: - Helpers

    private var updatesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KerioSplit/Updates", isDirectory: true)
    }

    private func cachedPkg(for release: Release) -> URL? {
        let url = updatesDir.appendingPathComponent("\(release.version)-\(release.assetName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private enum UpdateError: Error { case message(String) }

    private static func describe(_ error: Error) -> String {
        if case UpdateError.message(let m) = error { return m }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorDNSLookupFailed:
                return "Can't reach GitHub — check your connection and try again."
            default: break
            }
        }
        return error.localizedDescription
    }

    nonisolated private static func parse(_ data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.message("Unexpected response from GitHub.")
        }
        if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { return nil }
        guard let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        // Prefer the installer pkg; never pick the uninstaller.
        let pick = assets.first { ($0["name"] as? String) == "KerioSplit.pkg" }
            ?? assets.first {
                let n = ($0["name"] as? String ?? "").lowercased()
                return n.hasSuffix(".pkg") && !n.contains("uninstall")
            }
        guard let asset = pick,
              let name = asset["name"] as? String,
              let dl = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.message("Release \(version) has no installer package.") }
        var sha: String?
        if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
            sha = String(digest.dropFirst(7)).lowercased()
        }
        return Release(
            version: version,
            notes: (json["body"] as? String) ?? "",
            pageURL: page,
            assetURL: dl,
            assetName: name,
            assetSize: (asset["size"] as? Int64) ?? Int64((asset["size"] as? Int) ?? 0),
            sha256: sha
        )
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension UpdateManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            let expected = total > 0 ? total : (self.release?.assetSize ?? 0)
            if expected > 0 { self.progress = min(1, Double(totalBytesWritten) / Double(expected)) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this returns, so move it synchronously.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("keriosplit-\(UUID().uuidString).pkg")
        let moved = (try? FileManager.default.moveItem(at: location, to: staging)) != nil
        Task { @MainActor [weak self] in
            guard let self, let release = self.release else { return }
            guard status == 200, moved else {
                self.phase = .failed("Download failed (HTTP \(status)).")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? 0
            if release.assetSize > 0, size != release.assetSize {
                try? FileManager.default.removeItem(at: staging)
                self.phase = .failed("Download was incomplete — try again.")
                return
            }
            if let expected = release.sha256 {
                let actual = await Task.detached { Self.sha256(of: staging) }.value
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: staging)
                    self.phase = .failed("Checksum mismatch — the download was discarded.")
                    return
                }
            }
            let dest = self.updatesDir.appendingPathComponent("\(release.version)-\(release.assetName)")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.createDirectory(at: self.updatesDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staging, to: dest)
            } catch {
                self.phase = .failed("Could not save update: \(error.localizedDescription)")
                return
            }
            self.downloadedPkg = dest
            self.progress = 1
            self.phase = .readyToInstall
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor [weak self] in
            guard let self, self.phase == .downloading else { return }
            self.phase = .failed(Self.describe(error))
        }
    }
}
