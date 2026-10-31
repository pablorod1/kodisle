import AppKit
import SwiftUI

@main
struct KodisleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $settings.config.menuBarEnabled) {
            MenuBarView().kodisleEnvironment()
        } label: {
            MenuBarLabel().environment(KodisleStore.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController?
    private var dock: DockController?
    private var badgeTask: Task<Void, Never>?
    private var settingsWatch: Task<Void, Never>?
    private var badgeEnabled: Bool?
    private var signalSources: [DispatchSourceSignal] = []
    /// `-KodisleDebugDock <widget>` shows the dock for this run only, without persisting the setting.
    private let debugDock = UserDefaults.standard.string(forKey: "KodisleDebugDock") != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If a previous run crashed while the Kodisle dock was active, put the macOS Dock back first.
        if !AppSettings.shared.config.dockEnabled && !debugDock { SystemDock.restore() }
        installSignalHandlers()
        DockController.forceReveal = debugDock
        KodisleStore.shared.start()
        applySurfaces()
        watchSettings()
        applyDebugArguments()
        if !AppSettings.shared.config.menuBarEnabled && !AppSettings.shared.config.islandEnabled && !AppSettings.shared.config.dockEnabled {
            SettingsWindow.shared.show()
        }
    }

    /// Development helpers, e.g. `open Kodisle.app --args -KodisleDebugIsland github`
    /// or `-KodisleDebugDock generator` to open a surface without hovering (used for screenshots).
    private func applyDebugArguments() {
        let defaults = UserDefaults.standard
        if let tab = defaults.string(forKey: "KodisleDebugIsland").flatMap(WidgetID.init(rawValue:)) {
            Task {
                try? await Task.sleep(for: .seconds(4))
                island?.model.pinned = true
                island?.expand(tab: tab)
            }
        }
        if defaults.string(forKey: "KodisleDebugEvent") != nil {
            // Replays an "agent finished" banner using the most recent real session.
            Task {
                try? await Task.sleep(for: .seconds(6))
                let store = KodisleStore.shared
                guard let s = store.agents.first(where: { $0.summary != nil }) ?? store.agents.first else { return }
                store.post(KodisleEvent(symbol: "checkmark.seal.fill", title: "\(s.provider.shortName) finished",
                                        subtitle: [s.title, s.project].compactMap { $0 }.joined(separator: " · "),
                                        tint: .green, widget: .agents, detail: s.summary), duration: 30)
            }
        }
        if let widget = defaults.string(forKey: "KodisleDebugDock").flatMap(WidgetID.init(rawValue:)), let dock {
            Task {
                try? await Task.sleep(for: .seconds(4))
                dock.model.panelAnchorX = dock.model.dockFrame.midX
                dock.model.openPanel = widget
            }
        }
    }

    /// `kill`/`pkill`/logout send SIGTERM, which skips `applicationWillTerminate`.
    /// Route it through a normal quit so the macOS Dock is always restored.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        KodisleStore.shared.stopBridge()
        SystemDock.restore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let store = KodisleStore.shared
        let menu = NSMenu()
        func item(_ title: String) { menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        if let c = store.claude?.fiveHour { item("Claude: \(Fmt.percent(c.usedPercent)) · \(Fmt.resetIn(c.resetsAt))") }
        if let c = store.codex?.fiveHour { item("Codex: \(Fmt.percent(c.usedPercent)) · \(Fmt.resetIn(c.resetsAt))") }
        item("Dev servers: \(store.devServers.count)")
        if let gh = store.github { item("Failing CI: \(gh.failingRuns.count) · Reviews: \(gh.reviewRequests.count)") }
        return menu
    }

    private func applySurfaces() {
        let config = AppSettings.shared.config
        if config.islandEnabled, island == nil { island = IslandController() }
        if !config.islandEnabled, let current = island { current.tearDown(); island = nil }
        let dockOn = config.dockEnabled || debugDock
        if dockOn, dock == nil { dock = DockController() }
        if !dockOn, let current = dock { current.tearDown(); dock = nil }
        applyBadge(config.systemDockBadge && !dockOn)
    }

    private func applyBadge(_ enabled: Bool) {
        guard enabled != badgeEnabled else { return }
        badgeEnabled = enabled
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
        badgeTask?.cancel()
        guard enabled else { NSApp.dockTile.badgeLabel = nil; return }
        badgeTask = Task {
            while !Task.isCancelled {
                let count = KodisleStore.shared.attentionCount
                NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Re-applies surfaces whenever the relevant settings change.
    private func watchSettings() {
        settingsWatch = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        let c = AppSettings.shared.config
                        _ = (c.islandEnabled, c.dockEnabled, c.systemDockBadge)
                    } onChange: { continuation.resume() }
                }
                try? await Task.sleep(for: .milliseconds(50))
                self?.applySurfaces()
            }
        }
    }
}
