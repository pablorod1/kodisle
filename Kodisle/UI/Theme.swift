import SwiftUI

extension Color {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) })
    }

    // Categorical chart hues, checked for contrast and color-blind separation on both appearances.
    static let chartBlue = adaptive(light: 0x2A78D6, dark: 0x3987E5)
    static let chartOrange = adaptive(light: 0xCF5A23, dark: 0xD95926)
    static let chartGreen = adaptive(light: 0x158A62, dark: 0x199E70)
}

func usageColor(_ percent: Double) -> Color {
    percent >= 90 ? .red : percent >= 70 ? .orange : .green
}

struct UsageRing: View {
    var percent: Double
    var tint: Color? = nil
    var size: CGFloat = 32
    var lineWidth: CGFloat = 4
    var showsLabel = true

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                .stroke(tint ?? usageColor(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLabel {
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: percent)
    }
}

struct UsageBar: View {
    var percent: Double
    var tint: Color? = nil
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                // Nothing at 0%: a capsule's minimum width would read as "a little used".
                if percent > 0 {
                    Capsule().fill(tint ?? usageColor(percent))
                        .frame(width: max(height, geo.size.width * min(percent, 100) / 100))
                }
            }
        }
        .frame(height: height)
        .animation(.smooth, value: percent)
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var animate = false

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay {
                if pulsing {
                    Circle().stroke(color, lineWidth: 2)
                        .scaleEffect(animate ? 2.2 : 1).opacity(animate ? 0 : 0.8)
                        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { animate = true } }
                }
            }
    }
}

extension EnvironmentValues {
    /// The panel has room for two columns (the island, as opposed to dock popovers and the menu bar).
    @Entry var panelWide = false
}

/// Tinted rounded square holding a symbol: the identity mark of panels, rows and tiles.
struct IconChip: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(shape.fill(tint.opacity(0.16)))
            .overlay(shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }
}

struct PanelHeader<Trailing: View>: View {
    var symbol: String
    var title: String
    var tint: Color = .accentColor
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconChip(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(symbol: String, title: String, tint: Color = .accentColor, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, tint: tint, subtitle: subtitle) { EmptyView() }
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

/// Icon in a soft circle, a line of text and optionally how to get out of the empty state.
struct EmptyHint: View {
    var symbol: String
    var text: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).background(Circle().fill(.primary.opacity(0.07)))
            VStack(spacing: 2) {
                Text(text).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
    }
}

struct RowBackground: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(shape.fill(.primary.opacity(hover ? 0.1 : 0.05)))
            .overlay(shape.strokeBorder(.primary.opacity(hover ? 0.1 : 0.04), lineWidth: 0.5))
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension View {
    func rowStyle() -> some View { modifier(RowBackground()) }
}

/// One column, or two where the panel has room.
struct RowGrid<Content: View>: View {
    @Environment(\.panelWide) private var wide
    @ViewBuilder var content: Content

    var body: some View {
        if wide {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)], spacing: 8) { content }
        } else {
            VStack(spacing: 6) { content }
        }
    }
}

/// A row whose actions float in on hover, so a list of ten rows isn't forty idle buttons.
struct HoverActions<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @State private var hovering = false

    var body: some View {
        content
            .rowStyle()
            .overlay(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 4) { actions }
                        .padding(3)
                        .background(Capsule().fill(.thickMaterial))
                        .padding(.trailing, 7)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.13), value: hovering)
    }
}

/// Small capsule for a state or an attribute. States carry a symbol, never color alone.
struct Pill: View {
    var text: String
    var tint: Color = .secondary
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).frame(height: 18)
        .background(Capsule().fill(tint.opacity(0.15)))
        .fixedSize()
    }
}

struct Stat: Identifiable {
    var id: String { label }
    var value: String
    var label: String
    /// Marks a state; numbers themselves stay in the text color.
    var tint: Color? = nil
}

/// Row of headline numbers at the top of a panel.
struct StatStrip: View {
    var stats: [Stat]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    HStack(spacing: 4) {
                        if let tint = stat.tint { Circle().fill(tint).frame(width: 6, height: 6) }
                        Text(stat.label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.055)))
            }
        }
    }
}

/// Segmented control drawn by hand: the system one goes gray in the never-key island and dock.
struct PillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = option.value }
                } label: {
                    Text(option.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(.primary.opacity(0.14)).matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(0.06)))
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
    }
}

/// Capsule button with its own colors, which stay put when the panel isn't key.
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .chartBlue
    var prominent = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 13).frame(height: 30)
            .background(Capsule().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.09))))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// On/off chip, for options that sit in a row.
struct ChipToggle: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(isOn ? 0.15 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = .secondary
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(hovering ? (tint == .secondary ? .primary : tint) : tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hovering ? 0.15 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

struct Sparkline: View {
    var values: [Double]
    var tint: Color = .green

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let maxV = values.max(), let minV = values.min() {
                let range = max(maxV - minV, 1)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let point = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                            y: geo.size.height * (1 - CGFloat((v - minV) / range)))
                        i == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Filled line chart of recent samples, with a crosshair and value on hover.
struct HistoryChart: View {
    var values: [Double]
    var tint: Color = .green
    var capacity = SystemHistory.capacity
    /// Top of the scale; `nil` fits the highest sample.
    var maxValue: Double? = nil
    var format: (Double) -> String
    @State private var hoverX: CGFloat?

    private func point(_ index: Int, size: CGSize, top: Double) -> CGPoint {
        // Right-aligned: a short history fills in from the newest sample.
        let step = size.width / CGFloat(max(1, capacity - 1))
        let x = size.width - CGFloat(values.count - 1 - index) * step
        return CGPoint(x: x, y: size.height * (1 - CGFloat(min(values[index], top) / top)))
    }

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), .leastNonzeroMagnitude)
            ZStack(alignment: .topLeading) {
                if values.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: point(0, size: geo.size, top: top).x, y: geo.size.height))
                        for i in values.indices { path.addLine(to: point(i, size: geo.size, top: top)) }
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        for i in values.indices {
                            let p = point(i, size: geo.size, top: top)
                            i == 0 ? path.move(to: p) : path.addLine(to: p)
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
                if let hoverX, let index = nearest(to: hoverX, size: geo.size, top: top) {
                    let p = point(index, size: geo.size, top: top)
                    Rectangle().fill(.primary.opacity(0.3)).frame(width: 1).offset(x: p.x)
                    Circle().fill(tint).frame(width: 8, height: 8).offset(x: p.x - 4, y: p.y - 4)
                    Text(format(values[index]))
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.background.opacity(0.9)))
                        .fixedSize()
                        .frame(width: 70, alignment: p.x > geo.size.width / 2 ? .trailing : .leading)
                        .offset(x: p.x > geo.size.width / 2 ? p.x - 76 : p.x + 6)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase { hoverX = location.x } else { hoverX = nil }
            }
        }
    }

    private func nearest(to x: CGFloat, size: CGSize, top: Double) -> Int? {
        values.indices.min { abs(point($0, size: size, top: top).x - x) < abs(point($1, size: size, top: top).x - x) }
    }
}

/// Inset surface grouping one metric inside a panel.
struct MetricCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.055)))
    }
}

/// Two-line text of a tile.
struct TileText: View {
    var title: String
    var subtitle: String
    var sensitive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                .contentTransition(.numericText())
                .privacySensitive(sensitive)
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                .privacySensitive(sensitive)
        }
    }
}

/// Standard layout of a dock / island tile: leading visual + title + subtitle.
struct TileLayout<Leading: View>: View {
    var title: String
    var subtitle: String
    var sensitive = false
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    .contentTransition(.numericText())
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    .privacySensitive(sensitive)
            }
            Spacer(minLength: 0)
        }
    }
}

struct TileIcon: View {
    var symbol: String
    var tint: Color
    var body: some View { IconChip(symbol: symbol, tint: tint, size: 34) }
}
