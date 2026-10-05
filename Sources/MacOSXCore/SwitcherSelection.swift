/// Selection is bound to a window identity, so async refreshes cannot switch the user's target.
public struct SwitcherSelection: Equatable {
    public private(set) var windowIDs: [UInt32]
    public private(set) var selectedIndex: Int
    public var selectedWindowID: UInt32? {
        windowIDs.isEmpty ? nil : windowIDs[selectedIndex]
    }

    public init(windowIDs: [UInt32] = [], initialOffset: Int = 0) {
        self.windowIDs = Self.unique(windowIDs)
        self.selectedIndex = 0
        move(by: initialOffset)
    }

    /// When the active app has no eligible window (e.g. desktop), choose the first
    /// available MRU window instead of accidentally skipping it.
    public init(windowIDs: [UInt32], focusedWindowID: UInt32?, reverse: Bool) {
        self.windowIDs = Self.unique(windowIDs)
        self.selectedIndex = 0
        if let focusedWindowID, let index = self.windowIDs.firstIndex(of: focusedWindowID) {
            self.selectedIndex = index
            move(by: reverse ? -1 : 1)
        } else if reverse, !self.windowIDs.isEmpty {
            self.selectedIndex = self.windowIDs.count - 1
        }
    }

    public mutating func move(by offset: Int) {
        guard !windowIDs.isEmpty else { return }
        let count = windowIDs.count
        selectedIndex = (selectedIndex + offset % count + count) % count
    }

    public mutating func select(windowID: UInt32) {
        guard let index = windowIDs.firstIndex(of: windowID) else { return }
        selectedIndex = index
    }

    public mutating func moveVertically(direction: Int, columns: Int) {
        guard !windowIDs.isEmpty, direction != 0 else { return }
        let columns = min(max(1, columns), windowIDs.count)
        let rows = (windowIDs.count + columns - 1) / columns
        let column = selectedIndex % columns
        var row = (selectedIndex / columns + direction.signum() + rows) % rows
        if row * columns + column >= windowIDs.count {
            row = direction > 0 ? 0 : max(0, rows - 2)
        }
        selectedIndex = row * columns + column
    }

    public mutating func replaceWindows(_ ids: [UInt32]) {
        let previous = selectedWindowID
        windowIDs = Self.unique(ids)
        if let previous, let index = windowIDs.firstIndex(of: previous) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(0, windowIDs.count - 1))
        }
    }

    private static func unique(_ ids: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        return ids.filter { seen.insert($0).inserted }
    }
}
