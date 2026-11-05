import SwiftUI

/// Compact tile shown in the dock (and menu bar summary).
struct WidgetTile: View {
    let id: WidgetID
    @Environment(KodisleStore.self) private var store
    private var timer: FocusTimer { .shared }
    private var calc: CalculatorModel { .shared }
    private var todos: TodoList { .shared }

    var body: some View {
        content.trackVisibility(id)
    }

    @ViewBuilder private var content: some View {
        switch id {
        case .ai:
            TileLayout(title: "AI usage", subtitle: aiSubtitle) {
                HStack(spacing: -8) {
                    UsageRing(percent: store.claude?.fiveHour?.usedPercent ?? 0, size: 26, lineWidth: 3, showsLabel: false)
                    UsageRing(percent: store.codex?.fiveHour?.usedPercent ?? 0, size: 26, lineWidth: 3, showsLabel: false)
                }
            }
        case .claude: aiTile(.claude, store.claude, store.claudeError)
        case .codex: aiTile(.codex, store.codex, store.codexError)
        case .agents:
            let running = store.runningAgents
            TileLayout(title: running.isEmpty ? "Agents idle" : "\(running.count) agent\(running.count == 1 ? "" : "s")",
                       subtitle: running.first.map { "\($0.provider.shortName) · \($0.project)" } ?? "No active sessions",
                       sensitive: true) {
                if running.contains(where: { $0.state == .waiting }) {
                    TileIcon(symbol: "hand.raised.fill", tint: .orange)
                } else if !running.isEmpty {
                    TileIcon(symbol: "sparkles", tint: .purple)
                } else {
                    TileIcon(symbol: "sparkles", tint: .secondary)
                }
            }
        case .devServers:
            TileLayout(title: store.devServers.isEmpty ? "No servers" : "\(store.devServers.count) server\(store.devServers.count == 1 ? "" : "s")",
                       subtitle: store.devServers.isEmpty ? "Nothing listening" : store.devServers.flatMap(\.ports).prefix(4).map { ":\($0)" }.joined(separator: " ")) {
                TileIcon(symbol: "server.rack", tint: store.devServers.isEmpty ? .secondary : .green)
            }
        case .github:
            let failing = store.github?.failingRuns.count ?? 0
            let reviews = store.github?.reviewRequests.count ?? 0
            TileLayout(title: store.github.map { "\($0.myPRs.count) PRs · \(reviews) review\(reviews == 1 ? "" : "s")" } ?? "GitHub",
                       subtitle: store.githubError ?? (failing > 0 ? "\(failing) failing workflow\(failing == 1 ? "" : "s")" : "CI green")) {
                TileIcon(symbol: failing > 0 ? "xmark.octagon.fill" : "arrow.triangle.pull", tint: failing > 0 ? .red : .primary)
            }
        case .git:
            let repo = store.repos.first
            TileLayout(title: repo?.branch ?? "No repos", subtitle: repo.map { "\($0.name) · \($0.changes) changes" } ?? "Set projects folder", sensitive: true) {
                TileIcon(symbol: "arrow.triangle.branch", tint: (repo?.changes ?? 0) > 0 ? .orange : .primary)
            }
        case .endpoints:
            let statuses = store.endpointStatus.values
            let up = statuses.filter(\.ok).count
            let avg = statuses.compactMap(\.latencyMs).reduce(0, +) / Double(max(1, statuses.compactMap(\.latencyMs).count))
            TileLayout(title: statuses.isEmpty ? "Endpoints" : "\(up)/\(statuses.count) up",
                       subtitle: statuses.isEmpty ? "Add a URL to monitor" : "avg \(Int(avg)) ms") {
                TileIcon(symbol: "antenna.radiowaves.left.and.right", tint: up < statuses.count ? .red : .green)
            }
        case .docker:
            let running = store.containers.filter(\.isRunning).count
            TileLayout(title: store.dockerAvailable ? "\(running) running" : "Docker", subtitle: store.dockerAvailable ? "\(store.containers.count) containers" : "Not running") {
                TileIcon(symbol: "shippingbox.fill", tint: running > 0 ? .blue : .secondary)
            }
        case .system:
            let system = store.system
            TileLayout(title: "CPU \(Int(system.cpu * 100))%",
                       subtitle: "RAM \(Fmt.percent(system.memoryPercent)) · Disk \(Fmt.percent(system.diskPercent))") {
                SystemRings(cpu: system.cpu * 100, memory: system.memoryPercent, disk: system.diskPercent)
            }
        case .battery:
            let b = store.system.battery
            TileLayout(title: b.map { "\($0.percent)%" } ?? "AC power",
                       subtitle: b.map { $0.isCharging ? "Charging" : $0.onAC ? "Charged" : ($0.minutesRemaining.map { "\(Fmt.duration(Double($0 * 60))) left" } ?? "On battery") } ?? "No battery") {
                TileIcon(symbol: b?.onAC == true ? "powerplug.fill" : "battery.75percent", tint: (b?.percent ?? 100) < 20 ? .red : .green)
            }
        case .timer:
            TileLayout(title: Fmt.clock(timer.remaining), subtitle: timer.phase.rawValue + (timer.completedSessions > 0 ? " · \(timer.completedSessions) done" : "")) {
                Button { timer.toggle() } label: {
                    ZStack {
                        UsageRing(percent: timer.progress * 100, tint: .orange, size: 32, lineWidth: 3, showsLabel: false)
                        Image(systemName: timer.isRunning ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
            }
        case .calculator:
            TileLayout(title: "Calculator", subtitle: calc.history.first.map { "= \($0.result)" } ?? "Click to calculate") {
                TileIcon(symbol: "plus.forwardslash.minus", tint: .primary)
            }
        case .generator:
            TileLayout(title: "Generator", subtitle: "Passwords · UUID · Lorem") {
                TileIcon(symbol: "key.horizontal.fill", tint: .yellow)
            }
        case .vercel:
            let latest = store.deployments.first
            TileLayout(title: latest.map { $0.project } ?? "Vercel",
                       subtitle: store.vercelError ?? latest.map { "\($0.state.capitalized) · \(Fmt.ago($0.created))" } ?? "No deployments",
                       sensitive: true) {
                ZStack {
                    TileIcon(symbol: "triangle.fill", tint: .primary)
                    if let latest { Circle().fill(latest.color).frame(width: 9, height: 9).offset(x: 12, y: 10) }
                }
            }
        case .tasks:
            let pending = todos.pendingCount, done = todos.doneTodayCount
            TileLayout(title: pending == 0 ? "All done" : "\(pending) pending",
                       subtitle: todos.next?.title ?? (done > 0 ? "\(done) done today" : "Add a task"),
                       sensitive: true) {
                UsageRing(percent: pending + done == 0 ? 0 : Double(done) / Double(pending + done) * 100,
                          tint: .indigo, size: 32, lineWidth: 3.5, showsLabel: false)
                    .overlay(Image(systemName: "checklist").font(.system(size: 11, weight: .bold)).foregroundStyle(.indigo))
            }
        case .clipboard:
            let clips = ClipboardHistory.shared.items
            TileLayout(title: "Clipboard", subtitle: clips.first.map { $0.masked.replacingOccurrences(of: "\n", with: " ") } ?? "Copy something", sensitive: true) {
                TileIcon(symbol: "doc.on.clipboard.fill", tint: .teal)
            }
        case .whatsapp: WhatsAppTile()
        case .spotify: SpotifyTile()
        case .downloads:
            TileLayout(title: "Downloads", subtitle: store.downloads.first?.name ?? "Recent files", sensitive: true) {
                TileIcon(symbol: "arrow.down.circle.fill", tint: .blue)
            }
            .onAppear { store.ensureDownloads() }
        }
    }

    private var aiSubtitle: String {
        [store.claude.map { "Claude \(Fmt.percent($0.fiveHour?.usedPercent ?? 0))" },
         store.codex.map { "Codex \(Fmt.percent($0.fiveHour?.usedPercent ?? 0))" }]
            .compactMap { $0 }.joined(separator: " · ").ifEmpty("No providers")
    }

    @ViewBuilder
    private func aiTile(_ provider: AIProvider, _ usage: AIUsage?, _ error: String?) -> some View {
        if let usage {
            TileLayout(title: "\(provider.shortName) \(Fmt.percent(usage.fiveHour?.usedPercent ?? 0))",
                       subtitle: "Week \(Fmt.percent(usage.weekly?.usedPercent ?? 0)) · \(Fmt.resetIn(usage.fiveHour?.resetsAt, short: true))") {
                UsageRing(percent: usage.fiveHour?.usedPercent ?? 0, size: 32, lineWidth: 3.5, showsLabel: false)
                    .overlay(Image(systemName: provider.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(provider.tint))
            }
        } else {
            TileLayout(title: provider.shortName, subtitle: error ?? "Loading…") {
                TileIcon(symbol: provider.symbol, tint: provider.tint)
            }
        }
    }
}

/// Tiny glyph for the island "ears" around the notch.
struct CompactGlyph: View {
    let id: WidgetID
    @Environment(KodisleStore.self) private var store

    var body: some View {
        content.trackVisibility(id)
    }

    private var content: some View {
        HStack(spacing: 5) {
            switch id {
            case .ai, .claude, .codex:
                let usage = id == .codex ? store.codex : store.claude ?? store.codex
                if let usage, let p = usage.fiveHour?.usedPercent {
                    UsageRing(percent: p, size: 16, lineWidth: 2.5, showsLabel: false)
                    Text(Fmt.percent(p)).monospacedDigit()
                } else {
                    Image(systemName: id.symbol)
                }
            case .agents:
                let running = store.runningAgents
                if running.contains(where: { $0.state == .waiting }) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Wait")
                } else if !running.isEmpty {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text("\(running.count)")
                } else {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                }
            case .tasks:
                Image(systemName: "checklist").foregroundStyle(.secondary)
                Text("\(TodoList.shared.pendingCount)").monospacedDigit()
            case .devServers:
                Image(systemName: "server.rack").foregroundStyle(store.devServers.isEmpty ? .secondary : Color.green)
                if store.devServers.count == 1, let port = store.devServers.first?.ports.first {
                    Text(verbatim: ":\(port)").monospacedDigit()
                } else {
                    Text("\(store.devServers.count)")
                }
            case .github:
                let failing = store.github?.failingRuns.count ?? 0
                let running = store.github?.runs.contains { $0.status != "completed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-1800) } ?? false
                if running {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("CI")
                } else {
                    Image(systemName: failing > 0 ? "xmark.octagon.fill" : "checkmark.circle.fill").foregroundStyle(failing > 0 ? .red : .green)
                    Text("\(store.github?.reviewRequests.count ?? 0)")
                }
            case .vercel:
                let active = store.deployments.first(where: \.isActive)
                Image(systemName: "triangle.fill").foregroundStyle(active == nil ? Color.white : .orange)
                Text(active == nil ? (store.deployments.first?.state.capitalized ?? "—") : "Deploy")
            case .endpoints:
                let down = store.endpointStatus.values.filter { !$0.ok }.count
                StatusDot(color: down > 0 ? .red : .green)
                Text(down > 0 ? "\(down) down" : "OK")
            case .timer:
                Image(systemName: "timer").foregroundStyle(.orange)
                Text(Fmt.clock(FocusTimer.shared.remaining)).monospacedDigit()
            case .system:
                Image(systemName: "cpu")
                Text("\(Int(store.system.cpu * 100))%").monospacedDigit()
            case .battery:
                Image(systemName: "battery.75percent")
                Text("\(store.system.battery?.percent ?? 100)%")
            case .whatsapp:
                Image(systemName: "message.fill").foregroundStyle(.green)
                Text("\(store.whatsapp.alerting.count)").monospacedDigit()
            case .spotify:
                Image(systemName: store.spotify?.isPlaying == true ? "music.note" : "pause.fill").foregroundStyle(.green)
            default:
                Image(systemName: id.symbol)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
}

/// Expanded view of a widget (island tab, dock popover, menu bar).
struct WidgetPanel: View {
    let id: WidgetID

    var body: some View { content.trackVisibility(id) }

    @ViewBuilder private var content: some View {
        switch id {
        case .ai, .claude, .codex: AIUsagePanel()
        case .agents: AgentsPanel()
        case .tasks: TasksPanel()
        case .devServers: DevServersPanel()
        case .github: GitHubPanel()
        case .git: GitPanel()
        case .endpoints: EndpointsPanel()
        case .docker: DockerPanel()
        case .system, .battery: SystemPanel()
        case .timer: TimerPanel()
        case .calculator: CalculatorPanel()
        case .generator: GeneratorPanel()
        case .downloads: DownloadsPanel()
        case .vercel: VercelPanel()
        case .clipboard: ClipboardPanel()
        case .whatsapp: WhatsAppPanel()
        case .spotify: SpotifyPanel()
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension View {
    /// Tells the store a widget is on screen, so on-demand sources only poll while visible.
    func trackVisibility(_ id: WidgetID) -> some View {
        onAppear { KodisleStore.shared.widgetAppeared(id) }
            .onDisappear { KodisleStore.shared.widgetDisappeared(id) }
    }
}
