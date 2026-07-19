import SwiftUI

/// Flat top (screen edge) + continuous rounded bottom — mirrors the hardware notch.
struct IslandShape: InsettableShape {
    var inset: CGFloat = 0
    var bottomRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: 0
            ),
            style: .continuous
        ).path(in: r)
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var s = self
        s.inset += amount
        return s
    }
}
