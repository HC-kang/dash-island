import SwiftUI

/// Island presentation. Compact = hairline rim around the physical notch.
/// Expanded = panel dropping below the notch dead zone.
@MainActor
final class IslandModel: ObservableObject {
    enum State: Equatable {
        case compact
        case expanded
    }

    @Published private(set) var state: State = .compact
    @Published private(set) var notch: NotchInfo
    @Published private(set) var size: CGSize

    private let expandedContentHeight: CGFloat = 132
    private let tooltipOverflow: CGFloat = 72
    private let expandedWidth: CGFloat = 600
    /// Room for rim outset + stroke so L/R flanks are not clipped.
    private let compactRimPad: CGFloat = 3

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

    func recomputeSize() {
        size = state == .compact
            ? Self.compactSize(for: notch, rimPad: compactRimPad)
            : CGSize(
                width: expandedWidth,
                height: notch.height + expandedContentHeight + tooltipOverflow
            )
    }

    private static func compactSize(for notch: NotchInfo, rimPad: CGFloat) -> CGSize {
        CGSize(
            width: max(notch.width + rimPad * 2, 80),
            height: notch.height + rimPad
        )
    }
}
