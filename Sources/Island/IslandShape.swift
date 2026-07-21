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

/// Open U: full-height left flank + bottom curve + full-height right flank.
/// Drawn in a rect that is slightly larger than the black fill so the rim
/// sits *outside* the hardware notch and stays visible against the menu bar.
struct NotchRimPath: Shape {
    var bottomRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX
        let x1 = rect.maxX
        let y0 = rect.minY
        let y1 = rect.maxY
        let r = min(bottomRadius, (y1 - y0) * 0.48, (x1 - x0) * 0.22)

        var p = Path()
        p.move(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x0, y: y1 - r))
        p.addQuadCurve(
            to: CGPoint(x: x0 + r, y: y1),
            control: CGPoint(x: x0, y: y1)
        )
        p.addLine(to: CGPoint(x: x1 - r, y: y1))
        p.addQuadCurve(
            to: CGPoint(x: x1, y: y1 - r),
            control: CGPoint(x: x1, y: y1)
        )
        p.addLine(to: CGPoint(x: x1, y: y0))
        return p
    }
}
