import Foundation

/// Continuous visual energy from burn ratio — Apple-instrument language.
///
/// Tier map (design brief: Dynamic Island morph · AW rings · CC thermal · analog needle):
///
/// | Tier    | burnRatio   | glow α     | jitter amp   | period (s) |
/// |---------|-------------|------------|--------------|------------|
/// | rest    | 0.00–0.35   | 0.00–0.08  | 0.15–0.35°   | 2.8–3.6    |
/// | cruise  | 0.35–1.15   | 0.10–0.22  | 0.35–0.70°   | 1.8–2.4    |
/// | hot     | 1.15–1.70   | 0.24–0.40  | 0.70–1.20°   | 1.1–1.6    |
/// | redline | 1.70–2.00+  | 0.42–0.58  | 1.20–1.80°   | 0.75–1.05  |
///
/// Continuous smoothstep across the full 0…2 range (morph energy, not mode flips).
/// Ratio > 2 soft-caps at redline params.
enum BurnMotion {
    /// Soft unit 0…1 from ratio (needle: redline at 2.0 → 1.0).
    static func unit(ratio: Double) -> Double {
        BurnRate.needleUnit(ratio: ratio)
    }

    /// Clamp burn into the design domain.
    static func clampedRatio(_ ratio: Double) -> Double {
        min(2.0, max(0, ratio))
    }

    // MARK: - Tier anchors (low edge of each band)

    private static let tierRatio: [Double] = [0.00, 0.35, 1.15, 1.70, 2.00]
    private static let tierGlow: [Double] = [0.00, 0.08, 0.22, 0.40, 0.58]
    private static let tierJitter: [Double] = [0.15, 0.35, 0.70, 1.20, 1.80]
    private static let tierPeriod: [Double] = [3.6, 2.8, 2.1, 1.35, 0.90]

    /// Piecewise smoothstep between tier anchors.
    private static func lerpTier(_ ratio: Double, values: [Double]) -> Double {
        let r = clampedRatio(ratio)
        let edges = tierRatio
        if r <= edges[0] { return values[0] }
        if r >= edges[edges.count - 1] { return values[values.count - 1] }
        for i in 0..<(edges.count - 1) {
            let a = edges[i]
            let b = edges[i + 1]
            if r >= a && r <= b {
                let t = (r - a) / (b - a)
                let s = t * t * (3 - 2 * t) // smoothstep
                return values[i] + s * (values[i + 1] - values[i])
            }
        }
        return values[values.count - 1]
    }

    /// 0…1 continuous energy for secondary chrome (trail, bloom, cell).
    /// Rest band stays very quiet; opens after cruise. True zero still maps ~0
    /// (glow anchor 0) so trail/bloom stay off — needle uses separate rest floor.
    static func energy(ratio: Double) -> Double {
        let r = clampedRatio(ratio)
        // Map glow curve → 0…1 for callers that want a single knob.
        return lerpTier(r, values: tierGlow) / 0.58
    }

    /// How “hot” past cruise (0 at ≤1.0, 1 at redline).
    static func overdrive(ratio: Double) -> Double {
        let r = clampedRatio(ratio)
        if r <= 1.0 { return 0 }
        return min(1, (r - 1.0) / 1.0)
    }

    // MARK: - Needle

    /// Peak jitter amplitude in degrees (brief: rest floor 0.15° … redline 1.80°).
    /// Alive-idle at rest so chrome never freeze-dead (brief principle 4).
    static func needleJitterAmplitude(ratio: Double) -> Double {
        lerpTier(clampedRatio(ratio), values: tierJitter)
    }

    /// Dominant breath / wobble period (seconds).
    static func motionPeriod(ratio: Double) -> Double {
        lerpTier(clampedRatio(ratio), values: tierPeriod)
    }

    /// Multi-frequency micro-wobble. `phaseOffset` desyncs widgets (≥0.2s intent).
    static func needleJitterDegrees(
        ratio: Double,
        at date: Date,
        phaseOffset: TimeInterval = 0
    ) -> Double {
        let amp = needleJitterAmplitude(ratio: ratio)
        guard amp > 0.02 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate + phaseOffset
        let period = motionPeriod(ratio: ratio)
        let fundamental = 1.0 / max(0.5, period)
        // Weights sum to 1 so the envelope never exceeds `amp` (brief soft-cap).
        // Older 1+0.42+0.28 stacking could peak ~1.7×amp ≈ 3° at redline — tacky.
        let fast = sin(t * fundamental * 2.4 * 2 * .pi) * 0.55
        let mid = sin(t * fundamental * 1.0 * 2 * .pi + 1.1) * 0.28
        let slow = sin(t * fundamental * 0.35 * 2 * .pi + 0.4) * 0.17
        return (fast + mid + slow) * amp
    }

    /// Needle tip glow α from tier table (brief soft-cap 0.58). Stroke stays flat.
    static func needleGlowOpacity(ratio: Double) -> Double {
        lerpTier(clampedRatio(ratio), values: tierGlow)
    }

    /// Needle stroke alpha — nearly flat (brief 0.75–0.95).
    static func needleStrokeOpacity(ratio: Double) -> Double {
        0.78 + energy(ratio: ratio) * 0.14
    }

    /// Soft shadow radius scale (multiply by view `scale`).
    static func needleGlowRadius(ratio: Double) -> Double {
        1.6 + energy(ratio: ratio) * 1.6 + overdrive(ratio: ratio) * 1.2
    }

    /// Needle line width multiplier (1.0 rest → ~1.10 redline) — amplitude before hue.
    static func needleWidthScale(ratio: Double) -> Double {
        1.0 + energy(ratio: ratio) * 0.08 + overdrive(ratio: ratio) * 0.04
    }

    // MARK: - Arc trail (rest → tip)

    static func trailOpacity(ratio: Double) -> Double {
        let e = energy(ratio: ratio)
        guard e > 0.04 else { return 0 }
        return 0.05 + e * 0.16 + overdrive(ratio: ratio) * 0.08
    }

    static func trailOuterOpacity(ratio: Double) -> Double {
        trailOpacity(ratio: ratio) * 0.45
    }

    // MARK: - Ambient bloom

    /// Very soft center bloom. Cap well under neon (≤0.14).
    static func bloomOpacity(ratio: Double) -> Double {
        let e = energy(ratio: ratio)
        guard e > 0.12 else { return 0 }
        return min(0.14, (e - 0.12) * 0.16 + overdrive(ratio: ratio) * 0.05)
    }

    /// Slow breath on bloom (0…1). Rest: long period; redline: still >0.75s (no strobe).
    static func breath(at date: Date, ratio: Double, phaseOffset: TimeInterval = 0) -> Double {
        let e = energy(ratio: ratio)
        guard e > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate + phaseOffset
        let period = motionPeriod(ratio: ratio) * 1.15
        let phase = sin(t * (2 * .pi / period))
        // Never fully off — 70% floor + 30% breath (no LED blink).
        return 0.70 + 0.30 * (0.5 + 0.5 * phase)
    }

    // MARK: - Rings / track

    static func brandRingGlowBoost(ratio: Double) -> Double {
        energy(ratio: ratio) * 0.14 + overdrive(ratio: ratio) * 0.08
    }

    static func trackHighlightOpacity(ratio: Double) -> Double {
        let e = energy(ratio: ratio)
        guard e > 0.05 else { return 0 }
        return 0.04 + e * 0.14 + overdrive(ratio: ratio) * 0.08
    }

    /// Cruise pip brightness boost when near cruise (±0.35 ratio).
    static func cruisePipBoost(ratio: Double) -> Double {
        let d = abs(clampedRatio(ratio) - 1.0)
        guard d < 0.35 else { return 0 }
        return (1 - d / 0.35) * 0.28
    }

    // MARK: - Cell chrome (AccountWidget)

    static func cellBorderBoost(ratio: Double) -> Double {
        energy(ratio: ratio) * 0.07 + overdrive(ratio: ratio) * 0.05
    }

    /// Warm red tint into border (0 = pure white edge).
    static func cellBorderWarmth(ratio: Double) -> Double {
        energy(ratio: ratio) * 0.32 + overdrive(ratio: ratio) * 0.40
    }

    static func cellFillLift(ratio: Double) -> Double {
        energy(ratio: ratio) * 0.025 + overdrive(ratio: ratio) * 0.02
    }

    /// Stable per-widget phase offset (seconds) so gauges don't sync-throb.
    static func phaseOffset(for accountID: AccountID) -> TimeInterval {
        var hash: UInt64 = 5381
        for b in accountID.uuidString.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(b)
        }
        // 0.20 … 1.85 s spread (brief: ≥0.2s desync).
        let frac = Double(hash % 1_000_000) / 1_000_000
        return 0.20 + frac * 1.65
    }
}
