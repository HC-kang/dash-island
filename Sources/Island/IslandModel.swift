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
    /// Window occluded or displays asleep, and Low Power Mode — both pause decoration.
    @Published private(set) var windowHidden = false
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Non-notch display in a full-screen space: draw no compact handle, take no hits.
    @Published private(set) var compactHidden = false

    // Pure geometry lives in `IslandGeometry` (unit-tested).
    static let cellSize: CGFloat = IslandGeometry.cellSize
    static let cellGap: CGFloat = IslandGeometry.cellGap
    /// Hard cap on stored accounts (scroll when more than `maxVisibleSlots`).
    static let maxItems: Int = AccountStore.maxAccounts
    /// How many gauges fit in the island body at once; extra accounts scroll horizontally.
    static let maxVisibleSlots: Int = IslandGeometry.maxVisibleSlots

    init(notch: NotchInfo) {
        self.notch = notch
        self.size = Self.compactSize(for: notch)
    }

    var blackHeight: CGFloat {
        switch state {
        case .compact: return notch.height
        case .expanded: return notch.height + IslandGeometry.expandedContentHeight
        }
    }

    /// Black silhouette width (no bleed), including chevron + open add rail.
    var expandedContentWidth: CGFloat {
        IslandGeometry.expandedWidth(
            notchWidth: notch.width,
            itemCount: expandedItemCount,
            canAdd: expandedItemCount < Self.maxItems,
            addRailOpen: addRailOpen
        )
    }

    /// Stable NSWindow size: always the maximum expanded footprint for this notch.
    /// Expand/collapse must not change this — only screen/notch geometry does.
    var canvasSize: CGSize {
        IslandGeometry.canvasSize(notchWidth: notch.width, notchHeight: notch.height)
    }

    /// Mouse hit / hover target — physical black body only.
    /// Excludes drag-bleed so the fixed canvas window does not steal nearby menu-bar clicks.
    /// Expanded adds a short strip under the body for downward tooltips.
    var hitSize: CGSize {
        IslandGeometry.hitSize(
            expanded: state == .expanded,
            compactHidden: compactHidden,
            compact: Self.compactSize(for: notch),
            bodyWidth: expandedContentWidth,
            notchHeight: notch.height
        )
    }

    /// Drawing space only. Tooltips must not enlarge the mouse retention area.
    static let tooltipHitPad: CGFloat = 200

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

    func setWindowHidden(_ hidden: Bool) {
        if hidden != windowHidden { windowHidden = hidden }
    }

    func setLowPower(_ on: Bool) {
        if on != lowPower { lowPower = on }
    }

    func setCompactHidden(_ hidden: Bool) {
        if hidden != compactHidden { compactHidden = hidden }
    }

    func recomputeSize() {
        if state == .compact {
            size = Self.compactSize(for: notch)
        } else {
            size = IslandGeometry.expandedSize(bodyWidth: expandedContentWidth, notchHeight: notch.height)
        }
    }

    /// Row width for `count` cells (no outer padding).
    static func rowWidth(slotCount: Int) -> CGFloat {
        CGFloat(IslandClusterLayout.rowWidth(
            slotCount: slotCount,
            cell: Double(cellSize),
            gap: Double(cellGap)
        ))
    }

    private static func compactSize(for notch: NotchInfo) -> CGSize {
        IslandGeometry.compactSize(notchWidth: notch.width, notchHeight: notch.height, hasNotch: notch.hasNotch)
    }
}
