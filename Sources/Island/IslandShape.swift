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

/// Open U path along the notch edge only (no top edge). Used for the hairline rim.
struct NotchRimPath: Shape {
    var bottomRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height * 0.5, rect.width * 0.25)
        var p = Path()
        // Start at top-left (screen edge), run down, around the bottom U, up to top-right.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}
