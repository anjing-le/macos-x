import Foundation

/// Product presets, not arbitrary encoder controls. Stored independently of audio choices.
public enum RecordingQuality: String, CaseIterable, Sendable {
    case standard, high, ultra
    public static let preferenceKey = "recording.quality"
    public var title: String {
        switch self { case .standard: return "1080p"; case .high: return "2K"; case .ultra: return "4K" }
    }
    public var maximumDimension: Int {
        switch self { case .standard: return 1920; case .high: return 2560; case .ultra: return 3840 }
    }
    public var maximumPixels: Int { min(maximumDimension * maximumDimension, 3840 * 2160) }
    public var bitsPerPixel: Double {
        switch self { case .standard: return 0.10; case .high: return 0.14; case .ultra: return 0.18 }
    }
    public var maximumBitRate: Int {
        switch self { case .standard: return 16_000_000; case .high: return 32_000_000; case .ultra: return 64_000_000 }
    }
    public var help: String {
        AppLanguage.text("最高长边 {0} 像素 · 60 fps；保持选区比例，不放大小区域。清晰度越高，文件通常越大。", String(maximumDimension))
    }
    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .ultra
    }
    public func save(to defaults: UserDefaults) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}
