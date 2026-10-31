import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel used by the island and the dock.
/// It can become key (for text fields) without stealing focus from the frontmost app.
final class OverlayPanel: NSPanel {
    init(level: NSWindow.Level, joinsFullScreen: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        self.level = level
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if joinsFullScreen { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Global + local mouse monitors (no Accessibility permission required).
final class MouseTracker {
    private var monitors: [Any] = []

    init(onMove: @escaping (NSPoint) -> Void, onClick: ((NSPoint) -> Void)? = nil) {
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveEvents, handler: { _ in onMove(NSEvent.mouseLocation) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moveEvents, handler: { event in onMove(NSEvent.mouseLocation); return event }) {
            monitors.append(local)
        }
        if let onClick, let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in onClick(NSEvent.mouseLocation) }) {
            monitors.append(click)
        }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }
}

extension View {
    /// Injects the shared environment every surface needs.
    @MainActor
    func kodisleEnvironment() -> some View {
        KodisleRoot { self }
            .environment(KodisleStore.shared)
            .environment(AppSettings.shared)
    }
}

/// Re-reads settings so `.redacted` follows the privacy toggle live.
struct KodisleRoot<Content: View>: View {
    @Environment(AppSettings.self) private var settings
    @ViewBuilder var content: Content
    var body: some View {
        content.redacted(reason: settings.config.privacyMode ? .privacy : [])
    }
}
