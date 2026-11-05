import Foundation
import SwiftUI

enum WidgetID: String, Codable, CaseIterable, Identifiable {
    case ai, claude, codex, agents, tasks, devServers, github, git, vercel, endpoints, docker, system, battery, timer, calculator, generator, downloads, clipboard, whatsapp, spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: "AI usage"
        case .claude: "Claude"
        case .codex: "Codex"
        case .agents: "Agents"
        case .tasks: "Tasks"
        case .devServers: "Dev servers"
        case .github: "GitHub"
        case .git: "Git"
        case .vercel: "Vercel"
        case .clipboard: "Clipboard"
        case .endpoints: "Endpoints"
        case .docker: "Docker"
        case .system: "System"
        case .battery: "Battery"
        case .timer: "Focus timer"
        case .calculator: "Calculator"
        case .generator: "Generator"
        case .downloads: "Downloads"
        case .whatsapp: "WhatsApp"
        case .spotify: "Spotify"
        }
    }

    var symbol: String {
        switch self {
        case .ai: "gauge.with.dots.needle.67percent"
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .agents: "sparkles"
        case .tasks: "checklist"
        case .devServers: "server.rack"
        case .github: "arrow.triangle.pull"
        case .git: "arrow.triangle.branch"
        case .vercel: "triangle.fill"
        case .clipboard: "doc.on.clipboard"
        case .endpoints: "antenna.radiowaves.left.and.right"
        case .docker: "shippingbox"
        case .system: "cpu"
        case .battery: "battery.100percent"
        case .timer: "timer"
        case .calculator: "plus.forwardslash.minus"
        case .generator: "key.horizontal"
        case .downloads: "arrow.down.circle"
        case .whatsapp: "message.fill"
        case .spotify: "music.note"
        }
    }
}

extension WidgetID {
    /// Identity color, shared by the widget's panel, row icons and island tab.
    var tint: Color {
        switch self {
        case .ai, .agents: .purple
        case .claude: AIProvider.claude.tint
        case .codex: AIProvider.codex.tint
        case .tasks: .indigo
        case .devServers, .whatsapp, .spotify: .green
        case .github, .vercel, .calculator: .primary
        case .git, .timer: .orange
        case .endpoints, .clipboard: .teal
        case .docker, .downloads: .blue
        case .system, .battery: .mint
        case .generator: .yellow
        }
    }
}

// MARK: - AI

enum AIProvider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var shortName: String { self == .claude ? "Claude" : "Codex" }
    var symbol: String { self == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right" }
    var tint: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.45, green: 0.6, blue: 1.0) }
}

struct UsageWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
    var label: String
}

struct AIUsage: Equatable {
    var provider: AIProvider
    var plan: String?
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    /// `true` when fetched from the account; `false` when read from local CLI logs.
    var isLive: Bool
    var observedAt: Date
}

// MARK: - Agents

struct AgentSession: Identifiable, Equatable {
    enum State: Equatable { case working, waiting, finished }
    let id: String
    var provider: AIProvider
    var project: String
    var lastActivity: Date
    var state: State
    /// Session title (Claude Code `ai-title`/`custom-title`, Codex thread name).
    var title: String?
    /// One-line summary of the agent's last answer. In memory only, never persisted.
    var summary: String?
}

// MARK: - Dev servers

struct DevServer: Identifiable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    var command: String
    var ports: [Int]
    var cwd: String
    var project: String
    var framework: String?
    var uptime: String?
    var primaryURL: URL? { ports.first.flatMap { URL(string: "http://localhost:\($0)") } }
}

// MARK: - GitHub / Git

enum CheckState: String, Equatable {
    case success, failure, pending, none
    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case .none: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "circle.dotted"
        case .none: "circle"
        }
    }
}

struct PullRequest: Identifiable, Equatable {
    var id: String { url }
    let url: String
    var number: Int
    var title: String
    var repo: String
    var isDraft: Bool
    var checks: CheckState
    var reviewDecision: String?
    var updatedAt: Date?
}

struct WorkflowRun: Identifiable, Equatable {
    let id: Int
    var repo: String
    var title: String
    var workflow: String
    var branch: String
    var status: String
    var conclusion: String
    var url: String
    var updatedAt: Date?

    var state: CheckState {
        if status != "completed" { return .pending }
        switch conclusion {
        case "success": return .success
        case "skipped", "neutral", "cancelled": return .none
        default: return .failure
        }
    }
}

struct GitHubSnapshot: Equatable {
    var login: String
    var myPRs: [PullRequest]
    var reviewRequests: [PullRequest]
    var runs: [WorkflowRun]
    var unreadNotifications: Int
    var fetchedAt: Date

    var failingRuns: [WorkflowRun] {
        // Latest run per (repo, workflow, branch) that failed.
        var seen = Set<String>()
        var result: [WorkflowRun] = []
        for run in runs.sorted(by: { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) {
            let key = "\(run.repo)|\(run.workflow)|\(run.branch)"
            guard seen.insert(key).inserted else { continue }
            if run.state == .failure { result.append(run) }
        }
        return result
    }
}

struct RepoStatus: Identifiable, Equatable {
    var id: String { path }
    let path: String
    var name: String
    var branch: String
    var ahead: Int
    var behind: Int
    var changes: Int
    var githubSlug: String?
    var lastActivity: Date
}

// MARK: - Endpoints

struct Endpoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var method: String = "GET"
    var expectedStatus: Int?
}

struct EndpointStatus: Equatable {
    var httpStatus: Int?
    var latencyMs: Double?
    var ok: Bool
    var error: String?
    var history: [Double] = []
    var checkedAt: Date
}

// MARK: - Docker

struct DockerContainer: Identifiable, Equatable {
    let id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var ports: String
    var isRunning: Bool { state == "running" }
}

// MARK: - System

struct BatteryInfo: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var minutesRemaining: Int?
    var minutesToFull: Int?
}

struct SystemSnapshot: Equatable {
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    /// Load of each logical core, 0...1.
    var cores: [Double] = []
    var loadAverage: Double = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    /// Bytes per second over Ethernet and Wi-Fi.
    var netDown: Double = 0
    var netUp: Double = 0
    var battery: BatteryInfo?

    var memoryPercent: Double { Double(memUsed) / Double(max(1, memTotal)) * 100 }
    var diskPercent: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) * 100 : 0 }
}

/// Recent samples behind the System panel's charts, oldest first.
struct SystemHistory: Equatable {
    static let capacity = 72                // 6 minutes at one sample every 5 s
    var cpu: [Double] = []
    var netDown: [Double] = []
    var netUp: [Double] = []

    mutating func append(_ snapshot: SystemSnapshot) {
        cpu = Array((cpu + [snapshot.cpu * 100]).suffix(Self.capacity))
        netDown = Array((netDown + [snapshot.netDown]).suffix(Self.capacity))
        netUp = Array((netUp + [snapshot.netUp]).suffix(Self.capacity))
    }
}

struct TopProcess: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var cpu: Double
    var memory: Int64
}

// MARK: - Downloads

struct DownloadItem: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var name: String
    var size: Int64?
    var kind: String
    var added: Date
    var isDirectory: Bool
}

// MARK: - WhatsApp

struct WhatsAppChat: Identifiable, Equatable {
    /// The chat's JID.
    let id: String
    var name: String
    var preview: String
    /// -1 when the chat was marked as unread by hand.
    var unread: Int
    var date: Date
    var isGroup: Bool
    var isMuted: Bool
}

struct WhatsAppSnapshot: Equatable {
    enum State: Equatable { case loading, notInstalled, noAccess, ready }
    var state: State = .loading
    var chats: [WhatsAppChat] = []

    /// Muted chats stay in the panel but, like WhatsApp's own badge, don't count.
    var alerting: [WhatsAppChat] { chats.filter { !$0.isMuted } }
}

// MARK: - Spotify

struct SpotifyTrack: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var artworkURL: URL?
    var observedAt = Date()

    /// Playback position right now, extrapolated from the last observation.
    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(observedAt) : 0
        return duration > 0 ? min(duration, position + elapsed) : position + elapsed
    }

    /// `observedAt` and the position always change, so comparing them would redraw on every poll.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.isPlaying == rhs.isPlaying && lhs.artworkURL == rhs.artworkURL
            && abs(lhs.position(at: .now) - rhs.position(at: .now)) < 2
    }
}

// MARK: - Events (live activities for the island)

struct KodisleEvent: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color
    var widget: WidgetID?
    /// Optional longer text (e.g. what an agent just finished). Shown in the island banner.
    var detail: String?
    var date = Date()
}

// MARK: - Permission requests (Claude Code hook)

struct PermissionRequest: Identifiable, Equatable {
    let id = UUID()
    let tool: String
    /// What will run / be touched: the command, file path, URL…
    let target: String
    let project: String
    var sessionTitle: String?
    /// Claude Code's "always allow" rule suggestions, passed back verbatim on "Always".
    let suggestions: [[String: Any]]
    let reply: Bridge.Reply
    let date = Date()

    var canAlwaysAllow: Bool { !suggestions.isEmpty }
    var symbol: String {
        switch tool {
        case "Bash": "terminal.fill"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil.line"
        case "WebFetch", "WebSearch": "globe"
        case "Read", "Glob", "Grep": "doc.text.magnifyingglass"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension.fill" : "hand.raised.fill"
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Vercel

struct VercelDeployment: Identifiable, Equatable {
    let id: String
    var project: String
    var state: String          // BUILDING, READY, ERROR, CANCELED, QUEUED, INITIALIZING
    var target: String?        // production / preview
    var url: String
    var branch: String?
    var commit: String?
    var created: Date
    var team: String?

    var isActive: Bool { ["BUILDING", "QUEUED", "INITIALIZING"].contains(state) }
    var color: Color {
        switch state {
        case "READY": .green
        case "ERROR": .red
        case "CANCELED": .secondary
        default: .orange
        }
    }
}

// MARK: - Clipboard

struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var date: Date
    var app: String?
    /// Looks like a token/key: displayed masked and dropped after a short time.
    var isSecret: Bool

    var masked: String {
        guard isSecret else { return text }
        return String(repeating: "•", count: min(18, max(6, text.count - 4))) + text.suffix(4)
    }
}
