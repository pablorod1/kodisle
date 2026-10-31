import AppKit
import CryptoKit
import Observation

/// Checks GitHub Releases for a newer Kodisle and installs it in place.
///
/// - One anonymous request to `api.github.com` per day (no token, nothing sent about you).
/// - Updates are verified against the release's published SHA-256 before anything is replaced.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repo = "pablorod1/kodisle"

    struct Release: Equatable { let version: String; let notesURL: String }

    private(set) var available: Release?
    private(set) var checking = false
    private(set) var installing = false
    private(set) var error: String?
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "kodisle.update.lastChecked") as? Date

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func checkIfDue() async {
        guard AppSettings.shared.config.autoUpdateCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 86_400 { return }
        await check(announce: true)
    }

    func check(announce: Bool = false) async {
        checking = true
        defer { checking = false }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kodisle/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await Net.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw URLError(.badServerResponse) }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "kodisle.update.lastChecked")
            error = nil
            if Self.isNewer(version, than: currentVersion) {
                let release = Release(version: version, notesURL: json["html_url"] as? String ?? "https://github.com/\(Self.repo)/releases")
                let isNew = available != release
                available = release
                if announce && isNew {
                    KodisleStore.shared.post(KodisleEvent(symbol: "arrow.down.app.fill", title: "Kodisle \(version) is available",
                                                          subtitle: "Open Settings › General to update", tint: .blue, widget: nil), duration: 8)
                }
            } else {
                available = nil
            }
        } catch {
            self.error = "Couldn't check for updates"
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads, verifies and swaps the app bundle, then relaunches.
    func install() async {
        guard let release = available, !installing else { return }
        installing = true
        error = nil
        defer { installing = false }
        let base = "https://github.com/\(Self.repo)/releases/download/v\(release.version)"
        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            error = "No permission to update \(parent). Re-run the installer."
            return
        }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kodisle-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (zipURL, _) = try await Net.session.download(from: URL(string: "\(base)/Kodisle.zip")!)
            let (sumData, _) = try await Net.session.data(from: URL(string: "\(base)/Kodisle.zip.sha256")!)
            let zip = tmp.appendingPathComponent("Kodisle.zip")
            try FileManager.default.moveItem(at: zipURL, to: zip)

            let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else { throw UpdateError.checksum }

            let unpack = try await Shell.run("ditto", ["-x", "-k", zip.path, tmp.appendingPathComponent("app").path], timeout: 60)
            let newApp = tmp.appendingPathComponent("app/Kodisle.app").path
            guard unpack.ok, FileManager.default.fileExists(atPath: newApp) else { throw UpdateError.archive }

            // A detached helper waits for this process to quit, swaps the bundle and relaunches.
            let script = """
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(appPath)" && mv "\(newApp)" "\(appPath)"
            xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null
            open "\(appPath)"
            rm -rf "\(tmp.path)"
            """
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script]
            helper.environment = Shell.minimalEnvironment
            try helper.run()
            NSApp.terminate(nil)
        } catch let e as UpdateError {
            error = e.message
        } catch {
            self.error = "Update failed: \(error.localizedDescription)"
        }
    }

    enum UpdateError: Error {
        case checksum, archive
        var message: String { self == .checksum ? "Checksum mismatch — update aborted" : "Unexpected update archive" }
    }
}
