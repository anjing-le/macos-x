import AVFoundation

/// Product-owned defaults, shared by capture and encoder; no expert controls.
enum CaptureRecordingPreset {
    static let frameRate: Int32 = 60
    static func bitRate(width: Int, height: Int) -> Int {
        let value = Double(width) * Double(height) * Double(frameRate) * 0.10
        return value.isFinite ? Int(min(16_000_000, max(2_000_000, value))) : 16_000_000
    }
    static func videoSettings(width: Int, height: Int) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264,
         AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitRate(width: width, height: height),
            AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(frameRate),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false
         ]]
    }
}
