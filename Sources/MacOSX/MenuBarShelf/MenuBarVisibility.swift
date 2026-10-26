import AppKit
import MenuBarVisibilityBridge

@MainActor protocol MenuVisibilityHandle: AnyObject { func invalidate() }
@MainActor protocol MenuVisibilityProviding {
    var available: Bool { get }
    func activate(allowing: [String], completion: @escaping (MenuVisibilityHandle?) -> Void)
}
@MainActor final class NativeMenuVisibility: MenuVisibilityProviding {
    var available: Bool { MXMenuVisibilityAvailable() }
    func activate(allowing: [String], completion: @escaping (MenuVisibilityHandle?) -> Void) {
        MXMenuVisibilityActivate((0..<64).map { NSNumber(value: $0) }, allowing) { raw, _ in
            MainActor.assumeIsolated { completion(raw.map { Handle($0) }) }
        }
    }
    private final class Handle: MenuVisibilityHandle {
        private var raw: AnyObject?
        init(_ raw: Any) { self.raw = raw as AnyObject }
        func invalidate() { guard let raw else { return }; self.raw = nil; MXMenuVisibilityInvalidate(raw) }
        deinit { if let raw { MXMenuVisibilityInvalidate(raw) } }
    }
}
