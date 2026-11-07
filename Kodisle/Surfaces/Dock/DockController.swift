import AppKit
import Observation
import SwiftUI

struct DockApp: Identifiable, Equatable {
    var id: String { path }
    let path: String
    var name: String
    var isRunning: Bool
    var isPinned: Bool
    var isActive: Bool
}

@MainActor @Observable
final class DockModel {
    var apps: [DockApp] = []
    var openPanel: WidgetID?
    /// The panel an opened app last closed: failures reported there need it back.
    var closedForApp: WidgetID?
    var panelAnchorX: CGFloat = 0
    var dockFrame: CGRect = .zero
    var panelFrame: CGRect = .zero
    var revealed = true
    var page = 0
    /// Left button held inside the dock, for the icons' press feedback.
    var mouseDown = false
    /// Apps opening right now (their icon bounces until they're up).
    var launching: Set<String> = []
    /// Extra space above the bar that magnified icons and tooltips occupy (still interactive).
    var headroom: CGFloat = 0
    /// Item being dragged inside the dock (for live reordering).
    var draggingApp: String? { didSet { if draggingApp != nil { watchDragEnd() } } }
    var draggingWidget: WidgetID? { didSet { if draggingWidget != nil { watchDragEnd() } } }

    /// Drops outside the dock never call the drop delegate: clear the drag once the button is up.
    private func watchDragEnd() {
        Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(120)) }
            try? await Task.sleep(for: .milliseconds(150))
            self?.mouseDown = false                            // the drag loop eats the mouse up
            self?.draggingApp = nil
            self?.draggingWidget = nil
        }
    }

    static let finderPath = "/System/Library/CoreServices/Finder.app"

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored var focusPanel: (() -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    var pinnedPaths: [String] {
        get {
            if let saved = AppSettings.shared.config.dockPinnedApps { return saved }
            let imported = SystemDock.pinnedApps().filter { $0 != Self.finderPath }
            AppSettings.shared.config.dockPinnedApps = imported
            return imported
        }
        set { AppSettings.shared.config.dockPinnedApps = newValue }
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningPaths = Dictionary(running.compactMap { app in app.bundleURL.map { ($0.path, app) } }, uniquingKeysWith: { a, _ in a })
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleURL?.path

        func make(_ path: String, pinned: Bool) -> DockApp {
            DockApp(path: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                    isRunning: runningPaths[path] != nil || path == Self.finderPath, isPinned: pinned, isActive: path == frontmost)
        }
        var result = [make(Self.finderPath, pinned: true)]
        let pinned = pinnedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        result += pinned.map { make($0, pinned: true) }
        let extra = running.compactMap(\.bundleURL?.path)
            .filter { $0 != Self.finderPath && !pinned.contains($0) && $0 != Bundle.main.bundlePath }
        result += extra.map { make($0, pinned: false) }
        if result != apps { apps = result }
        let up = launching.filter { runningPaths[$0] != nil }
        if !up.isEmpty { launching.subtract(up) }
    }

    func runningApp(_ app: DockApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.path }
    }

    func launch(_ app: DockApp) {
        Open.willOpen?()
        if app.path == Self.finderPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
            return
        }
        if let running = runningApp(app) {
            if running.isActive { running.hide(); return }
            running.unhide()
        } else {
            bounce(app)
        }
        // Like the system Dock, go through Launch Services even when the app is already running:
        // it activates the app and sends a "reopen" event, so apps with no open windows create one
        // (e.g. Brave running in the background only to host an installed web app).
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
    }

    private func bounce(_ app: DockApp) {
        launching.insert(app.path)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))           // apps that never finish launching
            self?.launching.remove(app.path)
        }
    }

    func togglePin(_ app: DockApp) {
        var paths = pinnedPaths
        if let index = paths.firstIndex(of: app.path) { paths.remove(at: index) } else { paths.append(app.path) }
        pinnedPaths = paths
        refresh()
    }

    /// Moves (or pins) `path` so it sits where `target` is. Finder always stays first.
    func move(_ path: String, to target: DockApp) {
        guard path != target.path, path != Self.finderPath else { return }
        var paths = pinnedPaths
        paths.removeAll { $0 == path }
        if target.path == Self.finderPath {
            paths.insert(path, at: 0)
        } else if let index = paths.firstIndex(of: target.path) {
            let from = pinnedPaths.firstIndex(of: path) ?? Int.max
            paths.insert(path, at: from < pinnedPaths.firstIndex(of: target.path) ?? 0 ? index + 1 : index)
        } else {
            paths.append(path)
        }
        pinnedPaths = paths
        refresh()
    }

    func moveWidget(_ id: WidgetID, to target: WidgetID) {
        var list = AppSettings.shared.config.dockWidgets
        guard id != target, let from = list.firstIndex(of: id), let to = list.firstIndex(of: target) else { return }
        list.remove(at: from)
        list.insert(id, at: to)
        AppSettings.shared.config.dockWidgets = list
    }

    func open(_ urls: [URL], with app: DockApp) {
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Owns the dock panel at the bottom of the main screen.
@MainActor
final class DockController {
    let model = DockModel()
    private let panel = OverlayPanel(level: .statusBar, joinsFullScreen: false)
    private var tracker: MouseTracker?
    private var observers: [NSObjectProtocol] = []
    private var hideTask: Task<Void, Never>?
    private var pressMonitor: Any?
    private static let panelHeight: CGFloat = 640
    /// Set by the `-KodisleDebugDock` launch argument: keeps the dock visible for screenshots.
    static var forceReveal = false

    init() {
        SystemDock.hide()
        let root = DockView(model: model).kodisleEnvironment()
        model.focusPanel = { [weak self] in self?.panel.makeKey() }
        Open.willOpen = { [weak self] in self?.closePanelForApp() }
        let host = OverlayPanel.hosting(root, size: CGSize(width: screen.frame.width, height: Self.panelHeight), anchor: .bottomFullWidth)
        panel.contentView = host
        layout(height: 200)
        panel.orderFrontRegardless()
        watchSize()
        model.revealed = !AppSettings.shared.config.dockAutoHide || Self.forceReveal

        tracker = MouseTracker(onMove: { [weak self] point in
            MainActor.assumeIsolated { self?.mouseMoved(point) }
        }, onClick: { [weak self] point in
            MainActor.assumeIsolated { self?.outsideClick(point) }
        })
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.model.mouseDown = event.type == .leftMouseDown
            return event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
    }

    func tearDown() {
        sizeWatch?.cancel()
        tracker = nil
        if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        panel.orderOut(nil)
        SystemDock.restore()
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    /// The window is only as tall as it needs to be: bar + magnification/tooltip headroom,
    /// or the full popover height while a widget panel is open.
    private var compactHeight: CGFloat {
        let bar = model.dockFrame.height > 0 ? model.dockFrame.height : 90
        return min(Self.panelHeight, bar + model.headroom + 24)
    }

    private func layout(height: CGFloat? = nil) {
        let frame = screen.frame
        let target = height ?? (model.openPanel == nil ? compactHeight : Self.panelHeight)
        guard abs(panel.frame.height - target) > 0.5 || panel.frame.width != frame.width || panel.frame.minY != frame.minY else { return }
        panel.setFrameSafely(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: target))
    }

    private var sizeWatch: Task<Void, Never>?

    private func watchSize() {
        sizeWatch = Task { [weak self] in
            var wasOpen = false
            while !Task.isCancelled {
                guard let self else { return }
                let open = self.model.openPanel != nil
                if open {
                    self.layout(height: Self.panelHeight)
                } else if wasOpen {
                    try? await Task.sleep(for: .milliseconds(420))   // let the close animation finish
                    if self.model.openPanel == nil { self.layout() }
                } else {
                    self.layout()
                }
                wasOpen = open
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.model.openPanel
                        _ = self.model.headroom
                        _ = self.model.dockFrame.height
                    } onChange: { continuation.resume() }
                }
            }
        }
    }

    /// Converts a frame reported by `DockView` (bottom-left origin, see `DockView.bottomUp`) to
    /// screen coordinates. The hosted content is anchored to the window's bottom edge.
    private func toScreen(_ rect: CGRect) -> NSRect {
        NSRect(x: panel.frame.minX + rect.minX, y: panel.frame.minY + rect.minY, width: rect.width, height: rect.height)
    }

    private func mouseMoved(_ point: NSPoint) {
        var bar = toScreen(model.dockFrame)
        bar.size.height += model.headroom
        var rects = [bar]
        if model.openPanel != nil { rects.append(toScreen(model.panelFrame)) }
        let inside = rects.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        panel.ignoresMouseEvents = !inside || !model.revealed

        guard AppSettings.shared.config.dockAutoHide, !Self.forceReveal else {
            if !model.revealed { withAnimation(.snappy) { model.revealed = true } }
            return
        }
        let atEdge = point.y <= screen.frame.minY + 3 && screen.frame.contains(NSPoint(x: point.x, y: screen.frame.minY + 1))
        if atEdge {
            // Resting on the edge keeps the dock up; otherwise it would hide and immediately
            // re-reveal in a loop whenever the cursor sits outside the bar's rect.
            hideTask?.cancel(); hideTask = nil
            if !model.revealed {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.revealed = true }
            }
        } else if model.revealed && !inside && model.openPanel == nil {
            let near = rects.contains { $0.insetBy(dx: -30, dy: -30).contains(point) }
            if !near, hideTask == nil {
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self.model.revealed = false }
                    self.hideTask = nil
                }
            }
        } else if inside {
            hideTask?.cancel(); hideTask = nil
        }
    }

    private func outsideClick(_ point: NSPoint) {
        guard model.openPanel != nil else { return }
        let inside = [toScreen(model.dockFrame), toScreen(model.panelFrame)].contains { $0.contains(point) }
        if !inside {
            withAnimation(.snappy) { model.openPanel = nil }
            panel.resignKey()
        }
    }

    private func closePanelForApp() {
        guard model.openPanel != nil else { return }
        model.closedForApp = model.openPanel
        withAnimation(.snappy) { model.openPanel = nil }
        panel.releaseKeyboard()
    }

    func focusPanel() { panel.makeKey() }
}
