import SwiftUI

/// Flush dual usage rings + outer speed ticks + red burn needle.
///
/// Geometry matches design brainstorm v5 (viewBox 96, center 48):
/// - Outer brand ring r≈31 stroke 5.5; inner cool steel r≈25 (flush).
/// - Speed ticks outside rings; rest 7:30 → cruise 1:00 → redline 4:30.
struct GaugeRingView: View {
    var primaryFraction: Double
    var secondaryFraction: Double?
    var centerPercent: Int
    var burnRatio: Double
    var tint: VendorTint
    var size: CGFloat = 96

    /// Drawn values (spring toward targets — Apple-quiet, not theatrical).
    @State private var drawnPrimary: Double = 0
    @State private var drawnSecondary: Double = 0
    @State private var drawnHasSecondary: Bool = false
    @State private var drawnBurn: Double = 0
    @State private var drawnPercent: Int = 0
    @State private var didAppear = false

    private var brand: Color { tint.brandColor }
    private var steel: Color { Color(red: 0.23, green: 0.40, blue: 0.50) } // ~#3a6580

    private static let settle = Animation.spring(response: 0.55, dampingFraction: 0.88)

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let scale = s / 96

                drawSpeedTrack(context: context, center: c, scale: scale)
                drawTicks(context: context, center: c, scale: scale)
                drawUsageRings(context: context, center: c, scale: scale)
                drawNeedle(context: context, center: c, scale: scale)
            }

            VStack(spacing: 1) {
                Text("\(drawnPercent)")
                    .font(.system(size: size * 0.177, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.96))
                    .tracking(-0.4)
                Text("%")
                    .font(.system(size: size * 0.083, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.36))
                    .tracking(0.6)
            }
            .offset(y: 1)
            .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(centerPercent) percent")
        .onAppear {
            applyTargets(animated: false)
            didAppear = true
        }
        .onChange(of: primaryFraction) { _ in applyTargets(animated: didAppear) }
        .onChange(of: secondaryFraction ?? -1) { _ in applyTargets(animated: didAppear) }
        .onChange(of: burnRatio) { _ in applyTargets(animated: didAppear) }
        .onChange(of: centerPercent) { _ in applyTargets(animated: didAppear) }
    }

    private func applyTargets(animated: Bool) {
        let update = {
            drawnPrimary = primaryFraction
            drawnSecondary = secondaryFraction ?? 0
            drawnHasSecondary = secondaryFraction != nil
            drawnBurn = burnRatio
            drawnPercent = centerPercent
        }
        if animated {
            withAnimation(Self.settle, update)
        } else {
            update()
        }
    }

    // MARK: - Drawing

    private func drawSpeedTrack(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        let r: CGFloat = 42 * scale
        // Arc rest (7:30) → redline (4:30) the long way (270° clockwise).
        var path = Path()
        path.addArc(
            center: center,
            radius: r,
            startAngle: .degrees(135),
            endAngle: .degrees(45),
            clockwise: false // screen y-down: false = clockwise visually
        )
        context.stroke(
            path,
            with: .color(Color.white.opacity(0.08)),
            style: StrokeStyle(lineWidth: 0.9 * scale, lineCap: .round)
        )
    }

    private func drawTicks(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        let innerR: CGFloat = 40 * scale
        let outerR: CGFloat = 44 * scale
        let majorOuterR: CGFloat = 44.5 * scale

        // Quiet ticks along rest → cruise (7:30, 9, 10:30, 12).
        let quietAngles: [Double] = [135, 180, 225, 270]
        for deg in quietAngles {
            strokeTick(
                context: context,
                center: center,
                angleDeg: deg,
                innerR: innerR,
                outerR: outerR,
                color: Color.white.opacity(0.34),
                width: 1.05 * scale
            )
        }

        // Cruise pip (~1 o'clock).
        let cruise: Double = 300 // 1:00
        strokeTick(
            context: context,
            center: center,
            angleDeg: cruise,
            innerR: innerR,
            outerR: majorOuterR,
            color: Color.white.opacity(0.52),
            width: 1.15 * scale
        )
        let pip = point(center: center, angleDeg: cruise, radius: majorOuterR + 1.2 * scale)
        let pipRect = CGRect(x: pip.x - 1.55 * scale, y: pip.y - 1.55 * scale,
                             width: 3.1 * scale, height: 3.1 * scale)
        context.fill(Path(ellipseIn: pipRect), with: .color(Color.white.opacity(0.52)))

        // Redline ticks (3, 4, 4:30).
        let redAngles: [Double] = [0, 30, 45]
        for deg in redAngles {
            strokeTick(
                context: context,
                center: center,
                angleDeg: deg,
                innerR: innerR,
                outerR: outerR,
                color: Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.38), // #f87171
                width: 1.05 * scale
            )
        }
    }

    private func drawUsageRings(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        let stroke: CGFloat = 5.5 * scale
        // Flush: outer centerline = inner centerline + stroke.
        let outerR: CGFloat = 31 * scale
        let innerR: CGFloat = 25 * scale

        // Track underlays.
        strokeRing(context: context, center: center, radius: outerR, fraction: 1,
                   color: Color.white.opacity(0.07), lineWidth: stroke)
        if drawnHasSecondary {
            strokeRing(context: context, center: center, radius: innerR, fraction: 1,
                       color: Color.white.opacity(0.045), lineWidth: stroke)
        }

        // Outer brand (primary).
        let p = clamped(drawnPrimary)
        if p > 0.0005 {
            var ctx = context
            ctx.addFilter(.shadow(color: brand.opacity(0.35), radius: 2 * scale, x: 0, y: 0))
            strokeRing(context: ctx, center: center, radius: outerR, fraction: p,
                       color: brand, lineWidth: stroke)
        }

        // Inner cool steel (secondary).
        if drawnHasSecondary {
            let s = clamped(drawnSecondary)
            if s > 0.0005 {
                strokeRing(context: context, center: center, radius: innerR, fraction: s,
                           color: steel, lineWidth: stroke)
            }
        }
    }

    private func drawNeedle(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        let unit = BurnRate.needleUnit(ratio: drawnBurn)
        let angle = Self.needleAngleDegrees(unit: unit)
        let tipR: CGFloat = 38 * scale
        let tip = point(center: center, angleDeg: angle, radius: tipR)
        let red = Color(red: 0.937, green: 0.267, blue: 0.267) // #ef4444

        var path = Path()
        path.move(to: center)
        path.addLine(to: tip)

        var glow = context
        glow.addFilter(.shadow(color: red.opacity(0.55), radius: 2.2 * scale, x: 0, y: 0))
        glow.stroke(
            path,
            with: .color(red),
            style: StrokeStyle(lineWidth: 1.35 * scale, lineCap: .round)
        )

        // Hub.
        let hubR: CGFloat = 2.25 * scale
        let hubRect = CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2)
        context.fill(Path(ellipseIn: hubRect), with: .color(red))
        let coreR: CGFloat = 0.95 * scale
        let coreRect = CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)
        context.fill(Path(ellipseIn: coreRect), with: .color(Color(red: 0.10, green: 0.02, blue: 0.02)))
    }

    // MARK: - Helpers

    /// Piecewise map of needle unit 0...1 → screen degrees (0 = east, CW via y-down sin/cos).
    /// unit 0 → 7:30 (135°), unit 0.5 → 1:00 (300°), unit 1 → 4:30 (45°).
    static func needleAngleDegrees(unit: Double) -> Double {
        let u = min(1, max(0, unit))
        if u <= 0.5 {
            let t = u / 0.5
            return 135 + t * 165 // 135 → 300
        } else {
            let t = (u - 0.5) / 0.5
            return 300 + t * 105 // 300 → 405 ≡ 45
        }
    }

    private func strokeRing(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        fraction: Double,
        color: Color,
        lineWidth: CGFloat
    ) {
        let f = clamped(fraction)
        guard f > 0 else { return }
        // Start at 12 o'clock, sweep clockwise (screen: start -90°, clockwise = false in addArc? ).
        // SwiftUI Path.addArc clockwise:true goes counter-clockwise on screen with y-down.
        // We want clockwise from 12 o'clock: start -90°, end -90° + 360*f, clockwise: false.
        var path = Path()
        let start = Angle.degrees(-90)
        let end = Angle.degrees(-90 + 360 * f)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
        )
    }

    private func strokeTick(
        context: GraphicsContext,
        center: CGPoint,
        angleDeg: Double,
        innerR: CGFloat,
        outerR: CGFloat,
        color: Color,
        width: CGFloat
    ) {
        var path = Path()
        path.move(to: point(center: center, angleDeg: angleDeg, radius: innerR))
        path.addLine(to: point(center: center, angleDeg: angleDeg, radius: outerR))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func point(center: CGPoint, angleDeg: Double, radius: CGFloat) -> CGPoint {
        let rad = angleDeg * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(rad)),
            y: center.y + radius * CGFloat(sin(rad))
        )
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

// MARK: - Tint → brand color

extension VendorTint {
    /// Brand hue for outer usage ring + decorative marks.
    var brandColor: Color {
        switch self {
        case .claude: return IslandColor.claude
        case .codex: return IslandColor.codex
        case .grok: return IslandColor.grok
        case .neutral: return Color(red: 0.75, green: 0.72, blue: 0.68)
        }
    }
}
