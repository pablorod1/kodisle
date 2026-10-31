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
    /// Hosts SwiftUI at a **fixed size**, anchored to the top-centre or the bottom of the window.
    /// The window only crops it, so resizing the window never moves or re-lays out the content
    /// (otherwise the island would slide in from the side while the window grows).
    static func hosting<Content: View>(_ root: Content, size: CGSize, anchor: AnchoredContainer.Anchor) -> AnchoredContainer {
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        return AnchoredContainer(content: hosting, size: size, anchor: anchor)
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

/// Window content view that keeps its single subview at a fixed size and anchor.
final class AnchoredContainer: NSView {
    enum Anchor { case topCenter, bottomFullWidth }
    let content: NSView
    var contentSize: CGSize { didSet { needsLayout = true } }
    let anchor: Anchor

    init(content: NSView, size: CGSize, anchor: Anchor) {
        self.content = content
        self.contentSize = size
        self.anchor = anchor
        super.init(frame: NSRect(origin: .zero, size: size))
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        addSubview(content)
        place()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { place() }

    private func place() {
        let target: NSRect = switch anchor {
        case .topCenter:
            NSRect(x: ((bounds.width - contentSize.width) / 2).rounded(), y: bounds.height - contentSize.height,
                   width: contentSize.width, height: contentSize.height)
        case .bottomFullWidth:
            NSRect(x: 0, y: 0, width: bounds.width, height: contentSize.height)
        }
        if content.frame != target { content.frame = target }
    }

    /// Top edge of the hosted content in screen coordinates (SwiftUI's global origin).
    var contentTopInScreen: CGFloat {
        guard let window else { return 0 }
        return window.frame.minY + content.frame.maxY
    }
}
