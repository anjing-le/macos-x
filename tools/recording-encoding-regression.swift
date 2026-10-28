import AVFoundation

@main struct RecordingEncodingRegression {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        check(CaptureRecordingPreset.bitRate(width: 1920, height: 1080) > CaptureRecordingPreset.bitRate(width: 1280, height: 720), "Bitrate follows output pixels")
        check(CaptureRecordingPreset.bitRate(width: 16, height: 16) == 2_000_000, "Small captures retain a quality floor")
        check(CaptureRecordingPreset.bitRate(width: 10_000, height: 10_000) == 16_000_000, "Encoding budget has an upper bound")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-60fps-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: CaptureRecordingPreset.videoSettings(width: 320, height: 180))
        input.expectsMediaDataInRealTime = true
        check(writer.canAdd(input), "System writer accepts the production H264 preset")
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        check(writer.startWriting(), "Writer starts with the product preset")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            var buffer: CVPixelBuffer?
            check(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess, "Frame allocation")
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 4), CVPixelBufferGetBytesPerRow(buffer!) * 180)
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            check(input.isReadyForMoreMediaData && adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)), "Append a timestamped 60-fps frame")
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        check(writer.status == .completed, "MP4 is finalized")
        let asset = AVURLAsset(url: url), tracks = try await asset.loadTracks(withMediaType: .video)
        check(tracks.count == 1, "One playable video track")
        let rate = try await tracks[0].load(.nominalFrameRate)
        check(abs(rate - 60) < 0.1, "Final file reports 60 fps")
        let duration = try await asset.load(.duration)
        check(abs(CMTimeGetSeconds(duration) - 1) < 0.05, "Encoded timestamps preserve the one-second duration")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); check(reader.startReading(), "The resulting H264 file can be decoded")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        check(frames == 60 && reader.status == .completed, "All 60 frames survive encoding and decoding")
        print("PASS recording preset: \(checks) checks, real H264/MP4 60-fps encode/decode; no screen capture or user UI")
    }
}
