import Foundation

/// Detects running Claude Code / Codex sessions from their local JSONL transcripts.
///
/// Only metadata is read (timestamps, `cwd`, message type / stop reason). Message
/// contents are never shown or stored.
enum AgentProvider {
    static func scan(idleAfter: TimeInterval, summaries: Bool) async -> [AgentSession] {
        await Task.detached(priority: .utility) {
            (claudeSessions(idleAfter: idleAfter, summaries: summaries) + codexSessions(idleAfter: idleAfter, summaries: summaries))
                .sorted { $0.lastActivity > $1.lastActivity }
        }.value
    }

    /// Session titles rarely change; cache them per transcript to avoid rescanning big files.
    private static let titles = TitleCache()

    private final class TitleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (size: UInt64, title: String?)] = [:]
        func get(_ path: String, size: UInt64) -> String?? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = map[path], entry.size == size || entry.title != nil else { return nil }
            return .some(entry.title)
        }
        func set(_ path: String, size: UInt64, title: String?) {
            lock.lock(); defer { lock.unlock() }
            map[path] = (size, title)
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Claude Code writes `{"type":"custom-title","customTitle":…}` (from /rename) and
    /// `{"type":"ai-title","aiTitle":…}`. A custom title wins.
    private static func claudeTitle(_ file: URL, tail: [[String: Any]]) -> String? {
        func pick(_ lines: [[String: Any]]) -> String? {
            var ai: String?
            for line in lines.reversed() {
                if line["type"] as? String == "custom-title", let t = line["customTitle"] as? String, !t.isEmpty { return t }
                if ai == nil, line["type"] as? String == "ai-title", let t = line["aiTitle"] as? String, !t.isEmpty { ai = t }
            }
            return ai
        }
        let size = fileSize(file)
        // Titles are re-emitted periodically, so the tail usually has the latest one.
        if let fromTail = pick(tail) { titles.set(file.path, size: size, title: fromTail); return fromTail }
        if let cached = titles.get(file.path, size: size) { return cached }
        var title: String?
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            // Stream the file looking only for title lines (cheap substring check first).
            var lines: [[String: Any]] = []
            var buffer = Data()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard line.count < 4096, let text = String(data: line, encoding: .utf8),
                          text.contains("-title\"") else { continue }
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { lines.append(obj) }
                }
            }
            title = pick(lines)
        }
        titles.set(file.path, size: size, title: title)
        return title
    }

    /// Text of the last assistant message (only the text blocks, never tool calls/results).
    private static func claudeLastAnswer(_ lines: [[String: Any]]) -> String? {
        for line in lines.reversed() where line["type"] as? String == "assistant" {
            guard let content = (line["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private static var codexIndex: [String: String] {
        let url = CodexUsageProvider.home.appendingPathComponent("session_index.jsonl")
        var map: [String: String] = [:]
        for line in FileTail.jsonLines(url, bytes: 2 * 1024 * 1024) {
            if let id = line["id"] as? String, let name = line["thread_name"] as? String { map[id] = name }
        }
        return map
    }

    private static let window: TimeInterval = 30 * 60

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func recentFiles(in dir: URL) -> [(URL, Date)] {
        let cutoff = Date().addingTimeInterval(-window)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard url.pathExtension == "jsonl", let date = mtime(url), date > cutoff else { return nil }
            return (url, date)
        }
    }

    // MARK: Claude Code (~/.claude/projects/<project>/<session>.jsonl)

    private static func claudeSessions(idleAfter: TimeInterval, summaries: Bool) -> [AgentSession] {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var sessions: [AgentSession] = []
        for dir in dirs {
            for (file, date) in recentFiles(in: dir) {
                let lines = FileTail.jsonLines(file, bytes: 256 * 1024)
                let cwd = lines.reversed().lazy.compactMap { $0["cwd"] as? String }.first
                let idle = Date().timeIntervalSince(date)
                var state: AgentSession.State = .finished
                // Last meaningful entry decides the state.
                for line in lines.reversed() {
                    guard let type = line["type"] as? String else { continue }
                    if type == "assistant" {
                        let stop = (line["message"] as? [String: Any])?["stop_reason"] as? String
                        if stop == "end_turn" || stop == "stop_sequence" {
                            state = .finished
                        } else if stop == "tool_use" {
                            // A pending tool call with no writes for a while usually means a permission prompt.
                            state = idle < max(60, idleAfter * 2.5) ? .working : .waiting
                        } else {
                            state = idle < idleAfter ? .working : .finished
                        }
                        break
                    }
                    if type == "user" {
                        state = idle < idleAfter * 4 ? .working : .finished
                        break
                    }
                }
                guard state != .finished || idle < window else { continue }
                sessions.append(AgentSession(id: file.path, provider: .claude,
                                             project: cwd.map { ($0 as NSString).lastPathComponent } ?? dir.lastPathComponent,
                                             lastActivity: date, state: state,
                                             title: claudeTitle(file, tail: lines),
                                             summary: summaries ? claudeLastAnswer(lines).map { Summary.oneLine($0) } : nil))
            }
        }
        return sessions
    }

    // MARK: Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    private static func codexSessions(idleAfter: TimeInterval, summaries: Bool) -> [AgentSession] {
        let root = CodexUsageProvider.home.appendingPathComponent("sessions")
        var index: [String: String]?
        let calendar = Calendar.current
        var sessions: [AgentSession] = []
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            for (file, date) in recentFiles(in: dir) {
                let lines = FileTail.jsonLines(file, bytes: 64 * 1024)
                var cwd: String?
                for line in lines.reversed() {
                    if let payload = line["payload"] as? [String: Any], let value = payload["cwd"] as? String { cwd = value; break }
                }
                if cwd == nil, let head = try? String(contentsOf: file, encoding: .utf8).prefix(8192),
                   let match = head.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) {
                    cwd = String(head[match]).replacingOccurrences(of: "\"cwd\":\"", with: "").replacingOccurrences(of: "\"", with: "")
                }
                let idle = Date().timeIntervalSince(date)
                var state: AgentSession.State = idle < idleAfter ? .working : .finished
                var lastAnswer: String?
                for line in lines.reversed() {
                    guard line["type"] as? String == "event_msg",
                          let payload = line["payload"] as? [String: Any],
                          let kind = payload["type"] as? String else { continue }
                    if kind == "task_complete" || kind == "turn_aborted" {
                        state = .finished
                        lastAnswer = payload["last_agent_message"] as? String
                        break
                    }
                    if kind.hasSuffix("approval_request") { state = .waiting; break }
                    if kind == "task_started" { state = idle < idleAfter * 4 ? .working : .finished; break }
                }
                if index == nil { index = codexIndex }
                let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
                sessions.append(AgentSession(id: file.path, provider: .codex,
                                             project: cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex",
                                             lastActivity: date, state: state, title: index?[id],
                                             summary: summaries ? lastAnswer.map { Summary.oneLine($0) } : nil))
            }
        }
        return sessions
    }
}

/// Condenses an agent's final answer into a short, plain-text line for notifications.
enum Summary {
    static func oneLine(_ text: String, limit: Int = 180) -> String {
        var s = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        var lines: [String] = []
        for raw in s.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: "^(#{1,6}|[-*•>]|\\d+[.)])\\s+", with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "[*_]{1,3}", with: "", options: .regularExpression)
            if !line.isEmpty, line != "---" { lines.append(line) }
        }
        var result = ""
        for line in lines {
            let piece = line.hasSuffix(":") ? String(line.dropLast()) : line
            result += result.isEmpty ? piece : (result.hasSuffix(".") ? " " : " · ") + piece
            if result.count >= limit { break }
        }
        if result.count > limit {
            let cut = result.prefix(limit)
            result = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return result
    }
}
