import AppKit
import ApplicationServices

/// Opens chats and sends replies by driving WhatsApp's own window through the Accessibility API:
/// WhatsApp has no API for this, and its links only reach chats with a known phone number.
///
/// A message that lands in the wrong chat can't be taken back, so every step checks the window
/// before touching it: keys are only posted while WhatsApp is frontmost, and Send is only pressed
/// when the open chat is the right one and the composer holds exactly the reply.
enum WhatsAppAutomation {
    enum Failure: LocalizedError {
        case needsPermission, noWindow, chatNotFound, severalChats, lostFocus, hasDraft, notSent

        var errorDescription: String? {
            switch self {
            case .needsPermission: "Kodisle needs the Accessibility permission for this."
            case .noWindow: "WhatsApp's window isn't available."
            case .chatNotFound: "Couldn't find this chat in WhatsApp."
            case .severalChats: "Several chats have this name. Pick the right one in WhatsApp."
            case .lostFocus: "WhatsApp lost focus, so nothing was sent."
            case .hasDraft: "This chat has an unsent draft in WhatsApp, so nothing was sent."
            case .notSent: "WhatsApp didn't confirm the message. Check the chat."
            }
        }
    }

    private enum ID {
        static let header = "NavigationBar_HeaderViewButton"
        static let search = "TokenizedSearchBar_TextView"
        static let clearSearch = "TokenizedSearchBar_DeleteButton"
        static let searchResult = "ChatListSearchView_ChatResult"
        static let composer = "ChatBar_ComposerTextView"
        static let send = "ChatBar_SendButton"
    }

    private enum Key {
        static let a: CGKeyCode = 0, f: CGKeyCode = 3, v: CGKeyCode = 9
    }

    static func open(_ chat: WhatsAppChat) async throws {
        let window = try await show(chat)
        window.press(ID.clearSearch)
    }

    /// Goes back to the previous app only on success: after a failure WhatsApp is where it gets fixed.
    static func send(_ text: String, to chat: WhatsAppChat) async throws {
        let previous = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        let window = try await show(chat)
        guard window.value(of: ID.composer).isEmpty else { throw Failure.hasDraft }
        guard window.isFocused(ID.composer) else { throw Failure.lostFocus }

        try requireFrontmost()
        try await paste(text)
        let expected = normalized(text)
        guard await poll(seconds: 1.5, { normalized(window.value(of: ID.composer)) == expected }) else { throw Failure.notSent }

        guard window.isShowing(chat), window.press(ID.send) else { throw Failure.notSent }
        guard await poll(seconds: 3, { window.value(of: ID.composer).isEmpty }) else { throw Failure.notSent }

        // Only now: clearing the search takes the focus away from the composer.
        window.press(ID.clearSearch)
        if let previous, previous.bundleIdentifier != WhatsAppProvider.bundleID { previous.activate() }
    }

    // MARK: - Reaching a chat

    /// Leaves the chat open and verified, with the composer focused.
    private static func show(_ chat: WhatsAppChat) async throws -> Window {
        guard AXIsProcessTrusted() else { throw Failure.needsPermission }
        if let link = WhatsAppProvider.link(to: chat) {
            await MainActor.run { _ = NSWorkspace.shared.open(link) }
            let window = try await frontWindow()
            // A chat with the same name that was already open must not pass for the new one.
            try await Task.sleep(for: .seconds(1))
            guard await poll(seconds: 3, { window.isShowing(chat) }) else { throw Failure.chatNotFound }
            return window
        }
        await MainActor.run { WhatsAppProvider.openApp() }
        let window = try await frontWindow()
        try await search(chat, in: window)
        guard await poll(seconds: 2, { window.isShowing(chat) }) else { throw Failure.chatNotFound }
        return window
    }

    private static func search(_ chat: WhatsAppChat, in window: Window) async throws {
        try requireFrontmost()
        postKey(Key.f, flags: .maskCommand)
        // Otherwise the name would be pasted into whichever chat is open.
        guard await poll(seconds: 1, { window.isFocused(ID.search) }) else { throw Failure.lostFocus }
        try requireFrontmost()
        postKey(Key.a, flags: .maskCommand)
        try await paste(chat.name)

        var matches: [AXUIElement] = []
        _ = await poll(seconds: 2) {
            matches = window.elements(ID.searchResult).filter { normalized(Window.description($0)) == normalized(chat.name) }
            return !matches.isEmpty
        }
        guard !matches.isEmpty else {
            window.press(ID.clearSearch)
            throw Failure.chatNotFound
        }
        guard matches.count == 1 else { throw Failure.severalChats } // Results stay up to pick from.
        guard AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success else { throw Failure.chatNotFound }
    }

    private static func frontWindow() async throws -> Window {
        guard let window = await Window.waitForFront() else { throw Failure.noWindow }
        return window
    }

    // MARK: - Keyboard and clipboard

    private static func requireFrontmost() throws {
        guard isFrontmost else { throw Failure.lostFocus }
    }

    private static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == WhatsAppProvider.bundleID
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// WhatsApp ignores the text of synthetic key events, so it's pasted. The clipboard goes back
    /// to what it held, and the transient marker keeps the text out of clipboard histories.
    private static func paste(_ text: String) async throws {
        let saved = await MainActor.run {
            let pasteboard = NSPasteboard.general
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            return UncheckedBox(items)
        }
        postKey(Key.v, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(300))
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !saved.value.isEmpty { pasteboard.writeObjects(saved.value) }
        }
    }

    private static func poll(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date.now < deadline
        return condition()
    }

    /// Without the invisible marks WhatsApp adds around names, and in one Unicode form.
    fileprivate static func normalized(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .format })
    }

    /// `NSPasteboardItem` isn't `Sendable`; the items only ever move between main-actor blocks.
    private struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct Window: @unchecked Sendable {
        let element: AXUIElement

        /// WhatsApp may still be launching, so this waits for it to come up and take the front.
        static func waitForFront() async -> Window? {
            let deadline = Date.now.addingTimeInterval(8)
            while Date.now < deadline {
                if WhatsAppAutomation.isFrontmost, let window = current() { return window }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        private static func current() -> Window? {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: WhatsAppProvider.bundleID).first else { return nil }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 1)
            // Mac Catalyst apps build their accessibility tree on demand.
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
            guard let window = (windows as? [AXUIElement])?.first else { return nil }
            return Window(element: window)
        }

        static func description(_ element: AXUIElement) -> String { attribute(element, kAXDescriptionAttribute) as? String ?? "" }

        private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }

        func isShowing(_ chat: WhatsAppChat) -> Bool {
            guard let header = elements(ID.header).first else { return false }
            return WhatsAppAutomation.normalized(Self.description(header)) == WhatsAppAutomation.normalized(chat.name)
        }

        func value(of id: String) -> String {
            elements(id).first.flatMap { Self.attribute($0, kAXValueAttribute) as? String } ?? ""
        }

        func isFocused(_ id: String) -> Bool {
            elements(id).first.flatMap { Self.attribute($0, kAXFocusedAttribute) as? Bool } ?? false
        }

        @discardableResult
        func press(_ id: String) -> Bool {
            guard let element = elements(id).first else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }

        func elements(_ id: String) -> [AXUIElement] {
            var found: [AXUIElement] = []
            collect(id, from: element, depth: 0, into: &found)
            return found
        }

        private func collect(_ id: String, from parent: AXUIElement, depth: Int, into found: inout [AXUIElement]) {
            guard depth < 14, let children = Self.attribute(parent, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children {
                if Self.attribute(child, kAXIdentifierAttribute) as? String == id { found.append(child) }
                collect(id, from: child, depth: depth + 1, into: &found)
            }
        }
    }
}
