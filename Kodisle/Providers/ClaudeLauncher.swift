import AppKit
import Foundation

/// Starts Claude Code on a task in a new Warp tab, waiting for Enter before it runs.
///
/// Warp can only run commands from a Tab Config, and `claude` can't pre-fill its input, so this
/// rewrites one Tab Config per click (Warp reads it when the tab opens) and the tab shows the
/// prompt and waits. The prompt travels in a private file instead of the command line: tasks can
/// be written by agents, and their text must never reach a shell as code.
enum ClaudeLauncher {
    private static let warpBundleID = "dev.warp.Warp-Stable"
    private static let configName = "kodisle_claude"

    static var isAvailable: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: warpBundleID) != nil }

    /// Blocking: call off the main thread.
    static func prepare(_ item: TodoItem, projectsRoot: URL) throws {
        let prompts = URL(fileURLWithPath: NSHomeDirectory() + "/.kodisle/prompts", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: prompts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let promptFile = prompts.appendingPathComponent(UUID().uuidString + ".txt")
        guard fm.createFile(atPath: promptFile.path, contents: Data(prompt(for: item).utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let configs = URL(fileURLWithPath: NSHomeDirectory() + "/.warp/tab_configs", isDirectory: true)
        try fm.createDirectory(at: configs, withIntermediateDirectories: true)
        let directory = project(item.project, in: projectsRoot) ?? projectsRoot
        try tabConfig(title: item.title, directory: directory.path, promptFile: promptFile.path)
            .write(to: configs.appendingPathComponent(configName + ".toml"), atomically: true, encoding: .utf8)
    }

    @MainActor
    static func openTab() {
        Open.url("warp://tab_config/\(configName)")
    }

    private static func prompt(for item: TodoItem) -> String {
        var text = "Work on this task from my Kodisle list (id \(item.id)):\n\n\(item.title)"
        if let notes = item.notes, !notes.isEmpty { text += "\n\nNotes:\n\(notes)" }
        return text
    }

    /// Tasks store the repository's folder name, not its path.
    private static func project(_ name: String?, in root: URL) -> URL? {
        guard let name else { return nil }
        return GitProvider.discover(root: root).first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func tabConfig(title: String, directory: String, promptFile: String) -> String {
        let file = shellQuoted(promptFile)
        let command = """
            p=$(<\(file)); rm -f \(file); print -r -- "$p"; print; \
            read -s '?Press Enter to start Claude (Ctrl+C to cancel)'; print; claude "$p"
            """
        // `{{` would make Warp ask for a parameter.
        let tabTitle = String(title.prefix(40)).replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
        return """
            # Rewritten by Kodisle each time you press Claude on a task.
            name = "Claude task (Kodisle)"
            title = \(tomlQuoted(tabTitle))

            [[panes]]
            id = "main"
            type = "terminal"
            directory = \(tomlQuoted(directory))
            shell = "zsh"
            commands = [\(tomlQuoted(command))]

            """
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tomlQuoted(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n", "\r", "\t": quoted += " "
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: break
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}
