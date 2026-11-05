import SwiftUI
import UniformTypeIdentifiers

/// Geometry of the macOS Dock (Tahoe), derived from the icon tile size.
struct DockMetrics {
    let tile: CGFloat
    var tileWidth: CGFloat = DockMetrics.minTileWidth
    var spacing: CGFloat { (tile * 0.08).rounded() }           // ~4 pt at 52
    var padV: CGFloat { (tile * 0.17).rounded() }              // ~9 pt at 52 (room for the running dot)
    var padH: CGFloat { (tile * 0.16).rounded() }
    var height: CGFloat { tile + padV * 2 }
    var radius: CGFloat { (height * 0.34).rounded() }          // continuous corners, ~24 pt at 52
    var innerRadius: CGFloat { max(8, radius - padV) }         // concentric radius for tiles
    var arrowWidth: CGFloat { (tile * 0.42).rounded() }

    /// Narrowest tile that still reads: icon plus about 15 characters. Tile content has a fixed
    /// size, so these widths don't scale with the icons.
    static let minTileWidth: CGFloat = 150

    /// Fewer tiles per page get more room each.
    static func preferredTileWidth(perPage: Int) -> CGFloat {
        max(minTileWidth, 288 - 28 * CGFloat(perPage))
    }
}

struct DockView: View {
    /// Spans the whole fixed-size hosted content. `.global` is relative to the *window*, which is
    /// shorter than the content (it only crops it), so frames reported to the controller use this.
    static let space = "kodisle.dock"

    /// Reports `rect` (in `space`) with a bottom-left origin: `minY` is the distance from the
    /// bottom of the space. The dock is anchored to the bottom of the window, so this stays right
    /// even if the space's height or top edge is off (seen right after login, when SwiftUI laid the
    /// reader out ~430pt shorter than the content and the hover rect sat far above the real dock).
    static func bottomUp(_ rect: CGRect, spaceHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: spaceHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    @Bindable var model: DockModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    @State private var availableWidth: CGFloat = 1400

    private var widgets: [WidgetID] { settings.config.dockWidgets }

    /// Peak scale of the magnification wave (1 = off).
    private func maxScale(tile: CGFloat) -> CGFloat {
        switch settings.config.dockMagnification {
        case "on": return 1.6
        case "off": return 1
        default:
            let system = SystemDock.magnification
            guard system.enabled else { return 1 }
            return min(max((system.largeSize ?? tile * 1.6) / tile, 1), 2.4)
        }
    }

    /// macOS Dock size unless the user picked a custom one.
    private var preferredTile: CGFloat {
        if settings.config.dockMatchSystemSize, let size = SystemDock.tileSize { return size }
        return settings.config.dockIconSize
    }

    /// Fits the dock to the screen: shrinks icons, then tile width, then tiles per page.
    private var layout: (metrics: DockMetrics, perPage: Int) {
        let slots = CGFloat(model.apps.count + 2)                  // apps + downloads + trash
        func width(_ m: DockMetrics, tiles: Int) -> CGFloat {
            let icons = slots * (m.tile + m.spacing)
            let widgetArea = tiles == 0 ? 0 : CGFloat(tiles) * (m.tileWidth + m.spacing) + m.arrowWidth * 2 + m.spacing * 2
            return icons + widgetArea + m.padH * 2 + 2 * (m.spacing * 2 + 1) + 32
        }
        let minTiles = widgets.isEmpty ? 0 : 1
        var tile = preferredTile
        while tile > 28, width(DockMetrics(tile: tile), tiles: minTiles) > availableWidth { tile -= 2 }
        var perPage = min(max(1, settings.config.dockWidgetsPerPage), max(1, widgets.count))
        while perPage > 1, width(DockMetrics(tile: tile), tiles: perPage) > availableWidth { perPage -= 1 }
        var metrics = DockMetrics(tile: tile, tileWidth: DockMetrics.preferredTileWidth(perPage: perPage))
        while metrics.tileWidth > DockMetrics.minTileWidth, width(metrics, tiles: perPage) > availableWidth { metrics.tileWidth -= 2 }
        return (metrics, perPage)
    }

    var body: some View {
        let (m, perPage) = layout
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                    Color.clear
                    if let open = model.openPanel {
                        popover(open, containerWidth: geo.size.width, spaceHeight: geo.size.height)
                            .padding(.bottom, m.height + 18)
                            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                    }
                    bar(m, perPage: perPage, spaceHeight: geo.size.height)
                        .padding(.bottom, 4)
                        .offset(y: model.revealed ? 0 : m.height + 30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: DockView.space)
            .onAppear { availableWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in availableWidth = width }
        }
        // The window only crops the hosted content; never let a window-derived safe area inset it.
        .ignoresSafeArea()
    }

    // MARK: Bar

    private func bar(_ m: DockMetrics, perPage: Int, spaceHeight: CGFloat) -> some View {
        let peak = maxScale(tile: m.tile)
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)
        return HStack(alignment: .bottom, spacing: m.spacing) {
            AppStrip(apps: model.apps, metrics: m, maxScale: peak, model: model)
            if !widgets.isEmpty {
                separator(m)
                WidgetPager(widgets: widgets, perPage: perPage, metrics: m, model: model) { id, frame in
                    toggle(id, anchor: frame.midX)
                }
            }
            separator(m)
            DockStackIcon(model: model, metrics: m, selected: model.openPanel == .downloads) { frame in
                toggle(.downloads, anchor: frame.midX)
            }
            TrashIcon(model: model, metrics: m)
        }
        .padding(.horizontal, m.padH)
        .padding(.bottom, m.padV)
        // Fixed shelf height: magnified icons grow *above* the shelf, exactly like the macOS Dock.
        .frame(height: m.height, alignment: .bottom)
        .background {
            Color.clear
                .glassEffect(.regular, in: shape)
                .overlay {
                    // Thin specular rim like the system Dock.
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGRect.self, of: { DockView.bottomUp($0.frame(in: .named(DockView.space)), spaceHeight: spaceHeight) },
                          action: { model.dockFrame = $0 })
        .onAppear { model.headroom = m.tile * (peak - 1) + 44 }
        .onChange(of: peak) { _, value in model.headroom = m.tile * (value - 1) + 44 }
    }

    private func separator(_ m: DockMetrics) -> some View {
        Capsule().fill(.primary.opacity(0.22)).frame(width: 1, height: m.tile * 0.72)
            .frame(height: m.tile).padding(.horizontal, m.spacing)
    }

    private func toggle(_ id: WidgetID, anchor: CGFloat) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            if model.openPanel == id { model.openPanel = nil } else {
                model.openPanel = id
                model.panelAnchorX = anchor
            }
        }
        if model.openPanel != nil { model.focusPanel?() }
    }

    // MARK: Popover

    private func popover(_ id: WidgetID, containerWidth: CGFloat, spaceHeight: CGFloat) -> some View {
        let width: CGFloat = 400
        let x = min(max(model.panelAnchorX, width / 2 + 12), containerWidth - width / 2 - 12)
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return ScrollView {
            WidgetPanel(id: id).padding(16)
        }
        .scrollIndicators(.never)
        .frame(width: width)
        .frame(maxHeight: 550)
        .fixedSize(horizontal: false, vertical: true)
        // The tint keeps text legible over busy windows without losing the glass.
        .glassEffect(.regular.tint(colorScheme == .dark ? .black.opacity(0.6) : .white.opacity(0.68)), in: shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onGeometryChange(for: CGRect.self, of: { DockView.bottomUp($0.frame(in: .named(DockView.space)), spaceHeight: spaceHeight) },
                          action: { model.panelFrame = $0 })
        .offset(x: x - containerWidth / 2)
    }
}

// MARK: - Widget pager

/// Pages of widget tiles that slide horizontally: trackpad swipe, arrows and page dots.
private struct WidgetPager: View {
    let widgets: [WidgetID]
    let perPage: Int
    let metrics: DockMetrics
    let model: DockModel
    let onTap: (WidgetID, CGRect) -> Void
    @State private var position: Int? = 0

    private var pages: [[WidgetID]] {
        stride(from: 0, to: widgets.count, by: perPage).map { Array(widgets[$0..<min($0 + perPage, widgets.count)]) }
    }
    private var current: Int { min(position ?? 0, max(0, pages.count - 1)) }
    private var pageWidth: CGFloat { CGFloat(perPage) * metrics.tileWidth + CGFloat(perPage - 1) * metrics.spacing }

    var body: some View {
        HStack(spacing: metrics.spacing) {
            if pages.count > 1 { arrow("chevron.left", enabled: current > 0) { go(current - 1) } }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        HStack(spacing: metrics.spacing) {
                            ForEach(page) { id in
                                DockWidgetTile(id: id, model: model, metrics: metrics, selected: model.openPanel == id) { frame in onTap(id, frame) }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(width: pageWidth)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.never)
            .frame(width: pageWidth, height: metrics.tile)
            .clipShape(RoundedRectangle(cornerRadius: metrics.innerRadius, style: .continuous))
            .overlay(alignment: .bottom) {
                if pages.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(pages.indices, id: \.self) { i in
                            Circle().fill(.primary.opacity(i == current ? 0.85 : 0.25))
                                .frame(width: 4.5, height: 4.5)
                                .contentShape(Rectangle().inset(by: -4))
                                .onTapGesture { go(i) }
                        }
                    }
                    .offset(y: metrics.padV * 0.5 + 4)
                }
            }
            if pages.count > 1 { arrow("chevron.right", enabled: current < pages.count - 1) { go(current + 1) } }
        }
        .onChange(of: perPage) { _, _ in position = 0 }
        .onChange(of: position) { _, page in model.page = page ?? 0 }
    }

    private func go(_ page: Int) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { position = max(0, min(page, pages.count - 1)) }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: metrics.tile * 0.24, weight: .bold))
                .frame(width: metrics.arrowWidth, height: metrics.tile)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(enabled ? 0.75 : 0.18))
        .disabled(!enabled)
    }
}

// MARK: - Pieces

/// Capsule label shown above a hovered icon, like the macOS Dock.
private struct DockTooltip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// App icons with the macOS magnification wave: icons near the cursor grow (and take more
/// room, so the dock widens) with a cosine falloff. Scales are computed from the *resting*
/// icon positions, so the layout never feeds back into itself.
private struct AppStrip: View {
    let apps: [DockApp]
    let metrics: DockMetrics
    let maxScale: CGFloat
    let model: DockModel
    @State private var mouseX: CGFloat?
    @State private var restingMinX: CGFloat = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: metrics.spacing) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                DockIcon(app: app, metrics: metrics, scale: scale(at: index), lifts: maxScale <= 1, model: model)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: apps.map(\.id))
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { minX in
            if mouseX == nil { restingMinX = minX }
        }
        .onContinuousHover(coordinateSpace: .global) { phase in
            guard maxScale > 1 else { return }
            switch phase {
            case .active(let point):
                if mouseX == nil {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) { mouseX = point.x }
                } else {
                    mouseX = point.x
                }
            case .ended:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { mouseX = nil }
            }
        }
    }

    private func scale(at index: Int) -> CGFloat {
        guard maxScale > 1, let x = mouseX else { return 1 }
        let center = restingMinX + CGFloat(index) * (metrics.tile + metrics.spacing) + metrics.tile / 2
        let range = metrics.tile * 2.8
        let distance = abs(x - center)
        guard distance < range else { return 1 }
        return 1 + (maxScale - 1) * (cos(.pi * distance / range) + 1) / 2
    }
}

/// Press and hover feedback shared by the dock's icons: the icon darkens and sinks while pressed
/// like the system Dock's, and springs back. `hoverLift` gives a resting dock some life when
/// magnification is off. `pressed` comes from `DockModel.mouseDown`: a SwiftUI press gesture here
/// would swallow the clicks and drags of `onTapGesture` and `onDrag`.
private struct DockPress: ViewModifier {
    var pressed: Bool
    var hovering = false
    var hoverLift: CGFloat = 1
    var pressScale: CGFloat = 0.92
    var pressDim: Double = -0.3

    func body(content: Content) -> some View {
        content
            .brightness(pressed ? pressDim : 0)
            .scaleEffect(pressed ? pressScale : hovering ? hoverLift : 1, anchor: .bottom)
            .animation(pressed ? .easeOut(duration: 0.08) : .spring(response: 0.28, dampingFraction: 0.5), value: pressed)
            .animation(.spring(response: 0.26, dampingFraction: 0.58), value: hovering)
    }
}

private struct DockIcon: View {
    private static let hoverLift: CGFloat = 1.14

    let app: DockApp
    let metrics: DockMetrics
    let scale: CGFloat
    let lifts: Bool
    let model: DockModel
    @State private var hovering = false
    @State private var dropTarget = false
    @State private var bouncing = false

    private var launching: Bool { model.launching.contains(app.path) }

    var body: some View {
        Image(nsImage: IconCache.icon(forFile: app.path, size: scale > 1 || hovering ? metrics.tile * 2 : metrics.tile))
            .resizable().interpolation(.high)
            .frame(width: metrics.tile * scale, height: metrics.tile * scale)
            .brightness(dropTarget ? 0.15 : 0)
            .modifier(DockPress(pressed: hovering && model.mouseDown, hovering: hovering, hoverLift: lifts ? Self.hoverLift : 1))
            // Rises fast and slows at the top, then falls back: the system Dock's launch bounce.
            .offset(y: bouncing ? -metrics.tile * 0.5 : 0)
            .animation(bouncing ? .easeOut(duration: 0.34).repeatForever(autoreverses: true) : .spring(response: 0.3, dampingFraction: 0.6),
                       value: bouncing)
            .onChange(of: launching, initial: true) { _, value in bouncing = value }
            .overlay(alignment: .bottom) {
                Circle().fill(.primary.opacity(app.isRunning ? 0.7 : 0)).frame(width: 4, height: 4)
                    .scaleEffect(app.isRunning ? 1 : 0.2)
                    .offset(y: metrics.padV * 0.5 + 2)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: app.isRunning)
            }
            .overlay(alignment: .top) {
                if hovering {
                    DockTooltip(text: app.name)
                        .offset(y: -40)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .opacity(model.draggingApp == app.path ? 0.35 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { model.launch(app) }
            .onDrag {
                model.draggingApp = app.path
                return NSItemProvider(object: "kodisle-app:\(app.path)" as NSString)
            }
            .onDrop(of: [.fileURL, .text], delegate: AppDropDelegate(app: app, model: model, targeted: $dropTarget))
            .contextMenu {
                if let running = model.runningApp(app) { WindowMenuItems(app: running) }
                if app.path != DockModel.finderPath {
                    Button(app.isPinned ? "Remove from Dock" : "Keep in Dock") { model.togglePin(app) }
                }
                Button("Show in Finder") { Open.reveal(app.path) }
                if let running = model.runningApp(app), app.path != DockModel.finderPath {
                    Divider()
                    Button("Hide") { running.hide() }
                    Button("Quit") { running.terminate() }
                }
            }
    }
}

private struct DockWidgetTile: View {
    let id: WidgetID
    let model: DockModel
    let metrics: DockMetrics
    let selected: Bool
    let onTap: (CGRect) -> Void
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.innerRadius, style: .continuous)
        WidgetTile(id: id)
            .padding(.horizontal, 11)
            .frame(width: metrics.tileWidth, height: metrics.tile)
            .background(shape.fill(.primary.opacity(selected ? 0.16 : hovering ? 0.11 : 0.065)))
            .overlay(shape.strokeBorder(.white.opacity(selected ? 0.22 : 0.08), lineWidth: 0.5))
            .contentShape(shape)
            .modifier(DockPress(pressed: hovering && model.mouseDown, pressScale: 0.97, pressDim: -0.06))
            .opacity(model.draggingWidget == id ? 0.4 : 1)
            .onHover { hovering = $0 }
            .onTapGesture { onTap(frame) }
            .onDrag {
                model.draggingWidget = id
                return NSItemProvider(object: "kodisle-widget:\(id.rawValue)" as NSString)
            }
            .onDrop(of: [.text], delegate: WidgetDropDelegate(target: id, model: model))
            .contextMenu {
                Button("Remove from Dock") { AppSettings.shared.config.dockWidgets.removeAll { $0 == id } }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frame = $0 })
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct DockStackIcon: View {
    let model: DockModel
    let metrics: DockMetrics
    let selected: Bool
    let onTap: (CGRect) -> Void
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Image(nsImage: IconCache.icon(forFile: DownloadsProvider.folder.path, size: metrics.tile))
            .resizable().frame(width: metrics.tile, height: metrics.tile)
            .modifier(DockPress(pressed: hovering && model.mouseDown, hovering: hovering || selected, hoverLift: 1.14))
            .overlay(alignment: .top) {
                if hovering && !selected { DockTooltip(text: "Downloads").offset(y: -40).transition(.opacity.combined(with: .offset(y: 4))) }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { onTap(frame) }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frame = $0 })
    }
}

private struct TrashIcon: View {
    let model: DockModel
    let metrics: DockMetrics
    @State private var targeted = false
    @State private var hovering = false
    private var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
    }

    var body: some View {
        Image(nsImage: IconCache.named(NSImage.trashEmptyName, size: metrics.tile))
            .resizable().frame(width: metrics.tile, height: metrics.tile)
            .modifier(DockPress(pressed: hovering && model.mouseDown, hovering: hovering || targeted, hoverLift: 1.14))
            .overlay(alignment: .top) {
                if hovering { DockTooltip(text: "Trash").offset(y: -40).transition(.opacity.combined(with: .offset(y: 4))) }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { NSWorkspace.shared.open(trashURL) }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                loadURLs(providers) { urls in
                    for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                }
                return true
            }
    }
}

@MainActor
private func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
}

// MARK: - Reordering & window list

/// Handles both reordering (internal drag) and "open with" (files dropped from Finder).
private struct AppDropDelegate: DropDelegate {
    let app: DockApp
    let model: DockModel
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .text]) }

    func dropEntered(info: DropInfo) {
        if let dragging = model.draggingApp {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.move(dragging, to: app) }
        } else {
            targeted = true
        }
    }

    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.draggingApp != nil ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        if model.draggingApp != nil { model.draggingApp = nil; return true }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        loadURLs(providers) { model.open($0, with: app) }
        return true
    }
}

private struct WidgetDropDelegate: DropDelegate {
    let target: WidgetID
    let model: DockModel

    func validateDrop(info: DropInfo) -> Bool { model.draggingWidget != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging = model.draggingWidget else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.moveWidget(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.draggingWidget = nil
        return true
    }
}

/// Window list shown at the top of an app's context menu (built when the menu opens).
private struct WindowMenuItems: View {
    let app: NSRunningApplication

    var body: some View {
        if AppWindows.isTrusted {
            let windows = AppWindows.windows(of: app)
            if !windows.isEmpty {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    Button { AppWindows.focus(window, of: app) } label: {
                        Label(window.title, systemImage: window.minimized ? "minus.rectangle" : "macwindow")
                    }
                }
                Divider()
            }
        } else {
            Button("Show windows…") { AppWindows.requestAccess() }
                .help("Kodisle needs the Accessibility permission to list and focus windows")
            Divider()
        }
    }
}
