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

    private let expandedContentHeight: CGFloat = 132
    private let tooltipOverflow: CGFloat = 72
    private let compactRimPad: CGFloat = 3

    // Layout constants — keep in sync with AccountWidget / GaugeClusterView.
    static let cellSize: CGFloat = 100
    static let cellGap: CGFloat = 12
    static let horizontalPadding: CGFloat = 32 // 16pt each side
    static let maxItems: Int = 5

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

    /// Call when the number of visible widgets / empty state changes.
    func setExpandedItemCount(_ count: Int) {
        let c = min(Self.maxItems, max(0, count))
        guard c != expandedItemCount else { return }
        expandedItemCount = c
        recomputeSize()
    }

    func recomputeSize() {
        size = state == .compact
            ? Self.compactSize(for: notch, rimPad: compactRimPad)
            : CGSize(
                width: Self.expandedWidth(notchWidth: notch.width, itemCount: expandedItemCount),
                height: notch.height + expandedContentHeight + tooltipOverflow
            )
    }

    /// Minimum = hardware notch width. Grows per added account cell.
    ///
    /// - 0 items (empty +): notch width
    /// - n items: `max(notch, n×cell + (n−1)×gap + horizontal padding)`
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

    private static func compactSize(for notch: NotchInfo, rimPad: CGFloat) -> CGSize {
        CGSize(
            width: max(notch.width + rimPad * 2, 80),
            height: notch.height + rimPad
        )
    }
}
