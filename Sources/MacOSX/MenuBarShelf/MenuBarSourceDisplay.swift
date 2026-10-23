import AppKit
import Darwin

/// The inactive bar can contain stale replicas. This optional, read-only bridge
/// identifies the active menu-bar display; an unavailable symbol falls back to
/// the caller's current screen instead of failing module startup.
@MainActor enum MenuBarSourceDisplay {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Active = @convention(c) (UInt32) -> Unmanaged<CFString>?
    private static let functions: (Connection, Active)? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let active = dlsym(handle, "CGSCopyActiveMenuBarDisplayIdentifier") else { return nil }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(active, to: Active.self))
    }()
    static func current(fallback: CGDirectDisplayID) -> CGDirectDisplayID {
        guard let functions, let identifier = functions.1(functions.0())?.takeRetainedValue(),
              let activeUUID = CFUUIDCreateFromString(nil, identifier) else { return fallback }
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            if CFEqual(activeUUID, uuid) { return id }
        }
        return fallback
    }
}
