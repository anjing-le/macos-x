import AppKit
import Carbon
import ApplicationServices
import MacOSXCore

enum ShortcutAction: UInt32, CaseIterable, Sendable {
    case wheel = 1, capture, pin, recording, togglePins
    var title: String {
        switch self {
        case .wheel: return "颜文字"
        case .capture: return "截图"
        case .pin: return "贴图"
        case .recording: return "录屏"
        case .togglePins: return "显示 / 隐藏"
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .wheel: return .init(kind: .doubleModifier, keyCode: 61, modifiers: 0, keyLabel: "")
        case .capture: return .init(keyCode: 122, modifiers: 0, keyLabel: "F1")
        case .pin: return .init(keyCode: 99, modifiers: 0, keyLabel: "F3")
        case .recording: return .init(keyCode: 15, modifiers: 5, keyLabel: "R")
        case .togglePins: return .init(keyCode: 99, modifiers: 4, keyLabel: "F3")
        }
    }
}

private enum InputAction: Sendable {
    case shortcut(ShortcutAction), advance(Bool), release, cancel, move(Int, Int), confirm, available, unavailable
}

/// A dedicated run loop keeps UI rendering out of the event-tap callback.
/// Its only work is scalar state, a small lock and ordered main-queue messages.
private final class SwitcherInputTap: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private var ready = false
    private var suspended = false
    private var doubleBinding: ShortcutBinding?
    private var captureBinding: ShortcutBinding?
    private var capturedKey: UInt16?
    private var session = false
    private var recognizer = ModifierDoubleTap()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var thread: Thread?
    let delivery: @Sendable (InputAction) -> Void

    init(delivery: @escaping @Sendable (InputAction) -> Void) {
        self.delivery = delivery
        let worker = Thread { [self] in run() }
        worker.name = "macos-x.shortcuts"
        thread = worker; worker.start()
    }

    func configure(ready: Bool, doubleBinding: ShortcutBinding?, captureBinding: ShortcutBinding?, suspended: Bool) {
        lock.lock()
        self.ready = ready; self.doubleBinding = doubleBinding; self.captureBinding = captureBinding; self.suspended = suspended
        if !ready || suspended { session = false }
        recognizer.reset()
        lock.unlock()
    }

    func endSession() { lock.lock(); session = false; lock.unlock() }

    func stop() {
        lock.lock()
        alive = false; session = false; recognizer.reset()
        let activePort = port; let activeLoop = loop
        lock.unlock()
        if let activePort { CGEvent.tapEnable(tap: activePort, enable: false); CFMachPortInvalidate(activePort) }
        if let activeLoop {
            CFRunLoopPerformBlock(activeLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(activeLoop) }
            CFRunLoopWakeUp(activeLoop)
        }
    }

    private func run() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, kind, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SwitcherInputTap>.fromOpaque(context).takeUnretainedValue().handle(kind, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lock.lock(); thread = nil; lock.unlock()
            delivery(.unavailable)
            return
        }
        let runLoop = CFRunLoopGetCurrent()!
        lock.lock(); port = tap; loop = runLoop; let shouldRun = alive; lock.unlock()
        if shouldRun {
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            delivery(.available)
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        lock.lock(); port = nil; loop = nil; thread = nil; lock.unlock()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        lock.lock()
        guard alive else { lock.unlock(); return pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            session = false; recognizer.reset(); let tap = port
            lock.unlock()
            delivery(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard !suspended else { lock.unlock(); return pass }
        let code = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged {
            if session && !event.flags.contains(.maskCommand) {
                session = false; lock.unlock(); delivery(.release); return pass
            }
            if let binding = doubleBinding, binding.keyCode == code, !session {
                let onlyModifier = binding.keyCode == 58 || binding.keyCode == 61 ? CGEventFlags.maskAlternate : .maskControl
                let useful = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                if !useful.subtracting(onlyModifier).isEmpty { recognizer.reset(); lock.unlock(); return pass }
                let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
                let fire = recognizer.update(isDown: down, timestamp: Double(event.timestamp) / 1_000_000_000)
                lock.unlock()
                if fire { delivery(.shortcut(.wheel)) }
                return pass
            }
            recognizer.reset(); lock.unlock(); return pass
        }
        if type == .keyUp {
            if capturedKey == code { capturedKey = nil; lock.unlock(); return nil }
            let swallow = session && [48, 53, 36, 76, 123, 124, 125, 126].contains(code)
            lock.unlock(); return swallow ? nil : pass
        }
        guard type == .keyDown else { lock.unlock(); return pass }
        recognizer.reset()
        // Carbon requires exact modifiers. During Cmd+Tab, F1 must also work
        // while Command is held; swallow this event to avoid double delivery.
        let flags = event.flags
        let modifiers: UInt8 = (flags.contains(.maskControl) ? 1 : 0)
            | (flags.contains(.maskAlternate) ? 2 : 0)
            | (flags.contains(.maskShift) ? 4 : 0)
            | (flags.contains(.maskCommand) ? 8 : 0)
        if session, let captureBinding, captureBinding.matches(keyCode: code, modifiers: modifiers, ignoringHeldCommand: true) {
            let repeated = capturedKey == code
            capturedKey = code; session = false
            lock.unlock()
            if !repeated { delivery(.shortcut(.capture)) }
            return nil
        }
        if capturedKey == code { lock.unlock(); return nil }
        if ready && code == 48 && event.flags.contains(.maskCommand)
            && !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate) {
            session = true
            let reverse = event.flags.contains(.maskShift)
            lock.unlock(); delivery(.advance(reverse)); return nil
        }
        guard session else { lock.unlock(); return pass }
        let action: InputAction?
        switch code {
        case 53: session = false; action = .cancel
        case 36, 76: session = false; action = .confirm
        case 123: action = .move(-1, 0)
        case 124: action = .move(1, 0)
        case 126: action = .move(0, -1)
        case 125: action = .move(0, 1)
        default: action = nil
        }
        lock.unlock()
        if let action { delivery(action); return nil }
        return pass
    }
}

@MainActor
final class GlobalInput {
    var onShortcut: ((ShortcutAction) -> Void)?
    var onAdvance: ((Bool) -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onTapUnavailable: (() -> Void)?
    var onTapAvailable: (() -> Void)?
    private(set) var hasActiveTap = false
    private var registered: [ShortcutAction: (ShortcutBinding, EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?
    private var tap: SwitcherInputTap?
    private var desired: [ShortcutAction: ShortcutBinding] = [:]
    private var switcherReady = false
    private var suspended = false
    private var heldSession = false
    private var generation: UInt64 = 0
    private let signature: OSType = 0x4D4F5358 // MOSX

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let input = Unmanaged<GlobalInput>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { input.handleCarbon(event) }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    func configure(bindings: [ShortcutAction: ShortcutBinding], switcherReady: Bool) -> [ShortcutAction: String] {
        if self.switcherReady != switcherReady || desired[.wheel] != bindings[.wheel] {
            invalidateTap()
        }
        desired = bindings; self.switcherReady = switcherReady
        return apply()
    }

    func setRecordingShortcut(_ recording: Bool) {
        guard suspended != recording else { return }
        invalidateTap()
        suspended = recording
        _ = apply()
    }

    private func apply() -> [ShortcutAction: String] {
        var issues: [ShortcutAction: String] = [:]
        let chords = suspended ? [:] : desired.filter { $0.value.kind == .chord }
        for (action, value) in registered where chords[action] != value.0 {
            UnregisterEventHotKey(value.1); registered.removeValue(forKey: action)
        }
        for (action, binding) in chords where registered[action] == nil {
            guard eventHandler != nil else {
                issues[action] = "快捷键监听不可用，请重新打开应用"; continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers,
                EventHotKeyID(signature: signature, id: action.rawValue), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered[action] = (binding, ref) }
            else { issues[action] = "快捷键已被占用，请换一个" }
        }
        let wheel = desired[.wheel].flatMap { $0.kind == .doubleModifier ? $0 : nil }
        let needsTap = !suspended && (switcherReady || wheel != nil) && AXIsProcessTrusted()
        if needsTap && tap == nil {
            generation &+= 1
            let expected = generation
            tap = SwitcherInputTap { [weak self] action in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == expected else { return }
                    self.consume(action)
                }
            }
        } else if !needsTap, let tap {
            generation &+= 1; hasActiveTap = false; tap.stop(); self.tap = nil
        }
        tap?.configure(ready: switcherReady, doubleBinding: wheel, captureBinding: chords[.capture], suspended: suspended)
        return issues
    }

    func endSwitcherSession() { heldSession = false; tap?.endSession() }

    func probe(_ binding: ShortcutBinding, for action: ShortcutAction) -> String? {
        guard binding.kind == .chord else { return nil }
        guard eventHandler != nil else { return "快捷键监听不可用，请重新打开应用" }
        if registered[action]?.0 == binding { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers,
            EventHotKeyID(signature: signature, id: 99), GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr ? nil : "快捷键已被占用，请换一个"
    }

    private func consume(_ action: InputAction) {
        guard !suspended else { return }
        switch action {
        case let .shortcut(action): if desired[action] != nil { onShortcut?(action) }
        case let .advance(reverse): if switcherReady { heldSession = true; onAdvance?(reverse) }
        case .release: if heldSession { heldSession = false; onRelease?() }
        case .cancel: heldSession = false; onCancel?()
        case let .move(horizontal, vertical): if heldSession { onMove?(horizontal, vertical) }
        case .confirm: if heldSession { heldSession = false; onConfirm?() }
        case .available: hasActiveTap = true; onTapAvailable?()
        case .unavailable:
            invalidateTap()
            onTapUnavailable?()
        }
    }

    private func handleCarbon(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
            id.signature == signature, let action = ShortcutAction(rawValue: id.id),
            !suspended, registered[action] != nil else { return OSStatus(eventNotHandledErr) }
        onShortcut?(action)
        return noErr
    }

    func stop() {
        invalidateTap()
        for value in registered.values { UnregisterEventHotKey(value.1) }
        registered.removeAll(); desired.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    private func invalidateTap() {
        generation &+= 1
        hasActiveTap = false
        tap?.stop(); tap = nil
        heldSession = false; onCancel?()
    }
}

extension ShortcutBinding {
    var carbonModifiers: UInt32 {
        (modifiers & 1 != 0 ? UInt32(controlKey) : 0) | (modifiers & 2 != 0 ? UInt32(optionKey) : 0)
            | (modifiers & 4 != 0 ? UInt32(shiftKey) : 0) | (modifiers & 8 != 0 ? UInt32(cmdKey) : 0)
    }
    var cgModifiers: UInt64 {
        (modifiers & 1 != 0 ? CGEventFlags.maskControl.rawValue : 0)
            | (modifiers & 2 != 0 ? CGEventFlags.maskAlternate.rawValue : 0)
            | (modifiers & 4 != 0 ? CGEventFlags.maskShift.rawValue : 0)
            | (modifiers & 8 != 0 ? CGEventFlags.maskCommand.rawValue : 0)
    }
}
