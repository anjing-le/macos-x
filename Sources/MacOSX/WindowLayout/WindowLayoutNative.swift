import AppKit

/// Same-process windows never enter the external AX worker.
@MainActor enum WindowLayoutNative {
    static func apply(_ window:NSWindow,frame:CGRect) {
        let width=min(window.maxSize.width,max(window.minSize.width,frame.width))
        let height=min(window.maxSize.height,max(window.minSize.height,frame.height))
        window.setFrame(CGRect(x:frame.minX,y:frame.maxY-height,width:width,height:height),display:true,animate:false)
    }
}
