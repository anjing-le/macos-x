import ApplicationServices
import Darwin

/// The sole non-public API in this module. It maps an existing accessibility
/// window to a WindowServer ID; it does not focus, change Spaces, or inject code.
/// The symbol is optional. Missing/failed mapping omits that window rather than
/// guessing from a title (different windows can have the same title).
enum PrivateWindowBridge {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let function: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static var isAvailable: Bool { function != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id = CGWindowID(0)
        guard function(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
