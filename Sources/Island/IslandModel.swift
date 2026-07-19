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

    /// Gauge row only (chrome sits in the notch band, not a bottom footer).
    private let expandedContentHeight: CGFloat = 124
    private let tooltipOverflow: CGFloat = 72
    private let compactRimPad: CGFloat = 3

    static let cellSize: CGFloat = 100
    static let cellGap: CGFloat = 12
    static let horizontalPadding: CGFloat = 32
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

    func setExpandedItemCount(_ count: Int) {
        let c = min(Self.maxItems, max(0, count))
        guard c != expandedItemCount else { return }
        expandedItemCount = c
        recomputeSize()
    }

    func recomputeSize() {
        if state == .compact {
            size = Self.compactSize(for: notch, rimPad: compactRimPad)
        } else {
            size = CGSize(
                width: Self.expandedWidth(notchWidth: notch.width, itemCount: expandedItemCount),
                height: notch.height + expandedContentHeight + tooltipOverflow
            )
        }
    }

    /// Floor at the 3-slot layout (not the bare notch — one cell looked too thin).
    /// 0…3 items share that width; 4–5 grow from there.
    static func expandedWidth(notchWidth: CGFloat, itemCount: Int) -> CGFloat {
        let n = min(maxItems, max(3, itemCount))
        let content =
            CGFloat(n) * cellSize
            + CGFloat(n - 1) * cellGap
            + horizontalPadding
        // Never narrower than the hardware notch either (ultra-wide notches).
        return max(notchWidth, content)
    }

    private static func compactSize(for notch: NotchInfo, rimPad: CGFloat) -> CGSize {
        CGSize(
            width: max(notch.width + rimPad * 2, 80),
            height: notch.height + rimPad
        )
    }
}
