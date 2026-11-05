import AppKit
import Foundation

/// Spotify desktop app. Track changes arrive as a distributed notification (no permission needed);
/// artwork, the live position and playback controls go through AppleScript (Automation permission).
enum SpotifyProvider {
    static let bundleID = "com.spotify.client"
    static let stateChanged = Notification.Name("com.spotify.client.PlaybackStateChanged")

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    enum Command: String {
        case playPause = "playpause", next = "next track", previous = "previous track"
    }

    enum FetchResult { case track(SpotifyTrack?), denied, failed }

    private static let separator = "\u{1F}"
    private static let script = """
        tell application id "\(bundleID)"
            if player state is stopped then return ""
            set t to current track
            set s to character id 31
            return (player state as string) & s & (id of t) & s & (name of t) & s & (artist of t) & s & (album of t) ¬
                & s & (duration of t) & s & (player position as string) & s & (artwork url of t)
        end tell
        """

    /// `tell application` launches a closed app, so nothing here may run unless it's already open.
    static func fetch() async -> FetchResult {
        guard isRunning else { return .track(nil) }
        guard let result = try? await Shell.run("osascript", ["-e", script], timeout: 5) else { return .failed }
        guard result.ok else { return result.stderr.contains("-1743") ? .denied : .failed }
        let output = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .track(nil) }
        let parts = output.components(separatedBy: separator)
        guard parts.count == 8 else { return .failed }
        return .track(SpotifyTrack(id: parts[1], title: parts[2], artist: parts[3], album: parts[4],
                                   duration: (Double(parts[5]) ?? 0) / 1000,
                                   // AppleScript formats reals with the system's decimal separator.
                                   position: Double(parts[6].replacingOccurrences(of: ",", with: ".")) ?? 0,
                                   isPlaying: parts[0] == "playing", artworkURL: URL(string: parts[7])))
    }

    /// Returns `false` when macOS denied the Automation permission.
    static func send(_ command: Command) async -> Bool {
        guard isRunning else { return true }
        let result = try? await Shell.run("osascript", ["-e", "tell application id \"\(bundleID)\" to \(command.rawValue)"], timeout: 5)
        return result?.stderr.contains("-1743") != true
    }

    /// The notification's payload, used instantly and as a fallback without Automation access.
    static func track(from userInfo: [AnyHashable: Any]) -> SpotifyTrack? {
        guard let state = userInfo["Player State"] as? String, state != "Stopped",
              let title = userInfo["Name"] as? String else { return nil }
        return SpotifyTrack(id: userInfo["Track ID"] as? String ?? title, title: title,
                            artist: userInfo["Artist"] as? String ?? "", album: userInfo["Album"] as? String ?? "",
                            duration: ((userInfo["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                            position: (userInfo["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
                            isPlaying: state == "Playing", artworkURL: nil)
    }

    /// Cover art only ever comes from Spotify's image CDN.
    static func artwork(_ url: URL) async -> NSImage? {
        guard url.scheme == "https", let host = url.host,
              host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com"),
              let (data, _) = try? await Net.session.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
