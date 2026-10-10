import Foundation

public enum WindowLayoutAction: String, CaseIterable, Sendable {
    case left, right, top, bottom, maximize, restore, topLeft, topRight, bottomLeft, bottomRight
    public var title:String {
        switch self {
        case .left:return "左半屏"; case .right:return "右半屏"; case .top:return "上半屏"; case .bottom:return "下半屏"
        case .maximize:return "最大化"; case .restore:return "恢复原大小"
        case .topLeft:return "左上角"; case .topRight:return "右上角"; case .bottomLeft:return "左下角"; case .bottomRight:return "右下角"
        }
    }
}
public enum WindowLayoutGeometry {
    public static func frame(for action:WindowLayoutAction,in work:CGRect,scale:CGFloat=1)->CGRect? {
        guard work.width>0,work.height>0,work.width.isFinite,work.height.isFinite,scale>0,scale.isFinite else { return nil }
        let w=floor(work.width*scale/2)/scale,h=floor(work.height*scale/2)/scale
        switch action {
        case .left:return CGRect(x:work.minX,y:work.minY,width:w,height:work.height)
        case .right:return CGRect(x:work.minX+w,y:work.minY,width:work.width-w,height:work.height)
        case .top:return CGRect(x:work.minX,y:work.minY+h,width:work.width,height:work.height-h)
        case .bottom:return CGRect(x:work.minX,y:work.minY,width:work.width,height:h)
        case .maximize:return work
        case .restore:return nil
        case .topLeft:return CGRect(x:work.minX,y:work.minY+h,width:w,height:work.height-h)
        case .topRight:return CGRect(x:work.minX+w,y:work.minY+h,width:work.width-w,height:work.height-h)
        case .bottomLeft:return CGRect(x:work.minX,y:work.minY,width:w,height:h)
        case .bottomRight:return CGRect(x:work.minX+w,y:work.minY,width:work.width-w,height:h)
        }
    }
    public static func snap(at point:CGPoint,on screen:CGRect,threshold:CGFloat=18)->WindowLayoutAction? {
        guard screen.contains(point),screen.width>threshold*2,screen.height>threshold*2 else { return nil }
        let left=point.x-screen.minX<threshold,right=screen.maxX-point.x<threshold
        let top=screen.maxY-point.y<threshold,bottom=point.y-screen.minY<threshold
        if left && top { return .topLeft }; if right && top { return .topRight }
        if left && bottom { return .bottomLeft }; if right && bottom { return .bottomRight }
        if top { return .top }; if bottom { return .bottom }; if left { return .left }; if right { return .right }
        return nil
    }
    public static func isMove(original:CGRect,current:CGRect)->Bool {
        abs(original.width-current.width)<2 && abs(original.height-current.height)<2
            && hypot(original.minX-current.minX,original.minY-current.minY)>2
    }
    public static func axFrame(_ frame:CGRect,primaryTop:CGFloat)->CGRect {
        CGRect(x:frame.minX,y:primaryTop-frame.maxY,width:frame.width,height:frame.height)
    }
    public static func restored(_ frame:CGRect,within work:CGRect)->CGRect {
        let w=min(frame.width,work.width),h=min(frame.height,work.height)
        return CGRect(x:min(max(frame.minX,work.minX),work.maxX-w),y:min(max(frame.minY,work.minY),work.maxY-h),width:w,height:h)
    }
}
