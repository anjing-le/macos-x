import XCTest
@testable import MacOSXCore
final class WindowLayoutTests:XCTestCase {
    func testOddRetinaAreaTilesWithoutGaps() {
        let work=CGRect(x:-1600,y:25,width:1439.5,height:877.5)
        let left=WindowLayoutGeometry.frame(for:.left,in:work,scale:2)!,right=WindowLayoutGeometry.frame(for:.right,in:work,scale:2)!
        XCTAssertEqual(left.maxX,right.minX); XCTAssertEqual(left.width+right.width,work.width)
        let tl=WindowLayoutGeometry.frame(for:.topLeft,in:work,scale:2)!,bl=WindowLayoutGeometry.frame(for:.bottomLeft,in:work,scale:2)!
        XCTAssertEqual(tl.minY,bl.maxY); XCTAssertEqual(tl.height+bl.height,work.height)
        let top=WindowLayoutGeometry.frame(for:.top,in:work,scale:2)!,bottom=WindowLayoutGeometry.frame(for:.bottom,in:work,scale:2)!
        XCTAssertEqual(bottom.maxY,top.minY); XCTAssertEqual(top.height+bottom.height,work.height)
        XCTAssertEqual(top.width,work.width); XCTAssertEqual(bottom.width,work.width)
        XCTAssertEqual(WindowLayoutGeometry.frame(for:.maximize,in:work),work)
        XCTAssertNil(WindowLayoutGeometry.frame(for:.restore,in:work))
    }
    func testSnapZonesAndInterior() {
        let screen=CGRect(x:0,y:0,width:1440,height:900)
        XCTAssertEqual(WindowLayoutGeometry.snap(at:CGPoint(x:1,y:450),on:screen),.left)
        XCTAssertEqual(WindowLayoutGeometry.snap(at:CGPoint(x:1439,y:450),on:screen),.right)
        XCTAssertEqual(WindowLayoutGeometry.snap(at:CGPoint(x:720,y:899),on:screen),.top)
        XCTAssertEqual(WindowLayoutGeometry.snap(at:CGPoint(x:1,y:899),on:screen),.topLeft)
        XCTAssertEqual(WindowLayoutGeometry.snap(at:CGPoint(x:1439,y:1),on:screen),.bottomRight)
        XCTAssertNil(WindowLayoutGeometry.snap(at:CGPoint(x:720,y:450),on:screen))
        XCTAssertEqual(WindowLayoutGeometry.snap(at:CGPoint(x:720,y:1),on:screen),.bottom)
        XCTAssertNil(WindowLayoutGeometry.snap(at:CGPoint(x:-1,y:450),on:screen))
    }
    func testMovingIsRequiredAndResizeRejected() {
        let original=CGRect(x:50,y:50,width:500,height:400)
        XCTAssertFalse(WindowLayoutGeometry.isMove(original:original,current:original))
        XCTAssertFalse(WindowLayoutGeometry.isMove(original:original,current:CGRect(x:55,y:50,width:520,height:400)))
        XCTAssertTrue(WindowLayoutGeometry.isMove(original:original,current:original.offsetBy(dx:30,dy:10)))
    }
    func testGlobalAXCoordinatesAndOffscreenRestore() {
        let appKit=CGRect(x:-1000,y:-800,width:700,height:500)
        let ax=WindowLayoutGeometry.axFrame(appKit,primaryTop:900)
        XCTAssertEqual(ax.minY,1200); XCTAssertEqual(WindowLayoutGeometry.axFrame(ax,primaryTop:900),appKit)
        let visible=CGRect(x:0,y:25,width:1200,height:775)
        let restored=WindowLayoutGeometry.restored(appKit,within:visible)
        XCTAssertTrue(visible.contains(restored)); XCTAssertEqual(restored.size,appKit.size)
    }
}
