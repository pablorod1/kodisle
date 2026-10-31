import AppKit
import Foundation

/// Hides / restores the macOS Dock so Kodisle's dock can replace it.
///
/// We only flip `autohide` and set a huge `autohide-delay` — the same thing users do from
/// Terminal. The previous values are remembered and restored when Kodisle's dock is disabled
/// or the app quits. If Kodisle ever crashes, `scripts/restore-dock.sh` puts everything back.
enum SystemDock {
    private static let savedKey = "kodisle.systemDock.saved"
    private static let dock = UserDefaults(suiteName: "com.apple.dock")

    /// Icon size of the macOS Dock (System Settings › Desktop & Dock › Size).
    static var tileSize: CGFloat? {
        (dock?.object(forKey: "tilesize") as? NSNumber).map { CGFloat(truncating: $0) }
    }

    /// Magnification as configured for the macOS Dock.
    static var magnification: (enabled: Bool, largeSize: CGFloat?) {
        (dock?.bool(forKey: "magnification") ?? false,
         (dock?.object(forKey: "largesize") as? NSNumber).map { CGFloat(truncating: $0) })
    }

    static var isHiddenByKodisle: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }

    static func hide() {
        guard !isHiddenByKodisle else { return }
        var saved: [String: Any] = ["autohide": dock?.object(forKey: "autohide") as? Bool ?? false]
        if let delay = dock?.object(forKey: "autohide-delay") as? Double { saved["autohide-delay"] = delay }
        UserDefaults.standard.set(saved, forKey: savedKey)
        Task {
            _ = try? await Shell.run("defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
            _ = try? await Shell.run("defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            _ = try? await Shell.run("killall", ["Dock"])
        }
    }

    /// Synchronous so it can run from `applicationWillTerminate`.
    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        let autohide = saved["autohide"] as? Bool ?? false
        var commands: [[String]] = [["write", "com.apple.dock", "autohide", "-bool", autohide ? "true" : "false"]]
        if let delay = saved["autohide-delay"] as? Double {
            commands.append(["write", "com.apple.dock", "autohide-delay", "-float", String(delay)])
        } else {
            commands.append(["delete", "com.apple.dock", "autohide-delay"])
        }
        for args in commands { runSync("/usr/bin/defaults", args) }
        runSync("/usr/bin/killall", ["Dock"])
    }

    private static func runSync(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = Shell.minimalEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Apps pinned in the macOS Dock, used to seed Kodisle's dock on first run.
    static func pinnedApps() -> [String] {
        let items = dock?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let tile = item["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let urlString = file["_CFURLString"] as? String else { return nil }
            let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
            return url.path.isEmpty ? nil : url.path
        }
    }
}
