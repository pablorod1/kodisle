import AppKit
import ApplicationServices

/// Lists and focuses an app's windows via the Accessibility API (needed for titles,
/// minimized windows and raising a specific window). Requires the Accessibility permission,
/// which Kodisle only asks for the first time you open a window list.
enum AppWindows {
    struct Window {
        let title: String
        let minimized: Bool
        let element: AXUIElement
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func windows(of app: NSRunningApplication) -> [Window] {
        guard isTrusted else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.compactMap { window in
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            guard (subrole as? String) == (kAXStandardWindowSubrole as String) else { return nil }
            var title: CFTypeRef?, minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            let name = (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Window"
            return Window(title: name, minimized: (minimized as? Bool) ?? false, element: window)
        }
    }

    static func focus(_ window: Window, of app: NSRunningApplication) {
        if window.minimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        app.activate()
    }
}
