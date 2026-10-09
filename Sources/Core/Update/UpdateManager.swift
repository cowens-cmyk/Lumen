import AppKit
import CryptoKit
import Observation

/// Updates Lumen from its GitHub repository.
///
/// Two modes, picked automatically:
/// - **Release mode** (any Mac): downloads the newest GitHub release's DMG, checks its checksum and
///   Hope Church signature, swaps the app in place and relaunches.
/// - **Source mode** (a Mac that has the git checkout, e.g. the one with the DeckLink/NDI SDKs): pulls the
///   latest code and rebuilds, so SDK-dependent outputs keep working after an update.
///
/// The repository is private, so requests carry a GitHub token: one saved in Setup → General → Updates, or the
/// `gh auth login` session on this Mac.
@MainActor
@Observable
final class UpdateManager {
    struct Release: Decodable {
        struct Asset: Decodable {
            let id: Int
            let name: String
            let url: String          // API URL; works for private repos with a token (browser_download_url does not)
            let digest: String?      // "sha256:…"
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(String)
        case installing(String)
        case failed(String)
    }

    static let repo = "cowens-cmyk/Lumen"
    static let teamID = "TCAQTA64TB"
    static let tokenKey = "github-update-token"

    private(set) var state: State = .idle
    private(set) var release: Release?
    private(set) var commits: [String] = []
    private(set) var lastChecked: Date?

    @ObservationIgnored weak var app: AppModel?

    // MARK: Environment

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Tests point the updater at a local server with LUMEN_RELEASES_URL.
    static var testMode: Bool { env["LUMEN_RELEASES_URL"] != nil }

    static var releasesURL: String {
        env["LUMEN_RELEASES_URL"] ?? "https://api.github.com/repos/\(repo)/releases/latest"
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var sourcePath: String? { Bundle.main.object(forInfoDictionaryKey: "LumenSourcePath") as? String }

    /// True on the Mac that has the repository checked out: updates rebuild from source there.
    static var hasSourceFolder: Bool {
        guard !testMode, env["LUMEN_FORCE_RELEASE_CHECK"] == nil, let dir = sourcePath else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir + "/.git") && fm.fileExists(atPath: dir + "/Scripts/update.sh")
    }

    /// Only copies installed in Applications are auto-checked (so Xcode/dev builds never nag).
    static var installedInApplications: Bool {
        let p = Bundle.main.bundleURL.path
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var installedCommitFile: URL {
        LibraryStore.defaultFolder.appendingPathComponent("installed-commit")
    }

    static var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    // MARK: Launch / manual checks

    func checkAtLaunch() {
        guard Self.testMode || (Self.autoCheckEnabled && Self.installedInApplications) else { return }
        Task {
            await check()
            guard case .available(let v) = state else { return }
            if Self.testMode, Self.env["LUMEN_AUTOINSTALL"] == "1" {
                _ = await performInstall()
                return
            }
            if app?.volunteerMode != true { app?.flash("Lumen \(v) is available — click Update in the toolbar") }
        }
    }

    func check() async {
        state = .checking
        if Self.hasSourceFolder { await checkSource() } else { await checkRelease() }
        lastChecked = Date()
    }

    /// "Check for Updates…" menu item and the Check Now button.
    func checkAndPrompt() async {
        await check()
        switch state {
        case .upToDate:
            let a = NSAlert()
            a.messageText = "Lumen is up to date"
            a.informativeText = Self.hasSourceFolder ? "You have the latest code from GitHub." : "You have the latest version (\(Self.currentVersion))."
            a.runModal()
        case .failed(let message):
            let a = NSAlert()
            a.messageText = "Couldn't check for updates"
            a.informativeText = message
            a.alertStyle = .warning
            a.runModal()
        case .available:
            await promptInstall()
        default:
            break
        }
    }

    // MARK: Release mode

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Token from Setup → General → Updates, else the `gh auth login` session on this Mac, else none (public repos).
    static func githubToken() async -> String? {
        let saved = Keychain.get(tokenKey)
        if !saved.isEmpty { return saved }
        let owner = String(repo.split(separator: "/")[0])
        for gh in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: gh) {
            var r = await run(gh, ["auth", "token", "--hostname", "github.com", "--user", owner], mergeStderr: false)
            if r.status != 0 { r = await run(gh, ["auth", "token", "--hostname", "github.com"], mergeStderr: false) }
            if r.status == 0, !r.out.isEmpty { return r.out }
        }
        return nil
    }

    private func checkRelease() async {
        guard let url = URL(string: Self.releasesURL) else { state = .failed("Bad update address."); return }
        let token = await Self.githubToken()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token, url.host == "api.github.com" { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: break
            case 401:
                state = .failed("GitHub rejected the saved token. Replace it in Setup → General → Updates."); return
            case 403:
                state = .failed("GitHub refused the request (rate limit or token permissions). Try again in a few minutes."); return
            case 404:
                state = .failed(token == nil
                    ? "Lumen's GitHub repository is private. Run “gh auth login” on this Mac, or paste a GitHub token in Setup → General → Updates."
                    : "No release was found. Either nothing is published yet, or this token can't read \(Self.repo).")
                return
            default:
                state = .failed("GitHub answered with status \(code)."); return
            }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            guard rel.dmg != nil else { state = .failed("The newest release has no download attached."); return }
            release = rel
            state = Self.isNewer(rel.version, than: Self.currentVersion) ? .available(rel.version) : .upToDate
        } catch {
            state = .failed("Couldn't reach GitHub: \(error.localizedDescription)")
        }
    }

    // MARK: Source mode

    private static var gitCredentialArgs: [String] {
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        // Use the GitHub CLI's login, not whichever account the macOS keychain happens to hold.
        return gh.map { ["-c", "credential.helper=", "-c", "credential.helper=!\($0) auth git-credential"] } ?? []
    }

    private static func git(_ args: [String], in dir: String) async -> (status: Int32, out: String) {
        await run("/usr/bin/git", Self.gitCredentialArgs + ["-C", dir] + args, env: ["GIT_TERMINAL_PROMPT": "0"])
    }

    private func checkSource() async {
        guard let dir = Self.sourcePath else { state = .failed("Source folder unknown."); return }
        let fetch = await Self.git(["fetch", "--quiet", "origin", "main"], in: dir)
        guard fetch.status == 0 else { state = .failed("Couldn't reach GitHub: \(fetch.out)"); return }
        let remote = await Self.git(["rev-parse", "origin/main"], in: dir)
        guard remote.status == 0 else { state = .failed(remote.out); return }
        let installed = (try? String(contentsOf: Self.installedCommitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if installed == remote.out { state = .upToDate; return }
        let range = installed.isEmpty ? ["-5"] : ["\(installed)..origin/main"]
        let log = await Self.git(["log", "--pretty=format:%s"] + range, in: dir)
        commits = log.status == 0 ? log.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty } : []
        state = .available("latest")
    }

    // MARK: Installing

    private var somethingIsLive: Bool {
        guard let e = app?.engine else { return false }
        return (e.livePresentationID != nil && !e.slideCleared) || e.mediaLayer != nil
    }

    func promptInstall() async {
        guard case .available(let v) = state else { return }
        let live = somethingIsLive
        let a = NSAlert()
        if Self.hasSourceFolder {
            a.messageText = "A new version of Lumen is available"
            a.informativeText = "What's new:\n• " + (commits.isEmpty ? ["Newer code on GitHub"] : commits).prefix(6).joined(separator: "\n• ")
                + "\n\nUpdating rebuilds Lumen from GitHub in a Terminal window (using the DeckLink/NDI SDKs on this Mac), then reopens it."
        } else {
            a.messageText = "Lumen \(v) is available"
            a.informativeText = "You have \(Self.currentVersion).\n\n"
                + (release?.body?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600).description ?? "")
        }
        if live {
            a.informativeText += "\n\nSomething is on screen right now. Updating restarts Lumen and blanks every output for several seconds. Wait for a break in the service."
            a.addButton(withTitle: "Not Now")
            a.addButton(withTitle: "Install Anyway")
            guard a.runModal() == .alertSecondButtonReturn else { return }
        } else {
            a.addButton(withTitle: "Install and Restart")
            a.addButton(withTitle: "Later")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if let error = await performInstall() {
            let f = NSAlert()
            f.messageText = "The update wasn't installed"
            f.informativeText = error
            f.alertStyle = .warning
            f.runModal()
            state = .available(v)
        }
    }

    /// Returns an error message, or nil if the app is about to quit and relaunch.
    func performInstall() async -> String? {
        if Self.hasSourceFolder { return installFromSource() }
        guard let release else { return "No release information. Check for updates first." }
        state = .installing(release.version)
        app?.flash("Downloading Lumen \(release.version)…")
        let error = await installRelease(release)
        if error != nil { state = .available(release.version) }
        return error
    }

    private func installFromSource() -> String? {
        guard let dir = Self.sourcePath else { return "Source folder unknown." }
        let script = "#!/bin/zsh\ncd \"\(dir)\" && ./Scripts/update.sh\nstatus=$?\necho\n[ $status -eq 0 ] || read -k 1 '?Update failed. Press any key to close.'\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-update.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch { return error.localizedDescription }
        NSWorkspace.shared.open(url)
        return nil
    }

    /// Drops the Authorization header if GitHub redirects the download to another host (its storage CDN).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var r = request
            if r.url?.host != task.originalRequest?.url?.host { r.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(r)
        }
    }

    private func installRelease(_ release: Release) async -> String? {
        guard let asset = release.dmg, let assetURL = URL(string: asset.url) else { return "No download found." }
        let dest = Bundle.main.bundleURL
        if !Self.testMode, !Self.installedInApplications {
            return "Move Lumen into your Applications folder first, then check for updates again."
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Lumen-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            var request = URLRequest(url: assetURL, timeoutInterval: 300)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            if let token = await Self.githubToken(), assetURL.host == "api.github.com" {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (tmp, response) = try await URLSession.shared.download(for: request, delegate: RedirectGuard())
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return "Download failed (status \(http.statusCode))." }
            let dmg = work.appendingPathComponent("update.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            if let digest = asset.digest, digest.hasPrefix("sha256:") {
                let hash = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                guard hash == digest.dropFirst(7) else { return "The download didn't match its checksum, so it was not installed." }
            }

            let mount = work.appendingPathComponent("mnt")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            let attach = await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
            guard attach.status == 0 else { return "Couldn't open the download: \(attach.out)" }
            defer { Task { _ = await Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) } }

            let staged = work.appendingPathComponent("Lumen.app")
            let cp = await Self.run("/usr/bin/ditto", [mount.appendingPathComponent("Lumen.app").path, staged.path])
            guard cp.status == 0 else { return "Couldn't unpack the update: \(cp.out)" }
            guard Bundle(url: staged)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return "The download isn't Lumen, so it was not installed." }
            // Must be intact and signed by Hope Church's Developer ID — a stolen token can't push a rogue build.
            let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(Self.teamID)\""
            let verify = await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R" + requirement, staged.path])
            guard verify.status == 0 else { return "The update isn't signed by Hope Church, so it was not installed. \(verify.out)" }

            let script = work.appendingPathComponent("swap.sh")
            let text = """
            #!/bin/zsh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            mv "$1" "$1.old" || exit 1
            if ditto "$2" "$1"; then
              rm -rf "$1.old"
              xattr -dr com.apple.quarantine "$1" 2>/dev/null
            else
              rm -rf "$1"; mv "$1.old" "$1"   # put the old version back if the copy failed
            fi
            open "$1"
            rm -rf "$3"
            """
            try text.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script.path, dest.path, staged.path, work.path]
            try p.run()
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Process helper

    nonisolated static func run(_ path: String, _ args: [String], env: [String: String] = [:],
                                mergeStderr: Bool = true) async -> (status: Int32, out: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
