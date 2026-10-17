import AppKit
import Foundation
import Security

struct ReleaseInfo: Equatable {
    var version: String
    var tag: String
    var title: String
    var notes: String
    var htmlURL: URL
    var assetURL: URL
    var assetName: String
    var assetSize: Int64
}

enum UpdateError: LocalizedError {
    case badResponse, http(Int), noAsset, noAppInArchive, invalidSignature, teamMismatch(String?, String?)
    case translocated, notWritable(String), versionMismatch, toolFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from GitHub."
        case .http(let c): return c == 404 ? "No release published yet." : "GitHub returned HTTP \(c)."
        case .noAsset: return "The latest release has no Makstat zip attached."
        case .noAppInArchive: return "The downloaded archive does not contain Makstat.app."
        case .invalidSignature: return "The downloaded app has an invalid code signature."
        case .teamMismatch(let mine, let theirs):
            return "The downloaded app is signed by a different team (\(theirs ?? "ad hoc")) than this copy (\(mine ?? "ad hoc")). Refusing to install."
        case .translocated: return "Makstat is running from a quarantined location. Move it to /Applications first."
        case .notWritable(let p): return "Cannot write to \(p)."
        case .versionMismatch: return "The downloaded app is not newer than this one."
        case .toolFailed(let t, let c): return "\(t) failed with exit code \(c)."
        }
    }
}

/// Checks GitHub releases for a newer build and installs it over the running bundle.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "KarpelesLab/makstat"
    static let checkInterval: TimeInterval = 6 * 3600

    enum State: Equatable {
        case idle, checking, upToDate, available, downloading(Double), installing, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var lastCheck: Date?
    private var timer: Timer?
    private var notifiedVersion: String?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    // MARK: Scheduling

    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.automaticCheck() }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            await automaticCheck()
        }
    }

    private func automaticCheck() async {
        guard UserDefaults.standard.bool(forKey: PrefKey.autoUpdate) else { return }
        await check()
        if let r = available, notifiedVersion != r.version {
            notifiedVersion = r.version
            Notifier.send(title: "Makstat \(r.version) is available",
                          body: "Open the Makstat menu and click Update to install it.")
        }
    }

    // MARK: Checking

    @discardableResult
    func check() async -> ReleaseInfo? {
        if state == .checking { return available }
        state = .checking
        do {
            let release = try await fetchLatest()
            lastCheck = Date()
            if Self.isNewer(release.version, than: currentVersion) {
                available = release
                state = .available
            } else {
                available = nil
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
        return available
    }

    private func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Makstat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int64 }
        struct Release: Decodable {
            let tag_name: String; let name: String?; let body: String?; let html_url: URL; let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("Makstat") && $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noAsset
        }
        var version = release.tag_name
        if version.hasPrefix("v") { version.removeFirst() }
        return ReleaseInfo(version: version, tag: release.tag_name, title: release.name ?? release.tag_name,
                           notes: release.body ?? "", htmlURL: release.html_url,
                           assetURL: asset.browser_download_url, assetName: asset.name, assetSize: asset.size)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func promptAndInstall() {
        guard let r = available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Makstat \(r.version) is available"
        var text = "You have \(currentVersion). The update will be downloaded, installed over this copy and relaunched."
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "\n\n" + String(notes.prefix(600)) }
        alert.informativeText = text
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await install() }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.htmlURL)
        default: break
        }
    }

    func install() async {
        guard let r = available else { return }
        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("makstat-update-\(UUID().uuidString)", isDirectory: true)
        do {
            guard !bundleURL.path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
            guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

            state = .downloading(0)
            let zip = tmp.appendingPathComponent(r.assetName)
            try await download(r.assetURL, to: zip, expectedSize: r.assetSize)

            state = .installing
            let extracted = tmp.appendingPathComponent("extract", isDirectory: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            guard let newApp = Self.findApp(in: extracted) else { throw UpdateError.noAppInArchive }
            try verifySignature(of: newApp)
            let newVersion = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard Self.isNewer(newVersion, than: currentVersion) else { throw UpdateError.versionMismatch }
            // We verified the signature ourselves; drop quarantine so Gatekeeper does not block the relaunch.
            try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            let backup = tmp.appendingPathComponent("previous.app")
            try FileManager.default.moveItem(at: bundleURL, to: backup)
            do {
                try FileManager.default.moveItem(at: newApp, to: bundleURL)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: bundleURL)
                throw error
            }
            Monitor.shared.store.log(.info, "Updated Makstat \(currentVersion) → \(newVersion); previous copy in \(backup.path)")
            relaunch(bundleURL)
        } catch {
            state = .failed(error.localizedDescription)
            Monitor.shared.store.log(.error, "Update to \(r.version) failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func download(_ url: URL, to file: URL, expectedSize: Int64) async throws {
        var request = URLRequest(url: url)
        request.setValue("Makstat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.badResponse }
        let total = http.expectedContentLength > 0 ? http.expectedContentLength : expectedSize
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                handle.write(buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { state = .downloading(Double(received) / Double(total)) }
            }
        }
        handle.write(buffer)
        state = .downloading(1)
    }

    private static func findApp(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let app = findApp(in: sub) { return app }
        }
        return nil
    }

    /// The new bundle must carry a valid signature and, if this copy was signed by a team, the same team.
    private func verifySignature(of app: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw UpdateError.invalidSignature
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw UpdateError.invalidSignature }
        let theirs = Self.teamIdentifier(of: code)
        let mine = Self.currentTeamIdentifier()
        if let mine, theirs != mine { throw UpdateError.teamMismatch(mine, theirs) }
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func currentTeamIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError.toolFailed((tool as NSString).lastPathComponent, p.terminationStatus) }
    }

    private func relaunch(_ app: URL) {
        let pid = getpid()
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(app.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }
}
