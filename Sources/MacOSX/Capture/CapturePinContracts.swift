import AppKit

@MainActor protocol CapturePinnedItem: AnyObject {
    var window: NSPanel { get }
    var isActive: Bool { get }
    var recovery: CapturePinRecovery { get }
    var onClose: (() -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func present(focus: Bool)
    func setOutline(_ visible: Bool)
    func applyEditIfKey() -> Bool
    func shelve(_ save: @escaping (CGImage, @escaping (Bool) -> Void) -> Void)
    func dispose()
}
enum CapturePinRecovery {
    case image(PinSnapshot)
    case text(CaptureTextDocument, CGRect, NSPoint)
}

struct PinSnapshot {
    let image: CGImage
    let baseSize: CGSize
    let frame: CGRect
    let transform: CapturePinTransform
    let zoom: CGFloat
    let thumbnail: Bool
    let opacity: CGFloat
}

