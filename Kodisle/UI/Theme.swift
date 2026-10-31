import SwiftUI

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
                Capsule().fill(tint ?? usageColor(percent))
                    .frame(width: max(height, geo.size.width * min(max(percent, 0), 100) / 100))
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

struct PanelHeader<Trailing: View>: View {
    var symbol: String
    var title: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(symbol: String, title: String, tint: Color = .accentColor) {
        self.init(symbol: symbol, title: title, tint: tint) { EmptyView() }
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

struct EmptyHint: View {
    var symbol: String
    var text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

struct RowBackground: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(hover ? 0.08 : 0.04)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension View {
    func rowStyle() -> some View { modifier(RowBackground()) }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
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
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
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
    var body: some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
    }
}
