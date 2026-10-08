import AppKit
@main struct Probe {
    @MainActor static func main() async {
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIPPED: probe has no existing Screen Recording access; no permission requested")
            return
        }
        let screens = NSScreen.screens.compactMap { screen -> CaptureScreen? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return CaptureScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        let service = CaptureImageService()
        for attempt in 1...3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result: Result<[CaptureFrame], Error> = await withCheckedContinuation { continuation in
                service.capture(screens) { continuation.resume(returning: $0) }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            switch result {
            case .success(let frames): print("attempt=\(attempt) displays=\(frames.count) acquisition_ms=\(ms)")
            case .failure(let error): print("capture failed: \(error)"); return
            }
        }
    }
}
