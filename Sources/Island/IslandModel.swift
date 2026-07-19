import SwiftUI

/// Island presentation. Compact wraps the physical notch; expanded drops
/// gauges *below* the notch dead zone.
@MainActor
final class IslandModel: ObservableObject {
    enum State: Equatable {
        case compact
        case expanded
    }

    @Published private(set) var state: State = .compact
    @Published private(set) var notch: NotchInfo
    @Published private(set) var size: CGSize

    /// Black silhouette height in expanded mode = notch + content (no tooltip gutter).
    private let expandedContentHeight: CGFloat = 132
    /// Transparent window tail so tooltips can paint outside the black shape.
    private let tooltipOverflow: CGFloat = 72
    private let expandedWidth: CGFloat = 600

    init(notch: NotchInfo = .detectPreferred()) {
        self.notch = notch
        self.size = Self.compactSize(for: notch)
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

    func recomputeSize() {
        size = state == .compact
            ? Self.compactSize(for: notch)
            : CGSize(
                width: expandedWidth,
                height: notch.height + expandedContentHeight + tooltipOverflow
            )
    }

    /// Compact window hugs the notch; 2pt slack so the stroke can sit outside.
    private static func compactSize(for notch: NotchInfo) -> CGSize {
        CGSize(width: max(notch.width + 4, 120), height: notch.height + 3)
    }
}
