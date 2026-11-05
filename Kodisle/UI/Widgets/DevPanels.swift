import SwiftUI

// MARK: - AI usage

struct AIUsagePanel: View {
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.panelWide) private var wide

    private var layout: AnyLayout {
        wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(symbol: "gauge.with.dots.needle.67percent", title: "AI usage", tint: .purple) {
                if store.refreshingAI { ProgressView().controlSize(.small) }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshAI() } }
            }
            layout {
                if settings.config.claudeEnabled { providerCard(.claude, store.claude, store.claudeError) }
                if settings.config.codexEnabled { providerCard(.codex, store.codex, store.codexError) }
            }
            if !settings.config.claudeEnabled && !settings.config.codexEnabled {
                EmptyHint(symbol: "gauge.with.dots.needle.0percent", text: "No providers", detail: "Enable one in Settings")
            }
        }
    }

    private func providerCard(_ provider: AIProvider, _ usage: AIUsage?, _ error: String?) -> some View {
        MetricCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IconChip(symbol: provider.symbol, tint: provider.tint, size: 24)
                    Text(provider.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let plan = usage?.plan { Pill(text: plan, tint: provider.tint) }
                    Spacer(minLength: 4)
                    if let usage {
                        if usage.isLive {
                            Text(Fmt.ago(usage.observedAt)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Pill(text: "Last session", symbol: "clock")
                        }
                    }
                }
                if let usage {
                    HStack(spacing: 8) {
                        ForEach([usage.fiveHour, usage.weekly].compactMap { $0 }, id: \.label) { gauge($0) }
                    }
                    .opacity(usage.isLive ? 1 : 0.6)
                } else if let error {
                    Label(Self.friendly(error), systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func gauge(_ window: UsageWindow) -> some View {
        HStack(spacing: 9) {
            UsageRing(percent: window.usedPercent, size: 48, lineWidth: 5.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Fmt.resetIn(window.resetsAt)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private static func friendly(_ error: String) -> String {
        error.contains("429") ? "Rate limited for now, it'll retry on its own" : error
    }
}

// MARK: - Agents

struct AgentsPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        let working = store.agents.filter { $0.state == .working }.count
        let waiting = store.agents.filter { $0.state == .waiting }.count
        let done = store.agents.filter { $0.state == .finished }.count
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "sparkles", title: "Agents", tint: .purple,
                        subtitle: store.agents.isEmpty ? nil : "Last 30 minutes")
            if store.agents.isEmpty {
                EmptyHint(symbol: "moon.zzz", text: "No recent sessions", detail: "Claude Code and Codex sessions show up here")
            } else {
                StatStrip(stats: [Stat(value: "\(working)", label: "Working", tint: .purple),
                                  Stat(value: "\(waiting)", label: "Waiting", tint: .orange),
                                  Stat(value: "\(done)", label: "Done", tint: .green)])
                RowGrid {
                    ForEach(store.agents) { session in
                        HStack(alignment: .top, spacing: 10) {
                            IconChip(symbol: session.provider.symbol, tint: session.provider.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title ?? session.project).font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1).privacySensitive()
                                Text(verbatim: session.title == nil ? session.provider.name : session.project)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                                if session.state == .finished, let summary = session.summary {
                                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .lineLimit(2).privacySensitive()
                                }
                            }
                            Spacer(minLength: 4)
                            stateLabel(session)
                        }
                        .rowStyle()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stateLabel(_ session: AgentSession) -> some View {
        switch session.state {
        case .working: Pill(text: "Working", tint: .purple, symbol: "sparkle")
        case .waiting: Pill(text: "Needs you", tint: .orange, symbol: "hand.raised.fill")
        case .finished: Text(Fmt.ago(session.lastActivity)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Dev servers

struct DevServersPanel: View {
    @Environment(KodisleStore.self) private var store
    @State private var confirmStop: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "server.rack", title: "Dev servers", tint: .green,
                        subtitle: store.devServers.isEmpty ? nil : "\(store.devServers.count) running") {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshDevServers() } }
            }
            if store.devServers.isEmpty {
                EmptyHint(symbol: "powersleep", text: "Nothing listening", detail: "Start a dev server and it shows up here")
            }
            RowGrid {
                ForEach(store.devServers) { server in
                    HoverActions {
                        HStack(spacing: 10) {
                            IconChip(symbol: "server.rack", tint: .green)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(server.project).font(.system(size: 13, weight: .semibold)).lineLimit(1).privacySensitive()
                                    if let framework = server.framework { Pill(text: framework, tint: .green) }
                                }
                                HStack(spacing: 5) {
                                    ForEach(server.ports, id: \.self) { port in
                                        Button { Open.url("http://localhost:\(port)") } label: { Pill(text: ":\(port)", tint: .chartBlue) }
                                            .buttonStyle(.plain)
                                    }
                                    Text(verbatim: [server.command, server.uptime].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    } actions: {
                        IconButton(symbol: "safari", help: "Open in browser") { if let url = server.primaryURL { NSWorkspace.shared.open(url) } }
                        IconButton(symbol: "doc.on.doc", help: "Copy URL") { Clipboard.copy("http://localhost:\(server.ports.first ?? 0)") }
                        IconButton(symbol: "folder", help: "Reveal project") { Open.reveal(server.cwd) }
                        if confirmStop == server.pid {
                            Button("Stop") { store.stop(server); confirmStop = nil }
                                .buttonStyle(PillButtonStyle(tint: .red)).controlSize(.small)
                        } else {
                            IconButton(symbol: "stop.fill", help: "Stop (SIGTERM)", tint: .red) { confirmStop = server.pid }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - GitHub

struct GitHubPanel: View {
    @Environment(KodisleStore.self) private var store
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "arrow.triangle.pull", title: "GitHub", tint: .primary, subtitle: store.github.map { "@\($0.login)" }) {
                if let unread = store.github?.unreadNotifications, unread > 0 {
                    Button { Open.url("https://github.com/notifications") } label: {
                        Pill(text: "\(unread)", tint: .chartBlue, symbol: "bell.fill")
                    }.buttonStyle(.plain).help("Unread notifications")
                }
                if store.refreshingGitHub { ProgressView().controlSize(.small) }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshGitHub() } }
            }
            if let error = store.githubError, store.github == nil {
                EmptyHint(symbol: "person.crop.circle.badge.exclamationmark", text: "Couldn't reach GitHub", detail: error)
            } else if let gh = store.github {
                StatStrip(stats: [Stat(value: "\(gh.myPRs.count)", label: "My PRs"),
                                  Stat(value: "\(gh.reviewRequests.count)", label: "To review", tint: gh.reviewRequests.isEmpty ? nil : .purple),
                                  Stat(value: "\(gh.failingRuns.count)", label: "Failing CI", tint: gh.failingRuns.isEmpty ? .green : .red)])
                PillTabs(selection: $tab, options: [(0, "My PRs"), (1, "Reviews"), (2, "Actions")])
                switch tab {
                case 0: prList(gh.myPRs, empty: "No open pull requests")
                case 1: prList(gh.reviewRequests, empty: "Nothing to review")
                default: runList(gh.runs)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    @ViewBuilder
    private func prList(_ prs: [PullRequest], empty: String) -> some View {
        if prs.isEmpty { EmptyHint(symbol: "checkmark.circle", text: empty) }
        RowGrid {
            ForEach(prs) { pr in
                Button { Open.url(pr.url) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pr.checks.symbol).font(.system(size: 15)).foregroundStyle(pr.checks.color)
                            .help("Checks: \(pr.checks.rawValue)")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pr.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).privacySensitive()
                            Text(verbatim: "\(pr.repo) #\(pr.number)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                        }
                        Spacer(minLength: 4)
                        if pr.isDraft { Pill(text: "Draft") }
                        if pr.reviewDecision == "APPROVED" { Pill(text: "Approved", tint: .green, symbol: "checkmark") }
                        if pr.reviewDecision == "CHANGES_REQUESTED" { Pill(text: "Changes", tint: .orange, symbol: "exclamationmark") }
                    }
                    .rowStyle()
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func runList(_ runs: [WorkflowRun]) -> some View {
        if runs.isEmpty { EmptyHint(symbol: "bolt.horizontal", text: "No recent workflow runs") }
        RowGrid {
            ForEach(runs.prefix(12)) { run in
                Button { Open.url(run.url) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: run.state.symbol).font(.system(size: 15)).foregroundStyle(run.state.color)
                            .symbolEffect(.rotate, isActive: run.state == .pending)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(run.workflow) · \(run.title)").font(.system(size: 12.5, weight: .medium)).lineLimit(1).privacySensitive()
                            Text(verbatim: "\(run.repo) · \(run.branch)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                        }
                        Spacer(minLength: 4)
                        if let date = run.updatedAt { Text(Fmt.ago(date)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .rowStyle()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Git

struct GitPanel: View {
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let dirty = store.repos.filter { $0.changes > 0 }.count
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "arrow.triangle.branch", title: "Repositories", tint: .orange,
                        subtitle: store.repos.isEmpty ? nil : "\(store.repos.count) repos · \(dirty) with changes") {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshRepos() } }
            }
            if store.repos.isEmpty {
                EmptyHint(symbol: "folder.badge.questionmark", text: "No repos found", detail: "Looked in \(settings.config.projectsRoot)")
            }
            RowGrid {
                ForEach(store.repos) { repo in
                    HoverActions {
                        HStack(spacing: 10) {
                            IconChip(symbol: "arrow.triangle.branch", tint: repo.changes > 0 ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(repo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).privacySensitive()
                                Text(repo.branch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                            }
                            Spacer(minLength: 4)
                            if repo.ahead > 0 { Pill(text: "\(repo.ahead)", tint: .chartBlue, symbol: "arrow.up").help("Commits to push") }
                            if repo.behind > 0 { Pill(text: "\(repo.behind)", tint: .purple, symbol: "arrow.down").help("Commits to pull") }
                            if repo.changes > 0 { Pill(text: "\(repo.changes)", tint: .orange, symbol: "pencil").help("Uncommitted changes") }
                        }
                    } actions: {
                        IconButton(symbol: "terminal", help: "Open in Terminal") { Open.terminal(repo.path) }
                        if let slug = repo.githubSlug {
                            IconButton(symbol: "arrow.up.right.square", help: "Open on GitHub") { Open.url("https://github.com/\(slug)") }
                        }
                    }
                    .contextMenu {
                        Button("Reveal in Finder") { Open.reveal(repo.path) }
                        Button("Copy path") { Clipboard.copy(repo.path) }
                    }
                }
            }
        }
    }
}

// MARK: - Endpoints

struct EndpointsPanel: View {
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var adding = false
    @State private var name = ""
    @State private var url = "https://"

    private var stats: [Stat] {
        let statuses = Array(store.endpointStatus.values)
        let latencies = statuses.compactMap(\.latencyMs)
        let down = statuses.filter { !$0.ok }.count
        return [Stat(value: "\(statuses.count - down)/\(statuses.count)", label: "Up", tint: down > 0 ? .red : .green),
                Stat(value: latencies.isEmpty ? "–" : "\(Int(latencies.reduce(0, +) / Double(latencies.count))) ms", label: "Average"),
                Stat(value: latencies.max().map { "\(Int($0)) ms" } ?? "–", label: "Slowest")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "antenna.radiowaves.left.and.right", title: "Endpoints", tint: .teal) {
                IconButton(symbol: adding ? "xmark" : "plus", help: "Add endpoint") { withAnimation(.snappy) { adding.toggle() } }
                IconButton(symbol: "arrow.clockwise", help: "Check now") { Task { await store.refreshEndpoints() } }
            }
            if adding {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Name", text: $name).frame(width: 100)
                        TextField("https://api.example.com/health", text: $url)
                        Button("Add") {
                            settings.config.endpoints.append(Endpoint(name: name.isEmpty ? (URL(string: url)?.host ?? url) : name, url: url))
                            name = ""; url = "https://"; adding = false
                            Task { await store.refreshEndpoints() }
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(URL(string: url)?.host == nil)
                    }
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    Text("Avoid putting tokens in URLs: they're stored in plain preferences.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if settings.config.endpoints.isEmpty && !adding {
                EmptyHint(symbol: "antenna.radiowaves.left.and.right.slash", text: "Nothing monitored", detail: "Add an API, a health check or a local service")
            }
            if !store.endpointStatus.isEmpty { StatStrip(stats: stats) }
            RowGrid {
                ForEach(settings.config.endpoints) { endpoint in
                    let status = store.endpointStatus[endpoint.id]
                    HStack(spacing: 10) {
                        StatusDot(color: status == nil ? .gray : status!.ok ? .green : .red, pulsing: status?.ok == false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(endpoint.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(Redact.url(endpoint.url)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                        }
                        Spacer(minLength: 4)
                        if let history = status?.history, history.count > 1 {
                            Sparkline(values: history, tint: status?.ok == true ? .green : .red).frame(width: 54, height: 18)
                        }
                        if let error = status?.error {
                            Pill(text: error, tint: .red, symbol: "exclamationmark")
                        } else {
                            Text(status.map { "\(Int($0.latencyMs ?? 0)) ms" } ?? "…")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                    .rowStyle()
                    .contextMenu {
                        Button("Open") { Open.url(endpoint.url) }
                        Button("Remove", role: .destructive) { settings.config.endpoints.removeAll { $0.id == endpoint.id } }
                    }
                }
            }
        }
    }
}

// MARK: - Docker

struct DockerPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        let running = store.containers.filter(\.isRunning).count
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "shippingbox.fill", title: "Docker", tint: .blue)
            if !store.dockerAvailable {
                EmptyHint(symbol: "shippingbox", text: "Docker isn't running", detail: "Start Docker Desktop, OrbStack or Colima")
            } else if store.containers.isEmpty {
                EmptyHint(symbol: "shippingbox", text: "No containers")
            } else {
                StatStrip(stats: [Stat(value: "\(running)", label: "Running", tint: .green),
                                  Stat(value: "\(store.containers.count - running)", label: "Stopped", tint: .gray)])
            }
            RowGrid {
                ForEach(store.containers) { container in
                    HoverActions {
                        HStack(spacing: 10) {
                            IconChip(symbol: "shippingbox.fill", tint: container.isRunning ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(container.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).privacySensitive()
                                Text("\(container.image) · \(container.status)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } actions: {
                        if container.isRunning {
                            IconButton(symbol: "arrow.clockwise", help: "Restart") { store.docker("restart", container) }
                            IconButton(symbol: "stop.fill", help: "Stop", tint: .red) { store.docker("stop", container) }
                        } else {
                            IconButton(symbol: "play.fill", help: "Start", tint: .green) { store.docker("start", container) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - System

struct SystemPanel: View {
    @Environment(KodisleStore.self) private var store
    @State private var processes: [TopProcess] = []
    @Environment(\.panelWide) private var wide

    private var columns: AnyLayout {
        wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
    }

    var body: some View {
        let s = store.system
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "cpu", title: "System", tint: .mint, subtitle: "Up \(Fmt.duration(ProcessInfo.processInfo.systemUptime))")
            columns {
                cpuCard(s)
                memoryCard(s)
            }
            columns {
                HStack(spacing: 10) {
                    diskCard(s)
                    if let battery = s.battery { batteryCard(battery) }
                    networkCard(s)
                }
                if !processes.isEmpty { processList.frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        // Only here: spawning `ps` isn't worth it unless someone is looking at the result.
        .task {
            while !Task.isCancelled {
                let top = await ProcessProvider.top()
                if top != processes { processes = top }
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
            }
        }
    }

    private func cpuCard(_ s: SystemSnapshot) -> some View {
        MetricCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("CPU").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(Int(s.cpu * 100))%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Text("user \(Int(s.cpuUser * 100))% · sys \(Int(s.cpuSystem * 100))% · load \(String(format: "%.1f", s.loadAverage))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                HistoryChart(values: store.systemHistory.cpu, tint: usageColor(s.cpu * 100), maxValue: 100) { "\(Int($0))%" }
                    .frame(height: 46)
                    .animation(.smooth, value: s.cpu)
                if !s.cores.isEmpty { CoreBars(cores: s.cores) }
            }
        }
    }

    private func memoryCard(_ s: SystemSnapshot) -> some View {
        let total = Double(max(1, s.memTotal))
        let segments: [MemorySegment] = [
            .init(title: "Apps", bytes: s.memApp, color: .chartBlue),
            .init(title: "Wired", bytes: s.memWired, color: .chartOrange),
            .init(title: "Compressed", bytes: s.memCompressed, color: .chartGreen),
        ]
        return MetricCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Memory").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(Fmt.bytes(Int64(s.memUsed)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    Text("\(Fmt.percent(Double(s.memUsed) / total * 100)) of \(Fmt.bytes(Int64(s.memTotal)))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(segment.color)
                                .frame(width: max(4, (geo.size.width - 6) * Double(segment.bytes) / total))
                                .help("\(segment.title): \(Fmt.bytes(Int64(segment.bytes)))")
                        }
                        Spacer(minLength: 0)
                    }
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.primary.opacity(0.08)))
                }
                .frame(height: 10)
                .animation(.smooth, value: s.memUsed)
                // Stacked so it fits a narrow card: the bar's colors are identified here, not by hue alone.
                HStack(alignment: .top, spacing: 8) {
                    ForEach(segments) { segment in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Circle().fill(segment.color).frame(width: 7, height: 7)
                                Text(segment.title).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                            }
                            Text(Fmt.bytes(Int64(segment.bytes))).font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1)
                        }
                        .font(.system(size: 10.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if s.swapUsed > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Swap").foregroundStyle(.secondary).lineLimit(1)
                            Text(Fmt.bytes(Int64(s.swapUsed))).font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1)
                        }
                        .font(.system(size: 10.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func diskCard(_ s: SystemSnapshot) -> some View {
        let used = s.diskTotal > 0 ? Double(s.diskTotal - s.diskFree) / Double(s.diskTotal) * 100 : 0
        return ringCard(title: "Disk", percent: used, tint: usageColor(used), detail: "\(Fmt.bytes(s.diskFree)) free")
    }

    private func batteryCard(_ b: BatteryInfo) -> some View {
        let detail = b.isCharging ? (b.minutesToFull.map { "\(Fmt.duration(Double($0 * 60))) to full" } ?? "Charging")
            : b.onAC ? "On AC" : (b.minutesRemaining.map { "\(Fmt.duration(Double($0 * 60))) left" } ?? "On battery")
        return ringCard(title: "Battery", percent: Double(b.percent), tint: b.percent < 20 ? .red : b.percent < 40 ? .orange : .green, detail: detail,
                        symbol: b.isCharging ? "bolt.fill" : nil)
    }

    private func ringCard(title: String, percent: Double, tint: Color, detail: String, symbol: String? = nil) -> some View {
        MetricCard {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                UsageRing(percent: percent, tint: tint, size: 52, lineWidth: 6)
                    .overlay(alignment: .topTrailing) {
                        if let symbol { Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.yellow).offset(x: 3, y: -2) }
                    }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func networkCard(_ s: SystemSnapshot) -> some View {
        MetricCard {
            VStack(alignment: .leading, spacing: 5) {
                Text("Network").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                rate("arrow.down", s.netDown, history: store.systemHistory.netDown)
                rate("arrow.up", s.netUp, history: store.systemHistory.netUp)
            }
        }
    }

    private func rate(_ symbol: String, _ value: Double, history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(Fmt.rate(value)).font(.system(size: 10.5, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            // Each direction has its own scale: uploads would vanish next to a big download.
            HistoryChart(values: history, tint: .chartBlue, format: Fmt.rate).frame(height: 16)
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "Top processes").padding(.top, 2)
            let peak = max(100, processes.map(\.cpu).max() ?? 100)
            ForEach(processes) { process in
                HStack(spacing: 8) {
                    Text(process.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UsageBar(percent: process.cpu / peak * 100, tint: .chartBlue, height: 4).frame(width: 64)
                    Text("\(Int(process.cpu.rounded()))%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    Text(Fmt.bytes(process.memory)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }
}

private struct MemorySegment: Identifiable {
    var id: String { title }
    var title: String
    var bytes: UInt64
    var color: Color
}

/// One bar per logical core, so a single pegged core is visible behind a low average.
private struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(cores.indices, id: \.self) { index in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2).fill(usageColor(cores[index] * 100))
                        .frame(height: max(2, 18 * cores[index]))
                }
                .frame(height: 18)
                .help("Core \(index + 1): \(Int(cores[index] * 100))%")
            }
        }
        .animation(.smooth, value: cores)
    }
}

// MARK: - Vercel

struct VercelPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "triangle.fill", title: "Vercel", tint: .primary,
                        subtitle: store.deployments.first.map { "Latest \(Fmt.ago($0.created))" }) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshVercel() } }
            }
            if let error = store.vercelError, store.deployments.isEmpty {
                EmptyHint(symbol: "exclamationmark.triangle", text: "Couldn't load deployments", detail: error)
            } else if !VercelProvider.isAvailable {
                EmptyHint(symbol: "triangle", text: "Vercel isn't set up", detail: "Install the CLI and run `vercel login`")
            } else if store.deployments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
            RowGrid {
                ForEach(store.deployments.prefix(12)) { d in
                    Button { Open.url("https://\(d.url)") } label: {
                        HStack(spacing: 10) {
                            StatusDot(color: d.color, pulsing: d.isActive)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(d.project).font(.system(size: 13, weight: .semibold)).lineLimit(1).privacySensitive()
                                    if d.target == "production" { Pill(text: "Production") }
                                }
                                Text([d.branch, d.commit].compactMap { $0 }.joined(separator: " · ").ifEmpty(d.team ?? "Personal"))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Pill(text: d.state.capitalized, tint: d.color)
                                Text(Fmt.ago(d.created)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .rowStyle()
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open deployment") { Open.url("https://\(d.url)") }
                        Button("Copy URL") { Clipboard.copy("https://\(d.url)") }
                    }
                }
            }
        }
    }
}
