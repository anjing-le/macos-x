import Foundation

public struct PromptEntry: Codable, Equatable, Sendable {
    public var title: String
    public var content: String
    public init(title: String, content: String) { self.title = title; self.content = content }
}

/// Ten stable common positions; text and title stay distinct during search/copy.
public enum PromptLibrary {
    public static let count = 10
    public static let titleLimit = 64
    public static let contentLimit = 16_384
    public static func normalize(_ entries: [PromptEntry]) -> [PromptEntry] {
        (0..<count).map { index in
            guard entries.indices.contains(index) else { return .init(title: "", content: "") }
            return .init(title: String(entries[index].title.prefix(titleLimit)), content: String(entries[index].content.prefix(contentLimit)))
        }
    }
    public static func migrate(_ strings: [String]) -> [PromptEntry] {
        normalize(strings.prefix(count).map { text in
            .init(title: String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(24) ?? ""), content: text)
        })
    }
    public static func matches(_ entries: [PromptEntry], query: String) -> [Int] {
        let query = String(query.prefix(titleLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.indices.prefix(count).filter {
            !entries[$0].content.isEmpty && (query.isEmpty || entries[$0].title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }
    public static let presets = normalize([
        .init(title: "总结", content: "请总结以下内容，保留关键结论、依据和待办事项：\n\n"),
        .init(title: "润色", content: "请在保留原意的前提下润色以下文字，使表达清晰、简洁、自然。只输出修改后的内容：\n\n"),
        .init(title: "翻译", content: "请将以下内容翻译成中文，保留专有名词、结构和原意：\n\n"),
        .init(title: "提取待办", content: "请从以下内容中提取待办事项，列出负责人和时间；未明确的信息标注为待确认：\n\n"),
        .init(title: "邮件回复", content: "请根据以下内容起草一封简洁、礼貌的回复，不补充未经确认的事实：\n\n")
    ])
}
