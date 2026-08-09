import Foundation

/// Pure layout rules for the gauge cluster (unit-testable).
///
/// Hang-below hover tips sit **under** the cell. Any parent that clips to
/// `cellHeight` (notably `ScrollView` / `NSClipView`) will hide them — so tips
/// must be drawn outside the scroll clip, or clipping must be disabled.
enum IslandClusterLayout {
    static let defaultMaxVisible = 5
    static let defaultTipGap: Double = 8

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

    /// Viewport width in slots (never more than maxVisible).
    static func viewportSlotCount(slotCount: Int, maxVisible: Int = defaultMaxVisible) -> Int {
        min(max(slotCount, 0), maxVisible)
    }
}
