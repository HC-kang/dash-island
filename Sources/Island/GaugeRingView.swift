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
    var secondaryFraction: Double?
    /// Optional third concentric ring (Fable / Codex model limit).
    var tertiaryFraction: Double? = nil
    var centerPercent: Int
    var burnRatio: Double
    var tint: VendorTint
    var size: CGFloat = 96
    /// Desyncs Timeline breath/jitter across widgets (≥0.2s).
    var phaseOffset: TimeInterval = 0

    /// Drawn values (spring toward targets).
    @State private var drawnPrimary: Double = 0
    @State private var drawnSecondary: Double = 0
    @State private var drawnTertiary: Double = 0
    @State private var drawnHasSecondary: Bool = false
    @State private var drawnHasTertiary: Bool = false
    @State private var drawnBurn: Double = 0
    @State private var drawnPercent: Int = 0
    @State private var didAppear = false
    @State private var revealTask: Task<Void, Never>?

    private var brand: Color { tint.brandColor }
    private var steel: Color { Color(red: 0.23, green: 0.40, blue: 0.50) } // ~#3a6580
    /// Innermost scoped ring (Fable / Spark) — warm amber, distinct from brand + steel.
    private var amber: Color { Color(red: 0.92, green: 0.68, blue: 0.28) }
    private static let burnRed = Color(red: 0.937, green: 0.267, blue: 0.267) // #ef4444
    private static let burnSoft = Color(red: 0.97, green: 0.44, blue: 0.42)

    /// Rings / % — quiet, quick.
    private static let ringSettle = Animation.spring(response: 0.55, dampingFraction: 0.88)
    /// Needle on expand — slow sweep so the user notices motion (rest → target).
    private static let needleReveal = Animation.spring(response: 1.55, dampingFraction: 0.86)
    /// Live burn updates — brief ~220–280ms settle, critically damped (no rubber).
    private static let needleLive = Animation.spring(response: 0.26, dampingFraction: 0.96)

    /// Always breathe while mounted (brief rest floor); FPS drops below cruise.
    private var timelineInterval: TimeInterval {
        BurnMotion.energy(ratio: drawnBurn) < 0.35 ? (1.0 / 15.0) : (1.0 / 30.0)
    }

    var body: some View {
        // Timeline: rest barely alive at 15fps; hot+ at 30fps. Never strobe.
        TimelineView(.animation(minimumInterval: timelineInterval, paused: !didAppear)) { timeline in
            ZStack {
                Canvas { context, canvasSize in
                    let s = min(canvasSize.width, canvasSize.height)
                    let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let scale = s / 96
                    let date = timeline.date

                    drawAmbientBloom(context: context, center: c, scale: scale, date: date)
                    drawSpeedTrack(context: context, center: c, scale: scale)
                    drawEnergyTrail(context: context, center: c, scale: scale)
                    drawTicks(context: context, center: c, scale: scale)
                    drawUsageRings(context: context, center: c, scale: scale)
                    drawNeedle(
                        context: context,
                        center: c,
                        scale: scale,
                        date: date
                    )
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
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(centerPercent) percent")
        .onAppear {
            playExpandReveal()
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
            didAppear = false
            // Next expand starts from rest again.
            drawnBurn = 0
        }
        .onChange(of: primaryFraction) { _ in applyRingTargets(animated: didAppear) }
        .onChange(of: secondaryFraction ?? -1) { _ in applyRingTargets(animated: didAppear) }
        .onChange(of: tertiaryFraction ?? -1) { _ in applyRingTargets(animated: didAppear) }
        .onChange(of: burnRatio) { _ in
            guard didAppear else { return }
            withAnimation(Self.needleLive) {
                drawnBurn = burnRatio
            }
        }
        .onChange(of: centerPercent) { _ in applyRingTargets(animated: didAppear) }
    }

    /// Compact → expanded: rings settle, needle slowly rises from rest so motion is visible.
    private func playExpandReveal() {
        revealTask?.cancel()
        // Always mount at rest — if we snap to target, expand feels static.
        drawnBurn = 0
        drawnPrimary = 0
        drawnSecondary = 0
        drawnTertiary = 0
        drawnHasSecondary = secondaryFraction != nil
        drawnHasTertiary = tertiaryFraction != nil
        drawnPercent = 0
        didAppear = false

        // Brief beat after expand chrome, then animate in.
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(Self.ringSettle) {
                drawnPrimary = primaryFraction
                drawnSecondary = secondaryFraction ?? 0
                drawnTertiary = tertiaryFraction ?? 0
                drawnHasSecondary = secondaryFraction != nil
                drawnHasTertiary = tertiaryFraction != nil
                drawnPercent = centerPercent
            }
            withAnimation(Self.needleReveal) {
                drawnBurn = burnRatio
            }
            didAppear = true
        }
    }

    private func applyRingTargets(animated: Bool) {
        let update = {
            drawnPrimary = primaryFraction
            drawnSecondary = secondaryFraction ?? 0
            drawnTertiary = tertiaryFraction ?? 0
            drawnHasSecondary = secondaryFraction != nil
            drawnHasTertiary = tertiaryFraction != nil
            drawnPercent = centerPercent
        }
        if animated {
            withAnimation(Self.ringSettle, update)
        } else {
            update()
        }
    }

    // MARK: - Drawing

    /// Warm center haze past light activity — breath modulates, never blinks off.
    private func drawAmbientBloom(
        context: GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        date: Date
    ) {
        let base = BurnMotion.bloomOpacity(ratio: drawnBurn)
        guard base > 0.004 else { return }
        let breath = BurnMotion.breath(at: date, ratio: drawnBurn, phaseOffset: phaseOffset)
        let op = base * breath
        let r: CGFloat = (22 + BurnMotion.overdrive(ratio: drawnBurn) * 6) * scale
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        var ctx = context
        // Blur only past cruise — rest/cruise stay cheap hairline chrome.
        if BurnMotion.energy(ratio: drawnBurn) >= 0.35 {
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
        let highlight = BurnMotion.trackHighlightOpacity(ratio: drawnBurn)
        guard highlight > 0.01 else { return }
        let unit = BurnRate.needleUnit(ratio: drawnBurn)
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
        let op = BurnMotion.trailOpacity(ratio: drawnBurn)
        guard op > 0.01 else { return }
        let unit = BurnRate.needleUnit(ratio: drawnBurn)
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
            with: .color(Self.burnSoft.opacity(BurnMotion.trailOuterOpacity(ratio: drawnBurn))),
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
        let e = BurnMotion.energy(ratio: drawnBurn)

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
        let pipBoost = BurnMotion.cruisePipBoost(ratio: drawnBurn)
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
        let od = BurnMotion.overdrive(ratio: drawnBurn)
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

    private func drawUsageRings(context: GraphicsContext, center: CGPoint, scale: CGFloat) {
        // Triple-ring geometry: outer brand · mid steel · inner amber (scoped).
        // Slightly tighter stroke when tertiary is present so the core stays readable.
        let triple = drawnHasTertiary
        let stroke: CGFloat = (triple ? 4.6 : 5.5) * scale
        let outerR: CGFloat = (triple ? 32 : 31) * scale
        let midR: CGFloat = (triple ? 26.5 : 25) * scale
        let coreR: CGFloat = 21 * scale
        let glowBoost = BurnMotion.brandRingGlowBoost(ratio: drawnBurn)

        // Track underlays (tertiary uses amber ghost so 0% Fable/Spark still reads).
        strokeRing(context: context, center: center, radius: outerR, fraction: 1,
                   color: Color.white.opacity(0.07), lineWidth: stroke)
        if drawnHasSecondary {
            strokeRing(context: context, center: center, radius: midR, fraction: 1,
                       color: Color.white.opacity(0.045), lineWidth: stroke)
        }
        if drawnHasTertiary {
            strokeRing(context: context, center: center, radius: coreR, fraction: 1,
                       color: amber.opacity(0.22), lineWidth: stroke)
        }

        // Outer brand (primary — 5h / main window).
        let p = clamped(drawnPrimary)
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

        // Mid cool steel (secondary — weekly).
        if drawnHasSecondary {
            let s = clamped(drawnSecondary)
            if s > 0.0005 {
                strokeRing(context: context, center: center, radius: midR, fraction: s,
                           color: steel, lineWidth: stroke)
            }
        }

        // Inner amber (tertiary — Fable / Codex Spark / scoped model).
        // Always paint at least a hairline so 0–1% usage still registers.
        if drawnHasTertiary {
            let t = max(clamped(drawnTertiary), 0.015)
            strokeRing(context: context, center: center, radius: coreR, fraction: t,
                       color: amber.opacity(drawnTertiary < 0.02 ? 0.55 : 1), lineWidth: stroke)
        }
    }

    private func drawNeedle(
        context: GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        date: Date
    ) {
        let unit = BurnRate.needleUnit(ratio: drawnBurn)
        let baseAngle = Self.needleAngleDegrees(unit: unit)
        let angle = baseAngle + BurnMotion.needleJitterDegrees(
            ratio: drawnBurn,
            at: date,
            phaseOffset: phaseOffset
        )
        let tipR: CGFloat = 38 * scale
        let tip = point(center: center, angleDeg: angle, radius: tipR)
        let red = Self.burnRed
        let widthScale = BurnMotion.needleWidthScale(ratio: drawnBurn)
        let lineW = 1.35 * scale * CGFloat(widthScale)

        var path = Path()
        path.move(to: center)
        path.addLine(to: tip)

        // Tip halo only deep overdrive — amp-first; avoid stacking FX past hot.
        let od = BurnMotion.overdrive(ratio: drawnBurn)
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

        let glowα = BurnMotion.needleGlowOpacity(ratio: drawnBurn)
        if glowα > 0.02 {
            var glow = context
            glow.addFilter(.shadow(
                color: red.opacity(glowα),
                radius: BurnMotion.needleGlowRadius(ratio: drawnBurn) * scale,
                x: 0,
                y: 0
            ))
            glow.stroke(
                path,
                with: .color(red.opacity(BurnMotion.needleStrokeOpacity(ratio: drawnBurn))),
                style: StrokeStyle(lineWidth: lineW, lineCap: .round)
            )
        } else {
            context.stroke(
                path,
                with: .color(red.opacity(BurnMotion.needleStrokeOpacity(ratio: drawnBurn))),
                style: StrokeStyle(lineWidth: lineW, lineCap: .round)
            )
        }

        // Hub.
        let hubR: CGFloat = (2.25 + BurnMotion.energy(ratio: drawnBurn) * 0.25) * scale
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

    /// Back-compat for tests / call sites that still pass burn into the old helper.
    static func needleJitterDegrees(burn: Double, at date: Date, phaseOffset: TimeInterval = 0) -> Double {
        BurnMotion.needleJitterDegrees(ratio: burn, at: date, phaseOffset: phaseOffset)
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
        case .gemini: return IslandColor.gemini
        case .neutral: return Color(red: 0.75, green: 0.72, blue: 0.68)
        }
    }
}
