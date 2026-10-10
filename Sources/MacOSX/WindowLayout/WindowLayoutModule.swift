import AppKit
import ApplicationServices
import MacOSXCore

@MainActor final class WindowLayoutModule {
    var onStatusChange:(()->Void)?
    private let worker=WindowLayoutWorker()
    private var localMonitor:Any?,globalMonitor:Any?,workspaceObserver:NSObjectProtocol?
    private var enabled=false
    private var generation:UInt64=0
    private var target:Target?
    private var anchor=CGPoint.zero,lastPoint=CGPoint.zero
    private var verifying=false,verified=false,attempts=0
    private var preview:LayoutPreviewPanel?
    private var pendingAction:WindowLayoutAction?
    private var history:[Saved]=[]
    private let status=NSTextField(wrappingLabelWithString:"")
    private lazy var settings=makeSettings()
    var settingsView:NSView { settings }
    private enum Target { case local(NSWindow,CGRect),external(ExternalLayoutWindow)
        var frame:CGRect { switch self { case let .local(_,frame):return frame;case let .external(value):return WindowLayoutGeometry.axFrame(value.frame,primaryTop:CGDisplayBounds(CGMainDisplayID()).height) } }
    }
    private final class Saved {
        weak var local:NSWindow?
        let external:ExternalLayoutWindow?
        let frame:CGRect
        init(_ target:Target) { frame=target.frame; switch target { case let .local(window,_):local=window; external=nil; case let .external(window):external=window } }
        func matches(_ target:Target)->Bool { switch target { case let .local(window,_):return local === window;case let .external(window):return external?.matches(window) == true } }
    }
    init() {}
    func start() {
        guard !enabled else { return }; enabled=true
        guard AXIsProcessTrusted() else { updateStatus("需要辅助功能权限"); return }
        let mask:NSEvent.EventTypeMask=[.leftMouseDown,.leftMouseDragged,.leftMouseUp]
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:mask) { [weak self] event in self?.receive(event); return event }
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:mask) { [weak self] event in MainActor.assumeIsolated { self?.receive(event) } }
        workspaceObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { if NSEvent.pressedMouseButtons & 1 == 0 { self?.cancelDrag() } } }
        updateStatus("")
    }
    func stop() {
        enabled=false; cancelDrag(); history.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor=nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor=nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }; workspaceObserver=nil
    }
    func refreshPermission() { if enabled && localMonitor == nil && AXIsProcessTrusted() { enabled=false; start() } }
    func cancelDrag() {
        generation &+= 1; worker.invalidate(); target=nil; verifying=false; verified=false; attempts=0; pendingAction=nil
        preview?.orderOut(nil); preview?.close(); preview=nil
    }
    private func receive(_ event:NSEvent) {
        guard enabled,AXIsProcessTrusted() else { return }
        let point=NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            cancelDrag(); anchor=point; lastPoint=point
            let token=generation
            if let window=event.window {
                guard eligible(window) else { return }; target = .local(window,window.frame)
            } else {
                let pid=pid_t(event.cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0)
                let owner=pid>0 ? pid : NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                guard owner>0,owner != getpid() else { return }
                let axPoint=CGPoint(x:point.x,y:CGDisplayBounds(CGMainDisplayID()).height-point.y)
                worker.locate(pid:owner,point:axPoint) { [weak self] value in MainActor.assumeIsolated {
                    guard let self,self.generation == token,self.enabled else { return }
                    self.target=value.map(Target.external)
                    self.updateDrag(self.lastPoint)
                } }
            }
        case .leftMouseDragged: lastPoint=point; updateDrag(point)
        case .leftMouseUp:
            guard verified,let target,let action=pendingAction,let screen=NSScreen.screens.first(where: { $0.frame.contains(point) }),
                  WindowLayoutGeometry.snap(at:point,on:screen.frame) == action else { cancelDrag(); return }
            let request=WindowLayoutGeometry.frame(for:action,in:screen.visibleFrame,scale:screen.backingScaleFactor)
            preview?.orderOut(nil); pendingAction=nil
            if let request { apply(target,frame:request,restoring:false) }
            self.target=nil; verified=false
        default:break
        }
    }
    private func eligible(_ window:NSWindow)->Bool {
        !(window is NSPanel) && window.isVisible && !window.isMiniaturized && window.styleMask.contains(.titled)
            && window.styleMask.contains(.resizable) && !window.styleMask.contains(.fullScreen)
    }
    private func updateDrag(_ point:CGPoint) {
        guard let target,hypot(point.x-anchor.x,point.y-anchor.y)>10 else { return }
        guard let screen=NSScreen.screens.first(where: { $0.frame.contains(point) }),let action=WindowLayoutGeometry.snap(at:point,on:screen.frame) else {
            pendingAction=nil; preview?.orderOut(nil); return
        }
        if !verified {
            guard !verifying,attempts<4 else { return }; attempts += 1
            switch target {
            case let .local(window,original): verified=eligible(window) && WindowLayoutGeometry.isMove(original:original,current:window.frame)
            case let .external(window):
                verifying=true; let token=generation
                worker.read(window) { [weak self] value in MainActor.assumeIsolated {
                    guard let self,self.generation == token else { return }
                    self.verifying=false
                    self.verified=value.map { WindowLayoutGeometry.isMove(original:window.frame,current:$0.frame) } ?? false
                    if self.verified { self.updateDrag(self.lastPoint) }
                } }; return
            }
        }
        guard verified,let frame=WindowLayoutGeometry.frame(for:action,in:screen.visibleFrame,scale:screen.backingScaleFactor) else { return }
        if pendingAction != action || preview?.frame != frame {
            if preview == nil { preview=LayoutPreviewPanel() }
            preview?.setFrame(frame,display:true,animate:false); preview?.orderFrontRegardless()
            pendingAction=action
        }
    }
    func perform(_ action:WindowLayoutAction) {
        guard enabled else { return }; cancelDrag()
        guard AXIsProcessTrusted() else { updateStatus("请先允许辅助功能权限"); return }
        let token=generation
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            guard let window=NSApp.keyWindow,eligible(window) else { updateStatus("当前窗口不支持调整"); return }
            applyAction(action,to:.local(window,window.frame)); return
        }
        guard let pid=NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        worker.locate(pid:pid,point:nil) { [weak self] window in MainActor.assumeIsolated {
            guard let self,self.generation == token,self.enabled else { return }
            guard let window else { self.updateStatus("当前窗口不支持调整"); return }
            self.applyAction(action,to:.external(window))
        } }
    }
    private func applyAction(_ action:WindowLayoutAction,to target:Target) {
        let screen=NSScreen.screens.max { intersectionArea($0.visibleFrame,target.frame)<intersectionArea($1.visibleFrame,target.frame) }
        guard let screen else { return }
        if action == .restore {
            guard let saved=history.first(where: { $0.matches(target) }) else { updateStatus("当前窗口没有可恢复的大小"); return }
            apply(target,frame:WindowLayoutGeometry.restored(saved.frame,within:screen.visibleFrame),restoring:true)
        } else if let frame=WindowLayoutGeometry.frame(for:action,in:screen.visibleFrame,scale:screen.backingScaleFactor) { apply(target,frame:frame,restoring:false) }
    }
    private func intersectionArea(_ a:CGRect,_ b:CGRect)->CGFloat { let rect=a.intersection(b); return rect.isNull ? 0 : rect.width*rect.height }
    private func apply(_ target:Target,frame:CGRect,restoring:Bool) {
        if !restoring,!history.contains(where: { $0.matches(target) }) { history.append(Saved(target)); if history.count>64 { history.removeFirst() } }
        let token=generation
        switch target {
        case let .local(window,_):
            guard eligible(window) else { return }
            WindowLayoutNative.apply(window,frame:frame)
            if restoring { history.removeAll { $0.matches(target) } }
            updateStatus("")
        case let .external(window):
            let ax=WindowLayoutGeometry.axFrame(frame,primaryTop:CGDisplayBounds(CGMainDisplayID()).height)
            worker.apply(window,frame:ax) { [weak self] actual in MainActor.assumeIsolated {
                guard let self,self.generation == token else { return }
                if actual != nil,restoring { self.history.removeAll { $0.matches(target) } }
                self.updateStatus(actual == nil ? "应用未接受窗口调整，请重试" : "")
            } }
        }
    }
    private func updateStatus(_ value:String) { status.stringValue=value; status.isHidden=value.isEmpty; onStatusChange?() }
    private func makeSettings()->NSView {
        let stack=NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=16
        let heading=NSTextField(labelWithString:"拖到边缘，松手落位")
        heading.font=SketchPalette.heading(22); heading.textColor=SketchPalette.ink
        let description=NSTextField(wrappingLabelWithString:"左、右、上、下边缘：对应半屏\n四个角：四分之一屏　·　预览出现后松手")
        description.font = .systemFont(ofSize:14); description.textColor=SketchPalette.muted
        status.font = .systemFont(ofSize:12); status.textColor=SketchPalette.muted; status.maximumNumberOfLines=2
        for view in [heading,description,status] { stack.addArrangedSubview(view) }
        description.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
        return stack
    }
}
@MainActor private final class LayoutPreviewPanel:NSPanel {
    init() {
        super.init(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        backgroundColor = .clear; isOpaque=false; hasShadow=false; ignoresMouseEvents=true
        level = .floating; isReleasedWhenClosed=false; collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        contentView=LayoutPreviewView()
    }
    override var canBecomeKey:Bool { false }
}
@MainActor private final class LayoutPreviewView:NSView {
    override func draw(_ dirtyRect:NSRect) {
        let path=SketchPencil.outline(in:bounds.insetBy(dx:3,dy:3),radius:10)
        SketchPalette.blue.withAlphaComponent(0.12).setFill(); path.fill()
        SketchPencil.stroke(path,color:SketchPalette.blue.withAlphaComponent(0.8),width:2)
    }
}
