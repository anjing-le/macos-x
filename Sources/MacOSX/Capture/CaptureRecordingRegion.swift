import Foundation

/// AppKit global, Y-up points -> display-local, Y-down points. SCK crops at
/// the source; only the selected region is encoded, with a 1920-pixel cap.
struct CaptureRecordingRegion {
    let source: CGRect
    let width: Int
    let height: Int

    init?(screen: CaptureScreen, region: CGRect) {
        let bounds = screen.frame
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height,
               region.minX, region.minY, region.width, region.height, screen.scale].allSatisfy({ $0.isFinite }),
              bounds.width > 0, bounds.height > 0, screen.scale > 0,
              region.width > 0, region.height > 0, bounds.contains(region) else { return nil }
        let pixelsWide = region.width * screen.scale, pixelsHigh = region.height * screen.scale
        guard pixelsWide.isFinite, pixelsHigh.isFinite, pixelsWide >= 2, pixelsHigh >= 2 else { return nil }
        let ratio = min(1, 1920 / max(pixelsWide, pixelsHigh))
        width = max(2, Int(pixelsWide * ratio) / 2 * 2)
        height = max(2, Int(pixelsHigh * ratio) / 2 * 2)
        source = CGRect(x: region.minX - bounds.minX, y: bounds.maxY - region.maxY,
                        width: region.width, height: region.height)
    }
}
