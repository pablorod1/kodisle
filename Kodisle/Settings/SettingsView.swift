import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView().kodisleEnvironment())
            let window = NSWindow(contentViewController: controller)
            window.title = "Kodisle Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DockSettings().tabItem { Label("Dock", systemImage: "dock.rectangle") }
            IslandSettings().tabItem { Label("Island", systemImage: "capsule.tophalf.filled") }
            SourcesSettings().tabItem { Label("Sources", systemImage: "point.3.connected.trianglepath.dotted") }
            IntegrationSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Surfaces") {
                Toggle("Dynamic island around the notch", isOn: $settings.config.islandEnabled)
                Toggle("Menu bar item", isOn: $settings.config.menuBarEnabled)
                Toggle("Kodisle dock (replaces the macOS Dock)", isOn: $settings.config.dockEnabled)
                Toggle("Badge in the macOS Dock", isOn: $settings.config.systemDockBadge)
                    .disabled(settings.config.dockEnabled)
                    .help("Shows Kodisle in the system Dock with a badge for failing CI, reviews, endpoints down and agents waiting.")
            }
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                HStack {
                    Text("Focus timer")
                    Spacer()
                    Stepper("\(Int(settings.config.focusMinutes)) min focus", value: $settings.config.focusMinutes, in: 5...90, step: 5)
                    Stepper("\(Int(settings.config.breakMinutes)) min break", value: $settings.config.breakMinutes, in: 1...30)
                }
            }
            Section {
                Button("Reset all settings", role: .destructive) { settings.reset() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WidgetOrderEditor: View {
    @Binding var selection: [WidgetID]
    var available: [WidgetID] = WidgetID.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(selection.enumerated()), id: \.element) { index, id in
                HStack {
                    Image(systemName: id.symbol).frame(width: 20)
                    Text(id.title)
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == selection.count - 1)
                    Button { selection.remove(at: index) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                }
                .buttonStyle(.borderless)
            }
            Menu("Add widget") {
                ForEach(available.filter { !selection.contains($0) }) { id in
                    Button { selection.append(id) } label: { Label(id.title, systemImage: id.symbol) }
                }
            }
            .fixedSize()
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard selection.indices.contains(target) else { return }
        selection.swapAt(index, target)
    }
}

private struct DockSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Enable Kodisle dock", isOn: $settings.config.dockEnabled)
                Text("Kodisle hides the macOS Dock (auto-hide with a long delay) and restores your original settings when you disable it or quit. If anything goes wrong, run scripts/restore-dock.sh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Toggle("Match macOS Dock size\(SystemDock.tileSize.map { " (\(Int($0)) pt)" } ?? "")", isOn: $settings.config.dockMatchSystemSize)
                Slider(value: $settings.config.dockIconSize, in: 32...80, step: 2) { Text("Icon size") }
                    .disabled(settings.config.dockMatchSystemSize)
                Picker("Magnification", selection: $settings.config.dockMagnification) {
                    Text("Same as macOS (\(SystemDock.magnification.enabled ? "on" : "off"))").tag("system")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                Toggle("Auto-hide (reveal at the bottom edge)", isOn: $settings.config.dockAutoHide)
                Stepper("\(settings.config.dockWidgetsPerPage) widgets per page", value: $settings.config.dockWidgetsPerPage, in: 1...6)
            }
            Section("Widgets in the dock") {
                WidgetOrderEditor(selection: $settings.config.dockWidgets, available: WidgetID.allCases.filter { $0 != .downloads })
            }
            Section("Pinned apps") {
                Text("Right-click an app in the Kodisle dock to keep or remove it.").font(.caption).foregroundStyle(.secondary)
                Button("Re-import from macOS Dock") { settings.config.dockPinnedApps = SystemDock.pinnedApps() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct IslandSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Enable dynamic island", isOn: $settings.config.islandEnabled)
                Toggle("Expand on hover", isOn: $settings.config.islandExpandOnHover)
                Toggle("Live activities (agent finished, CI failed, endpoint down…)", isOn: $settings.config.islandLiveEvents)
            }
            Section("Around the notch") {
                Picker("Left", selection: $settings.config.islandLeft) {
                    ForEach(WidgetID.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker(settings.config.islandAutoEars ? "Right (when nothing is active)" : "Right", selection: $settings.config.islandRight) {
                    ForEach(WidgetID.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Toggle("Show what's active on the right automatically", isOn: $settings.config.islandAutoEars)
                Text("Approvals, focus timer, agents working, deploys, CI, endpoints down and dev servers. Rotates every 4 s when several are active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tabs (also used by the menu bar)") {
                WidgetOrderEditor(selection: $settings.config.islandTabs,
                                  available: WidgetID.allCases.filter { $0 != .claude && $0 != .codex && $0 != .battery })
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourcesSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KodisleStore.self) private var store

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("AI providers") {
                Toggle("Claude Code limits", isOn: $settings.config.claudeEnabled)
                Toggle("Codex limits", isOn: $settings.config.codexEnabled)
                Picker("Refresh every", selection: $settings.config.aiRefreshSeconds) {
                    Text("1 min").tag(60.0); Text("3 min").tag(180.0); Text("5 min").tag(300.0); Text("15 min").tag(900.0)
                }
            }
            Section("Projects & GitHub") {
                HStack {
                    TextField("Projects folder", text: $settings.config.projectsRoot)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.config.projectsRoot = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                            Task { await store.refreshRepos() }
                        }
                    }
                }
                Stepper("Track \(settings.config.maxRepos) most recent repos", value: $settings.config.maxRepos, in: 1...30)
                Picker("GitHub refresh", selection: $settings.config.githubRefreshSeconds) {
                    Text("1 min").tag(60.0); Text("2 min").tag(120.0); Text("5 min").tag(300.0)
                }
                Text("GitHub uses the `gh` CLI — Kodisle never sees your token. Run `gh auth login` once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Endpoints") {
                ForEach($settings.config.endpoints) { $endpoint in
                    HStack {
                        TextField("Name", text: $endpoint.name).frame(width: 120)
                        TextField("URL", text: $endpoint.url)
                        Picker("", selection: $endpoint.method) { Text("GET").tag("GET"); Text("HEAD").tag("HEAD") }
                            .labelsHidden().frame(width: 80)
                        Button { settings.config.endpoints.removeAll { $0.id == endpoint.id } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add endpoint") { settings.config.endpoints.append(Endpoint(name: "API", url: "https://")) }
                Picker("Check every", selection: $settings.config.endpointRefreshSeconds) {
                    Text("30 s").tag(30.0); Text("1 min").tag(60.0); Text("5 min").tag(300.0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var approvals = Integrations.claudeApprovalsInstalled
    @State private var zsh = Integrations.zshInstalled
    @State private var error: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Approve Claude Code permissions from the island", isOn: Binding(get: { approvals }, set: { enable in
                    run { enable ? try Integrations.installClaudeApprovals() : try Integrations.uninstallClaudeApprovals() }
                    approvals = Integrations.claudeApprovalsInstalled
                }))
                Text("Adds a `PermissionRequest` hook to ~/.claude/settings.json (a backup is saved next to it). When Claude Code asks for permission, the island shows the command with Allow / Always allow / Deny. If Kodisle isn't running, Claude Code asks in the terminal as usual. Restart running Claude Code sessions after enabling.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Claude Code") }

            Section {
                Toggle("Notify when long terminal commands finish", isOn: Binding(get: { zsh }, set: { enable in
                    run { enable ? try Integrations.installZsh() : try Integrations.uninstallZsh() }
                    zsh = Integrations.zshInstalled
                }))
                Text("Adds one line to ~/.zshrc (backup saved). Commands that take longer than 15 s notify the island with ✓ / ✗ and the duration. Only the program and subcommand (e.g. `pnpm build`) are sent — never arguments. Change the threshold with `export KODISLE_MIN_SECONDS=30`. Open a new terminal tab after enabling.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Terminal (zsh)") }

            Section {
                Toggle("Vercel deployments", isOn: $settings.config.vercelEnabled)
                Text("Uses your Vercel CLI session (read-only, never refreshed). Run `vercel login` once.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Clipboard history (in memory only)", isOn: $settings.config.clipboardEnabled)
                    .onChange(of: settings.config.clipboardEnabled) { _, on in if on { ClipboardHistory.shared.start() } }
            } header: { Text("Services") }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ work: () throws -> Void) {
        do { try work(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct PrivacySettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Privacy mode (hide project names, URLs and titles — for screen sharing)", isOn: $settings.config.privacyMode)
                Toggle("Show what agents did in notifications (reads their last reply)", isOn: $settings.config.agentSummaries)
                Picker("Clear copied passwords after", selection: $settings.config.clipboardClearSeconds) {
                    Text("Never").tag(0.0); Text("30 s").tag(30.0); Text("1 min").tag(60.0); Text("2 min").tag(120.0)
                }
            }
            Section("How Kodisle handles your data") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Everything runs locally. No analytics, no telemetry, no servers of ours.", systemImage: "desktopcomputer")
                    Label("Tokens are never stored. GitHub goes through `gh`; Claude/Codex tokens are read on demand, used for one request and discarded — never refreshed.", systemImage: "key.slash")
                    Label("Child processes get a minimal environment, so your shell's secret env vars never leak.", systemImage: "terminal")
                    Label("Process arguments are never read (they often contain tokens). Only names, ports and folders.", systemImage: "eye.slash")
                    Label("From agent transcripts Kodisle reads metadata, the session title and — if enabled — the agent's last reply, condensed to one line, kept in memory only.", systemImage: "text.badge.checkmark")
                    Label("URLs are shown without credentials or query strings.", systemImage: "link")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
