import AppKit

@main struct ExportRegression {
    static var count = 0
    static func check(_ condition: Bool, _ message: String) {
        count += 1; precondition(condition, message)
    }
    static func main() throws {
        // Real local filesystem behavior, not a fake writer or destination.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macos-x-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("recording.mp4")
        let working = CaptureRecordingFile.workingURL(for: destination)
        check(working.deletingLastPathComponent() == destination.deletingLastPathComponent(), "same-volume working file")
        check(working.lastPathComponent.hasPrefix("."), "unfinished recording is hidden")
        let payload = Data("complete recording fixture".utf8)
        try payload.write(to: working)
        let saved = CaptureRecordingFile.publish(working, to: destination)
        check(saved.url == destination && saved.error == nil, "normal finalization")
        check(try Data(contentsOf: destination) == payload, "recording bytes survive rename")
        check(!FileManager.default.fileExists(atPath: working.path), "normal working file is removed by rename")
        let second = CaptureRecordingFile.workingURL(for: destination)
        let other = Data("second recording".utf8); try other.write(to: second)
        let collision = CaptureRecordingFile.publish(second, to: destination)
        check(collision.error != nil && collision.url == second, "destination collision surfaces recoverable file")
        check(try Data(contentsOf: second) == other, "failed rename retains complete recording")
        check(try Data(contentsOf: destination) == payload, "existing recording never overwritten")
        let missing = folder.appendingPathComponent("missing/new.mp4")
        let failed = CaptureRecordingFile.publish(second, to: missing)
        check(failed.error != nil && FileManager.default.fileExists(atPath: failed.url.path), "missing destination preserves video")

        let context = CaptureRaster.context(width: 64, height: 64)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 16, to: 48, by: 4) { for x in stride(from: 16, to: 48, by: 4) {
            if (x + y) % 8 == 0 { context.fill(CGRect(x: x, y: y, width: 4, height: 4)) }
        } }
        let image = context.makeImage()!
        check(CaptureAnnotationRenderer.render(base: image, annotations: [], isCurrent: { false }) == nil, "cancelled export does no rendering")
        let plain = CaptureAnnotationRenderer.render(base: image, annotations: [])!
        check((plain.dataProvider!.data! as Data) == (image.dataProvider!.data! as Data), "unannotated export preserves pixels")
        for tool in [CaptureTool.mosaic, .blur] {
            let ink = CaptureAnnotation(tool: tool, points: [CGPoint(x: 16, y: 16), CGPoint(x: 48, y: 48)], ink: .red, width: 3)
            let output = CaptureAnnotationRenderer.render(base: image, annotations: [ink])!
            let before = CapturePixelSampler(image: image)!, after = CapturePixelSampler(image: output)!
            check(after.sample(x: 2, y: 2)?.hex == before.sample(x: 2, y: 2)?.hex, "redaction leaves outside pixels intact")
            let changed = (20..<44).contains { y in (20..<44).contains { x in before.sample(x: x, y: y)?.hex != after.sample(x: x, y: y)?.hex } }
            check(changed, "redaction actually changes content")
        }
        print("PASS capture export: \(count) assertions; rename, failure recovery, no overwrite, unchanged pixels, redaction and cancellation")
    }
}
