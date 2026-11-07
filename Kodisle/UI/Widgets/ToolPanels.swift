import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Generator

struct GeneratorPanel: View {
    @Bindable private var model = GeneratorModel.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(symbol: "key.horizontal.fill", title: "Generator", tint: .yellow)
            PillTabs(selection: $model.mode, options: GeneratorModel.Mode.allCases.map { ($0, $0.rawValue) })

            ScrollView {
                Text(highlighted)
                    .font(.system(size: model.mode == .lorem ? 12 : 16, weight: .semibold, design: model.mode == .lorem ? .default : .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: model.mode == .lorem ? 120 : 84)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))

            HStack(spacing: 10) {
                if model.mode == .password {
                    VStack(alignment: .leading, spacing: 4) {
                        UsageBar(percent: model.strength.fraction * 100, tint: strengthColor, height: 5).frame(width: 110)
                        Text("\(model.strength.label) · \(Int(model.entropy)) bits").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Regenerate") { model.generate() }
                Button {
                    Clipboard.copy(model.output, sensitive: model.isSensitive)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minWidth: 64)
                }
                .buttonStyle(PillButtonStyle(tint: copied ? .green : .chartBlue))
            }
            options
        }
    }

    @ViewBuilder
    private var options: some View {
        switch model.mode {
        case .password:
            HStack {
                PillTabs(selection: $model.style, options: GeneratorModel.Style.allCases.map { ($0, $0.rawValue) }).frame(width: 200)
                Spacer()
                Text(model.style == .random ? "\(Int(model.length)) characters" : "\(Int(model.words)) words")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if model.style == .random {
                Slider(value: $model.length, in: 8...64, step: 1)
            } else {
                Slider(value: $model.words, in: 3...10, step: 1)
            }
            HStack(spacing: 6) {
                ChipToggle(title: "A–Z", isOn: $model.upper)
                ChipToggle(title: "a–z", isOn: $model.lower)
                ChipToggle(title: "0–9", isOn: $model.digits)
                ChipToggle(title: "#$&", isOn: $model.symbols)
            }
            Text("Copied passwords are hidden from clipboard managers and auto-cleared.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .uuid:
            Toggle("Uppercase", isOn: $model.uuidUppercase).toggleStyle(.switch).controlSize(.small)
        case .number:
            HStack {
                TextField("Min", value: $model.numberMin, format: .number).frame(width: 90)
                Text("to").foregroundStyle(.secondary)
                TextField("Max", value: $model.numberMax, format: .number).frame(width: 90)
            }
            .textFieldStyle(.roundedBorder)
        case .lorem:
            Stepper("\(Int(model.loremParagraphs)) paragraph\(model.loremParagraphs == 1 ? "" : "s")",
                    value: $model.loremParagraphs, in: 1...5)
        }
    }

    private var strengthColor: Color {
        switch model.strength.fraction {
        case ..<0.3: .red
        case ..<0.6: .orange
        case ..<0.8: .yellow
        default: .green
        }
    }

    private var highlighted: AttributedString {
        var result = AttributedString()
        for char in model.output {
            var piece = AttributedString(String(char))
            if model.mode == .password, char.isNumber || (!char.isLetter && !char.isWhitespace) {
                piece.foregroundColor = .blue
            }
            result += piece
        }
        return result
    }
}

// MARK: - Timer

struct TimerPanel: View {
    @Bindable private var timer = FocusTimer.shared
    private var tint: Color { timer.phase == .focus ? .orange : .teal }

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(symbol: "timer", title: "Focus timer", tint: .orange,
                        subtitle: timer.completedSessions == 0 ? "No sessions yet today" : "\(timer.completedSessions) session\(timer.completedSessions == 1 ? "" : "s") done")
            ZStack {
                UsageRing(percent: timer.progress * 100, tint: tint, size: 150, lineWidth: 10, showsLabel: false)
                VStack(spacing: 2) {
                    Text(Fmt.clock(timer.remaining)).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(timer.phase.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                IconButton(symbol: "arrow.counterclockwise", help: "Reset") { timer.reset() }
                Button { timer.toggle() } label: {
                    Label(timer.isRunning ? "Pause" : "Start", systemImage: timer.isRunning ? "pause.fill" : "play.fill").frame(minWidth: 76)
                }
                .buttonStyle(PillButtonStyle(tint: tint))
                IconButton(symbol: "forward.end.fill", help: "Skip to \(timer.phase == .focus ? "break" : "focus")") { timer.switchPhase() }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Calculator

struct CalculatorPanel: View {
    @Bindable private var calc = CalculatorModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "plus.forwardslash.minus", title: "Calculator", tint: .primary)
            VStack(alignment: .trailing, spacing: 4) {
                TextField("12 * (4 + 3) / 2", text: $calc.expression)
                    .textFieldStyle(.plain).font(.system(size: 18, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit { calc.commit() }
                Text(calc.result.map { "= \($0)" } ?? (calc.expression.isEmpty ? " " : "…"))
                    .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(calc.result == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
            HStack(spacing: 8) {
                Button("Copy result") { if let r = calc.result { Clipboard.copy(r) } }
                    .buttonStyle(PillButtonStyle()).disabled(calc.result == nil)
                Button("Clear") { calc.clear() }.buttonStyle(PillButtonStyle(prominent: false))
                Spacer()
                Text("↩ to keep result").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if !calc.history.isEmpty { SectionLabel(text: "History").padding(.top, 4) }
            ForEach(Array(calc.history.enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(entry.expr).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(entry.result).fontWeight(.semibold).lineLimit(1)
                }
                .font(.system(size: 12, design: .monospaced))
                .rowStyle()
                .onTapGesture { calc.expression = entry.result }
                .help("Use this result")
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Downloads

struct DownloadsPanel: View {
    @Environment(KodisleStore.self) private var store
    @State private var query = ""

    private var filtered: [DownloadItem] {
        query.isEmpty ? store.downloads : store.downloads.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var groups: [(String, [DownloadItem])] {
        let calendar = Calendar.current
        var today: [DownloadItem] = [], yesterday: [DownloadItem] = [], week: [DownloadItem] = [], older: [DownloadItem] = []
        for item in filtered.prefix(80) {
            if calendar.isDateInToday(item.added) { today.append(item) }
            else if calendar.isDateInYesterday(item.added) { yesterday.append(item) }
            else if item.added > Date().addingTimeInterval(-7 * 86_400) { week.append(item) }
            else { older.append(item) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("This week", week), ("Earlier", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "arrow.down.circle.fill", title: "Downloads", tint: .blue,
                        subtitle: "\(store.downloads.count) items · \(Fmt.bytes(store.system.diskFree)) available") {
                Menu {
                    Button("Open Downloads folder") { Open.url(DownloadsProvider.folder) }
                    Button("Refresh") { store.refreshDownloads() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 26).background(Circle().fill(.primary.opacity(0.07)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            SearchField(text: $query)
            if filtered.isEmpty { EmptyHint(symbol: "tray", text: query.isEmpty ? "Downloads is empty" : "No matches") }
            ForEach(groups, id: \.0) { title, items in
                SectionLabel(text: title).padding(.top, 4)
                RowGrid { ForEach(items) { item in DownloadRow(item: item) } }
            }
        }
        .onAppear { store.ensureDownloads() }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: thumbnail ?? IconCache.icon(forFile: item.url.path, size: 34))
                .resizable().aspectRatio(contentMode: .fit).frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).privacySensitive()
                Text([item.kind, item.size.map(Fmt.bytes), Fmt.ago(item.added)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .rowStyle()
        .onTapGesture(count: 1) { Open.url(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { Open.url(item.url) }
            Button("Show in Finder") { Open.reveal(item.url.path) }
            Button("Copy path") { Clipboard.copy(item.url.path) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
        }
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 68, height: 68),
                                                       scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }
}

// MARK: - Clipboard

struct ClipboardPanel: View {
    @Bindable private var history = ClipboardHistory.shared
    @State private var query = ""
    @State private var copiedID: UUID?

    private var filtered: [ClipItem] {
        query.isEmpty ? history.items : history.items.filter { !$0.isSecret && $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(symbol: "doc.on.clipboard.fill", title: "Clipboard", tint: .teal,
                        subtitle: history.paused ? "Paused" : "Kept in memory only") {
                IconButton(symbol: history.paused ? "play.fill" : "pause.fill", help: history.paused ? "Resume" : "Pause recording") { history.paused.toggle() }
                IconButton(symbol: "trash", help: "Clear history") { history.clear() }
            }
            SearchField(text: $query)
            if filtered.isEmpty {
                EmptyHint(symbol: "doc.on.clipboard", text: history.paused ? "Recording paused" : "Nothing copied yet",
                          detail: history.paused ? nil : "Everything you copy appears here")
            }
            ForEach(filtered.prefix(40)) { item in
                Button { history.copy(item); copiedID = item.id } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isSecret ? "key.fill" : "text.alignleft")
                            .foregroundStyle(item.isSecret ? .orange : .secondary).frame(width: 16).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.masked.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 12.5, design: item.isSecret ? .monospaced : .default))
                                .lineLimit(2).multilineTextAlignment(.leading).privacySensitive()
                            Text([item.app, Fmt.ago(item.date), item.isSecret ? "secret · auto-removes" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if copiedID == item.id { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                    .rowStyle()
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Remove", role: .destructive) { history.remove(item) } }
            }
        }
    }
}
