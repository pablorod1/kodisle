import SwiftUI

struct MenuBarLabel: View {
    @Environment(KodisleStore.self) private var store

    var body: some View {
        let attention = store.attentionCount
        let working = !store.runningAgents.isEmpty
        HStack(spacing: 3) {
            Image(systemName: attention > 0 ? "waveform.path.ecg.rectangle.fill" : working ? "sparkles" : "waveform.path.ecg")
            if let p = store.claude?.fiveHour?.usedPercent ?? store.codex?.fiveHour?.usedPercent {
                Text(Fmt.percent(p)).monospacedDigit()
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var selected: WidgetID = .ai

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(settings.config.islandTabs) { tab in
                    Button { selected = tab } label: {
                        Image(systemName: tab.symbol).font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 26)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected == tab ? 0.12 : 0)))
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
                Spacer()
            }
            .padding(10)
            Divider()
            ScrollView {
                WidgetPanel(id: selected).padding(14)
            }
            .frame(height: 400)
            Divider()
            HStack {
                Button { store.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Spacer()
                Button { SettingsWindow.shared.show() } label: { Label("Settings", systemImage: "gearshape") }
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .padding(10)
        }
        .frame(width: 420)
        .onAppear { if let first = settings.config.islandTabs.first { selected = first } }
    }
}
