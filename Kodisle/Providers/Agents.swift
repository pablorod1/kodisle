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
        private var map: [String: (size: UInt64, title: String?, checked: Date)] = [:]
        /// A found title is reused until a newer one shows up in the tail; "no title" is
        /// trusted for 2 minutes so growing transcripts aren't rescanned on every pass.
        func get(_ path: String, size: UInt64) -> String?? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = map[path] else { return nil }
            if entry.title != nil || entry.size == size || Date().timeIntervalSince(entry.checked) < 120 { return .some(entry.title) }
            return nil
        }
        func set(_ path: String, size: UInt64, title: String?) {
            lock.lock(); defer { lock.unlock() }
            map[path] = (size, title, Date())
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        var st = stat()
        return stat(url.path, &st) == 0 ? UInt64(st.st_size) : 0
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

    /// Uncached modification date via stat(2) (URL resource values are cached per instance).
    private static func mtime(_ url: URL) -> Date? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Lists a folder's recent transcripts. A full listing (stat of every file) happens when
    /// the folder changes (new session) or once a minute; in between only files already known
    /// to be recent are re-checked — a handful of stats instead of hundreds every few seconds.
    private final class Listings: @unchecked Sendable {
        let lock = NSLock()
        var map: [String: (dirDate: Date, listed: Date, recent: [URL])] = [:]
    }
    private static let listings = Listings()

    private static func recentFiles(in dir: URL) -> [(URL, Date)] {
        let cutoff = Date().addingTimeInterval(-window)
        let dirDate = mtime(dir) ?? .distantPast
        listings.lock.lock()
        let cached = listings.map[dir.path]
        listings.lock.unlock()
        let candidates: [URL]
        if let cached, cached.dirDate == dirDate, Date().timeIntervalSince(cached.listed) < 60 {
            candidates = cached.recent
        } else {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            candidates = items.filter { $0.pathExtension == "jsonl" && (mtime($0) ?? .distantPast) > cutoff }
            listings.lock.lock()
            listings.map[dir.path] = (dirDate, Date(), candidates)
            listings.lock.unlock()
        }
        return candidates.compactMap { url in
            guard let date = mtime(url), date > cutoff else { return nil }
            return (url, date)
        }
    }

    // MARK: Parse cache
    //
    // Reading and decoding a transcript tail is the expensive part, so each file is parsed
    // only when its size or modification date changes. Deciding working / waiting / finished
    // from the cached facts plus the idle time is cheap and runs on every scan.

    private enum LastEntry { case none, user, assistantEnd, assistantToolUse, assistantOther, codexStarted, codexWaiting, codexDone }

    private struct Parsed {
        var cwd: String?
        var last: LastEntry
        var title: String?
        var summary: String?
    }

    private final class ParseCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (date: Date, size: UInt64, parsed: Parsed)] = [:]
        func get(_ path: String, date: Date, size: UInt64) -> Parsed? {
            lock.lock(); defer { lock.unlock() }
            guard let e = map[path], e.date == date, e.size == size else { return nil }
            return e.parsed
        }
        func set(_ path: String, date: Date, size: UInt64, _ parsed: Parsed) {
            lock.lock(); defer { lock.unlock() }
            map[path] = (date, size, parsed)
            if map.count > 400 { map = map.filter { Date().timeIntervalSince($0.value.date) < 3600 } }
        }
    }
    private static let parsed = ParseCache()

    private static func state(for last: LastEntry, idle: TimeInterval, idleAfter: TimeInterval) -> AgentSession.State {
        switch last {
        case .assistantEnd, .codexDone: .finished
        // A pending tool call with no writes for a while usually means a permission prompt.
        case .assistantToolUse: idle < max(60, idleAfter * 2.5) ? .working : .waiting
        case .codexWaiting: .waiting
        case .user, .codexStarted: idle < idleAfter * 4 ? .working : .finished
        case .assistantOther, .none: idle < idleAfter ? .working : .finished
        }
    }

    // MARK: Claude Code (~/.claude/projects/<project>/<session>.jsonl)

    /// Walks the transcript backwards and decodes only the few lines it needs, stopping as
    /// soon as it has them. A cheap substring test runs before any JSON decoding.
    private static func parseClaude(_ file: URL, summaries: Bool) -> Parsed {
        var last: LastEntry?
        var cwd: String?
        var title: String?
        var answer: String?
        var needAnswer = summaries
        for bytes in [96 * 1024, 512 * 1024] {
            guard let text = FileTail.read(file, bytes: bytes) else { break }
            for line in text.split(separator: "\n").reversed() {
                if cwd == nil, let range = line.range(of: "\"cwd\":\"") {
                    let rest = line[range.upperBound...]
                    if let close = rest.firstIndex(of: "\"") { cwd = String(rest[..<close]) }
                }
                if title == nil, line.contains("-title\""), let obj = decode(line) {
                    if obj["type"] as? String == "custom-title" { title = obj["customTitle"] as? String }
                    else if obj["type"] as? String == "ai-title" { title = obj["aiTitle"] as? String }
                }
                let isAssistant = line.contains("\"type\":\"assistant\"")
                let isUser = !isAssistant && line.contains("\"type\":\"user\"")
                if (last == nil && (isAssistant || isUser)) || (needAnswer && isAssistant && line.contains("\"text\"")),
                   let obj = decode(line), let type = obj["type"] as? String {
                    let message = obj["message"] as? [String: Any]
                    if last == nil {
                        if type == "assistant" {
                            let stop = message?["stop_reason"] as? String
                            last = (stop == "end_turn" || stop == "stop_sequence") ? .assistantEnd : stop == "tool_use" ? .assistantToolUse : .assistantOther
                        } else if type == "user" {
                            last = .user
                        }
                    }
                    if needAnswer, type == "assistant", let content = message?["content"] as? [[String: Any]] {
                        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer = text; needAnswer = false }
                    }
                }
                if last != nil, cwd != nil, title != nil, !needAnswer { break }
            }
            if last != nil, cwd != nil, !needAnswer { break }
        }
        if title == nil { title = claudeTitle(file, tail: []) }   // cached full-file fallback
        return Parsed(cwd: cwd, last: last ?? .none, title: title, summary: answer.map { Summary.oneLine($0) })
    }

    private static func decode(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func claudeSessions(idleAfter: TimeInterval, summaries: Bool) -> [AgentSession] {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var sessions: [AgentSession] = []
        for dir in dirs {
            for (file, date) in recentFiles(in: dir) {
                let size = fileSize(file)
                let info = parsed.get(file.path, date: date, size: size) ?? {
                    let fresh = parseClaude(file, summaries: summaries)
                    parsed.set(file.path, date: date, size: size, fresh)
                    return fresh
                }()
                let idle = Date().timeIntervalSince(date)
                sessions.append(AgentSession(id: file.path, provider: .claude,
                                             project: info.cwd.map { ($0 as NSString).lastPathComponent } ?? dir.lastPathComponent,
                                             lastActivity: date, state: state(for: info.last, idle: idle, idleAfter: idleAfter),
                                             title: info.title, summary: summaries ? info.summary : nil))
            }
        }
        return sessions
    }

    // MARK: Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

    private static func parseCodex(_ file: URL, summaries: Bool, index: inout [String: String]?) -> Parsed {
        let lines = FileTail.jsonLines(file, bytes: 64 * 1024)
        var cwd: String?
        for line in lines.reversed() {
            if let payload = line["payload"] as? [String: Any], let value = payload["cwd"] as? String { cwd = value; break }
        }
        if cwd == nil, let head = FileHead.read(file, bytes: 8192),
           let match = head.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) {
            cwd = String(head[match]).replacingOccurrences(of: "\"cwd\":\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        var last: LastEntry = .none
        var answer: String?
        for line in lines.reversed() {
            guard line["type"] as? String == "event_msg", let payload = line["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            if kind == "task_complete" || kind == "turn_aborted" { last = .codexDone; answer = payload["last_agent_message"] as? String; break }
            if kind.hasSuffix("approval_request") { last = .codexWaiting; break }
            if kind == "task_started" { last = .codexStarted; break }
        }
        if index == nil { index = codexIndex }
        let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
        return Parsed(cwd: cwd, last: last, title: index?[id], summary: summaries ? answer.map { Summary.oneLine($0) } : nil)
    }

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
                let size = fileSize(file)
                let info = parsed.get(file.path, date: date, size: size) ?? {
                    let fresh = parseCodex(file, summaries: summaries, index: &index)
                    parsed.set(file.path, date: date, size: size, fresh)
                    return fresh
                }()
                let idle = Date().timeIntervalSince(date)
                var st = state(for: info.last, idle: idle, idleAfter: idleAfter)
                if info.last == .none { st = idle < idleAfter ? .working : .finished }
                sessions.append(AgentSession(id: file.path, provider: .codex,
                                             project: info.cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex",
                                             lastActivity: date, state: st, title: info.title,
                                             summary: summaries ? info.summary : nil))
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
