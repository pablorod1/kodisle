import AppKit
import Foundation

enum Fmt {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }

    static func resetIn(_ date: Date?) -> String {
        guard let date else { return "" }
        let remaining = date.timeIntervalSinceNow
        return remaining <= 0 ? "reset" : "resets in \(duration(remaining))"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 45 { return "just now" }
        return "\(duration(s)) ago"
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

enum Redact {
    /// Strips credentials and query strings so URLs are safe to show on screen.
    static func url(_ string: String) -> String {
        guard var components = URLComponents(string: string) else { return string }
        components.user = nil
        components.password = nil
        let hadQuery = components.query != nil
        components.query = nil
        components.fragment = nil
        let base = components.string ?? string
        return hadQuery ? base + "?…" : base
    }

    /// Extracts `owner/repo` from any GitHub remote, dropping embedded credentials.
    static func githubSlug(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        guard let range = s.range(of: "github.com[:/]", options: .regularExpression) else { return nil }
        let parts = s[range.upperBound...].split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

@MainActor
enum Clipboard {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Copies text. Sensitive values are marked as concealed (clipboard managers skip them)
    /// and are cleared after the configured delay if nothing else was copied meanwhile.
    static func copy(_ text: String, sensitive: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if sensitive {
            pb.declareTypes([.string, concealed], owner: nil)
            pb.setString(text, forType: .string)
            pb.setString("", forType: concealed)
            let change = pb.changeCount
            let delay = AppSettings.shared.config.clipboardClearSeconds
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if pb.changeCount == change { pb.clearContents() }
                }
            }
        } else {
            pb.setString(text, forType: .string)
        }
    }
}

@MainActor
enum Open {
    static func url(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    static func terminal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
