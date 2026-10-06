import Foundation

public struct LibraryPrompt: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public init(id: String = UUID().uuidString, title: String, content: String) { self.id = id; self.title = title; self.content = content }
}
public struct PromptImport: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var id: String?
        public var title: String
        public var content: String
        public var slot: Int?
    }
    public var version: Int
    public var prompts: [Item]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= PromptCollection.byteLimit else { throw PromptCollection.Failure("JSON 超过 4 MB") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PromptCollection.Failure("需要 version: 1 和 prompts 数组，每项包含 title、content") }
        guard value.version == 1 else { throw PromptCollection.Failure("仅支持 version: 1") }
        guard !value.prompts.isEmpty, value.prompts.count <= PromptCollection.limit else { throw PromptCollection.Failure("每次导入 1–500 条") }
        var ids = Set<String>(), slots = Set<Int>()
        for item in value.prompts {
            try PromptCollection.check(title: item.title, content: item.content)
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !item.content.isEmpty else { throw PromptCollection.Failure("标题和内容不能为空") }
            if let id = item.id {
                guard !id.isEmpty, id.utf8.count <= 64, ids.insert(id).inserted else { throw PromptCollection.Failure("id 不能为空、重复或超过 64 字节") }
            }
            if let slot = item.slot { guard (1...10).contains(slot), slots.insert(slot).inserted else { throw PromptCollection.Failure("slot 必须是 1–10，且不能重复") } }
        }
        return value
    }
    public static let example = """
    {"version":1,"prompts":[
      {"id":"summary","title":"总结","content":"请总结以下内容：","slot":1},
      {"id":"rewrite","title":"润色","content":"请保留原意，简洁自然地润色以下文字："}
    ]}
    """
    public static let aiInstructions = """
    请把我的提示词整理成纯 JSON，不要 Markdown 代码块。协议：根对象 version 为 1，prompts 为数组；每项 title 是简短标题，content 是完整内容（字符串换行用 \\n）。可选 id 为稳定且唯一的字符串，用于再次导入时更新同一条；省略 id 时按相同标题和内容去重。可选 slot 为 1–10，表示转盘位置，从正上方开始顺时针；省略 slot 仅加入可搜索的库。一次最多 500 条，标题最多 64 字，内容最多 16384 字 / 64 KiB，整个 JSON 最多 4 MB。同一次导入 id 和 slot 均不能重复。
    示例：
    \(example)
    """
}
public struct PromptCollection: Codable, Equatable, Sendable {
    public static let limit = 500, byteLimit = 4_000_000
    public struct Failure: LocalizedError { public var errorDescription: String?; public init(_ message: String) { errorDescription = message } }
    public var prompts: [LibraryPrompt]
    public var slots: [String?]
    public init(legacy: [PromptEntry]) {
        let entries = PromptLibrary.normalize(legacy)
        prompts = entries.enumerated().compactMap { i, entry in
            entry.title.isEmpty && entry.content.isEmpty ? nil : LibraryPrompt(id: "legacy-\(i+1)", title: entry.title, content: entry.content)
        }
        slots = entries.enumerated().map { i, entry in entry.title.isEmpty && entry.content.isEmpty ? nil : "legacy-\(i+1)" }
    }
    public static func check(title: String, content: String) throws {
        guard title.count <= 64, title.utf8.count <= 512, content.count <= 16_384, content.utf8.count <= 65_536 else { throw Failure("标题最多 64 字，内容最多 16384 字 / 64 KiB") }
    }
    public func validate() throws {
        guard prompts.count <= Self.limit, slots.count == 10 else { throw Failure("提示词库最多 500 条，转盘固定 10 个位置") }
        var ids = Set<String>()
        for p in prompts { try Self.check(title: p.title, content: p.content); guard !p.id.isEmpty, p.id.utf8.count <= 64, ids.insert(p.id).inserted else { throw Failure("提示词 id 无效或重复") } }
        let assigned = slots.compactMap { $0 }
        guard Set(assigned).count == assigned.count, assigned.allSatisfy({ ids.contains($0) }) else { throw Failure("转盘位置引用无效") }
        guard try JSONEncoder().encode(self).count <= Self.byteLimit else { throw Failure("提示词库超过 4 MB") }
    }
    public var wheelEntries: [PromptEntry] { slots.map { id in
        guard let id, let p = prompts.first(where: { $0.id == id }) else { return .init(title: "", content: "") }
        return .init(title: p.title, content: p.content)
    } }
    public func search(_ query: String) -> [Int] {
        let q = String(query.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prompts.indices.filter { !prompts[$0].content.isEmpty && (q.isEmpty || prompts[$0].title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil) }
    }
    public mutating func assign(_ id: String?, to slot: Int) {
        guard slots.indices.contains(slot), id == nil || prompts.contains(where: { $0.id == id }) else { return }
        if let id { for i in slots.indices where slots[i] == id { slots[i] = nil } }
        slots[slot] = id
    }
    public func merging(_ document: PromptImport) throws -> Self {
        var copy = self
        var indices = Dictionary(uniqueKeysWithValues: copy.prompts.enumerated().map { ($0.element.id, $0.offset) })
        var exact = Dictionary(copy.prompts.enumerated().map { (PromptEntry(title: $0.element.title, content: $0.element.content), $0.offset) }, uniquingKeysWith: { a,_ in a })
        for item in document.prompts {
            let fingerprint = PromptEntry(title:item.title, content:item.content)
            let index: Int
            if let id = item.id, let old = indices[id] { index = old }
            else if item.id == nil, let old = exact[fingerprint] { index = old }
            else {
                guard copy.prompts.count < Self.limit else { throw Failure("提示词库最多 500 条") }
                index = copy.prompts.count
                copy.prompts.append(.init(id: item.id ?? UUID().uuidString, title: item.title, content: item.content))
                indices[copy.prompts[index].id] = index
            }
            let oldFingerprint = PromptEntry(title:copy.prompts[index].title, content:copy.prompts[index].content)
            if oldFingerprint != fingerprint, exact[oldFingerprint] == index {
                exact[oldFingerprint] = copy.prompts.indices.first { other in
                    other != index && PromptEntry(title:copy.prompts[other].title, content:copy.prompts[other].content) == oldFingerprint
                }
            }
            copy.prompts[index].title = item.title; copy.prompts[index].content = item.content; exact[fingerprint] = index
            if let slot = item.slot { copy.assign(copy.prompts[index].id, to: slot - 1) }
        }
        try copy.validate(); return copy
    }
}
