import Foundation
import Observation

/// All user configuration. Contains **no secrets**: tokens are always read on demand
/// from the tools that own them (gh CLI, Claude Code / Codex credentials) and never stored.
struct KodisleConfig: Codable, Equatable {
    // Surfaces
    var menuBarEnabled = true
    var islandEnabled = true
    var islandExpandOnHover = true
    var islandLiveEvents = true
    var islandAutoEars = true
    var islandLeft: WidgetID = .claude
    var islandRight: WidgetID = .agents
    var islandTabs: [WidgetID] = [.ai, .agents, .tasks, .devServers, .github, .vercel, .clipboard, .endpoints, .generator, .downloads, .whatsapp, .spotify]
    var dockEnabled = false
    var dockAutoHide = false
    /// "system" follows macOS (Desktop & Dock › Magnification), or "on" / "off".
    var dockMagnification = "system"
    var dockIconSize: Double = 52
    var dockMatchSystemSize = true
    var dockWidgets: [WidgetID] = [.whatsapp, .spotify, .claude, .codex, .tasks, .devServers, .github, .timer, .calculator]
    /// Marks configs that were already offered the WhatsApp and Spotify widgets.
    var mediaWidgetsAdded = true
    var dockWidgetsPerPage = 3
    var dockPinnedApps: [String]?
    var systemDockBadge = false

    // Sources
    var projectsRoot = "~/Dev"
    var maxRepos = 8
    var endpoints: [Endpoint] = []
    var claudeEnabled = true
    var vercelEnabled = true
    var clipboardEnabled = true
    var codexEnabled = true
    var aiRefreshSeconds: Double = 180
    var githubRefreshSeconds: Double = 120
    var endpointRefreshSeconds: Double = 60
    var agentIdleSeconds: Double = 25

    // Privacy & tools
    var privacyMode = false
    var autoUpdateCheck = true
    var agentSummaries = true
    /// Island banner when Claude Code adds or completes a task.
    var tasksEvents = true
    var clipboardClearSeconds: Double = 60
    var focusMinutes: Double = 25
    var breakMinutes: Double = 5

    var projectsRootURL: URL {
        URL(fileURLWithPath: (projectsRoot as NSString).expandingTildeInPath)
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private static let key = "kodisle.config.v1"

    var config: KodisleConfig {
        didSet { if config != oldValue { persist() } }
    }

    private init() { config = Self.load() }

    /// Merges the stored JSON over the defaults so new keys never break old installs.
    private static func load() -> KodisleConfig {
        let defaults = KodisleConfig()
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseData = try? JSONEncoder().encode(defaults),
              let base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
        else { return defaults }
        var merged = base.merging(stored) { _, new in new }
        // Migration: configs saved before Vercel/Clipboard existed get those tabs once.
        if stored["vercelEnabled"] == nil, var tabs = stored["islandTabs"] as? [String] {
            for tab in ["vercel", "clipboard"] where !tabs.contains(tab) { tabs.append(tab) }
            merged["islandTabs"] = tabs
        }
        // Migration: configs saved before Tasks existed get the tab and the dock tile once.
        if stored["tasksEvents"] == nil {
            for key in ["islandTabs", "dockWidgets"] {
                if var widgets = merged[key] as? [String], !widgets.contains("tasks") {
                    widgets.append("tasks")
                    merged[key] = widgets
                }
            }
        }
        // Migration: configs saved before WhatsApp and Spotify existed get them once.
        if stored["mediaWidgetsAdded"] == nil {
            if var widgets = merged["dockWidgets"] as? [String] {
                widgets.insert(contentsOf: ["whatsapp", "spotify"].filter { !widgets.contains($0) }, at: 0)
                merged["dockWidgets"] = widgets
            }
            if var tabs = merged["islandTabs"] as? [String] {
                tabs.append(contentsOf: ["whatsapp", "spotify"].filter { !tabs.contains($0) })
                merged["islandTabs"] = tabs
            }
        }
        // Migration: magnification used to be a Bool.
        if merged["dockMagnification"] is Bool { merged["dockMagnification"] = "system" }
        // Migration: users who already picked a custom dock size keep it.
        if stored["dockMatchSystemSize"] == nil, let size = stored["dockIconSize"] as? Double, size != 48 {
            merged["dockMatchSystemSize"] = false
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(KodisleConfig.self, from: mergedData)
        else { return defaults }
        return config
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func reset() { config = KodisleConfig() }
}
