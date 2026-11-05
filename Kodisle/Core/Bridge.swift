import Darwin
import Foundation

/// Local bridge between Kodisle and external tools (Claude Code hooks, the zsh integration).
///
/// A Unix domain socket at `~/.kodisle/bridge.sock` inside a 0700 directory, so only the
/// current user can talk to it. Each client sends **one line**: base64-encoded JSON.
/// - Claude Code `PermissionRequest` hook payloads keep the connection open until the user
///   decides in the island; the reply is the hook's stdout JSON.
/// - Everything else (e.g. `{"kind":"command",…}`) is fire-and-forget.
final class Bridge: @unchecked Sendable {
    static let directory = URL(fileURLWithPath: NSHomeDirectory() + "/.kodisle")
    static let socketPath = directory.appendingPathComponent("bridge.sock").path

    struct Message {
        let json: [String: Any]
        /// Non-nil when the client waits for an answer.
        let reply: Reply?
    }

    /// One pending reply channel; answering (or dropping) closes the connection.
    final class Reply: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var done = false
        init(fd: Int32) { self.fd = fd }

        func send(_ object: [String: Any]?) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            if let object, var data = try? JSONSerialization.data(withJSONObject: object) {
                data.append(0x0A)
                data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) }
            }
            close(fd)
        }

        /// True when the hook went away (Claude Code cancelled it or the prompt was answered elsewhere).
        var peerClosed: Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return true }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0 else { return false }
            if pfd.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
        }

        deinit { send(nil) }
    }

    private var listenFD: Int32 = -1
    private let onMessage: @Sendable (Message) -> Void

    init(onMessage: @escaping @Sendable (Message) -> Void) {
        self.onMessage = onMessage
    }

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(Self.directory.path, 0o700)
        unlink(Self.socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) } }
        guard bound == 0, listen(listenFD, 16) == 0 else { close(listenFD); listenFD = -1; return }
        chmod(Self.socketPath, 0o600)

        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { self?.handle(client) }
            }
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
    }

    private func handle(_ fd: Int32) {
        // Read one line (max 1 MB).
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1 << 20 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[..<n].contains(0x0A) { break }
        }
        let line = data.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        guard let decoded = Data(base64Encoded: line.filter { $0 != 0x0D }),
              let json = (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any]
        else { close(fd); return }
        let waits = json["hook_event_name"] as? String == "PermissionRequest"
        if !waits { close(fd) }
        onMessage(Message(json: json, reply: waits ? Reply(fd: fd) : nil))
    }
}

/// Installs / removes the optional integrations. Every change is opt-in from Settings,
/// backs up the file it touches, and only adds or removes Kodisle's own entries.
enum Integrations {
    static var hooksDir: URL { Bridge.directory.appendingPathComponent("hooks") }
    static var permissionHook: URL { hooksDir.appendingPathComponent("claude-permission.sh") }
    static var zshScript: URL { Bridge.directory.appendingPathComponent("kodisle.zsh") }
    static var claudeSettings: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json") }
    static var zshrc: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.zshrc") }
    private static let zshLine = "[ -f ~/.kodisle/kodisle.zsh ] && source ~/.kodisle/kodisle.zsh  # Kodisle"

    // MARK: Claude Code permission approvals

    static let permissionHookScript = """
    #!/bin/zsh -f
    # Kodisle — forwards Claude Code permission requests to the Kodisle island and prints the
    # decision. If Kodisle isn't running (or you choose "Terminal"), it prints nothing and
    # Claude Code falls back to its normal prompt. Nothing is logged or stored.
    SOCK="$HOME/.kodisle/bridge.sock"
    [[ -S $SOCK ]] || exit 0
    zmodload zsh/net/socket 2>/dev/null || exit 0
    zsocket "$SOCK" 2>/dev/null || exit 0
    fd=$REPLY
    print -r -- "$(base64 | tr -d '\\n')" >&$fd
    if IFS= read -r line <&$fd && [[ -n $line ]]; then print -r -- "$line"; fi
    exec {fd}>&-
    exit 0
    """

    static var claudeApprovalsInstalled: Bool {
        guard let settings = readJSON(claudeSettings),
              let entries = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] else { return false }
        return entries.contains { isOurs($0) }
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(".kodisle/hooks/") == true }
    }

    static func installClaudeApprovals() throws {
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try permissionHookScript.write(to: permissionHook, atomically: true, encoding: .utf8)
        chmod(permissionHook.path, 0o700)

        var settings = readJSON(claudeSettings) ?? [:]
        try backup(claudeSettings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = (hooks["PermissionRequest"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
        // Long timeout: the request waits while the notification is on screen.
        entries.append(["matcher": "*", "hooks": [["type": "command", "command": permissionHook.path, "timeout": 600]]])
        hooks["PermissionRequest"] = entries
        settings["hooks"] = hooks
        try writeJSON(settings, to: claudeSettings)
    }

    static func uninstallClaudeApprovals() throws {
        guard var settings = readJSON(claudeSettings) else { return }
        try backup(claudeSettings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let remaining = (hooks["PermissionRequest"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
        if remaining.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = remaining }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeJSON(settings, to: claudeSettings)
        try? FileManager.default.removeItem(at: permissionHook)
    }

    // MARK: Claude Code tasks (MCP)

    private static let tasksServerName = "kodisle"
    private static let tasksPermission = "mcp__kodisle"
    private static var tasksServer: URL { hooksDir.appendingPathComponent("tasks-mcp.sh") }
    private static var claudeConfig: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json") }

    /// Claude Code runs this launcher rather than the app directly, so moving the app or
    /// updating it only has to rewrite the launcher, not Claude Code's configuration.
    private static var tasksServerScript: String {
        let binary = (Bundle.main.executablePath ?? "").replacingOccurrences(of: "'", with: "'\\''")
        return "#!/bin/sh\n# Kodisle — starts the task list MCP server for Claude Code.\nexec '\(binary)' --mcp\n"
    }

    private static func writeTasksServer() throws {
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try tasksServerScript.write(to: tasksServer, atomically: true, encoding: .utf8)
        chmod(tasksServer.path, 0o700)
    }

    static var claudeTasksInstalled: Bool {
        (readJSON(claudeConfig)?["mcpServers"] as? [String: Any])?[tasksServerName] != nil
    }

    /// Registers the server through Claude Code's own CLI (`~/.claude.json` is rewritten by
    /// every running session) and allows its tools, so Claude can use them without a prompt.
    static func installClaudeTasks() async throws {
        try writeTasksServer()
        _ = try? await Shell.run("claude", ["mcp", "remove", "--scope", "user", tasksServerName])
        let added = try await Shell.run("claude", ["mcp", "add", "--scope", "user", tasksServerName, "--", tasksServer.path])
        guard added.ok else { throw IntegrationError.claude(added.stderr) }

        var settings = readJSON(claudeSettings) ?? [:]
        try backup(claudeSettings)
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        if !allow.contains(tasksPermission) { allow.append(tasksPermission) }
        permissions["allow"] = allow
        settings["permissions"] = permissions
        try writeJSON(settings, to: claudeSettings)
    }

    static func uninstallClaudeTasks() async throws {
        let removed = try await Shell.run("claude", ["mcp", "remove", "--scope", "user", tasksServerName])
        guard removed.ok || !claudeTasksInstalled else { throw IntegrationError.claude(removed.stderr) }

        if var settings = readJSON(claudeSettings), var permissions = settings["permissions"] as? [String: Any],
           let allow = permissions["allow"] as? [String], allow.contains(tasksPermission) {
            try backup(claudeSettings)
            permissions["allow"] = allow.filter { $0 != tasksPermission }
            settings["permissions"] = permissions
            try writeJSON(settings, to: claudeSettings)
        }
        try? FileManager.default.removeItem(at: tasksServer)
    }

    /// Keeps the launcher pointing at this copy of the app (e.g. after moving it).
    static func refreshTasksServer() {
        guard let current = try? String(contentsOf: tasksServer, encoding: .utf8), current != tasksServerScript else { return }
        try? writeTasksServer()
    }

    private enum IntegrationError: LocalizedError {
        case claude(String)
        var errorDescription: String? {
            switch self {
            case .claude(let output): "Claude Code: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    // MARK: zsh long-command notifications

    /// Only the program and its first subcommand are sent (e.g. `pnpm build`), never arguments,
    /// so secrets typed on the command line can't leak into notifications.
    static let zshScriptSource = """
    # Kodisle — notifies the island when a long terminal command finishes.
    # Sends: program + first subcommand, exit code, duration and folder. Never the full command.
    zmodload zsh/datetime 2>/dev/null
    typeset -g _kodisle_start=0 _kodisle_cmd=""
    : ${KODISLE_MIN_SECONDS:=15}
    _kodisle_preexec() {
      _kodisle_start=$EPOCHREALTIME
      local -a words; words=(${(z)1})
      while [[ ${#words} -gt 0 && ${words[1]} == *=* ]]; do shift words; done
      while [[ ${#words} -gt 0 && ( ${words[1]} == sudo || ${words[1]} == time || ${words[1]} == nohup ) ]]; do shift words; done
      _kodisle_cmd="${words[1]:t}"
      [[ -n ${words[2]} && ${words[2]} != -* && ${words[2]} != */* && ${words[2]} != *=* ]] && _kodisle_cmd+=" ${words[2]}"
    }
    _kodisle_precmd() {
      local code=$?
      [[ $_kodisle_start == 0 ]] && return
      local secs=$(( EPOCHREALTIME - _kodisle_start )); _kodisle_start=0
      (( secs < KODISLE_MIN_SECONDS )) && return
      [[ -S $HOME/.kodisle/bridge.sock ]] || return
      local json; json=$(printf '{"kind":"command","command":"%s","exit":%d,"seconds":%.1f,"cwd":"%s"}' \\
        "${_kodisle_cmd//\\"/}" $code $secs "${PWD//\\"/}")
      ( printf '%s\\n' "$(printf '%s' "$json" | base64 | tr -d '\\n')" | /usr/bin/nc -U $HOME/.kodisle/bridge.sock >/dev/null 2>&1 & ) 2>/dev/null
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _kodisle_preexec
    add-zsh-hook precmd _kodisle_precmd
    """

    static var zshInstalled: Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains("kodisle.zsh") == true
    }

    static func installZsh() throws {
        try FileManager.default.createDirectory(at: Bridge.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try zshScriptSource.write(to: zshScript, atomically: true, encoding: .utf8)
        guard !zshInstalled else { return }
        try backup(zshrc)
        var rc = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        if !rc.hasSuffix("\n") && !rc.isEmpty { rc += "\n" }
        rc += zshLine + "\n"
        try rc.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func uninstallZsh() throws {
        guard let rc = try? String(contentsOf: zshrc, encoding: .utf8) else { return }
        try backup(zshrc)
        let kept = rc.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("kodisle.zsh") }
        try kept.joined(separator: "\n").write(to: zshrc, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: zshScript)
    }

    // MARK: Helpers

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".kodisle-backup")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
    }
}
