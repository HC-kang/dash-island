import SwiftUI

/// Island presentation. Compact = hairline rim around the physical notch.
/// Expanded content width floors at 3 slots; drawing size includes drag bleed.
///
/// **Window vs drawing size:** the NSWindow stays at `canvasSize` (max expanded
/// footprint). Hover expand/collapse only changes `size` (what we draw), never
/// the window frame — resizing the window is what made the notch walk sideways.
@MainActor
final class IslandModel: ObservableObject {
    enum State: Equatable {
        case compact
        case expanded
    }

    @Published private(set) var state: State = .compact
    @Published private(set) var notch: NotchInfo
    /// Drawn island footprint (compact pill or expanded panel + bleed).
    @Published private(set) var size: CGSize
    @Published private(set) var expandedItemCount: Int = 0
    /// Trailing add rail revealed by chevron hover (grows black body to the right).
    @Published private(set) var addRailOpen: Bool = false

    /// Fits `AccountWidget.cellHeight` (gauge + title + caption slot) under the notch.
    private let expandedContentHeight: CGFloat = 136
    /// Transparent buffer so lifted widgets + trash + hang-down tips render past the black body.
    /// Must clear long caption tooltips (~180pt) and the trash magnet.
    private let dragBleed: CGFloat = 220
    private let compactRimPad: CGFloat = 3

    static let cellSize: CGFloat = 100
    static let cellGap: CGFloat = 12
    /// Must match `IslandRootView.expandedContent` horizontal padding.
    static let contentPadLeading: CGFloat = 14
    static let contentPadTrailing: CGFloat = 14
    /// Trailing when add chevron is visible (root pad + AddRail outer pad).
    static let contentPadTrailingWithAdd: CGFloat = 4 + 6
    /// Hard cap on stored accounts (scroll when more than `maxVisibleSlots`).
    static let maxItems: Int = 8
    /// How many gauges fit in the island body at once; extra accounts scroll horizontally.
    static let maxVisibleSlots: Int = 5
    static let addChevronWidth: CGFloat = AddRail.chevronWidth
    static let addRailWidth: CGFloat = AddRail.railWidth

    init(notch: NotchInfo) {
        self.notch = notch
        self.size = Self.compactSize(for: notch, rimPad: 3)
    }

    var blackHeight: CGFloat {
        switch state {
        case .compact: return notch.height
        case .expanded: return notch.height + expandedContentHeight
        }
    }

    /// Black silhouette width (no bleed), including chevron + open add rail.
    var expandedContentWidth: CGFloat {
        Self.expandedWidth(
            notchWidth: notch.width,
            itemCount: expandedItemCount,
            canAdd: expandedItemCount < Self.maxItems,
            addRailOpen: addRailOpen
        )
    }

    /// Stable NSWindow size: always the maximum expanded footprint for this notch.
    /// Expand/collapse must not change this — only screen/notch geometry does.
    var canvasSize: CGSize {
        Self.canvasSize(for: notch, dragBleed: dragBleed, expandedContentHeight: expandedContentHeight)
    }

    /// Mouse hit / hover target — physical black body only.
    /// Excludes drag-bleed so the fixed canvas window does not steal nearby menu-bar clicks.
    /// Expanded adds a short strip under the body for downward tooltips.
    var hitSize: CGSize {
        switch state {
        case .compact:
            return CGSize(
                width: max(notch.width + compactRimPad * 2, 80),
                height: notch.height + compactRimPad
            )
        case .expanded:
            return CGSize(
                width: expandedContentWidth,
                height: blackHeight + Self.tooltipHitPad
            )
        }
    }

    /// Extra height under the expanded body so tip-down hover cards stay interactive.
    /// Long Claude auth copy needs ~160–200pt; keep headroom past the caret.
    static let tooltipHitPad: CGFloat = 200
    /// Transparent gutter left/right of the black body so hang tips stay *on*
    /// the hovered widget instead of sliding inward (first-cell clip).
    /// Caption cards are 288pt including padding; also leave room for shadows.
    static let tooltipHorizontalBleed = CGFloat(IslandClusterLayout.tooltipHorizontalBleed)

    func setState(_ new: State) {
        guard new != state else { return }
        state = new
        if new == .compact { addRailOpen = false }
        recomputeSize()
    }

    func updateNotch(_ new: NotchInfo) {
        guard new != notch else { return }
        notch = new
        recomputeSize()
    }

    func setExpandedItemCount(_ count: Int) {
        let c = min(Self.maxItems, max(0, count))
        guard c != expandedItemCount else { return }
        expandedItemCount = c
        if c >= Self.maxItems { addRailOpen = false }
        recomputeSize()
    }

    func setAddRailOpen(_ open: Bool) {
        let capped = open && expandedItemCount < Self.maxItems
        guard capped != addRailOpen else { return }
        addRailOpen = capped
        recomputeSize()
    }

    func recomputeSize() {
        if state == .compact {
            size = Self.compactSize(for: notch, rimPad: compactRimPad)
        } else {
            let contentW = expandedContentWidth
            size = CGSize(
                width: contentW + max(dragBleed, Self.tooltipHorizontalBleed) * 2,
                height: notch.height + expandedContentHeight + dragBleed
            )
        }
    }

    /// Floor at 3 slots; body grows through `maxVisibleSlots`, then scrolls inside.
    /// Width matches real chrome: content pads + slot row + optional add rail.
    static func expandedWidth(
        notchWidth: CGFloat,
        itemCount: Int,
        canAdd: Bool = false,
        addRailOpen: Bool = false
    ) -> CGFloat {
        let padTrailing = canAdd ? contentPadTrailingWithAdd : contentPadTrailing
        let addW = canAdd ? (addChevronWidth + (addRailOpen ? addRailWidth : 0)) : 0
        return CGFloat(
            IslandClusterLayout.islandBodyWidth(
                itemCount: itemCount,
                maxVisible: maxVisibleSlots,
                minSlots: 3,
                cell: Double(cellSize),
                gap: Double(cellGap),
                padLeading: Double(contentPadLeading),
                padTrailing: Double(padTrailing),
                addChrome: Double(addW),
                notchWidth: Double(notchWidth)
            )
        )
    }

    /// Row width for `count` cells (no outer padding).
    static func rowWidth(slotCount: Int) -> CGFloat {
        CGFloat(IslandClusterLayout.rowWidth(
            slotCount: slotCount,
            cell: Double(cellSize),
            gap: Double(cellGap)
        ))
    }

    static func canvasSize(
        for notch: NotchInfo,
        dragBleed: CGFloat = 220,
        expandedContentHeight: CGFloat = 136
    ) -> CGSize {
        // Canvas uses viewport width (max visible), not full scroll content.
        let contentW = expandedWidth(
            notchWidth: notch.width,
            itemCount: maxVisibleSlots,
            canAdd: true,
            addRailOpen: true
        )
        return CGSize(
            width: contentW + max(dragBleed, tooltipHorizontalBleed) * 2,
            height: notch.height + expandedContentHeight + dragBleed
        )
    }

    private static func compactSize(for notch: NotchInfo, rimPad: CGFloat) -> CGSize {
        CGSize(
            width: max(notch.width + rimPad * 2, 80),
            height: notch.height + rimPad
        )
    }
}
