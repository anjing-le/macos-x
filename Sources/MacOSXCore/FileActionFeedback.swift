import Foundation

/// Event-driven phases, never an estimated percentage or a history database.
public struct FileActionFeedback: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing, processing, saving, completed, cancelled, failed
        public var isBusy: Bool { self == .preparing || self == .processing || self == .saving }
        public var title: String {
            switch self {
            case .preparing: return AppLanguage.text("正在准备…")
            case .processing: return AppLanguage.text("正在处理…")
            case .saving: return AppLanguage.text("正在保存…")
            case .completed: return AppLanguage.text("已完成")
            case .cancelled: return AppLanguage.text("已取消")
            case .failed: return AppLanguage.text("处理失败")
            }
        }
    }
    public let phase: Phase
    public let input: URL
    public let output: URL?
    public let message: String
    public init(phase: Phase, input: URL, output: URL? = nil, message: String = "") {
        self.phase = phase; self.input = input; self.output = output; self.message = message
    }
    public var title: String { AppLanguage.text("文件操作") + " · " + phase.title }
    public var detail: String {
        Self.compact(phase == .failed ? message : (output ?? input).lastPathComponent)
    }
    public static func compact(_ value: String) -> String {
        let text = value.components(separatedBy: .controlCharacters).joined(separator: " ")
        return text.count <= 48 ? text : String(text.prefix(31)) + "…" + String(text.suffix(16))
    }
}
