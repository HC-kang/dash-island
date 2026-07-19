import SwiftUI

/// Island presentation. Compact = hairline rim around the physical notch.
/// Expanded content width floors at 3 slots; window is larger by drag bleed.
@MainActor
final class IslandModel: ObservableObject {
    enum State: Equatable {
        case compact
        case expanded
    }

    @Published private(set) var state: State = .compact
    @Published private(set) var notch: NotchInfo
    @Published private(set) var size: CGSize
    @Published private(set) var expandedItemCount: Int = 0
    /// Trailing add rail revealed by chevron hover (grows black body to the right).
    @Published private(set) var addRailOpen: Bool = false

    private let expandedContentHeight: CGFloat = 124
    /// Transparent buffer so lifted widgets + trash can render past the black body.
    private let dragBleed: CGFloat = 112
    private let compactRimPad: CGFloat = 3

    static let cellSize: CGFloat = 100
    static let cellGap: CGFloat = 12
    static let horizontalPadding: CGFloat = 32
    static let maxItems: Int = 5
    static let addChevronWidth: CGFloat = AddRail.chevronWidth
    static let addRailWidth: CGFloat = AddRail.railWidth

    init(notch: NotchInfo = .detectPreferred()) {
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
                width: contentW + dragBleed * 2,
                height: notch.height + expandedContentHeight + dragBleed
            )
        }
    }

    /// Floor at the 3-slot layout; 4–5 grow. Optional trailing add chrome.
    static func expandedWidth(
        notchWidth: CGFloat,
        itemCount: Int,
        canAdd: Bool = false,
        addRailOpen: Bool = false
    ) -> CGFloat {
        let n = min(maxItems, max(3, itemCount))
        let content =
            CGFloat(n) * cellSize
            + CGFloat(n - 1) * cellGap
            + horizontalPadding
        let base = max(notchWidth, content)
        guard canAdd else { return base }
        // Chevron always when under cap; rail width only when revealed.
        let trailing = addChevronWidth + (addRailOpen ? addRailWidth : 0)
        return base + trailing
    }

    private static func compactSize(for notch: NotchInfo, rimPad: CGFloat) -> CGSize {
        CGSize(
            width: max(notch.width + rimPad * 2, 80),
            height: notch.height + rimPad
        )
    }
}
