import SwiftUI

/// Island presentation. Compact = hairline rim around the physical notch.
/// Expanded width starts at notch width and grows with account count.
@MainActor
final class IslandModel: ObservableObject {
    enum State: Equatable {
        case compact
        case expanded
    }

    @Published private(set) var state: State = .compact
    @Published private(set) var notch: NotchInfo
    @Published private(set) var size: CGSize
    /// Visible account/widget slots driving expanded width (0…5).
    @Published private(set) var expandedItemCount: Int = 0

    /// Gauges + footer strip under the notch band.
    private let expandedContentHeight: CGFloat = 168
    private let tooltipOverflow: CGFloat = 72
    private let compactRimPad: CGFloat = 3

    static let cellSize: CGFloat = 100
    static let cellGap: CGFloat = 12
    static let horizontalPadding: CGFloat = 32
    static let maxItems: Int = 5
    static let compactTabWidth: CGFloat = CompactVendorMarks.tabWidth

    init(notch: NotchInfo = .detectPreferred()) {
        self.notch = notch
        self.size = Self.compactSize(for: notch, rimPad: 3, tabs: 0)
    }

    var blackHeight: CGFloat {
        switch state {
        case .compact: return notch.height
        case .expanded: return notch.height + expandedContentHeight
        }
    }

    var showsCompactTabs: Bool {
        expandedItemCount > 0 || ProcessInfo.processInfo.environment["DASHISLAND_DEMO"] == "1"
    }

    func setState(_ new: State) {
        guard new != state else { return }
        state = new
        recomputeSize()
    }

    func updateNotch(_ new: NotchInfo) {
        guard new != notch else { return }
        notch = new
        recomputeSize()
    }

    func setExpandedItemCount(_ count: Int) {
        let c = min(Self.maxItems, max(0, count))
        guard c != expandedItemCount else {
            // Still recompute compact tabs when count was already set but tabs flag changes.
            recomputeSize()
            return
        }
        expandedItemCount = c
        recomputeSize()
    }

    func recomputeSize() {
        if state == .compact {
            let tabs = showsCompactTabs ? Self.compactTabWidth * 2 : 0
            size = Self.compactSize(for: notch, rimPad: compactRimPad, tabs: tabs)
        } else {
            size = CGSize(
                width: Self.expandedWidth(notchWidth: notch.width, itemCount: expandedItemCount),
                height: notch.height + expandedContentHeight + tooltipOverflow
            )
        }
    }

    static func expandedWidth(notchWidth: CGFloat, itemCount: Int) -> CGFloat {
        let minW = max(notchWidth, 80)
        let n = min(maxItems, max(0, itemCount))
        guard n > 0 else { return minW }
        let content =
            CGFloat(n) * cellSize
            + CGFloat(n - 1) * cellGap
            + horizontalPadding
        return max(minW, content)
    }

    private static func compactSize(for notch: NotchInfo, rimPad: CGFloat, tabs: CGFloat) -> CGSize {
        CGSize(
            width: max(notch.width + rimPad * 2, 80) + tabs,
            height: notch.height + rimPad
        )
    }
}
