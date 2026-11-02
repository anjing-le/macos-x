import AVFoundation
import MacOSXCore

/// Product-owned defaults, shared by capture and encoder; three product quality presets.
enum CaptureRecordingPreset {
    static let frameRate: Int32 = 60
    static func bitRate(width: Int, height: Int, quality: RecordingQuality = .ultra) -> Int {
        let value = Double(width) * Double(height) * Double(frameRate) * quality.bitsPerPixel
        return value.isFinite ? Int(min(Double(quality.maximumBitRate), max(2_000_000, value))) : quality.maximumBitRate
    }
    static func videoSettings(width: Int, height: Int, quality: RecordingQuality = .ultra) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264,
         AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitRate(width: width, height: height, quality: quality),
            AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(frameRate),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false
         ]]
    }
}
