//
//  UpdateChecker.swift
//  EM Network Repair
//
//  GitHub-hosted automatic updater — the same pattern as AlphaCaps /
//  OmniGrids: check on launch → download the release zip → verify its
//  code signature → swap the app bundle in place → relaunch. No browser,
//  no manual drag-install.
//
//  Repo expectations:
//    - Public GitHub repo at https://github.com/RUDEWORLD/EMNetworkRepair
//    - `update.json` at the main-branch root:
//        { "version": "1.0.1",
//          "url": "https://github.com/RUDEWORLD/EMNetworkRepair/releases/download/v1.0.1/EMNetworkRepair.zip" }
//    - Each release: tag the commit, upload a zipped "EM Network Repair.app"
//      (Developer ID signed + notarized), bump update.json.
//      Keep versions strictly numeric — "1.0.1", never "1.0.1b".
//
//  Install safety rails:
//    1. The zip must unpack to an "EM Network Repair.app" bundle.
//    2. That bundle's signature must be valid AND signed by this team
//       (EGET63XBLQ) with this bundle id — update.json is plain HTTPS with
//       no signature of its own, so the bundle check is what stops a
//       tampered download from installing.
//    3. The install directory must be writable; the swap is a two-step
//       rename with rollback if the second step fails.
//    4. Relaunch happens via a detached shell that waits for this process
//       to fully exit, so there's no old/new instance race.
//
//  Requires the un-sandboxed build (ENABLE_APP_SANDBOX = NO): a sandboxed
//  process can neither replace the installed bundle nor spawn the relaunch
//  helper outside its container. (The app's core repair function needs the
//  same, so this is not an extra concession.)

import SwiftUI
import Combine
import Security

struct UpdateInfo: Codable {
    let version: String
    let url: String
}

private let requiredTeamID = "EGET63XBLQ"
private let appBundleID = "com.rudeworld.emnetworkrepair"
private let appBundleName = "EM Network Repair.app"

@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking                 // manual check in flight
        case updateAvailable          // newer version found; waiting for user consent
        case downloading(Double)      // 0...1
        case installing
        case restarting
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var latestVersion = ""
    @Published var downloadURL = ""

    private var verifiedAppURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    private lazy var downloadSession: URLSession = {
        URLSession(configuration: .default,
                   delegate: DownloadDelegate(checker: self),
                   delegateQueue: nil)
    }()

    // Cache-busting timestamp — GitHub's CDN otherwise serves stale
    // update.json for several minutes after a push.
    private var updateURL: String {
        let t = Int(Date().timeIntervalSince1970)
        return "https://raw.githubusercontent.com/RUDEWORLD/EMNetworkRepair/main/update.json?t=\(t)"
    }

    // "1.0.0"-style identifier from the bundle's marketing + build version.
    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short).\(build)"
    }

    // MARK: - Checks

    /// Silent check used on launch — the ONLY automatic check. Network
    /// failure / missing repo / bad JSON are swallowed without UI. When a
    /// newer version IS found the user is ASKED before anything downloads.
    func checkForUpdates() {
        #if DEBUG
        return
        #else
        fetchUpdateInfo { [weak self] info in
            guard let self, let info else { return }
            self.latestVersion = info.version
            self.downloadURL = info.url
            if self.isNewerVersion(info.version, than: self.currentVersion) {
                self.offerUpdate()
            }
        }
        #endif
    }

    /// Verbose check used by the manual button: alerts for up-to-date /
    /// unreachable, same consent prompt when newer.
    func checkForUpdatesWithFeedback() {
        phase = .checking
        fetchUpdateInfo { [weak self] info in
            guard let self else { return }
            guard let info else { self.phase = .idle; self.showErrorAlert(); return }
            self.latestVersion = info.version
            self.downloadURL = info.url
            if self.isNewerVersion(info.version, than: self.currentVersion) {
                self.offerUpdate()
            } else {
                self.phase = .idle
                self.showUpToDateAlert()
            }
        }
    }

    private func offerUpdate() {
        phase = .updateAvailable
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "EM Network Repair \(latestVersion) is available (you have \(currentVersion)). Download and install it now? The app will restart to finish."
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            startConsentedUpdate()
        }
        // "Later": phase stays .updateAvailable — the footer keeps a
        // "Download & Install" button for the rest of the session.
    }

    func startConsentedUpdate() {
        guard !downloadURL.isEmpty else { return }
        beginAutoUpdate(UpdateInfo(version: latestVersion, url: downloadURL))
    }

    private func fetchUpdateInfo(completion: @escaping @MainActor (UpdateInfo?) -> Void) {
        guard let url = URL(string: updateURL) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let parsed: UpdateInfo? = {
                guard let data, error == nil else { return nil }
                let trimmed = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let cleaned = trimmed.data(using: .utf8),
                   let info = try? JSONDecoder().decode(UpdateInfo.self, from: cleaned) { return info }
                return try? JSONDecoder().decode(UpdateInfo.self, from: data)
            }()
            Task { @MainActor in completion(parsed) }
        }.resume()
    }

    // Component-wise: "1.0.0" vs "1.0.1" → newer. Missing components are 0.
    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let n = new.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(n.count, c.count) {
            let nv = i < n.count ? n[i] : 0
            let cv = i < c.count ? c[i] : 0
            if nv > cv { return true }
            if nv < cv { return false }
        }
        return false
    }

    // MARK: - Download → install → relaunch

    private func beginAutoUpdate(_ info: UpdateInfo) {
        // Never swap out a DerivedData product (a build run from Xcode).
        guard !Bundle.main.bundleURL.path.contains("/DerivedData/") else { return }
        guard let url = URL(string: info.url) else {
            phase = .failed("The update's download URL is malformed."); return
        }
        switch phase {
        case .downloading, .installing, .restarting: return
        default: break
        }
        phase = .downloading(0)
        let task = downloadSession.downloadTask(with: url)
        downloadTask = task
        task.resume()
    }

    func cancelUpdate() {
        downloadTask?.cancel(); downloadTask = nil
        phase = .updateAvailable
    }

    func downloadManually() {
        guard let url = URL(string: downloadURL) else { return }
        NSWorkspace.shared.open(url)
        phase = .idle
    }

    func retryUpdate() {
        guard !downloadURL.isEmpty else { phase = .idle; return }
        beginAutoUpdate(UpdateInfo(version: latestVersion, url: downloadURL))
    }

    fileprivate func downloadProgressed(_ fraction: Double) {
        if case .downloading = phase { phase = .downloading(fraction) }
    }

    fileprivate func downloadFailed(_ message: String) {
        guard case .downloading = phase else { return }
        phase = .failed("Download failed: \(message)")
    }

    fileprivate func downloadFinished(movedTo zipURL: URL) {
        guard case .downloading = phase else {
            try? FileManager.default.removeItem(at: zipURL); downloadTask = nil; return
        }
        downloadTask = nil
        phase = .installing
        let version = latestVersion
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let newAppURL = try Self.unpackAndVerify(zipURL: zipURL, version: version)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.verifiedAppURL = newAppURL
                    self.installNow()          // utility app: always safe to restart
                }
            } catch {
                await MainActor.run { [weak self] in self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func installNow() {
        guard let newAppURL = verifiedAppURL else { return }
        verifiedAppURL = nil
        phase = .installing
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let stagedURL = try Self.stageNextToInstall(newAppURL: newAppURL)
                try await MainActor.run { [weak self] in
                    try Self.atomicSwapAndScheduleRelaunch(stagedURL: stagedURL)
                    self?.phase = .restarting
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run { [weak self] in self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private nonisolated static func unpackAndVerify(zipURL: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("EMNetworkRepairUpdate-\(version)-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // ditto -x -k preserves code signatures like Archive Utility.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, staging.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError(message: "The update archive could not be unpacked.")
        }

        var appURL = staging.appendingPathComponent(appBundleName)
        if !fm.fileExists(atPath: appURL.path) {
            let contents = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            if let nested = contents.first(where: { fm.fileExists(atPath: $0.appendingPathComponent(appBundleName).path) }) {
                appURL = nested.appendingPathComponent(appBundleName)
            } else if let direct = contents.first(where: { $0.pathExtension == "app" }) {
                appURL = direct
            } else {
                throw UpdateError(message: "The update archive doesn't contain \(appBundleName).")
            }
        }

        // Strip quarantine before the signature check.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", appURL.path]
        try? xattr.run(); xattr.waitUntilExit()

        guard verifySignature(of: appURL) else {
            throw UpdateError(message: "The downloaded update failed code-signature verification — install aborted. Nothing was changed.")
        }

        // Identity + version validation stops a wrong/stale asset from
        // installing and re-triggering the pipeline on every launch.
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let payloadBundleID = plist["CFBundleIdentifier"] as? String else {
            throw UpdateError(message: "The downloaded update has no readable Info.plist — install aborted.")
        }
        guard payloadBundleID == (Bundle.main.bundleIdentifier ?? appBundleID) else {
            throw UpdateError(message: "The downloaded app is \(payloadBundleID), not EM Network Repair — install aborted.")
        }
        let payloadShort = plist["CFBundleShortVersionString"] as? String ?? "0"
        let payloadBuild = plist["CFBundleVersion"] as? String ?? "0"
        let payloadVersion = "\(payloadShort).\(payloadBuild)"
        guard payloadVersion == version else {
            throw UpdateError(message: "The downloaded update reports version \(payloadVersion), not the advertised \(version) — install aborted.")
        }
        return appURL
    }

    private nonisolated static func verifySignature(of appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        let requirementString =
            "identifier \"\(appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(requiredTeamID)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    private nonisolated static func stageNextToInstall(newAppURL: URL) throws -> URL {
        let fm = FileManager.default
        let currentAppURL = Bundle.main.bundleURL
        let parentDir = currentAppURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parentDir.path) else {
            throw UpdateError(message: "Can't write to \(parentDir.path). Move the app to /Applications (or a folder you own) and try again.")
        }
        let staged = parentDir.appendingPathComponent(".EM Network Repair.app.staged")
        try? fm.removeItem(at: staged)
        do { try fm.moveItem(at: newAppURL, to: staged) }
        catch {
            try? fm.removeItem(at: staged)
            throw UpdateError(message: "Couldn't stage the update next to the app: \(error.localizedDescription). The current version was left in place.")
        }
        return staged
    }

    private static func atomicSwapAndScheduleRelaunch(stagedURL: URL) throws {
        let fm = FileManager.default
        let currentAppURL = Bundle.main.bundleURL
        let parentDir = currentAppURL.deletingLastPathComponent()
        ProcessInfo.processInfo.disableSuddenTermination()

        let retired = parentDir.appendingPathComponent(".EM Network Repair.app.pre-update")
        try? fm.removeItem(at: retired)
        do { try fm.moveItem(at: currentAppURL, to: retired) }
        catch {
            ProcessInfo.processInfo.enableSuddenTermination()
            try? fm.removeItem(at: stagedURL)
            throw UpdateError(message: "Couldn't move the current app aside: \(error.localizedDescription). The current version was left in place.")
        }
        do { try fm.moveItem(at: stagedURL, to: currentAppURL) }
        catch {
            if fm.fileExists(atPath: currentAppURL.path) { try? fm.removeItem(at: currentAppURL) }
            do { try fm.moveItem(at: retired, to: currentAppURL) }
            catch {
                ProcessInfo.processInfo.enableSuddenTermination()
                throw UpdateError(message: "The install failed AND the rollback failed. Your working copy is at \(retired.path) — rename it back to \(appBundleName).")
            }
            ProcessInfo.processInfo.enableSuddenTermination()
            throw UpdateError(message: "Couldn't install the update: \(error.localizedDescription). The current version was left in place.")
        }

        // Detached helper waits for THIS process to exit, deletes the old
        // copy, opens the new. Paths are positional args ($1/$2), never
        // interpolated — a space or apostrophe in the path can't break it.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$1"
        /usr/bin/open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "emnr-relaunch", retired.path, currentAppURL.path]
        do { try helper.run() }
        catch {
            let aside = parentDir.appendingPathComponent(".EM Network Repair.app.failed-update")
            try? fm.removeItem(at: aside)
            try? fm.moveItem(at: currentAppURL, to: aside)
            try? fm.moveItem(at: retired, to: currentAppURL)
            try? fm.removeItem(at: aside)
            ProcessInfo.processInfo.enableSuddenTermination()
            throw UpdateError(message: "Couldn't schedule the relaunch: \(error.localizedDescription). The current version was left in place.")
        }
    }

    // MARK: - Alerts (manual-check feedback only)

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "EM Network Repair \(currentVersion) is the latest version available."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = "Please check your internet connection and try again."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// URLSessionDownloadDelegate — nonisolated, forwards events to the
// MainActor checker. The temp file must be moved synchronously inside
// didFinishDownloadingTo before the hop (the system deletes it on return).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var checker: UpdateChecker?
    init(checker: UpdateChecker) { self.checker = checker }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak checker] in checker?.downloadProgressed(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Task { @MainActor [weak checker] in checker?.downloadFailed("server returned HTTP \(http.statusCode)") }
            return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("EMNetworkRepairUpdate-\(UUID().uuidString).zip")
        do { try FileManager.default.moveItem(at: location, to: dest) }
        catch {
            Task { @MainActor [weak checker] in checker?.downloadFailed("couldn't stage the downloaded file") }
            return
        }
        Task { @MainActor [weak checker] in checker?.downloadFinished(movedTo: dest) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor [weak checker] in checker?.downloadFailed(error.localizedDescription) }
    }
}
