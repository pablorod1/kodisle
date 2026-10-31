import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class KodisleStore {
    static let shared = KodisleStore()

    var devServers: [DevServer] = []
    var claude: AIUsage?
    var claudeError: String?
    var codex: AIUsage?
    var codexError: String?
    var agents: [AgentSession] = []
    var github: GitHubSnapshot?
    var githubError: String?
    var repos: [RepoStatus] = []
    var endpointStatus: [UUID: EndpointStatus] = [:]
    var containers: [DockerContainer] = []
    var dockerAvailable = false
    var system = SystemSnapshot()
    var downloads: [DownloadItem] = []
    var currentEvent: KodisleEvent?
    var recentEvents: [KodisleEvent] = []
    var permissionRequests: [PermissionRequest] = []
    var deployments: [VercelDeployment] = []
    var vercelError: String?
    var refreshingAI = false
    var refreshingGitHub = false

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var downloadsWatcher: DirectoryWatcher?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var visibleCounts: [WidgetID: Int] = [:]
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var downloadsStarted = false
    @ObservationIgnored private var aiThresholds: [String: Int] = [:]
    @ObservationIgnored private var eventDismiss: Task<Void, Never>?
    private var config: KodisleConfig { AppSettings.shared.config }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            loop({ _ in 5 }) { await $0.refreshDevServers() },
            loop({ $0.runningAgents.isEmpty ? 10 : 4 }) { await $0.refreshAgents() },
            loop({ $0.config.aiRefreshSeconds }) { await $0.refreshAI() },
            loop({ $0.config.githubRefreshSeconds }) { await $0.refreshGitHub() },
            loop({ _ in 30 }) { await $0.refreshRepos() },
            loop({ $0.config.endpointRefreshSeconds }) { await $0.refreshEndpoints() },
            loop({ _ in 15 }) { if $0.isVisible(.docker) { await $0.refreshDocker() } },
            loop({ _ in 5 }) { if $0.isVisible(.system, .battery, .downloads) { $0.sampleSystem() } },
            loop({ $0.deployments.contains(where: \.isActive) ? 12 : 60 }) { await $0.refreshVercel() },
            loop({ _ in 2 }) { $0.pruneAnsweredRequests() },
            loop({ _ in 6 * 3600 }) { _ in await Updater.shared.checkIfDue() },
        ]
        if config.clipboardEnabled { ClipboardHistory.shared.start() }
        let bridge = Bridge { message in
            Task { @MainActor in KodisleStore.shared.handle(message) }
        }
        bridge.start()
        self.bridge = bridge
        observeSleep()
    }

    /// Downloads access triggers a macOS privacy prompt that blocks the calling thread,
    /// so it's only started (off the main thread) the first time a Downloads view appears.
    func ensureDownloads() {
        guard !downloadsStarted else { return }
        downloadsStarted = true
        Task {
            let folder = DownloadsProvider.folder
            let watcher = await Task.detached(priority: .utility) { () -> DirectoryWatcher? in
                DirectoryWatcher(url: folder) {
                    Task { @MainActor in KodisleStore.shared.refreshDownloads() }
                }
            }.value
            downloadsWatcher = watcher
            refreshDownloads()
        }
    }

    private func loop(_ interval: @escaping @MainActor (KodisleStore) -> Double,
                      _ work: @escaping @MainActor (KodisleStore) async -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.waitIfPaused()
                await work(self)
                let seconds = max(1, interval(self))
                // Tolerance lets macOS coalesce Kodisle's timers with other wakeups.
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(seconds * 0.25))
            }
        }
    }

    // MARK: Visibility & power

    func widgetAppeared(_ id: WidgetID) {
        let count = visibleCounts[id, default: 0]
        visibleCounts[id] = count + 1
        guard count == 0 else { return }
        // Refresh on-demand sources right away when they come on screen.
        switch id {
        case .docker: Task { await refreshDocker() }
        case .system, .battery, .downloads: sampleSystem()
        default: break
        }
    }

    func widgetDisappeared(_ id: WidgetID) {
        visibleCounts[id] = max(0, visibleCounts[id, default: 0] - 1)
    }

    func isVisible(_ ids: WidgetID...) -> Bool { ids.contains { visibleCounts[$0, default: 0] > 0 } }

    private func sampleSystem() {
        var snap = sampler.snapshot()
        snap.cpu = (snap.cpu * 100).rounded() / 100                       // 1% steps
        snap.memUsed = snap.memUsed / (64 << 20) * (64 << 20)               // 64 MB steps
        snap.diskFree = snap.diskFree / (256 << 20) * (256 << 20)
        if snap != system { system = snap }
    }

    /// No polling while the displays sleep or the session is locked / switched away.
    private func observeSleep() {
        let ws = NSWorkspace.shared.notificationCenter
        let pauseNames: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        let resumeNames: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pauseNames {
            sleepObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KodisleStore.shared.setPaused(true) }
            })
        }
        for name in resumeNames {
            sleepObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KodisleStore.shared.setPaused(false) }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        sleepObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KodisleStore.shared.setPaused(true) }
        })
        sleepObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KodisleStore.shared.setPaused(false) }
        })
    }

    private func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if !value {
            resumeWaiters.forEach { $0.resume() }
            resumeWaiters.removeAll()
        }
    }

    private func waitIfPaused() async {
        guard paused else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    // MARK: Refreshers

    func refreshDevServers() async {
        let servers = await DevServerProvider.fetch()
        let oldPorts = Set(devServers.flatMap(\.ports))
        if !devServers.isEmpty || !oldPorts.isEmpty {
            for server in servers where !server.ports.contains(where: oldPorts.contains) {
                post(KodisleEvent(symbol: "server.rack", title: "\(server.project) is up",
                                subtitle: server.ports.map { ":\($0)" }.joined(separator: " ") + (server.framework.map { " · \($0)" } ?? ""),
                                tint: .green, widget: .devServers))
            }
        }
        if servers != devServers { devServers = servers }
    }

    func refreshAgents() async {
        // Round activity to 30 s so a busy session doesn't redraw the island every scan;
        // state changes (working → finished…) still propagate immediately.
        let sessions = await AgentProvider.scan(idleAfter: config.agentIdleSeconds, summaries: config.agentSummaries)
            .map { session -> AgentSession in
                var s = session
                s.lastActivity = Date(timeIntervalSince1970: (session.lastActivity.timeIntervalSince1970 / 30).rounded(.down) * 30)
                return s
            }
        let previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.state) })
        for session in sessions {
            guard let old = previous[session.id], old != session.state else { continue }
            let context = [session.title, session.project].compactMap { $0 }.joined(separator: " · ")
            switch session.state {
            case .finished where old == .working || old == .waiting:
                post(KodisleEvent(symbol: "checkmark.seal.fill", title: "\(session.provider.shortName) finished",
                                  subtitle: context, tint: .green, widget: .agents, detail: session.summary),
                     duration: session.summary == nil ? 5 : 9)
                NSSound(named: "Glass")?.play()
            case .waiting:
                post(KodisleEvent(symbol: "hand.raised.fill", title: "\(session.provider.shortName) is waiting for you",
                                  subtitle: context, tint: .orange, widget: .agents))
                NSSound(named: "Tink")?.play()
            default: break
            }
        }
        if sessions != agents { agents = sessions }
    }

    func refreshAI() async {
        refreshingAI = true
        defer { refreshingAI = false }
        async let claudeResult: Result<AIUsage, Error>? = config.claudeEnabled ? capture { try await ClaudeUsageProvider.fetch() } : nil
        async let codexResult: Result<AIUsage, Error>? = config.codexEnabled ? capture { try await CodexUsageProvider.fetch() } : nil
        switch await claudeResult {
        case .success(let usage)?: claude = usage; claudeError = nil; checkThresholds(usage)
        case .failure(let error)?: claudeError = error.localizedDescription
        case nil: claude = nil; claudeError = nil
        }
        switch await codexResult {
        case .success(let usage)?: codex = usage; codexError = nil; checkThresholds(usage)
        case .failure(let error)?: codexError = error.localizedDescription
        case nil: codex = nil; codexError = nil
        }
    }

    private func capture(_ work: () async throws -> AIUsage) async -> Result<AIUsage, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func checkThresholds(_ usage: AIUsage) {
        guard usage.isLive else { return }
        for window in [usage.fiveHour, usage.weekly].compactMap({ $0 }) {
            let key = "\(usage.provider.rawValue)-\(window.label)"
            let level = window.usedPercent >= 95 ? 95 : window.usedPercent >= 80 ? 80 : 0
            let old = aiThresholds[key]
            aiThresholds[key] = level
            if let old, level > old {
                post(KodisleEvent(symbol: "gauge.with.dots.needle.100percent",
                                title: "\(usage.provider.shortName) at \(Fmt.percent(window.usedPercent))",
                                subtitle: "\(window.label) limit · \(Fmt.resetIn(window.resetsAt))",
                                tint: level >= 95 ? .red : .orange, widget: .ai))
            }
        }
    }

    func refreshGitHub() async {
        refreshingGitHub = true
        defer { refreshingGitHub = false }
        if repos.isEmpty { await refreshRepos() }
        let slugs = Array(Set(repos.compactMap(\.githubSlug))).sorted()
        do {
            let snapshot = try await GitHubProvider.fetch(repos: slugs)
            if let old = github {
                let previous = Dictionary(uniqueKeysWithValues: old.runs.map { ($0.id, $0) })
                for run in snapshot.runs {
                    guard let before = previous[run.id], before.status != "completed", run.status == "completed" else { continue }
                    let failed = run.state == .failure
                    post(KodisleEvent(symbol: failed ? "xmark.octagon.fill" : "checkmark.circle.fill",
                                    title: failed ? "CI failed · \(run.workflow)" : "CI passed · \(run.workflow)",
                                    subtitle: "\(run.repo) · \(run.branch)", tint: failed ? .red : .green, widget: .github))
                }
                let newReviews = Set(snapshot.reviewRequests.map(\.id)).subtracting(old.reviewRequests.map(\.id))
                for pr in snapshot.reviewRequests where newReviews.contains(pr.id) {
                    post(KodisleEvent(symbol: "eye.fill", title: "Review requested", subtitle: "\(pr.repo) #\(pr.number)",
                                    tint: .purple, widget: .github))
                }
            }
            github = snapshot
            githubError = nil
        } catch {
            githubError = error.localizedDescription
        }
    }

    func refreshRepos() async {
        let result = await GitProvider.fetch(root: config.projectsRootURL, limit: config.maxRepos)
        if result != repos { repos = result }
    }

    func refreshEndpoints() async {
        let endpoints = config.endpoints
        await withTaskGroup(of: (Endpoint, (status: Int?, latency: Double?, ok: Bool, error: String?)).self) { group in
            for endpoint in endpoints { group.addTask { (endpoint, await EndpointProvider.check(endpoint)) } }
            for await (endpoint, result) in group {
                var history = endpointStatus[endpoint.id]?.history ?? []
                if let latency = result.latency { history.append(latency) }
                let wasOK = endpointStatus[endpoint.id]?.ok
                endpointStatus[endpoint.id] = EndpointStatus(httpStatus: result.status, latencyMs: result.latency, ok: result.ok,
                                                             error: result.error, history: Array(history.suffix(30)), checkedAt: .now)
                if let wasOK, wasOK != result.ok {
                    post(KodisleEvent(symbol: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                    title: result.ok ? "\(endpoint.name) recovered" : "\(endpoint.name) is down",
                                    subtitle: result.error ?? "\(Int(result.latency ?? 0)) ms",
                                    tint: result.ok ? .green : .red, widget: .endpoints))
                }
            }
        }
        let ids = Set(endpoints.map(\.id))
        endpointStatus = endpointStatus.filter { ids.contains($0.key) }
    }

    func refreshDocker() async {
        if let list = await DockerProvider.fetch() {
            dockerAvailable = true
            if list != containers { containers = list }
        } else {
            dockerAvailable = false
            containers = []
        }
    }

    func refreshDownloads() {
        Task {
            let items = await Task.detached(priority: .utility) { DownloadsProvider.list() }.value
            if items != downloads { downloads = items }
        }
    }

    func refreshAll() {
        Task {
            async let a: Void = refreshAI()
            async let b: Void = refreshGitHub()
            async let c: Void = refreshEndpoints()
            async let d: Void = refreshDevServers()
            _ = await (a, b, c, d)
        }
    }

    func refreshVercel() async {
        guard config.vercelEnabled, VercelProvider.isAvailable else { deployments = []; return }
        do {
            let list = try await VercelProvider.fetch()
            let previous = Dictionary(uniqueKeysWithValues: deployments.map { ($0.id, $0.state) })
            for d in list {
                guard let old = previous[d.id], old != d.state, !d.isActive else { continue }
                let target = d.target == "production" ? "Production" : "Preview"
                switch d.state {
                case "READY":
                    post(KodisleEvent(symbol: "checkmark.circle.fill", title: "Deploy ready · \(d.project)",
                                      subtitle: [target, d.branch].compactMap { $0 }.joined(separator: " · "),
                                      tint: .green, widget: .vercel, detail: d.commit))
                case "ERROR":
                    post(KodisleEvent(symbol: "xmark.octagon.fill", title: "Deploy failed · \(d.project)",
                                      subtitle: [target, d.branch].compactMap { $0 }.joined(separator: " · "),
                                      tint: .red, widget: .vercel, detail: d.commit), duration: 9)
                    NSSound(named: "Basso")?.play()
                default: break
                }
            }
            if list != deployments { deployments = list }
            vercelError = nil
        } catch {
            vercelError = error.localizedDescription
        }
    }

    // MARK: Bridge (Claude Code hook, zsh integration)

    func handle(_ message: Bridge.Message) {
        let json = message.json
        if let reply = message.reply {
            let input = json["tool_input"] as? [String: Any] ?? [:]
            let tool = json["tool_name"] as? String ?? "Tool"
            let cwd = json["cwd"] as? String ?? ""
            let target: String = {
                if let command = input["command"] as? String { return command }
                if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
                    return path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
                }
                if let url = input["url"] as? String { return Redact.url(url) }
                if let query = input["query"] as? String { return query }
                if let pattern = input["pattern"] as? String { return pattern }
                return tool.hasPrefix("mcp__") ? tool.split(separator: "_").suffix(1).joined() : tool
            }()
            let transcript = json["transcript_path"] as? String
            let request = PermissionRequest(tool: tool.hasPrefix("mcp__") ? tool.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ") : tool,
                                            target: target, project: (cwd as NSString).lastPathComponent,
                                            sessionTitle: agents.first { $0.id == transcript }?.title,
                                            suggestions: json["permission_suggestions"] as? [[String: Any]] ?? [],
                                            reply: reply)
            permissionRequests.append(request)
            NSSound(named: "Tink")?.play()
            // Dev helper for end-to-end tests: `-KodisleDebugAutoDecide allow|deny|terminal` (after 4 s).
            if let auto = UserDefaults.standard.string(forKey: "KodisleDebugAutoDecide") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    decide(request, auto == "deny" ? .deny : auto == "terminal" ? .terminal : .allow)
                }
            }
            return
        }
        if json["kind"] as? String == "command", let command = json["command"] as? String {
            let code = (json["exit"] as? NSNumber)?.intValue ?? 0
            let seconds = (json["seconds"] as? NSNumber)?.doubleValue ?? 0
            let project = ((json["cwd"] as? String ?? "") as NSString).lastPathComponent
            post(KodisleEvent(symbol: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill",
                              title: code == 0 ? "\(command) finished" : "\(command) failed (exit \(code))",
                              subtitle: [project, Fmt.duration(seconds)].filter { !$0.isEmpty }.joined(separator: " · "),
                              tint: code == 0 ? .green : .red, widget: nil))
            NSSound(named: code == 0 ? "Glass" : "Basso")?.play()
        }
    }

    enum PermissionDecision { case allow, always, deny, terminal }

    func decide(_ request: PermissionRequest, _ decision: PermissionDecision) {
        permissionRequests.removeAll { $0.id == request.id }
        func output(_ body: [String: Any]) -> [String: Any] {
            ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        }
        switch decision {
        case .allow: request.reply.send(output(["behavior": "allow"]))
        case .always: request.reply.send(output(["behavior": "allow", "updatedPermissions": request.suggestions]))
        case .deny: request.reply.send(output(["behavior": "deny", "message": "Denied from Kodisle"]))
        case .terminal: request.reply.send(nil)
        }
    }

    /// Drops requests whose hook went away (cancelled, timed out, or answered in the terminal).
    private func pruneAnsweredRequests() {
        let gone = permissionRequests.filter { $0.reply.peerClosed }
        guard !gone.isEmpty else { return }
        permissionRequests.removeAll { r in gone.contains(r) }
    }

    func stopBridge() { bridge?.stop() }

    // MARK: Actions

    func stop(_ server: DevServer) {
        kill(server.pid, SIGTERM)
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await refreshDevServers()
        }
    }

    func docker(_ action: String, _ container: DockerContainer) {
        Task {
            await DockerProvider.perform(action, id: container.id)
            await refreshDocker()
        }
    }

    // MARK: Events

    func post(_ event: KodisleEvent, duration: Double = 5) {
        recentEvents.insert(event, at: 0)
        recentEvents = Array(recentEvents.prefix(30))
        guard config.islandLiveEvents else { return }
        currentEvent = event
        eventDismiss?.cancel()
        eventDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            if self?.currentEvent?.id == event.id { self?.currentEvent = nil }
        }
    }

    // MARK: Derived

    var attentionCount: Int {
        (github?.failingRuns.count ?? 0)
            + (github?.reviewRequests.count ?? 0)
            + endpointStatus.values.filter { !$0.ok }.count
            + agents.filter { $0.state == .waiting }.count
            + permissionRequests.count
            + deployments.filter { $0.state == "ERROR" && $0.created > Date().addingTimeInterval(-3600) }.count
    }

    var runningAgents: [AgentSession] { agents.filter { $0.state != .finished } }

    /// Widgets with something going on right now, most urgent first (drives the island's
    /// automatic right ear).
    var activeWidgets: [WidgetID] {
        var result: [WidgetID] = []
        func add(_ id: WidgetID) { if !result.contains(id) { result.append(id) } }
        if !permissionRequests.isEmpty || agents.contains(where: { $0.state == .waiting }) { add(.agents) }
        if FocusTimer.shared.isRunning { add(.timer) }
        if agents.contains(where: { $0.state == .working }) { add(.agents) }
        if deployments.contains(where: \.isActive) { add(.vercel) }
        if github?.runs.contains(where: { $0.status != "completed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-1800) }) == true { add(.github) }
        if endpointStatus.values.contains(where: { !$0.ok }) { add(.endpoints) }
        if !devServers.isEmpty { add(.devServers) }
        return result
    }
}
