import AppKit
import ApplicationServices

/// Same-process AX calls synchronously enter AppKit: use native main-actor
/// access instead. No AppKit window references escape into the AX worker.
@MainActor enum LocalSwitcherWindows {
    struct Snapshot: Sendable {
        let windows: [SwitcherWindow]
        let focusedID: CGWindowID?
    }

    private static var windows: [NSWindow] {
        NSApp.windows.filter {
            !($0 is NSPanel) && $0.styleMask.contains(.titled)
                && $0.windowNumber > 0 && ($0.isVisible || $0.isMiniaturized || NSApp.isHidden)
        }
    }

    static func snapshot() -> Snapshot {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Required by the shared model; the local route never sends AX messages
        // to this placeholder. Window identity comes from NSWindow.windowNumber.
        let placeholder = AXUIElementCreateApplication(pid)
        return Snapshot(windows: windows.prefix(40).map {
            SwitcherWindow(id: CGWindowID($0.windowNumber), pid: pid, title: String($0.title.prefix(200)),
                applicationName: "macos-x", icon: NSApp.applicationIconImage, element: placeholder,
                isMinimized: $0.isMiniaturized, isHidden: NSApp.isHidden, isOnScreen: $0.isVisible && !$0.isMiniaturized)
        }, focusedID: focusedID())
    }

    static func focusedID() -> CGWindowID? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let window = NSApp.keyWindow, windows.contains(where: { $0 === window }),
              window.isVisible, !window.isMiniaturized else { return nil }
        return CGWindowID(window.windowNumber)
    }

    @discardableResult static func focus(_ id: CGWindowID) -> Bool {
        guard let window = windows.first(where: { CGWindowID($0.windowNumber) == id }) else { return false }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
