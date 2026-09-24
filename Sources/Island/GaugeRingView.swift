import SwiftUI

/// Flush dual usage rings + outer speed ticks + red burn needle.
///
/// Geometry matches design brainstorm v5 (viewBox 96, center 48):
/// - Outer brand ring r≈31 stroke 5.5; inner cool steel r≈25 (flush).
/// - Speed ticks outside rings; rest 7:30 → cruise 1:00 → redline 4:30.
///
/// Burn motion (Apple-instrument language via `BurnMotion`):
/// quiet at rest → soft trail + micro-wobble at cruise → warm bloom past cruise.
/// No strobe, bounce, or rainbow — continuous energy only.
struct GaugeRingView: View {
    var primaryFraction: Double
    /// Estimated end of the primary ring between API samples. Drawn as a faint,
    /// hollow extension so an estimate never reads as a vendor measurement.
    var projectedPrimaryFraction: Double? = nil
    var secondaryFraction: Double?
    /// Optional third concentric ring (Fable / Codex model limit).
    var tertiaryFraction: Double? = nil
    var centerPercent: Int
    var burnRatio: Double
    var tint: VendorTint
    var size: CGFloat = 96
    /// Desyncs Timeline breath/jitter across widgets (≥0.2s).
    var phaseOffset: TimeInterval = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandMotion) private var islandMotion

    private var brand: Color { tint.brandColor }
    private var steel: Color { Color(red: 0.23, green: 0.40, blue: 0.50) } // ~#3a6580
    /// Innermost scoped ring (Fable / Spark) — warm amber, distinct from brand + steel.
    private var amber: Color { Color(red: 0.92, green: 0.68, blue: 0.28) }
    private static let burnRed = Color(red: 0.937, green: 0.267, blue: 0.267) // #ef4444
    private static let restNeedle = Color(white: 0.62)
    private static let burnSoft = Color(red: 0.97, green: 0.44, blue: 0.42)

    /// Breath / jitter frames; `nil` = one static frame (rest, Reduce Motion, hidden, Low Power).
    private var frameInterval: TimeInterval? {
        var motion = islandMotion
        motion.reduceMotion = motion.reduceMotion || reduceMotion
        return MotionPolicy.gaugeFrameInterval(motion, burnRatio: burnRatio)
    }

    var body: some View {
        // Draw the current inputs directly. Canvas is not Animatable: the old
        // "drawn" springs never interpolated — they only blanked the rings for
        // 80ms on every expand, then snapped (measured 2026-09-23).
        let rings = DrawnRings(
            primary: primaryFraction,
            projected: projectedPrimaryFraction,
            secondary: secondaryFraction,
            tertiary: tertiaryFraction
        )
        Group {
            if let frameInterval {
                TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
                    dial(rings: rings, date: timeline.date)
                }
            } else {
                dial(rings: rings, date: nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(centerPercent) percent")
    }

    /// `date == nil`: still frame — no jitter, bloom at mid-breath.
    private func dial(rings: DrawnRings, date: Date?) -> some View {
        ZStack {
            Canvas { context, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let scale = s / 96

                drawAmbientBloom(context: context, center: c, scale: scale, date: date)
                drawSpeedTrack(context: context, center: c, scale: scale)
                drawEnergyTrail(context: context, center: c, scale: scale)
                drawTicks(context: context, center: c, scale: scale)
                drawUsageRings(context: context, center: c, scale: scale, rings: rings)
                drawNeedle(context: context, center: c, scale: scale, date: date)
            }

            VStack(spacing: 1) {
                Text("\(centerPercent)")
                    .font(.system(size: size * 0.177, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.96))
                    .tracking(-0.4)
                Text("%")
                    .font(.system(size: size * 0.11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .tracking(0.6)
            }
            .offset(y: 1)
            .allowsHitTesting(false)
        }
    }

    private struct DrawnRings: Equatable {
        var primary: Double
        var projected: Double?
        var secondary: Double?
        var tertiary: Double?
    }

    // MARK: - Drawing

    /// Warm center haze past light activity — breath modulates, never blinks off.
    private func drawAmbientBloom(
        context: GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        date: Date?
    ) {
        let base = BurnMotion.bloomOpacity(ratio: burnRatio)
        guard base > 0.004 else { return }
        let breath = date.map { BurnMotion.breath(at: $0, ratio: burnRatio, phaseOffset: phaseOffset) } ?? 0.85
        let op = base * breath
        let r: CGFloat = (22 + BurnMotion.overdrive(ratio: burnRatio) * 6) * scale
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        var ctx = context
        // Blur only past cruise — rest/cruise stay cheap hairline chrome.
        if BurnMotion.energy(ratio: burnRatio) >= 0.35 {
            ctx.addFilter(.blur(radius: 6 * scale))
        }
        ctx.fill(
            Path(ellipseIn: rect),
            with: .color(Self.burnSoft.opacity(op))
        )
    }

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

        // Active sector highlight: rest → current needle base (no jitter).
        let highlight = BurnMotion.trackHighlightOpacity(ratio: burnRatio)
        guard highlight > 0.01 else { return }
        let unit = BurnRate.needleUnit(ratio: burnRatio)
        let endDeg = Self.needleAngleDegrees(unit: unit)
        var lit = Path()
        lit.addArc(
            center: center,
            radius: r,
            startAngle: .degrees(135),
            endAngle: .degrees(endDeg),
            clockwise: false
        )
        context.stroke(
            lit,
            with: .color(Self.burnSoft.opacity(highlight)),
            style: StrokeStyle(lineWidth: 1.15 * scale, lineCap: .round)
        )
    }

    /// Soft fan under the needle from rest → tip — reads as swept energy, not a progress bar.
    private func drawEnergyTrail(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        let op = BurnMotion.trailOpacity(ratio: burnRatio)
        guard op > 0.01 else { return }
        let unit = BurnRate.needleUnit(ratio: burnRatio)
        let endDeg = Self.needleAngleDegrees(unit: unit)
        // Don't draw a full loop artifact when near rest.
        guard unit > 0.02 else { return }

        let innerR: CGFloat = 34 * scale
        let outerR: CGFloat = 41 * scale

        var ring = Path()
        ring.addArc(
            center: center,
            radius: (innerR + outerR) / 2,
            startAngle: .degrees(135),
            endAngle: .degrees(endDeg),
            clockwise: false
        )

        let outer = context
        outer.stroke(
            ring,
            with: .color(Self.burnSoft.opacity(BurnMotion.trailOuterOpacity(ratio: burnRatio))),
            style: StrokeStyle(lineWidth: (outerR - innerR) * 0.85, lineCap: .round)
        )

        var core = context
        core.addFilter(.blur(radius: 0.8 * scale))
        core.stroke(
            ring,
            with: .color(Self.burnRed.opacity(op)),
            style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round)
        )
    }

    private func drawTicks(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        let innerR: CGFloat = 40 * scale
        let outerR: CGFloat = 44 * scale
        let majorOuterR: CGFloat = 44.5 * scale
        let e = BurnMotion.energy(ratio: burnRatio)

        // Quiet ticks along rest → cruise (7:30, 9, 10:30, 12).
        let quietAngles: [Double] = [135, 180, 225, 270]
        for deg in quietAngles {
            strokeTick(
                context: context,
                center: center,
                angleDeg: deg,
                innerR: innerR,
                outerR: outerR,
                color: Color.white.opacity(0.34 + e * 0.06),
                width: 1.05 * scale
            )
        }

        // Cruise pip (~1 o'clock) — brightens when near cruise pace.
        let cruise: Double = 300 // 1:00
        let pipBoost = BurnMotion.cruisePipBoost(ratio: burnRatio)
        let pipOp = 0.52 + pipBoost
        strokeTick(
            context: context,
            center: center,
            angleDeg: cruise,
            innerR: innerR,
            outerR: majorOuterR,
            color: Color.white.opacity(pipOp),
            width: 1.15 * scale
        )
        let pip = point(center: center, angleDeg: cruise, radius: majorOuterR + 1.2 * scale)
        let pipR: CGFloat = (1.55 + pipBoost * 0.35) * scale
        let pipRect = CGRect(x: pip.x - pipR, y: pip.y - pipR, width: pipR * 2, height: pipR * 2)
        context.fill(Path(ellipseIn: pipRect), with: .color(Color.white.opacity(pipOp)))
        if pipBoost > 0.05 {
            var glow = context
            glow.addFilter(.blur(radius: 1.2 * scale))
            let gR = pipR * 1.8
            let gRect = CGRect(x: pip.x - gR, y: pip.y - gR, width: gR * 2, height: gR * 2)
            glow.fill(Path(ellipseIn: gRect), with: .color(Color.white.opacity(pipBoost * 0.35)))
        }

        // Redline ticks (3, 4, 4:30) — slightly more present in overdrive.
        let od = BurnMotion.overdrive(ratio: burnRatio)
        let redAngles: [Double] = [0, 30, 45]
        for deg in redAngles {
            strokeTick(
                context: context,
                center: center,
                angleDeg: deg,
                innerR: innerR,
                outerR: outerR,
                color: Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.38 + od * 0.18),
                width: 1.05 * scale
            )
        }
    }

    private func drawUsageRings(
        context: GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        rings: DrawnRings
    ) {
        // Triple-ring geometry: outer brand · mid steel · inner amber (scoped).
        // Slightly tighter stroke when tertiary is present so the core stays readable.
        let triple = (rings.tertiary != nil)
        let stroke: CGFloat = (triple ? 4.6 : 5.5) * scale
        let outerR: CGFloat = (triple ? 32 : 31) * scale
        let midR: CGFloat = (triple ? 26.5 : 25) * scale
        let coreR: CGFloat = 21 * scale
        let glowBoost = BurnMotion.brandRingGlowBoost(ratio: burnRatio)

        // Track underlays (tertiary uses amber ghost so 0% Fable/Spark still reads).
        strokeRing(context: context, center: center, radius: outerR, fraction: 1,
                   color: Color.white.opacity(0.07), lineWidth: stroke)
        if (rings.secondary != nil) {
            strokeRing(context: context, center: center, radius: midR, fraction: 1,
                       color: Color.white.opacity(0.045), lineWidth: stroke)
        }
        if (rings.tertiary != nil) {
            strokeRing(context: context, center: center, radius: coreR, fraction: 1,
                       color: amber.opacity(0.22), lineWidth: stroke)
        }

        // Outer brand (primary — 5h / main window).
        let p = clamped(rings.primary)
        if p > 0.0005 {
            var ctx = context
            ctx.addFilter(.shadow(
                color: brand.opacity(0.35 + glowBoost),
                radius: (2 + glowBoost * 4) * scale,
                x: 0,
                y: 0
            ))
            strokeRing(context: ctx, center: center, radius: outerR, fraction: p,
                       color: brand, lineWidth: stroke)
        }

        // Estimated segment (local captured calls, not a vendor reading). A thinner,
        // translucent stroke keeps it visibly subordinate to the measured arc.
        // Used mode grows the ring, so the estimate is a faint extension past it.
        // Remaining mode shrinks it, so the same faint brand over an already solid
        // brand arc would be invisible — paint that direction as erosion instead.
        if let projected = rings.projected {
            let q = clamped(projected)
            if abs(q - p) > 0.0005 {
                let eroding = q < p
                strokeArc(context: context, center: center, radius: outerR,
                          from: min(p, q), to: max(p, q),
                          color: eroding ? Color.black.opacity(0.42) : brand.opacity(0.34),
                          lineWidth: stroke * 0.62)
            }
        }

        // Mid cool steel (secondary — weekly).
        if (rings.secondary != nil) {
            let s = clamped((rings.secondary ?? 0))
            if s > 0.0005 {
                strokeRing(context: context, center: center, radius: midR, fraction: s,
                           color: steel, lineWidth: stroke)
            }
        }

        // Inner amber (tertiary — Fable / Codex Spark / scoped model).
        // Always paint at least a hairline so 0–1% usage still registers.
        if (rings.tertiary != nil) {
            let t = max(clamped((rings.tertiary ?? 0)), 0.015)
            strokeRing(context: context, center: center, radius: coreR, fraction: t,
                       color: amber.opacity((rings.tertiary ?? 0) < 0.02 ? 0.55 : 1), lineWidth: stroke)
        }
    }

    private func drawNeedle(
        context: GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        date: Date?
    ) {
        let unit = BurnRate.needleUnit(ratio: burnRatio)
        let baseAngle = Self.needleAngleDegrees(unit: unit)
        let jitter = date.map {
            BurnMotion.needleJitterDegrees(ratio: burnRatio, at: $0, phaseOffset: phaseOffset)
        } ?? 0
        let angle = baseAngle + jitter
        let tipR: CGFloat = 38 * scale
        let tip = point(center: center, angleDeg: angle, radius: tipR)
        // At rest a red needle read as an alarm; grey until there is real burn.
        let red = burnRatio < 0.05 ? Self.restNeedle : Self.burnRed
        let widthScale = BurnMotion.needleWidthScale(ratio: burnRatio)
        let lineW = 1.35 * scale * CGFloat(widthScale)

        var path = Path()
        path.move(to: center)
        path.addLine(to: tip)

        // Tip halo only deep overdrive — amp-first; avoid stacking FX past hot.
        let od = BurnMotion.overdrive(ratio: burnRatio)
        if od > 0.55 {
            let tipHaloR: CGFloat = (1.6 + od * 0.9) * scale
            var halo = context
            halo.addFilter(.blur(radius: 1.2 * scale))
            let hRect = CGRect(
                x: tip.x - tipHaloR,
                y: tip.y - tipHaloR,
                width: tipHaloR * 2,
                height: tipHaloR * 2
            )
            halo.fill(Path(ellipseIn: hRect), with: .color(red.opacity(0.12 + od * 0.10)))
        }

        let glowα = BurnMotion.needleGlowOpacity(ratio: burnRatio)
        if glowα > 0.02 {
            var glow = context
            glow.addFilter(.shadow(
                color: red.opacity(glowα),
                radius: BurnMotion.needleGlowRadius(ratio: burnRatio) * scale,
                x: 0,
                y: 0
            ))
            glow.stroke(
                path,
                with: .color(red.opacity(BurnMotion.needleStrokeOpacity(ratio: burnRatio))),
                style: StrokeStyle(lineWidth: lineW, lineCap: .round)
            )
        } else {
            context.stroke(
                path,
                with: .color(red.opacity(BurnMotion.needleStrokeOpacity(ratio: burnRatio))),
                style: StrokeStyle(lineWidth: lineW, lineCap: .round)
            )
        }

        // Hub.
        let hubR: CGFloat = (2.25 + BurnMotion.energy(ratio: burnRatio) * 0.25) * scale
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

    /// Partial arc between two fractions of the same ring (12 o'clock origin).
    private func strokeArc(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        from: Double,
        to: Double,
        color: Color,
        lineWidth: CGFloat
    ) {
        let a = clamped(from)
        let b = clamped(to)
        guard b > a else { return }
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: Angle.degrees(-90 + 360 * a),
            endAngle: Angle.degrees(-90 + 360 * b),
            clockwise: false
        )
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
        )
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
        // Start at 12 o'clock, sweep clockwise (screen: start -90°, end -90° + 360*f).
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
        case .agy: return IslandColor.agy
        case .neutral: return Color(red: 0.75, green: 0.72, blue: 0.68)
        }
    }
}
