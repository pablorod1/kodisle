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

    /// Mouse monitors set this on every mouse move; only talk to the window server on changes.
    override var ignoresMouseEvents: Bool {
        get { super.ignoresMouseEvents }
        set { if newValue != super.ignoresMouseEvents { super.ignoresMouseEvents = newValue } }
    }

    /// Hosting view that never resizes the window itself: the controllers size these panels.
    /// (With the default sizing options SwiftUI resizes the window mid-layout and AppKit aborts.)
    /// The hosting view lives inside a plain container so it is never the window's content view
    /// (SwiftUI only drives the window frame from a content-view hosting view).
    static func hosting<Content: View>(_ root: Content) -> NSView {
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }

    /// Frame changes are deferred to the next run-loop turn so they never happen mid-layout.
    func setFrameSafely(_ rect: NSRect) {
        guard frame != rect else { return }
        // Growing happens right away (from event handlers) so animations are never clipped;
        // shrinking waits a run-loop turn.
        if rect.width >= frame.width && rect.height >= frame.height && !inLiveResize {
            setFrame(rect, display: true)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frame != rect else { return }
            self.setFrame(rect, display: true)
        }
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
