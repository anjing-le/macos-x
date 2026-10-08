import Foundation
import CoreGraphics

public enum SwitcherPresentation: String, CaseIterable {
    case twoRows, all
}

/// Two-row pages or one bounded, scrollable document. Thumbnails stay viewport-only.
public struct SwitcherLayout: Equatable {
    public let presentation: SwitcherPresentation
    public let columns: Int
    public let capacity: Int
    public let cardSize: CGSize
    public let size: CGSize
    public let gap: CGFloat = 12
    public let margin: CGFloat = 16

    public init(windowCount: Int, available: CGSize, presentation: SwitcherPresentation = .twoRows) {
        self.presentation = presentation
        let availableWidth = available.width.isFinite ? max(180, min(4096, available.width - 64)) : 900
        let availableHeight = available.height.isFinite ? max(160, min(2160, available.height - 64)) : 600
        let preferredColumns = max(1, min(4, Int(availableWidth / 228)))
        columns = min(preferredColumns, max(1, windowCount))
        let width = max(80, min(216, (availableWidth - 32 - CGFloat(columns - 1) * 12) / CGFloat(columns), (availableHeight - 106) / 0.60))
        cardSize = CGSize(width: width, height: width * 0.60 + 40)
        let rows = max(1, min(presentation == .all ? 3 : 2, Int((availableHeight - 66 + 12) / (cardSize.height + 12))))
        capacity = presentation == .all ? min(256, max(1, windowCount)) : columns * rows
        let visibleCount = min(columns * rows, max(1, windowCount))
        let usedRows = (visibleCount + columns - 1) / columns
        size = CGSize(width: 32 + CGFloat(columns) * width + CGFloat(columns - 1) * 12,
                      height: (presentation == .all ? 50 : 66) + CGFloat(usedRows) * cardSize.height + CGFloat(usedRows - 1) * 12)
    }

    public func pageStart(selectedIndex: Int) -> Int { presentation == .all ? 0 : max(0, selectedIndex) / capacity * capacity }
    public func pageSize(visibleCount: Int) -> CGSize {
        let count = min(capacity, max(1, visibleCount))
        let usedColumns = min(columns, count)
        let rows = (count + columns - 1) / columns
        return CGSize(width: margin * 2 + CGFloat(usedColumns) * cardSize.width + CGFloat(usedColumns - 1) * gap,
                      height: (presentation == .all ? 50 : 66) + CGFloat(rows) * cardSize.height + CGFloat(rows - 1) * gap)
    }
    public func card(at index: Int) -> CGRect {
        CGRect(x: margin + CGFloat(index % columns) * (cardSize.width + gap),
               y: (presentation == .all ? 8 : margin) + CGFloat(index / columns) * (cardSize.height + gap),
               width: cardSize.width, height: cardSize.height)
    }
    public func visibleIndices(in viewport: CGRect, count: Int) -> [Int] {
        (0..<min(capacity, max(0, count))).filter {
            let overlap = card(at: $0).intersection(viewport)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }
}
