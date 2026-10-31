import Foundation

enum AIError: LocalizedError {
    case notInstalled, notSignedIn, expired, http(Int), parse

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Not installed"
        case .notSignedIn: "Not signed in"
        case .expired: "Session expired — open the CLI to refresh it"
        case .http(let code): "Server returned HTTP \(code)"
        case .parse: "Unexpected response"
        }
    }
}

/// Claude Code plan limits (5-hour + weekly), the same numbers `/usage` shows.
///
/// The OAuth access token Claude Code keeps in the login Keychain is read through
/// `/usr/bin/security` (already trusted by that item, so no prompt), held in memory for
/// one request and discarded. Kodisle **never refreshes** the token: rotating it would sign
/// the CLI out. If it's expired we simply ask the user to open Claude Code.
enum ClaudeUsageProvider {
    private struct Token { let access: String; let plan: String? }

    static func fetch() async throws -> AIUsage {
        let token = try await readToken()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Kodisle", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Net.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AIError.expired }
        guard code == 200 else { throw AIError.http(code) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AIError.parse }

        func window(_ key: String, _ label: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: (w["resets_at"] as? String).flatMap(ISO.parse), label: label)
        }
        return AIUsage(provider: .claude, plan: token.plan?.capitalized,
                       fiveHour: window("five_hour", "5 hours"), weekly: window("seven_day", "Week"),
                       isLive: true, observedAt: .now)
    }

    private static func readToken() async throws -> Token {
        let service = "Claude Code-credentials"
        let attempts = [
            ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"],
            ["find-generic-password", "-s", service, "-w"],
        ]
        for args in attempts {
            guard let result = try? await Shell.run("/usr/bin/security", args), result.ok,
                  let token = parse(result.stdout) else { continue }
            return try token.get()
        }
        // Fallback used by some installs (Linux-style credentials file).
        let file = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = parse(data) { return try token.get() }
        if !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude") { throw AIError.notInstalled }
        throw AIError.notSignedIn
    }

    private static func parse(_ data: Data) -> Result<Token, AIError>? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           expires / 1000 < Date().timeIntervalSince1970 {
            return .failure(.expired)
        }
        return .success(Token(access: access, plan: oauth["subscriptionType"] as? String))
    }
}

/// Codex (ChatGPT plan) limits: 5-hour primary + weekly secondary window.
///
/// Live numbers come from the ChatGPT account endpoint Codex itself uses, authenticated
/// with the access token in `~/.codex/auth.json` (read-only, in memory, never refreshed).
/// If that fails we fall back to the last `rate_limits` snapshot in the local session logs.
enum CodexUsageProvider {
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.codex")
    }

    static func fetch() async throws -> AIUsage {
        guard FileManager.default.fileExists(atPath: home.path) else { throw AIError.notInstalled }
        do {
            return try await fetchLive()
        } catch {
            if let local = await Task.detached(operation: { fetchLocal() }).value { return local }
            throw error
        }
    }

    private static func fetchLive() async throws -> AIUsage {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { throw AIError.notSignedIn }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("Kodisle", forHTTPHeaderField: "User-Agent")
        let (body, response) = try await Net.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AIError.expired }
        guard code == 200, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any] else { throw AIError.http(code) }

        func window(_ key: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let seconds = (w["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
            return UsageWindow(usedPercent: used, resetsAt: reset, label: label(forSeconds: seconds))
        }
        return AIUsage(provider: .codex, plan: (json["plan_type"] as? String)?.capitalized,
                       fiveHour: window("primary_window"), weekly: window("secondary_window"),
                       isLive: true, observedAt: .now)
    }

    /// Reads the newest `rate_limits` event from local Codex session logs.
    static func fetchLocal() -> AIUsage? {
        let fm = FileManager.default
        let sessions = home.appendingPathComponent("sessions")
        guard let enumerator = fm.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        for (file, date) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            for line in FileTail.jsonLines(file, bytes: 512 * 1024).reversed() {
                guard let limits = findRateLimits(line) else { continue }
                func window(_ key: String) -> UsageWindow? {
                    guard let w = limits[key] as? [String: Any],
                          var used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    if let reset, reset < Date() { used = 0 } // window already rolled over
                    let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                    return UsageWindow(usedPercent: used, resetsAt: reset, label: label(forSeconds: minutes * 60))
                }
                return AIUsage(provider: .codex, plan: nil, fiveHour: window("primary"), weekly: window("secondary"),
                               isLive: false, observedAt: date)
            }
        }
        return nil
    }

    private static func findRateLimits(_ object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if let limits = dict["rate_limits"] as? [String: Any], limits["primary"] != nil { return limits }
            for value in dict.values { if let found = findRateLimits(value) { return found } }
        }
        return nil
    }

    private static func label(forSeconds seconds: Int) -> String {
        switch seconds {
        case 0: "Window"
        case ..<86_400: "\(seconds / 3600) hours"
        case 604_800: "Week"
        default: "\(seconds / 86_400) days"
        }
    }
}
