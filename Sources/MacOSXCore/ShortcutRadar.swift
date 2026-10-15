import Foundation

/// Semantic key names, not a US-only virtual-key table. The native reader resolves
/// virtual keys with the current keyboard layout before constructing these values.
public struct RadarChord: Hashable, Sendable {
    public let key: String
    public let modifiers: UInt8
    public init(key: String, modifiers: UInt8) {
        self.key = Self.normalizeKey(key)
        self.modifiers = modifiers & 31
    }
    public var keycaps: [String] {
        [(UInt8(1), "⌃"), (2, "⌥"), (4, "⇧"), (8, "⌘"), (16, "fn")].compactMap {
            modifiers & $0.0 != 0 ? $0.1 : nil
        } + [key]
    }
    public var displayName: String { keycaps.joined() }
    public var longName: String {
        ([(UInt8(1), "Control"), (2, "Option"), (4, "Shift"), (8, "Command"), (16, "Fn")].compactMap {
            modifiers & $0.0 != 0 ? $0.1 : nil
        } + [key]).joined(separator: " + ")
    }
    public static func normalizeKey(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let aliases = ["LEFT": "←", "RIGHT": "→", "UP": "↑", "DOWN": "↓", "SPACE": "Space",
                       "空格": "Space", "RETURN": "↩", "ENTER": "↩", "TAB": "Tab", "ESC": "Esc",
                       "ESCAPE": "Esc", "DELETE": "⌫", "BACKSPACE": "⌫", "HOME": "Home", "END": "End", "PAGEUP": "PageUp", "PAGEDOWN": "PageDown"]
        return aliases[upper] ?? upper
    }
    /// Exact chord parsing; plain words remain action/application text searches.
    public static func parse(_ text: String) -> Self? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var modifiers: UInt8 = 0
        var consumed = false
        let names: [(String, UInt8)] = [("control", 1), ("ctrl", 1), ("⌃", 1), ("option", 2),
            ("alt", 2), ("opt", 2), ("⌥", 2), ("shift", 4), ("⇧", 4),
            ("command", 8), ("cmd", 8), ("⌘", 8), ("fn", 16)]
        while !rest.isEmpty {
            var found = false
            for (name, bit) in names {
                guard rest.lowercased().hasPrefix(name) else { continue }
                let tail = String(rest.dropFirst(name.count))
                // Do not treat words such as "commandline" or "alternate" as chords.
                if name.count > 1 && name != "fn", let first = tail.first, first != "+" && !first.isWhitespace { continue }
                modifiers |= bit; consumed = true; found = true
                rest = tail.trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("+") { rest.removeFirst(); rest = rest.trimmingCharacters(in: .whitespaces) }
                break
            }
            if !found { break }
        }
        guard !rest.isEmpty, rest.count <= 12, !rest.contains("+") || rest == "+" else { return nil }
        let key = normalizeKey(rest)
        let special = ["←", "→", "↑", "↓", "Space", "↩", "Tab", "Esc", "⌫", "⌦", "Home", "End", "PageUp", "PageDown"]
        let function = key.first == "F" && Int(key.dropFirst()).map { (1...20).contains($0) } == true
        guard key.count == 1 || function || special.contains(key) else { return nil }
        guard consumed || function else { return nil }
        return .init(key: key, modifiers: modifiers)
    }
}

public struct RadarUse: Hashable, Sendable {
    public enum Scope: String, Sendable { case global, application }
    public enum Evidence: String, Sendable { case registration, configuration, system, menu }
    public let chord: RadarChord
    public let appID: String
    public let appName: String
    public let action: String
    public let path: String
    public let scope: Scope
    public let evidence: Evidence
    public let searchText: String
    public init(chord: RadarChord, appID: String, appName: String, action: String, path: String,
                scope: Scope, evidence: Evidence) {
        self.chord = chord; self.appID = String(appID.prefix(256)); self.appName = String(appName.prefix(100))
        self.action = String(action.prefix(160)); self.path = String(path.prefix(320))
        self.scope = scope; self.evidence = evidence
        self.searchText = [self.appName, self.action, self.path, chord.displayName, chord.longName]
            .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    public var sourceLabel: String {
        switch evidence {
        case .registration: return "本应用已启用"
        case .configuration: return "本应用配置 · 未确认生效"
        case .system: return "系统登记 · 用途未公开"
        case .menu: return "应用菜单 · 仅当前上下文"
        }
    }
    public var isConfirmed: Bool { evidence == .registration || evidence == .system }
}

public struct RadarGroup: Sendable {
    public let chord: RadarChord
    public let uses: [RadarUse]
    public init(chord: RadarChord, uses: [RadarUse]) { self.chord = chord; self.uses = uses }
    public var hasGlobal: Bool { uses.contains { $0.scope == .global } }
    /// Multiple local commands in different apps are ordinary contextual reuse.
    public var isPotentialConflict: Bool {
        guard uses.count > 1 else { return false }
        return hasGlobal || Set(uses.map(\.appID)).count < uses.count
    }
    public var explanation: String {
        if uses.isEmpty { return "暂无已知用途 · 占用情况待核对" }
        if isPotentialConflict { return "发现重复用途 · 需结合生效场景核对" }
        if uses.count > 1 { return "分别在应用内生效 · 不直接视为冲突" }
        return hasGlobal ? "发现已知全局用途" : "在对应应用内使用"
    }
}

public enum RadarIndex {
    public enum Filter: Int, CaseIterable { case all, global, application }
    public static let maximumUses = 4_096
    public static func groups(_ entries: [RadarUse], query: String = "", filter: Filter = .all) -> [RadarGroup] {
        let unique = Set(entries.prefix(maximumUses))
        var grouped: [RadarChord: [RadarUse]] = [:]
        for use in unique { grouped[use.chord, default: []].append(use) }
        let prepared = grouped.map { chord, uses in
            RadarGroup(chord: chord, uses: uses.sorted {
                if $0.scope != $1.scope { return $0.scope == .global }
                return ($0.appName + $0.path + $0.action) < ($1.appName + $1.path + $1.action)
            })
        }
        return search(prepared, query: query, filter: filter)
    }
    /// Reuse a bounded prepared index while typing, without regrouping or
    /// Unicode-folding thousands of menu titles on every key event.
    public static func search(_ prepared: [RadarGroup], query: String, filter: Filter = .all) -> [RadarGroup] {
        let exact = RadarChord.parse(query)
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        return prepared.compactMap { group -> RadarGroup? in
            let chord = group.chord
            let selected = group.uses.filter { filter == .all || ($0.scope == .global ? filter == .global : filter == .application) }
            guard !selected.isEmpty else { return nil }
            if let exact { guard chord == exact else { return nil } }
            else if !words.isEmpty {
                // Search matches one real use, then shows every known use of that chord.
                guard selected.contains(where: { use in
                    words.allSatisfy { use.searchText.contains($0) }
                }) else { return nil }
            }
            return RadarGroup(chord: chord, uses: selected)
        }.sorted {
            if $0.uses.count != $1.uses.count { return $0.uses.count > $1.uses.count }
            if $0.isPotentialConflict != $1.isPotentialConflict { return $0.isPotentialConflict }
            if $0.hasGlobal != $1.hasGlobal { return $0.hasGlobal }
            return $0.chord.displayName < $1.chord.displayName
        }
    }
}
