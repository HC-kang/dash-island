import SwiftUI

/// Island presentation. Compact = hairline rim on the physical notch.
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
    /// Half-stroke slack so the rim hairline is not clipped by the window.
    private let compactStrokePad: CGFloat = 1.5

    init(notch: NotchInfo = .detectPreferred()) {
        self.notch = notch
        self.size = Self.compactSize(for: notch, strokePad: 1.5)
    }

    /// Height of solid black (notch only when compact; notch+panel when expanded).
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
            ? Self.compactSize(for: notch, strokePad: compactStrokePad)
            : CGSize(
                width: expandedWidth,
                height: notch.height + expandedContentHeight + tooltipOverflow
            )
    }

    private static func compactSize(for notch: NotchInfo, strokePad: CGFloat) -> CGSize {
        // Exact notch + tiny pad so a 1pt rim is not clipped.
        CGSize(
            width: max(notch.width + strokePad * 2, 80),
            height: notch.height + strokePad
        )
    }
}
