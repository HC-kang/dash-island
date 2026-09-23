import Foundation

/// Pure island geometry (unit-testable). `IslandModel` and `NotchInfo` delegate here.
///
/// Two past regressions live in these numbers:
/// - The NSWindow is a fixed canvas that holds every expanded footprint, so
///   expand/collapse never resizes it (lateral drift).
/// - Hover hit covers the black body only, never drag bleed (hover hit tightened).
enum IslandGeometry {
    static let cellSize: CGFloat = 100
    static let cellGap: CGFloat = 12
    static let contentPadLeading: CGFloat = 14
    static let contentPadTrailing: CGFloat = 14
    /// Trailing when the add chevron is visible (root pad + AddRail outer pad).
    static let contentPadTrailingWithAdd: CGFloat = 4 + 6
    /// Gauges that fit the body at once; extra accounts scroll horizontally.
    static let maxVisibleSlots = 5
    static let minSlots = 3
    static let addChevronWidth: CGFloat = 16
    /// ~⅓ of a slot — narrow dashed add pocket.
    static let addRailWidth: CGFloat = 36
    /// Fits the gauge cell (gauge + title + caption slot) under the notch band.
    static let expandedContentHeight: CGFloat = 136
    /// Transparent buffer so lifted widgets, trash and hang-down tips draw past the body.
    static let dragBleed: CGFloat = 220
    static let compactRimPad: CGFloat = 3
    static let compactMinWidth: CGFloat = 80
    /// Strip under the expanded body that keeps hover while reaching a tip.
    static let expandedHitPad: CGFloat = 20
    /// Non-notch displays: a thin top-edge handle instead of a fake notch, so the
    /// compact island leaves the menu bar center clickable.
    static let handleSize = CGSize(width: 64, height: 4)

    static func menuBarHeight(
        safeTop: CGFloat,
        visibleFrameDelta: CGFloat,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        let fromVisibleFrame = visibleFrameDelta - 1
        if fromVisibleFrame > 0 {
            return safeTop > 0 ? min(fromVisibleFrame, safeTop) : fromVisibleFrame
        }
        if safeTop > 0 { return safeTop }
        return statusBarThickness > 0 ? statusBarThickness : 24
    }

    /// Black-body width: floor at 3 slots, grows through `maxVisibleSlots`, then scrolls.
    static func expandedWidth(
        notchWidth: CGFloat,
        itemCount: Int,
        canAdd: Bool = false,
        addRailOpen: Bool = false
    ) -> CGFloat {
        let padTrailing = canAdd ? contentPadTrailingWithAdd : contentPadTrailing
        let addW = canAdd ? (addChevronWidth + (addRailOpen ? addRailWidth : 0)) : 0
        return CGFloat(IslandClusterLayout.islandBodyWidth(
            itemCount: itemCount,
            maxVisible: maxVisibleSlots,
            minSlots: minSlots,
            cell: Double(cellSize),
            gap: Double(cellGap),
            padLeading: Double(contentPadLeading),
            padTrailing: Double(padTrailing),
            addChrome: Double(addW),
            notchWidth: Double(notchWidth)
        ))
    }

    /// Drawn expanded footprint: black body plus bleed on both sides and below.
    static func expandedSize(bodyWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: bodyWidth + dragBleed * 2,
            height: notchHeight + expandedContentHeight + dragBleed
        )
    }

    /// Stable window size: the widest expanded footprint (5 slots + open add rail).
    static func canvasSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        let widest = expandedWidth(
            notchWidth: notchWidth,
            itemCount: maxVisibleSlots,
            canAdd: true,
            addRailOpen: true
        )
        return expandedSize(bodyWidth: widest, notchHeight: notchHeight)
    }

    /// Drawn compact footprint: notch pill, or the thin handle without a notch.
    static func compactSize(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) -> CGSize {
        guard hasNotch else {
            return CGSize(
                width: handleSize.width + compactRimPad * 2,
                height: handleSize.height + compactRimPad
            )
        }
        return CGSize(
            width: max(notchWidth + compactRimPad * 2, compactMinWidth),
            height: notchHeight + compactRimPad
        )
    }

    /// Mouse hit: the compact footprint (none while hidden), or the expanded black
    /// body plus a short tip strip. Never the bleed — that would steal menu-bar clicks.
    static func hitSize(
        expanded: Bool,
        compactHidden: Bool,
        compact: CGSize,
        bodyWidth: CGFloat,
        notchHeight: CGFloat
    ) -> CGSize {
        guard expanded else { return compactHidden ? .zero : compact }
        return CGSize(
            width: bodyWidth,
            height: notchHeight + expandedContentHeight + expandedHitPad
        )
    }

    /// A full-screen space covers the whole display with one ordinary window.
    /// `windowBounds`: CGWindowList bounds of layer-0 windows (global, top-left origin);
    /// `screenFrame`: Cocoa frame (bottom-left origin of the primary display).
    static func hasFullScreenWindow(
        screenFrame: CGRect,
        primaryScreenHeight: CGFloat,
        windowBounds: [CGRect]
    ) -> Bool {
        let target = CGRect(
            x: screenFrame.minX,
            y: primaryScreenHeight - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        )
        return windowBounds.contains {
            abs($0.minX - target.minX) < 1 && abs($0.minY - target.minY) < 1
                && abs($0.width - target.width) < 1 && abs($0.height - target.height) < 1
        }
    }
}
