import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class IslandModel {
    enum Mode: Equatable { case collapsed, banner, approval, expanded }
    var mode: Mode = .collapsed
    var selectedTab: WidgetID = .ai
    var notchSize = CGSize(width: 200, height: 32)
    var hasNotch = false
    var pinned = false
    /// The current banner shows a multi-line detail (e.g. an agent's summary).
    var bannerHasDetail = false

    static let earWidth: CGFloat = 78
    static let expandedSize = CGSize(width: 680, height: 440)

    var collapsedSize: CGSize {
        CGSize(width: notchSize.width + Self.earWidth * 2, height: notchSize.height)
    }
    var bannerSize: CGSize {
        bannerHasDetail
            ? CGSize(width: max(collapsedSize.width, 560), height: notchSize.height + 112)
            : CGSize(width: max(collapsedSize.width, 440), height: notchSize.height + 62)
    }
    var approvalSize: CGSize { CGSize(width: max(collapsedSize.width, 600), height: notchSize.height + 150) }
    /// Room around the island so shadows are never clipped by the window.
    static let shadowMargin = CGSize(width: 70, height: 60)

    var currentSize: CGSize {
        switch mode {
        case .collapsed: collapsedSize
        case .approval: approvalSize
        case .banner: bannerSize
        case .expanded: CGSize(width: Self.expandedSize.width, height: Self.expandedSize.height)
        }
    }
}

/// Owns the island panel pinned to the top-center of the notched (or main) screen.
@MainActor
final class IslandController {
    let model = IslandModel()
    private let panel = OverlayPanel(level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3), joinsFullScreen: true)
    private var tracker: MouseTracker?
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var eventWatch: Task<Void, Never>?

    init() {
        let root = IslandView(model: model, onExpand: { [weak self] in self?.expand() })
            .environment(\.colorScheme, .dark)
            .kodisleEnvironment()
        panel.contentView = OverlayPanel.hosting(root)
        if let first = AppSettings.shared.config.islandTabs.first { model.selectedTab = first }
        layout()
        panel.orderFrontRegardless()

        tracker = MouseTracker(onMove: { [weak self] point in
            MainActor.assumeIsolated { self?.mouseMoved(point) }
        }, onClick: { [weak self] point in
            MainActor.assumeIsolated { self?.outsideClick(point) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        watchEvents()
    }

    func tearDown() {
        eventWatch?.cancel()
        tracker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        panel.orderOut(nil)
    }

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first ?? NSScreen.main!
    }

    private func layout() {
        let screen = screen
        let inset = screen.safeAreaInsets.top
        model.hasNotch = inset > 0
        if model.hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: inset)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            model.notchSize = CGSize(width: 150, height: max(menuBar, 28))
        }
        fitWindow(large: model.mode != .collapsed)
    }

    /// Collapsed, the window is just the notch-sized island; it grows before any expansion
    /// (so animations have room) and shrinks back once the collapse animation is done.
    private func fitWindow(large: Bool) {
        let frame = screen.frame
        let size: CGSize = large
            ? CGSize(width: IslandModel.expandedSize.width + IslandModel.shadowMargin.width * 2,
                     height: IslandModel.expandedSize.height + IslandModel.shadowMargin.height)
            : CGSize(width: model.collapsedSize.width + 16, height: model.collapsedSize.height + 4)
        let target = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrameSafely(target)
    }

    private func shrinkWhenCollapsed() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.model.mode == .collapsed else { return }
            self.fitWindow(large: false)
        }
    }

    /// Screen-space rectangle of the visible island for the current mode.
    private func hotRect(for mode: IslandModel.Mode) -> NSRect {
        let s = screen.frame
        let size: CGSize = switch mode {
        case .collapsed: model.collapsedSize
        case .banner: model.bannerSize
        case .approval: model.approvalSize
        case .expanded: IslandModel.expandedSize
        }
        return NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height, width: size.width, height: size.height)
    }

    private func mouseMoved(_ point: NSPoint) {
        let inside = hotRect(for: model.mode).insetBy(dx: -4, dy: -4).contains(point)
        panel.ignoresMouseEvents = !inside

        switch model.mode {
        case .approval:
            break // stays until the user decides
        case .collapsed, .banner:
            if inside && AppSettings.shared.config.islandExpandOnHover {
                guard hoverTask == nil else { return }
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    self?.expand()
                }
            } else if !inside {
                hoverTask?.cancel(); hoverTask = nil
            }
        case .expanded:
            if inside {
                collapseTask?.cancel(); collapseTask = nil
            } else if !model.pinned, collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self?.collapse()
                }
            }
        }
    }

    private func outsideClick(_ point: NSPoint) {
        guard model.mode == .expanded, !hotRect(for: .expanded).contains(point) else { return }
        model.pinned = false
        collapse()
    }

    func expand(tab: WidgetID? = nil) {
        hoverTask = nil
        if let tab { model.selectedTab = tab }
        fitWindow(large: true)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.mode = .expanded }
        panel.ignoresMouseEvents = false
        panel.makeKey()
    }

    func toggle() {
        model.mode == .expanded ? collapse() : expand()
    }

    func collapse() {
        collapseTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.mode = restingMode }
        if model.mode == .collapsed { shrinkWhenCollapsed() }
        panel.resignKey()
        panel.ignoresMouseEvents = !hotRect(for: model.mode).contains(NSEvent.mouseLocation)
    }

    /// What the island shows when not expanded: pending approvals win over banners.
    private var restingMode: IslandModel.Mode {
        let store = KodisleStore.shared
        if !store.permissionRequests.isEmpty { return .approval }
        return store.currentEvent == nil ? .collapsed : .banner
    }

    /// Shows live activities (banners and approval requests) as the store changes.
    private func watchEvents() {
        eventWatch = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    let event = KodisleStore.shared.currentEvent
                    if event != nil { self.model.bannerHasDetail = event?.detail?.isEmpty == false }
                    let target = self.restingMode
                    if self.model.mode != .expanded, self.model.mode != target {
                        if target != .collapsed { self.fitWindow(large: true) }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { self.model.mode = target }
                        if target == .collapsed { self.shrinkWhenCollapsed() }
                        if target == .approval { self.panel.ignoresMouseEvents = false }
                    }
                }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = KodisleStore.shared.currentEvent
                        _ = KodisleStore.shared.permissionRequests
                    } onChange: { continuation.resume() }
                }
            }
        }
    }
}
