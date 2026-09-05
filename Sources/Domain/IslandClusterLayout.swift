import Foundation

/// Pure layout rules for the gauge cluster (unit-testable).
///
/// Hang-below hover tips sit **under** the cell. Any parent that clips to
/// `cellHeight` (notably `ScrollView` / `NSClipView`) will hide them — so tips
/// must be drawn outside the scroll clip, or clipping must be disabled.
enum IslandClusterLayout {
    static let defaultMaxVisible = 5
    static let defaultTipGap: Double = 8
    static let tooltipHorizontalBleed: Double = 180

    static func needsHorizontalScroll(
        slotCount: Int,
        maxVisible: Int = defaultMaxVisible
    ) -> Bool {
        slotCount > maxVisible
    }

    /// Y of the top edge of a hang-below tip in cell-local coordinates (0 = cell top).
    static func hangTipTopY(
        cellHeight: Double,
        tipGap: Double = defaultTipGap
    ) -> Double {
        cellHeight + tipGap
    }

    /// Whether a hang-below tip is outside a viewport that is only `cellHeight` tall.
    /// Returns true when the tip would be fully or partially clipped by that viewport
    /// if the parent clips subviews (ScrollView does).
    static func hangTipClippedByCellHeightViewport(
        cellHeight: Double,
        tipGap: Double = defaultTipGap
    ) -> Bool {
        hangTipTopY(cellHeight: cellHeight, tipGap: tipGap) >= cellHeight
    }

    /// Wide mask strip in body coordinates. Overlap clears the tip's caret,
    /// rounded corners and shadow above the island bottom without shifting X.
    static func hangTipMaskRect(
        bodyWidth: Double,
        blackHeight: Double,
        tooltipHeight: Double
    ) -> CGRect {
        let top = max(0, blackHeight - 28)
        return CGRect(
            x: -tooltipHorizontalBleed,
            y: top,
            width: bodyWidth + tooltipHorizontalBleed * 2,
            height: blackHeight + tooltipHeight - top
        )
    }

    /// Viewport width in slots (never more than maxVisible).
    static func viewportSlotCount(slotCount: Int, maxVisible: Int = defaultMaxVisible) -> Int {
        min(max(slotCount, 0), maxVisible)
    }

    /// Whether the slot row needs horizontal scroll given real pixel widths.
    static func needsScroll(contentWidth: Double, availableWidth: Double) -> Bool {
        contentWidth > availableWidth + 0.5
    }

    /// Centered row leading edge in a wider parent (or 0 when content is wider).
    static func centeredRowOrigin(contentWidth: Double, availableWidth: Double) -> Double {
        if contentWidth >= availableWidth { return 0 }
        return (availableWidth - contentWidth) / 2
    }

    /// Row width for `count` cells (no outer padding).
    static func rowWidth(slotCount: Int, cell: Double = 100, gap: Double = 12) -> Double {
        let n = max(0, slotCount)
        guard n > 0 else { return 0 }
        return Double(n) * cell + Double(n - 1) * gap
    }

    /// Black-body width: pads + viewport slots + optional add chrome.
    /// Viewport is capped at `maxVisible` so extra accounts scroll inside.
    static func islandBodyWidth(
        itemCount: Int,
        maxVisible: Int = defaultMaxVisible,
        minSlots: Int = 3,
        cell: Double = 100,
        gap: Double = 12,
        padLeading: Double = 14,
        padTrailing: Double = 14,
        addChrome: Double = 0,
        notchWidth: Double = 0
    ) -> Double {
        let n = min(maxVisible, max(minSlots, itemCount))
        let slots = rowWidth(slotCount: n, cell: cell, gap: gap)
        let content = padLeading + slots + padTrailing + addChrome
        return max(notchWidth, content)
    }

    /// Width left for the gauge band after outer pads + add chrome.
    static func slotBandWidth(
        bodyWidth: Double,
        padLeading: Double,
        padTrailing: Double,
        addChrome: Double
    ) -> Double {
        max(0, bodyWidth - padLeading - padTrailing - addChrome)
    }
}
