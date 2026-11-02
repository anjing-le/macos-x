import AVFoundation
import MacOSXCore

@main struct RecordingEncodingRegression {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        check(CaptureRecordingPreset.bitRate(width: 1920, height: 1080) > CaptureRecordingPreset.bitRate(width: 1280, height: 720), "Bitrate follows output pixels")
        check(CaptureRecordingPreset.bitRate(width: 16, height: 16) == 2_000_000, "Small captures retain a quality floor")
        check(CaptureRecordingPreset.bitRate(width: 10_000, height: 10_000) == 64_000_000, "Encoding budget has an upper bound")
        for quality in RecordingQuality.allCases {
            let settings=CaptureRecordingPreset.videoSettings(width:3840,height:2160,quality:quality)
            let compression=settings[AVVideoCompressionPropertiesKey] as! [String:Any]
            check((compression[AVVideoAverageBitRateKey] as! Int) <= quality.maximumBitRate, "Each quality has a bounded bitrate")
            check(compression[AVVideoExpectedSourceFrameRateKey] as! Int == 60, "All presets retain 60 fps")
        }
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
        for (quality, width, height) in [(RecordingQuality.standard,1920,1080),(.high,2560,1440),(.ultra,3840,2160),(.ultra,3526,2350),(.ultra,2350,3526),(.ultra,2880,2880)] {
            let sampleURL=FileManager.default.temporaryDirectory.appendingPathComponent("quality-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at:sampleURL) }
            let outputWriter=try AVAssetWriter(outputURL:sampleURL,fileType:.mp4)
            let video=AVAssetWriterInput(mediaType:.video,outputSettings:CaptureRecordingPreset.videoSettings(width:width,height:height,quality:quality))
            outputWriter.add(video)
            let pixels=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:video,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
            check(outputWriter.startWriting(),"Preset starts a real H264 encoder: \(quality.title)")
            outputWriter.startSession(atSourceTime:.zero)
            for frame in 0..<12 {
                let deadline=Date().addingTimeInterval(10)
                while !video.isReadyForMoreMediaData && Date()<deadline { try await Task.sleep(nanoseconds:5_000_000) }
                check(video.isReadyForMoreMediaData,"Full-resolution writer accepts frames")
                var buffer:CVPixelBuffer?
                check(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pixels.pixelBufferPool!,&buffer)==kCVReturnSuccess,"Full-resolution pixel allocation")
                CVPixelBufferLockBaseAddress(buffer!,[])
                memset(CVPixelBufferGetBaseAddress(buffer!),Int32(frame*19),CVPixelBufferGetBytesPerRow(buffer!)*height)
                CVPixelBufferUnlockBaseAddress(buffer!,[])
                check(pixels.append(buffer!,withPresentationTime:CMTime(value:Int64(frame),timescale:60)),"Append full-resolution frame")
            }
            outputWriter.endSession(atSourceTime:CMTime(value:12,timescale:60));video.markAsFinished();await outputWriter.finishWriting()
            check(outputWriter.status == .completed,"Full-resolution MP4 finalizes")
            let file=AVURLAsset(url:sampleURL),track=try await file.loadTracks(withMediaType:.video).first!
            let size=try await track.load(.naturalSize)
            check(Int(size.width)==width && Int(size.height)==height,"Encoded preset preserves requested resolution")
            let decoder=try AVAssetReader(asset:file)
            let frames=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            decoder.add(frames);check(decoder.startReading(),"Full-resolution MP4 decodes")
            var count=0
            while autoreleasepool(invoking:{frames.copyNextSampleBuffer() != nil}) { count += 1 }
            check(count==12 && decoder.status == .completed,"Full-resolution samples survive encode/decode")
        }
        print("PASS recording preset: \(checks) checks, real H264/MP4 60-fps encode/decode; no screen capture or user UI")
    }
}
