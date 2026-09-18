import SwiftUI
import Combine

// ─────────────────────────────────────────────────────────────────────────────
//  EventMaster 9.2 Network Fix — engine + UI
//
//  Barco EventMaster 9.2 ships UNSIGNED. On macOS 15/26/27+ the Local Network
//  Privacy system needs a code-signing identity before it will let an app reach
//  the LAN, so it silently blocks EventMaster from connecting to E2/S3/EX
//  processors (you can ping the unit, but EMT never connects). This gives the
//  main program a harmless AD-HOC signature so macOS can identify it. It re-signs
//  the copy already installed on this Mac and contains none of Barco's code.
//
//  SAFETY: only touches an install that is BOTH bundle id "com.barco.em" AND not
//  already validly signed. EventMaster 10+ (Barco-signed, com.yourcompany.
//  EventMaster) is detected and left untouched.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Shell helper

func sh(_ exe: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "spawn failed: \(error)") }
    p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

func infoValue(_ appPath: String, _ key: String) -> String {
    sh("/usr/bin/defaults", ["read", "\(appPath)/Contents/Info.plist", key])
        .out.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Classification

enum SignState: CustomStringConvertible {
    case unsigned, adhoc, developerID(String), otherSigned
    var description: String {
        switch self {
        case .unsigned:           return "unsigned"
        case .adhoc:              return "ad-hoc"
        case .developerID(let a): return "Developer ID (\(a))"
        case .otherSigned:        return "signed"
        }
    }
}

func signState(_ appPath: String) -> SignState {
    let (code, o) = sh("/usr/bin/codesign", ["-dvvv", appPath])
    if code != 0 || o.contains("code object is not signed at all") { return .unsigned }
    if let r = o.range(of: "Authority=Developer ID Application: [^\\n]+", options: .regularExpression) {
        return .developerID(String(o[r]).replacingOccurrences(of: "Authority=Developer ID Application: ", with: ""))
    }
    if o.contains("Authority=") { return .otherSigned }
    if o.lowercased().contains("adhoc") { return .adhoc }
    return .otherSigned
}

func folderVersion(_ appPath: String) -> String {
    let parent = (appPath as NSString).deletingLastPathComponent
    let name = (parent as NSString).lastPathComponent
    if let r = name.range(of: "[0-9][0-9.]*", options: .regularExpression) { return String(name[r]) }
    return ""
}
func majorVersion(_ v: String) -> Int? { Int(v.split(separator: ".").first.map(String.init) ?? "") }

struct Candidate {
    let appPath: String, bundleID: String, version: String, state: SignState

    /// The safety decision — must pass ALL gates to be modified.
    var decision: (eligible: Bool, reason: String) {
        switch state {                                   // GATE 1: never touch signed code
        case .developerID(let a): return (false, "PROTECTED — already signed by \(a). Will NOT modify.")
        case .otherSigned:        return (false, "PROTECTED — already code-signed. Will NOT modify.")
        case .unsigned, .adhoc:   break
        }
        if bundleID != "com.barco.em" {                  // GATE 2: must be the EM9 identity
            return (false, "SKIP — id \"\(bundleID)\" is not EventMaster 9 (com.barco.em).")
        }
        if let m = majorVersion(version), m != 9 {       // GATE 3: version must be 9.x
            return (false, "SKIP — version \(version) is not 9.x.")
        }
        return (true, "ELIGIBLE — EventMaster \(version.isEmpty ? "9.x" : version).")
    }
}

func findEM() -> [String] {
    let fm = FileManager.default
    var found: Set<String> = []
    for root in ["/Applications", "\(NSHomeDirectory())/Applications"] {
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for item in items {
            let candidates = ["\(root)/\(item)/EventMaster.app", "\(root)/\(item)"]
            for cand in candidates where cand.hasSuffix("EventMaster.app") {
                if fm.fileExists(atPath: "\(cand)/Contents/MacOS/EventMaster") { found.insert(cand) }
            }
        }
    }
    return found.sorted()
}

/// Ad-hoc sign the main program in place. Returns success + a log to display.
func applyFix(_ appPath: String, _ bundleID: String) -> (ok: Bool, log: [String]) {
    var out: [String] = []
    let bin = "\(appPath)/Contents/MacOS/EventMaster"

    out.append("Quitting EventMaster if running…")
    _ = sh("/usr/bin/pkill", ["-x", "EventMaster"])
    _ = sh("/usr/bin/pkill", ["-f", "EventMaster.app/Contents"])
    Thread.sleep(forTimeInterval: 2)

    let tmp = NSTemporaryDirectory() + "EMfix_\(UUID().uuidString)"
    if sh("/bin/cp", [bin, tmp]).code != 0 { return (false, out + ["✗ Could not read the program file."]) }

    out.append("Signing (ad-hoc, \(bundleID))…")
    let s = sh("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", bundleID, tmp])
    if s.code != 0 { try? FileManager.default.removeItem(atPath: tmp)
        return (false, out + ["✗ Signing failed: \(s.out)"]) }

    if FileManager.default.isWritableFile(atPath: bin), sh("/bin/cp", [tmp, bin]).code == 0 {
        // written directly
    } else {
        out.append("Program not user-writable — asking for administrator permission…")
        let script = "do shell script \"cp '\(tmp)' '\(bin)'\" with administrator privileges"
        if sh("/usr/bin/osascript", ["-e", script]).code != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            return (false, out + ["✗ Could not write the signed program back (permission denied)."])
        }
    }
    try? FileManager.default.removeItem(atPath: tmp)

    let v = sh("/usr/bin/codesign", ["-dv", bin]).out
    let id = v.split(separator: "\n").first { $0.contains("Identifier") }.map(String.init) ?? ""
    return (true, out + ["✓ Signed. \(id)"])
}

// MARK: - View model

@MainActor final class FixModel: ObservableObject {
    @Published var logText = ""
    @Published var eligibleCount = 0
    @Published var busy = false

    func scan() {
        busy = true
        logText = "Scanning…"
        Task.detached {
            var out: [String] = []
            var elig = 0
            let apps = findEM()
            if apps.isEmpty {
                out.append("No EventMaster found in /Applications.")
            } else {
                for app in apps {
                    let c = Candidate(appPath: app,
                                      bundleID: infoValue(app, "CFBundleIdentifier"),
                                      version: folderVersion(app),
                                      state: signState(app))
                    let d = c.decision
                    out.append("• EventMaster \(c.version.isEmpty ? "?" : c.version)   [\(c.state)]")
                    out.append("    \(d.reason)")
                    out.append("")
                    if d.eligible { elig += 1 }
                }
                out.append(elig > 0
                    ? "Ready: \(elig) install(s) can be fixed. Click “Fix EventMaster 9.2”."
                    : "Nothing eligible to fix.")
            }
            let finalOut = out.joined(separator: "\n"); let finalElig = elig
            await MainActor.run { self.logText = finalOut; self.eligibleCount = finalElig; self.busy = false }
        }
    }

    func runFix() {
        busy = true
        Task.detached {
            var lines: [String] = ["────────── applying ──────────"]
            var fixed = 0
            for app in findEM() {
                let c = Candidate(appPath: app,
                                  bundleID: infoValue(app, "CFBundleIdentifier"),
                                  version: folderVersion(app),
                                  state: signState(app))
                if c.decision.eligible {
                    let r = applyFix(app, c.bundleID)
                    lines.append(contentsOf: r.log.map { "    " + $0 })
                    if r.ok { fixed += 1 }
                }
            }
            if fixed > 0 {
                lines.append("")
                lines.append("✓ Done. Launch EventMaster now.")
                lines.append("  If macOS asks about Local Network access, click Allow.")
                lines.append("  Otherwise: System Settings ▸ Privacy & Security ▸ Local Network ▸ turn EventMaster ON.")
            } else {
                lines.append("\nNo installs were changed.")
            }
            let block = lines.joined(separator: "\n")
            await MainActor.run { self.logText += "\n\n" + block; self.busy = false }
        }
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var model = FixModel()
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EventMaster 9.2 → E2 connection fix")
                .font(.title2).bold()
            Text("Fixes macOS blocking EventMaster 9.2 from reaching your processors. "
                 + "Click the button below; if macOS later asks about Local Network access, click Allow. "
                 + "EventMaster 10+ is never touched.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(model.logText.isEmpty ? " " : model.logText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            HStack {
                Button("Re-scan") { model.scan() }
                    .disabled(model.busy)
                Spacer()
                Button {
                    model.runFix()
                } label: {
                    HStack(spacing: 6) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text("Fix EventMaster 9.2")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || model.eligibleCount == 0)
            }

            Divider().padding(.top, 2)
            updateFooter
        }
        .padding(20)
        .frame(width: 640, height: 500)
        .onAppear { model.scan() }
    }

    // Version label (left) + update status/controls (right).
    private var updateFooter: some View {
        HStack(spacing: 8) {
            Text("v\(updateChecker.currentVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            updateStatus
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updateChecker.phase {
        case .idle:
            Button("Check for Updates") { updateChecker.checkForUpdatesWithFeedback() }
                .controlSize(.small)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .updateAvailable:
            Button("Download & Install \(updateChecker.latestVersion)") { updateChecker.startConsentedUpdate() }
                .controlSize(.small).buttonStyle(.borderedProminent)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 90)
                Text("Downloading \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            }
        case .restarting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Restarting…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Text("Update failed").font(.caption).foregroundStyle(.red)
                Button("Download manually") { updateChecker.downloadManually() }.controlSize(.small)
            }
            .help(msg)
        }
    }
}

#Preview {
    ContentView().environmentObject(UpdateChecker())
}
