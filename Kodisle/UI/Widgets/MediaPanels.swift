import SwiftUI

// MARK: - WhatsApp

/// Cycles through the unread chats with a vertical slide.
struct WhatsAppTile: View {
    @Environment(KodisleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    private var chats: [WhatsAppChat] { store.whatsapp.alerting }
    private var current: WhatsAppChat? { chats.isEmpty ? nil : chats[index % chats.count] }

    var body: some View {
        HStack(spacing: 10) {
            WhatsAppIcon(count: chats.count).frame(width: 34, height: 34)
            ZStack(alignment: .leading) {
                if let current {
                    TileText(title: current.name, subtitle: current.preview.ifEmpty("New message"), sensitive: true)
                        .id(current.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                } else {
                    TileText(title: "WhatsApp", subtitle: placeholder)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
        }
        .task(id: chats.map(\.id)) {
            index = 0
            guard chats.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { index += 1 }
            }
        }
    }

    private var placeholder: String {
        switch store.whatsapp.state {
        case .loading: "Loading…"
        case .notInstalled: "Not installed"
        case .noAccess: "Needs Full Disk Access"
        case .ready: "No unread chats"
        }
    }
}

private struct WhatsAppIcon: View {
    var count: Int

    var body: some View {
        Group {
            if let url = WhatsAppProvider.appURL {
                Image(nsImage: IconCache.icon(forFile: url.path, size: 34)).resizable()
            } else {
                TileIcon(symbol: "message.fill", tint: .green)
            }
        }
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(.red))
                    .offset(x: 4, y: -3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: count)
    }
}

struct WhatsAppPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        let snapshot = store.whatsapp
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(symbol: "message.fill", title: "WhatsApp", tint: .green, subtitle: subtitle(snapshot)) {
                if snapshot.state != .notInstalled {
                    IconButton(symbol: "arrow.up.forward.app", help: "Open WhatsApp") { WhatsAppProvider.open(nil) }
                }
            }
            switch snapshot.state {
            case .loading: EmptyHint(symbol: "hourglass", text: "Loading…")
            case .notInstalled: EmptyHint(symbol: "message", text: "WhatsApp isn't installed", detail: "Install WhatsApp for Mac to see unread chats here")
            case .noAccess:
                EmptyHint(symbol: "lock", text: "Needs Full Disk Access",
                          detail: "macOS only lets Kodisle read WhatsApp's local data with this permission. It never asks by itself: turn Kodisle on in the list (off and on again if it's already there), then reopen Kodisle.")
                Button("Open Full Disk Access") { Open.url("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") }
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: .infinity)
            case .ready:
                if snapshot.chats.isEmpty {
                    EmptyHint(symbol: "checkmark.bubble", text: "No unread chats")
                }
                RowGrid { ForEach(snapshot.chats) { WhatsAppRow(chat: $0) } }
            }
        }
    }

    private func subtitle(_ snapshot: WhatsAppSnapshot) -> String? {
        guard snapshot.state == .ready else { return nil }
        let count = snapshot.chats.count
        return count == 0 ? "Read from WhatsApp for Mac" : "\(count) unread chat\(count == 1 ? "" : "s")"
    }
}

private struct WhatsAppRow: View {
    let chat: WhatsAppChat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: chat.isGroup ? "person.2.fill" : "person.fill")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34).background(Circle().fill(.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(chat.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).privacySensitive()
                    if chat.isMuted { Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 6)
                    Text(Fmt.ago(chat.date)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(chat.preview.ifEmpty("New message")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).privacySensitive()
                    Spacer(minLength: 0)
                    Text(chat.unread > 0 ? "\(chat.unread)" : " ")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(chat.isMuted ? Color.secondary : .green))
                }
            }
        }
        .rowStyle()
        .onTapGesture { WhatsAppProvider.open(chat) }
    }
}

// MARK: - Spotify

private let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

private struct SpotifyCover: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(spotifyGreen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SpotifyTile: View {
    @Environment(KodisleStore.self) private var store
    @State private var hoveringCover = false

    var body: some View {
        let track = store.spotify
        HStack(spacing: 10) {
            Button { store.spotifyCommand(.playPause) } label: {
                SpotifyCover(image: store.spotifyArtwork, size: 34, radius: 7)
                    .overlay {
                        if track != nil && (hoveringCover || track?.isPlaying == false) {
                            Image(systemName: track?.isPlaying == true ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.42)))
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(track == nil)
            .onHover { hoveringCover = $0 }
            .animation(.easeOut(duration: 0.15), value: hoveringCover)
            TileText(title: track?.title ?? "Spotify",
                     subtitle: track?.artist ?? (SpotifyProvider.appURL == nil ? "Not installed" : "Nothing playing"),
                     sensitive: track != nil)
                .id(track?.id)
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.25), value: track?.id)
    }
}

struct SpotifyPanel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(symbol: "music.note", title: "Spotify", tint: spotifyGreen,
                        subtitle: store.spotify.map { $0.isPlaying ? "Playing" : "Paused" }) {
                if let url = SpotifyProvider.appURL {
                    IconButton(symbol: "arrow.up.forward.app", help: "Open Spotify") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
            if let track = store.spotify {
                HStack(spacing: 14) {
                    SpotifyCover(image: store.spotifyArtwork, size: 92, radius: 12)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                        Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        Text(track.album).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .privacySensitive()
                    Spacer(minLength: 0)
                }
                SpotifyProgress(track: track)
                HStack(spacing: 26) {
                    transport("backward.fill", size: 18, command: .previous)
                    transport(track.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 38, command: .playPause)
                    transport("forward.fill", size: 18, command: .next)
                }
                .frame(maxWidth: .infinity)
                .disabled(store.spotifyDenied)
            } else {
                EmptyHint(symbol: "music.note", text: "Nothing playing", detail: SpotifyProvider.appURL == nil ? "Install Spotify to see what's playing" : nil)
            }
            if store.spotifyDenied {
                Text("Allow Kodisle to control Spotify in System Settings › Privacy & Security › Automation for artwork and playback controls.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func transport(_ symbol: String, size: CGFloat, command: SpotifyProvider.Command) -> some View {
        Button { store.spotifyCommand(command) } label: {
            Image(systemName: symbol).font(.system(size: size)).contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 30, minHeight: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Ticks once a second, and only while the panel is on screen and music is playing.
private struct SpotifyProgress: View {
    let track: SpotifyTrack

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = track.position(at: context.date)
            VStack(spacing: 4) {
                UsageBar(percent: track.duration > 0 ? position / track.duration * 100 : 0, tint: spotifyGreen, height: 4)
                HStack {
                    Text(Fmt.clock(Int(position)))
                    Spacer()
                    Text(Fmt.clock(Int(track.duration)))
                }
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
