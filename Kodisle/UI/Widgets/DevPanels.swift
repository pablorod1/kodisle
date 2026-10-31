import SwiftUI

// MARK: - AI usage

struct AIUsagePanel: View {
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(symbol: "gauge.with.dots.needle.67percent", title: "AI usage", tint: .purple) {
                if store.refreshingAI { ProgressView().controlSize(.small) }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshAI() } }
            }
            if settings.config.claudeEnabled { providerCard(.claude, store.claude, store.claudeError) }
            if settings.config.codexEnabled { providerCard(.codex, store.codex, store.codexError) }
            if !settings.config.claudeEnabled && !settings.config.codexEnabled {
                EmptyHint(symbol: "gauge.with.dots.needle.0percent", text: "Enable a provider in Settings")
            }
        }
    }

    @ViewBuilder
    private func providerCard(_ provider: AIProvider, _ usage: AIUsage?, _ error: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: provider.symbol).foregroundStyle(provider.tint).font(.system(size: 12, weight: .bold))
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                if let plan = usage?.plan {
                    Text(plan).font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(provider.tint.opacity(0.2))).foregroundStyle(provider.tint)
                }
                Spacer()
                if let usage {
                    Text(usage.isLive ? "Live · \(Fmt.ago(usage.observedAt))" : "Last session · \(Fmt.ago(usage.observedAt))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if let usage {
                ForEach([usage.fiveHour, usage.weekly].compactMap { $0 }, id: \.label) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(window.label).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(Fmt.percent(window.usedPercent)).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(usageColor(window.usedPercent))
                        }
                        UsageBar(percent: window.usedPercent)
                        Text(Fmt.resetIn(window.resetsAt)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .rowStyle()
    }
}

// MARK: - Agents

struct AgentsPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "sparkles", title: "Agents", tint: .purple)
            if store.agents.isEmpty {
                EmptyHint(symbol: "moon.zzz", text: "No Claude Code or Codex sessions in the last 30 minutes")
            } else {
                ForEach(store.agents) { session in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: session.provider.symbol).foregroundStyle(session.provider.tint)
                            .frame(width: 20).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title ?? session.project).font(.system(size: 13, weight: .semibold))
                                .lineLimit(1).privacySensitive()
                            Text(verbatim: session.title == nil ? session.provider.name : "\(session.project) · \(session.provider.name)")
                                .font(.system(size: 11)).foregroundStyle(.secondary).privacySensitive()
                            if session.state == .finished, let summary = session.summary {
                                Text(summary).font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .lineLimit(2).privacySensitive()
                            }
                        }
                        Spacer()
                        stateLabel(session)
                    }
                    .rowStyle()
                }
            }
        }
    }

    @ViewBuilder
    private func stateLabel(_ session: AgentSession) -> some View {
        switch session.state {
        case .working:
            HStack(spacing: 5) { StatusDot(color: .purple, pulsing: true); Text("Working").font(.caption.weight(.medium)) }
        case .waiting:
            Label("Waiting for you", systemImage: "hand.raised.fill").font(.caption.weight(.medium)).foregroundStyle(.orange)
        case .finished:
            Text("Done · \(Fmt.ago(session.lastActivity))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dev servers

struct DevServersPanel: View {
    @Environment(KodisleStore.self) private var store
    @State private var confirmStop: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "server.rack", title: "Dev servers", tint: .green) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshDevServers() } }
            }
            if store.devServers.isEmpty {
                EmptyHint(symbol: "powersleep", text: "No dev servers listening.\nStart one and it shows up here.")
            }
            ForEach(store.devServers) { server in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.project).font(.system(size: 13, weight: .semibold)).privacySensitive()
                            if let framework = server.framework {
                                Text(framework).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(.green.opacity(0.18))).foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(server.ports, id: \.self) { port in
                                Button(String(":\(port)")) { Open.url("http://localhost:\(port)") }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(verbatim: "· \(server.command)\(server.uptime.map { " · \($0)" } ?? "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    IconButton(symbol: "safari", help: "Open in browser") { if let url = server.primaryURL { NSWorkspace.shared.open(url) } }
                    IconButton(symbol: "doc.on.doc", help: "Copy URL") { Clipboard.copy("http://localhost:\(server.ports.first ?? 0)") }
                    IconButton(symbol: "folder", help: "Reveal project") { Open.reveal(server.cwd) }
                    if confirmStop == server.pid {
                        Button("Stop") { store.stop(server); confirmStop = nil }
                            .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                    } else {
                        IconButton(symbol: "stop.fill", help: "Stop (SIGTERM)", tint: .red) { confirmStop = server.pid }
                    }
                }
                .rowStyle()
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
            PanelHeader(symbol: "arrow.triangle.pull", title: "GitHub", tint: .primary) {
                if let unread = store.github?.unreadNotifications, unread > 0 {
                    Button { Open.url("https://github.com/notifications") } label: {
                        Label("\(unread)", systemImage: "bell.badge.fill").font(.caption.weight(.semibold))
                    }.buttonStyle(.plain).foregroundStyle(.blue)
                }
                if store.refreshingGitHub { ProgressView().controlSize(.small) }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshGitHub() } }
            }
            if let error = store.githubError, store.github == nil {
                EmptyHint(symbol: "person.crop.circle.badge.exclamationmark", text: error)
            } else if let gh = store.github {
                Picker("", selection: $tab) {
                    Text("My PRs (\(gh.myPRs.count))").tag(0)
                    Text("Reviews (\(gh.reviewRequests.count))").tag(1)
                    Text("Actions").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case 0: prList(gh.myPRs, empty: "No open pull requests")
                case 1: prList(gh.reviewRequests, empty: "Nothing to review 🎉")
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
        ForEach(prs) { pr in
            Button { Open.url(pr.url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: pr.checks.symbol).foregroundStyle(pr.checks.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pr.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).privacySensitive()
                        Text(verbatim: "\(pr.repo) #\(pr.number)\(pr.isDraft ? " · draft" : "")").font(.system(size: 10.5)).foregroundStyle(.secondary).privacySensitive()
                    }
                    Spacer()
                    if pr.reviewDecision == "APPROVED" { Image(systemName: "hand.thumbsup.fill").foregroundStyle(.green) }
                    if pr.reviewDecision == "CHANGES_REQUESTED" { Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange) }
                }
                .rowStyle()
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func runList(_ runs: [WorkflowRun]) -> some View {
        if runs.isEmpty { EmptyHint(symbol: "bolt.horizontal", text: "No workflow runs in your recent repos") }
        ForEach(runs.prefix(12)) { run in
            Button { Open.url(run.url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: run.state.symbol).foregroundStyle(run.state.color)
                        .symbolEffect(.rotate, isActive: run.state == .pending)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(run.workflow) · \(run.title)").font(.system(size: 12.5, weight: .medium)).lineLimit(1).privacySensitive()
                        Text(verbatim: "\(run.repo) · \(run.branch)").font(.system(size: 10.5)).foregroundStyle(.secondary).privacySensitive()
                    }
                    Spacer()
                    if let date = run.updatedAt { Text(Fmt.ago(date)).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                }
                .rowStyle()
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Git

struct GitPanel: View {
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "arrow.triangle.branch", title: "Repositories", tint: .orange) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshRepos() } }
            }
            if store.repos.isEmpty {
                EmptyHint(symbol: "folder.badge.questionmark", text: "No git repos found in \(settings.config.projectsRoot)")
            }
            ForEach(store.repos) { repo in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.name).font(.system(size: 13, weight: .semibold)).privacySensitive()
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(repo.branch).privacySensitive()
                            if repo.ahead > 0 { Text(verbatim: "↑\(repo.ahead)") }
                            if repo.behind > 0 { Text(verbatim: "↓\(repo.behind)") }
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if repo.changes > 0 {
                        Text("\(repo.changes)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(.orange.opacity(0.2))).foregroundStyle(.orange)
                            .help("Uncommitted changes")
                    }
                    IconButton(symbol: "terminal", help: "Open in Terminal") { Open.terminal(repo.path) }
                    if let slug = repo.githubSlug {
                        IconButton(symbol: "arrow.up.right.square", help: "Open on GitHub") { Open.url("https://github.com/\(slug)") }
                    }
                }
                .rowStyle()
                .contextMenu {
                    Button("Reveal in Finder") { Open.reveal(repo.path) }
                    Button("Copy path") { Clipboard.copy(repo.path) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "antenna.radiowaves.left.and.right", title: "Endpoints", tint: .teal) {
                IconButton(symbol: "plus", help: "Add endpoint") { adding.toggle() }
                IconButton(symbol: "arrow.clockwise", help: "Check now") { Task { await store.refreshEndpoints() } }
            }
            if adding {
                HStack {
                    TextField("Name", text: $name).frame(width: 110)
                    TextField("https://api.example.com/health", text: $url)
                    Button("Add") {
                        settings.config.endpoints.append(Endpoint(name: name.isEmpty ? (URL(string: url)?.host ?? url) : name, url: url))
                        name = ""; url = "https://"; adding = false
                        Task { await store.refreshEndpoints() }
                    }
                    .disabled(URL(string: url)?.host == nil)
                }
                .textFieldStyle(.roundedBorder).controlSize(.small)
                Text("Tip: avoid putting tokens in URLs — they're stored in plain preferences.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if settings.config.endpoints.isEmpty && !adding {
                EmptyHint(symbol: "antenna.radiowaves.left.and.right.slash", text: "Monitor APIs, health checks or local services")
            }
            ForEach(settings.config.endpoints) { endpoint in
                let status = store.endpointStatus[endpoint.id]
                HStack(spacing: 10) {
                    StatusDot(color: status == nil ? .gray : status!.ok ? .green : .red, pulsing: status?.ok == false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(endpoint.name).font(.system(size: 13, weight: .semibold))
                        Text(Redact.url(endpoint.url)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                    }
                    Spacer()
                    if let history = status?.history, history.count > 1 {
                        Sparkline(values: history, tint: status?.ok == true ? .green : .red).frame(width: 60, height: 18)
                    }
                    Text(status.map { $0.error ?? "\(Int($0.latencyMs ?? 0)) ms" } ?? "…")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(status?.ok == false ? .red : .secondary)
                        .frame(minWidth: 54, alignment: .trailing)
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

// MARK: - Docker

struct DockerPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "shippingbox.fill", title: "Docker", tint: .blue)
            if !store.dockerAvailable {
                EmptyHint(symbol: "shippingbox", text: "Docker isn't running (Docker Desktop, OrbStack or Colima)")
            } else if store.containers.isEmpty {
                EmptyHint(symbol: "shippingbox", text: "No containers")
            }
            ForEach(store.containers) { container in
                HStack(spacing: 10) {
                    StatusDot(color: container.isRunning ? .green : .gray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(container.name).font(.system(size: 13, weight: .semibold)).privacySensitive()
                        Text("\(container.image) · \(container.status)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if container.isRunning {
                        IconButton(symbol: "arrow.clockwise", help: "Restart") { store.docker("restart", container) }
                        IconButton(symbol: "stop.fill", help: "Stop", tint: .red) { store.docker("stop", container) }
                    } else {
                        IconButton(symbol: "play.fill", help: "Start", tint: .green) { store.docker("start", container) }
                    }
                }
                .rowStyle()
            }
        }
    }
}

// MARK: - System

struct SystemPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        let s = store.system
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(symbol: "cpu", title: "System", tint: .mint)
            metric("CPU", value: "\(Int(s.cpu * 100))%", percent: s.cpu * 100)
            metric("Memory", value: "\(Fmt.bytes(Int64(s.memUsed))) / \(Fmt.bytes(Int64(s.memTotal)))",
                   percent: Double(s.memUsed) / Double(max(1, s.memTotal)) * 100)
            HStack {
                Label("\(Fmt.bytes(s.diskFree)) available", systemImage: "internaldrive").font(.system(size: 12))
                Spacer()
                if let b = s.battery {
                    Label("\(b.percent)%\(b.isCharging ? " · charging" : "")",
                          systemImage: b.onAC ? "powerplug.fill" : "battery.75percent").font(.system(size: 12))
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            UsageBar(percent: percent)
        }
    }
}

// MARK: - Vercel

struct VercelPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "triangle.fill", title: "Vercel", tint: .primary) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refreshVercel() } }
            }
            if let error = store.vercelError, store.deployments.isEmpty {
                EmptyHint(symbol: "exclamationmark.triangle", text: error)
            } else if !VercelProvider.isAvailable {
                EmptyHint(symbol: "triangle", text: "Install the Vercel CLI and run `vercel login`")
            } else if store.deployments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(store.deployments.prefix(12)) { d in
                Button { Open.url("https://\(d.url)") } label: {
                    HStack(spacing: 10) {
                        StatusDot(color: d.color, pulsing: d.isActive)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(d.project).font(.system(size: 13, weight: .semibold)).privacySensitive()
                                if d.target == "production" {
                                    Text("Production").font(.system(size: 9.5, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(.primary.opacity(0.1)))
                                }
                            }
                            Text([d.branch, d.commit].compactMap { $0 }.joined(separator: " · ").ifEmpty(d.team ?? "Personal"))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(d.state.capitalized).font(.system(size: 11, weight: .medium)).foregroundStyle(d.color)
                            Text(Fmt.ago(d.created)).font(.system(size: 10)).foregroundStyle(.tertiary)
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
