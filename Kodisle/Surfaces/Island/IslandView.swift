import SwiftUI

/// Notch-shaped silhouette: flat top with small outward "shoulders", rounded bottom.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 8

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @Bindable var model: IslandModel
    var onExpand: () -> Void = {}
    @Environment(KodisleStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Namespace private var tabs

    private var bottomRadius: CGFloat {
        switch model.mode {
        case .collapsed: model.notchSize.height * 0.42
        case .banner: 24
        case .approval: 28
        case .expanded: 36
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandSurface(shape: IslandShape(bottomRadius: bottomRadius), open: model.mode != .collapsed,
                              notchHeight: model.notchSize.height)
                content
                    .padding(.horizontal, 8)
                    .clipShape(IslandShape(bottomRadius: bottomRadius))
            }
            .frame(width: model.currentSize.width, height: model.currentSize.height)
            .contentShape(IslandShape(bottomRadius: bottomRadius))
            .onTapGesture { if model.mode == .collapsed || model.mode == .banner { onExpand() } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        // Always black, whatever the system appearance.
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            ears.frame(height: model.notchSize.height)
            switch model.mode {
            case .collapsed: EmptyView()
            case .banner: banner.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            case .approval: approval.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            case .expanded: expanded.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    private var ears: some View {
        HStack(spacing: 0) {
            CompactGlyph(id: settings.config.islandLeft)
                .frame(width: IslandModel.earWidth - 8, alignment: .leading)
                .padding(.leading, 10)
            Spacer(minLength: model.notchSize.width)
            ZStack(alignment: .trailing) {
                CompactGlyph(id: rightEar)
                    .id(rightEar)
                    .transition(.push(from: .bottom))
            }
            .frame(width: IslandModel.earWidth - 8, height: model.notchSize.height, alignment: .trailing)
            .clipped()
            .padding(.trailing, 10)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: rightEar)
        }
        .opacity(model.mode == .expanded ? 0 : 1)
    }

    /// Automatic right ear: whatever is active (rotating when several are), else the user's pick.
    private var rightEar: WidgetID {
        let config = settings.config
        guard config.islandAutoEars else { return config.islandRight }
        let active = store.activeWidgets.filter { $0 != config.islandLeft }
        guard !active.isEmpty else { return config.islandRight }
        return active[model.earTick % active.count]
    }

    @ViewBuilder
    private var banner: some View {
        if let event = store.currentEvent ?? store.recentEvents.first {
            HStack(spacing: 12) {
                Image(systemName: event.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(event.tint)
                    .symbolEffect(.bounce, value: event.id)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.date, style: .time).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    }
                    if !event.subtitle.isEmpty {
                        Text(event.subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1).privacySensitive()
                    }
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true).privacySensitive()
                            .padding(.top, 1)
                    }
                }
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            .onTapGesture {
                if let widget = event.widget { model.selectedTab = widget == .ai ? .ai : widget }
                onExpand()
            }
        }
    }

    @ViewBuilder
    private var approval: some View {
        if let request = store.permissionRequests.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: request.symbol)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.orange)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.orange.opacity(0.16)))
                        .symbolEffect(.bounce, value: request.id)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Claude wants to use \(request.tool)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            if store.permissionRequests.count > 1 {
                                Text(verbatim: "+\(store.permissionRequests.count - 1)").font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.white.opacity(0.15)))
                            }
                        }
                        Text([request.sessionTitle, request.project].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).privacySensitive()
                    }
                    Spacer()
                    Text(request.date, style: .relative).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).monospacedDigit()
                }
                Text(request.target)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    .textSelection(.enabled)
                    .privacySensitive()
                HStack(spacing: 8) {
                    Button { store.decide(request, .deny) } label: { Label("Deny", systemImage: "xmark") }
                        .buttonStyle(IslandButtonStyle(fill: .red.opacity(0.28), text: Color(red: 1, green: 0.62, blue: 0.6)))
                    Button("Terminal") { store.decide(request, .terminal) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .help("Answer in Claude Code instead")
                    Spacer()
                    if request.canAlwaysAllow {
                        Button("Always allow") { store.decide(request, .always) }
                            .buttonStyle(IslandButtonStyle(fill: .white.opacity(0.13), text: .white))
                            .help("Allow and remember this rule, like \"don't ask again\" in Claude Code")
                    }
                    Button { store.decide(request, .allow) } label: { Label("Allow", systemImage: "checkmark") }
                        .buttonStyle(IslandButtonStyle(fill: Color(red: 0.2, green: 0.78, blue: 0.42), text: .white, prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
    }

    private var expanded: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(settings.config.islandTabs) { tab in
                    IslandTabButton(tab: tab, selected: model.selectedTab == tab, badge: badgeCount(for: tab), namespace: tabs) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { model.selectedTab = tab }
                    }
                }
                Spacer()
                IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "Unpin" : "Keep open",
                           tint: model.pinned ? .yellow : .white.opacity(0.7)) { model.pinned.toggle() }
                IconButton(symbol: "gearshape", help: "Settings", tint: .white.opacity(0.7)) { SettingsWindow.shared.show() }
            }
            .padding(.horizontal, 14)

            ScrollView {
                WidgetPanel(id: model.selectedTab)
                    .environment(\.panelWide, true)
                    .id(model.selectedTab)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 2)
    }

    private func badgeCount(for tab: WidgetID) -> Int {
        switch tab {
        case .github: (store.github?.failingRuns.count ?? 0) + (store.github?.reviewRequests.count ?? 0)
        case .endpoints: store.endpointStatus.values.filter { !$0.ok }.count
        case .agents: store.agents.filter { $0.state == .waiting }.count
        default: 0
        }
    }
}

/// Icon tab; the selected one names itself, so twelve bare icons stay readable.
private struct IslandTabButton: View {
    let tab: WidgetID
    let selected: Bool
    let badge: Int
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? tab.tint : Color.white.opacity(hovering ? 0.95 : 0.6))
                if selected {
                    Text(tab.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, selected ? 10 : 0)
            .frame(minWidth: 32).frame(height: 28)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.15)).matchedGeometryEffect(id: "tab", in: namespace)
                } else if hovering {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red)).offset(x: 3, y: -3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

/// The island's material: solid black where it meets the hardware notch, melting into a
/// black-tinted Liquid Glass body with a soft specular rim and layered shadows when open.
private struct IslandSurface: View {
    let shape: IslandShape
    let open: Bool
    let notchHeight: CGFloat

    var body: some View {
        // Every layer always exists and only its opacity changes, so all of them follow the
        // island's size animation (inserting the glass on open made it pop in at full size).
        ZStack {
            shape.fill(.black)
                .opacity(open ? 0 : 1)
            Color.clear
                .glassEffect(.regular.tint(.black.opacity(0.78)), in: shape)
                .opacity(open ? 1 : 0)
            // Fuse with the notch: opaque black at the top, fading into the glass.
            shape.fill(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: min(0.45, notchHeight / 260)),
                .init(color: .black.opacity(0.55), location: 0.75),
                .init(color: .black.opacity(0.35), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .opacity(open ? 1 : 0)
            // Specular rim, only on the lower edges (the top is the notch).
            shape.stroke(LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0), location: 0.35),
                .init(color: .white.opacity(0.22), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .opacity(open ? 1 : 0)
        }
        // Ambient + contact shadow.
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 30, y: 18)
        .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 5, y: 2)
    }
}

/// Capsule button that keeps its colors even when the (never-active) island window isn't key.
private struct IslandButtonStyle: ButtonStyle {
    var fill: Color
    var text: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(text)
            .padding(.horizontal, 16).frame(height: 34)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(prominent ? 0.45 : 0.22), .white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: prominent ? fill.opacity(0.45) : .clear, radius: 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
