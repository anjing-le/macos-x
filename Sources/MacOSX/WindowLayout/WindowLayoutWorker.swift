import Foundation
import ApplicationServices
import MacOSXCore

struct ExternalLayoutWindow:@unchecked Sendable {
    let element:AXUIElement
    let pid:pid_t
    let frame:CGRect // AX/Quartz coordinates
    func matches(_ other:Self)->Bool {
        pid == other.pid && CFEqual(element,other.element)
    }
}
/// One serialized AX job and one replaceable pending job, never a drag-event backlog.
final class WindowLayoutWorker:@unchecked Sendable {
    private let queue=DispatchQueue(label:"cc.anjing.macos-x.window-layout",qos:.userInitiated)
    private let lock=NSLock()
    private var epoch:UInt64=0
    private var pending:(@Sendable ()->Void)?
    private var draining=false
    func invalidate() { lock.lock(); epoch &+= 1; pending=nil; lock.unlock() }
    private func ticket()->UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    private func valid(_ value:UInt64)->Bool { lock.lock(); defer { lock.unlock() }; return epoch == value }
    private func submit(_ job:@escaping @Sendable ()->Void) {
        lock.lock(); pending=job
        if !draining { draining=true; queue.async { self.drain() } }
        lock.unlock()
    }
    private func drain() {
        while true {
            lock.lock(); let job=pending; pending=nil
            if job == nil { draining=false }; lock.unlock()
            guard let job else { return }; job()
        }
    }
    func locate(pid:pid_t,point:CGPoint?,completion:@escaping @Sendable (ExternalLayoutWindow?)->Void) {
        let epoch=ticket()
        submit { [self] in
            guard valid(epoch),pid != getpid() else { return }
            let app=AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.12)
            var window:AXUIElement?
            if let point {
                let system=AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system,0.12)
                var hit:AXUIElement?
                if AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success,let hit {
                    var owner:pid_t=0; AXUIElementGetPid(hit,&owner)
                    guard owner != getpid() else { deliver(nil,epoch:epoch,completion:completion); return }
                    var cursor=hit
                    for _ in 0..<8 {
                        AXUIElementSetMessagingTimeout(cursor,0.12)
                        if attribute(cursor,kAXRoleAttribute) as? String == kAXWindowRole { window=cursor; break }
                        if let parent=element(cursor,kAXWindowAttribute) { window=parent; break }
                        guard let parent=element(cursor,kAXParentAttribute) else { break }; cursor=parent
                    }
                }
            } else { window=element(app,kAXFocusedWindowAttribute) }
            let value=window.flatMap { snapshot($0) }
            deliver(value,epoch:epoch,completion:completion)
        }
    }
    func read(_ window:ExternalLayoutWindow,completion:@escaping @Sendable (ExternalLayoutWindow?)->Void) {
        let epoch=ticket()
        submit { [self] in guard valid(epoch) else { return }; deliver(snapshot(window.element),epoch:epoch,completion:completion) }
    }
    func apply(_ window:ExternalLayoutWindow,frame:CGRect,completion:@escaping @Sendable (CGRect?)->Void) {
        let epoch=ticket()
        submit { [self] in
            guard valid(epoch),snapshot(window.element) != nil else { deliver(nil,epoch:epoch,completion:completion); return }
            var size=frame.size,position=frame.origin
            guard let sizeValue=AXValueCreate(.cgSize,&size),let pointValue=AXValueCreate(.cgPoint,&position) else { deliver(nil,epoch:epoch,completion:completion); return }
            guard valid(epoch),AXUIElementSetAttributeValue(window.element,kAXSizeAttribute as CFString,sizeValue) == .success,
                  valid(epoch),AXUIElementSetAttributeValue(window.element,kAXPositionAttribute as CFString,pointValue) == .success else {
                deliver(nil,epoch:epoch,completion:completion); return
            }
            deliver(snapshot(window.element)?.frame,epoch:epoch,completion:completion)
        }
    }
    private func deliver<T:Sendable>(_ value:T,epoch:UInt64,completion:@escaping @Sendable (T)->Void) {
        DispatchQueue.main.async { [weak self] in guard self?.valid(epoch) == true else { return }; completion(value) }
    }
    private func snapshot(_ window:AXUIElement)->ExternalLayoutWindow? {
        var pid:pid_t=0; AXUIElementGetPid(window,&pid)
        AXUIElementSetMessagingTimeout(window,0.12)
        guard pid != getpid(),attribute(window,kAXRoleAttribute) as? String == kAXWindowRole else { return nil }
        guard attribute(window,kAXMinimizedAttribute) as? Bool != true,attribute(window,"AXFullScreen") as? Bool != true else { return nil }
        var sizeSettable:DarwinBoolean=false,positionSettable:DarwinBoolean=false
        guard AXUIElementIsAttributeSettable(window,kAXSizeAttribute as CFString,&sizeSettable) == .success,sizeSettable.boolValue,
              AXUIElementIsAttributeSettable(window,kAXPositionAttribute as CFString,&positionSettable) == .success,positionSettable.boolValue,
              let point=attribute(window,kAXPositionAttribute),CFGetTypeID(point)==AXValueGetTypeID(),
              let size=attribute(window,kAXSizeAttribute),CFGetTypeID(size)==AXValueGetTypeID() else { return nil }
        var origin=CGPoint.zero,dimensions=CGSize.zero
        guard AXValueGetValue(point as! AXValue,.cgPoint,&origin),AXValueGetValue(size as! AXValue,.cgSize,&dimensions),dimensions.width>0,dimensions.height>0 else { return nil }
        return .init(element:window,pid:pid,frame:CGRect(origin:origin,size:dimensions))
    }
    private func attribute(_ value:AXUIElement,_ name:String)->CFTypeRef? {
        var result:CFTypeRef?; return AXUIElementCopyAttributeValue(value,name as CFString,&result) == .success ? result : nil
    }
    private func element(_ value:AXUIElement,_ name:String)->AXUIElement? {
        guard let result=attribute(value,name),CFGetTypeID(result)==AXUIElementGetTypeID() else { return nil }; return (result as! AXUIElement)
    }
}
