import AppKit
import CoreImage

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
        let dab = CaptureAnnotation(tool: .mosaic, points: [CGPoint(x: 32, y: 32)], ink: .red, width: 24)
        let dabImage = CaptureAnnotationRenderer.render(base: image, annotations: [dab])!
        let beforeDab = CapturePixelSampler(image: image)!, afterDab = CapturePixelSampler(image: dabImage)!
        check(dab.bounds == CGRect(x: 20, y: 20, width: 24, height: 24), "Dab bounds include the circular brush radius")
        check(afterDab.sample(x: 22, y: 22)?.hex == beforeDab.sample(x: 22, y: 22)?.hex, "Circular brush does not redact its bounding-box corners")
        check((26..<38).contains { y in (26..<38).contains { x in beforeDab.sample(x: x, y: y)?.hex != afterDab.sample(x: x, y: y)?.hex } }, "A single click produces real mosaic pixels")
        let trail = CaptureAnnotation(tool: .mosaic, points: [CGPoint(x: 8, y: 32), CGPoint(x: 56, y: 32)], ink: .red, width: 16)
        let trailImage = CaptureAnnotationRenderer.render(base: image, annotations: [trail])!
        let afterTrail = CapturePixelSampler(image: trailImage)!
        check((28..<36).contains { y in (28..<36).contains { x in beforeDab.sample(x: x, y: y)?.hex != afterTrail.sample(x: x, y: y)?.hex } }, "Fast sparse drag covers the continuous path between mouse samples")
        check(afterTrail.sample(x: 32, y: 18)?.hex == beforeDab.sample(x: 32, y: 18)?.hex, "Pixels away from the brush path are unchanged")
        let black = CaptureRaster.context(width: 64, height: 64)!
        black.setFillColor(CGColor(gray: 0, alpha: 1)); black.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let darkBase = black.makeImage()!
        for tool in [CaptureTool.rectangle, .arrow] {
            let mark = CaptureAnnotation(tool: tool, points: [CGPoint(x: 12, y: 12), CGPoint(x: 52, y: 52)], ink: .red, width: 4)
            let one = CaptureAnnotationRenderer.render(base: darkBase, annotations: [mark])!
            let two = CaptureAnnotationRenderer.render(base: darkBase, annotations: [mark])!
            check((one.dataProvider!.data! as Data) == (two.dataProvider!.data! as Data), "crayon export is deterministic across redraws")
            let sampler = CapturePixelSampler(image: one)!
            check(sampler.sample(x: 2, y: 2)?.hex == "#000000", "crayon leaves unrelated pixels unchanged")
            let colors = (8..<56).flatMap { y in (8..<56).compactMap { x in sampler.sample(x: x, y: y)?.hex } }
            check(Set(colors).count > 8, "wax stroke has actual pigment variation")
            check(!colors.contains("#FFFFFF"), "grain does not paint white over dark screenshots")
            check(CaptureAnnotationRenderer.render(base: darkBase, annotations: [mark], isCurrent: { false }) == nil, "crayon export respects cancellation")
        }
        // Reframing moves the crop, not the screen content or committed marks.
        let oldRegion = CGRect(x: 100, y: 200, width: 32, height: 32)
        let largerRegion = CGRect(x: 96, y: 196, width: 40, height: 40)
        var textMark = CaptureAnnotation(tool: .text, points: [CGPoint(x: 12, y: 16)], ink: .red, width: 4)
        textMark.text = "保留文字"
        let moved = textMark.reframed(from: oldRegion, pixels: CGSize(width: 64, height: 64),
                                     to: largerRegion, pixels: CGSize(width: 80, height: 80))
        check(moved.points == [CGPoint(x: 20, y: 24)] && moved.width == 4 && moved.text == textMark.text,
              "expanding crop preserves mark screen position, stroke width and text")
        let roundtrip = moved.reframed(from: largerRegion, pixels: CGSize(width: 80, height: 80),
                                       to: oldRegion, pixels: CGSize(width: 64, height: 64))
        check(roundtrip.points == textMark.points && roundtrip.width == textMark.width,
              "resize round trip keeps annotation coordinates")
        let lowerScale = textMark.reframed(from: oldRegion, pixels: CGSize(width: 64, height: 64),
                                          to: oldRegion, pixels: CGSize(width: 32, height: 32))
        check(lowerScale.points == [CGPoint(x: 6, y: 8)] && lowerScale.width == 2,
              "cross-display scale changes preserve physical mark geometry")
        let redaction = CaptureAnnotation(tool: .mosaic, points: [CGPoint(x: 16, y: 16), CGPoint(x: 48, y: 48)], ink: .red, width: 3)
        let expanded = CaptureRaster.context(width: 80, height: 80)!
        expanded.setFillColor(CGColor(gray: 1, alpha: 1)); expanded.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        expanded.draw(image, in: CGRect(x: 8, y: 8, width: 64, height: 64))
        let adjustedRedaction = redaction.reframed(from: oldRegion, pixels: CGSize(width: 64, height: 64),
                                                  to: largerRegion, pixels: CGSize(width: 80, height: 80))
        let output = CaptureAnnotationRenderer.render(base: expanded.makeImage()!, annotations: [adjustedRedaction])!
        let adjustedSample = CapturePixelSampler(image: output)!
        let originalOutput = CaptureAnnotationRenderer.render(base: image, annotations: [redaction])!
        let originalSample = CapturePixelSampler(image: originalOutput)!
        let sharedEffects = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        let reused = CaptureAnnotationRenderer.render(base: image, annotations: [redaction], effectsContext: sharedEffects)!
        check((reused.dataProvider!.data! as Data) == (originalOutput.dataProvider!.data! as Data), "Reusing the effects engine preserves exported pixels")
        if ProcessInfo.processInfo.environment["MACOSX_RENDER_BENCHMARK"] == "1" {
            let large = CaptureRaster.context(width: 1920, height: 1080)!
            large.setFillColor(CGColor(gray: 0.6, alpha: 1)); large.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let base = large.makeImage()!
            let stroke = CaptureAnnotation(tool: .mosaic, points: [CGPoint(x: 400, y: 400), CGPoint(x: 900, y: 650)], ink: .red, width: 64)
            var fresh = [Double](), shared = [Double]()
            for _ in 0..<9 {
                for reuse in [false, true] {
                    let start = ProcessInfo.processInfo.systemUptime
                    autoreleasepool { _ = CaptureAnnotationRenderer.render(base: base, annotations: [stroke], effectsContext: reuse ? sharedEffects : nil) }
                    let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
                    if reuse { shared.append(elapsed) } else { fresh.append(elapsed) }
                }
            }
            print(String(format: "1920×1080 mosaic render median (9 samples): fresh context %.2f ms; reused context %.2f ms", fresh.sorted()[4], shared.sorted()[4]))
        }
        check(adjustedSample.sample(x: 28, y: 28)?.hex == originalSample.sample(x: 20, y: 20)?.hex,
              "redaction stays applied to the same frozen desktop content after expanding crop")
        print("PASS capture export: \(count) assertions; rename, failure recovery, no overwrite, unchanged pixels, redaction and cancellation")
    }
}
