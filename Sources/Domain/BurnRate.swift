import Foundation

/// One usage sample for burn estimation (usually `preferredBurnWindow`).
struct BurnSample: Equatable, Sendable {
    var usedFraction: Double
    var at: Date
    var resetAt: Date?
    var kind: UsageWindowKind
    /// Absolute counters when the vendor exposes them (Grok monthly `used`/`limit`).
    var usedTokens: Int64? = nil
    var limitTokens: Int64? = nil

    var hasAbsoluteCounters: Bool {
        guard let usedTokens, let limitTokens, limitTokens > 0, usedTokens >= 0 else {
            return false
        }
        return true
    }
}

/// Burn vs cruise — **rate over time**, not total used.
///
/// ```
/// v        = Δu / Δt
/// v_cruise = (1 − u) / timeToReset   or   1 / W if reset unknown
/// ratio    = v / v_cruise
/// ```
///
/// Same structure for 5h / weekly / monthly — only `W` (and `resetAt`) change:
/// - 5h empty, 5‑minute poll → Δu_cruise ≈ 300/18000 ≈ **1.67%** → ratio ≈ 1
/// - weekly empty, 5‑minute poll → Δu_cruise ≈ 300/604800 ≈ **0.05%**
/// - monthly empty, 5‑minute poll → even smaller
///
/// So a +1% API tick on weekly is a *huge* burn; the same +1% on 5h is ~0.6–1× cruise.
struct BurnRate: Equatable, Sendable {
    /// Needle drive — short-horizon pace (recent bursts).
    var ratio: Double
    var sampleCount: Int
    /// Session-scale pace (slower EWMA). Hover honesty.
    var longRatio: Double = 0
    /// Last API sample that moved usage (for “Xm ago” honesty).
    var lastSampleAt: Date? = nil
    /// Whether the latest samples lack absolute counters (integer-%).
    var quantized: Bool = false

    static func compute(
        prev: (usedFraction: Double, at: Date)?,
        current: (usedFraction: Double, at: Date),
        resetAt: Date?,
        kind: UsageWindowKind = .fiveHour
    ) -> BurnRate {
        let r = instantRatio(
            prev: prev.map {
                BurnSample(usedFraction: $0.usedFraction, at: $0.at, resetAt: resetAt, kind: kind)
            },
            current: BurnSample(
                usedFraction: current.usedFraction,
                at: current.at,
                resetAt: resetAt,
                kind: kind
            )
        )
        return BurnRate(ratio: r ?? 0, sampleCount: prev == nil ? 1 : 2)
    }

    /// Instant ratio, or `nil` when undefined / no positive signal (flat).
    static func instantRatio(prev: BurnSample?, current: BurnSample) -> Double? {
        guard let prev else { return nil }

        let dt = current.at.timeIntervalSince(prev.at)
        guard dt > 0 else { return nil }

        let du = deltaUsedFraction(from: prev, to: current)
        if du <= 1e-12 {
            if du < -1e-9 { return 0 }
            return nil // flat — hold EWMA, do not force rest
        }

        guard let vCruise = cruiseRate(
            usedFraction: current.usedFraction,
            at: current.at,
            resetAt: current.resetAt,
            kind: current.kind
        ), vCruise > 0, vCruise.isFinite else {
            return nil
        }

        let v = du / dt
        let ratio = v / vCruise
        guard ratio.isFinite else { return nil }
        return max(0, ratio)
    }

    static func deltaUsedFraction(from prev: BurnSample, to current: BurnSample) -> Double {
        if let u0 = prev.usedTokens, let u1 = current.usedTokens,
           let lim = current.limitTokens ?? prev.limitTokens, lim > 0
        {
            return Double(u1 - u0) / Double(lim)
        }
        return current.usedFraction - prev.usedFraction
    }

    /// Even-pace burn rate for this window (fraction of limit per second).
    ///
    /// Prefer **remaining / timeToReset** (hit 100% exactly at reset). Fall back
    /// to **1 / W** using `kind.nominalDuration` (5h / 7d / 30d) — never reuse
    /// a 5h W for weekly/monthly samples.
    static func cruiseRate(
        usedFraction: Double,
        at: Date,
        resetAt: Date?,
        kind: UsageWindowKind
    ) -> Double? {
        if let resetAt {
            let timeToReset = resetAt.timeIntervalSince(at)
            let remaining = 1.0 - min(1, max(0, usedFraction))
            if timeToReset > 0, remaining > 1e-9 {
                let rate = remaining / timeToReset
                if rate.isFinite, rate > 0 { return rate }
            }
        }
        let w = kind.nominalDuration
        guard w > 0 else { return nil }
        return 1.0 / w
    }

    static func needleUnit(ratio: Double) -> Double {
        min(1.0, max(0, ratio) / 2.0)
    }

    // MARK: - EWMA

    /// Session-scale time-constant (half-life ~21 min).
    static let defaultTau: TimeInterval = 30 * 60
    /// Burst / “right now” time-constant (~3.5 min half-life).
    static let shortTau: TimeInterval = 5 * 60
    /// When API only steps in whole percent, attribute a jump to at most this
    /// much recent activity for the short needle (poll gap would otherwise
    /// dilute a real 2-minute burn into a 15-minute average).
    static let quantBurstCap: TimeInterval = 5 * 60

    static func ewmaAlpha(dt: TimeInterval, tau: TimeInterval = defaultTau) -> Double {
        guard dt > 0, tau > 0 else { return 1 }
        return min(1, max(0, 1 - exp(-dt / tau)))
    }

    static func ewmaStep(
        previous: Double?,
        instant: Double,
        dt: TimeInterval,
        tau: TimeInterval = defaultTau
    ) -> Double {
        guard let previous else { return max(0, instant) }
        let alpha = ewmaAlpha(dt: dt, tau: tau)
        return alpha * max(0, instant) + (1 - alpha) * max(0, previous)
    }
}

// MARK: - Per-account smoother

struct BurnSmoother: Equatable, Sendable {
    static let maxSpan: TimeInterval = 3 * 60 * 60
    static let maxSamples = 48
    /// Only start decaying toward rest after this much time with no positive Δ.
    static let idleBeforeDecay: TimeInterval = 3 * 60

    private(set) var samples: [BurnSample] = []
    private(set) var shortRatio: Double = 0
    private(set) var longRatio: Double = 0
    private(set) var lastUpdateAt: Date?
    private(set) var lastPositiveAt: Date?
    private(set) var lastSampleAt: Date?
    private var seeded = false
    private var lastQuantized = false

    /// Back-compat alias used by older call sites / logs.
    var smoothedRatio: Double { shortRatio }

    mutating func push(_ sample: BurnSample, tau: TimeInterval = BurnRate.defaultTau) -> BurnRate {
        // Period rollover: large absolute drop, or same-kind reset jump.
        // Do NOT wipe when switching weekly% → monthly counters (different resetAt).
        if shouldReset(for: sample) {
            samples.removeAll()
            shortRatio = 0
            longRatio = 0
            lastUpdateAt = nil
            lastPositiveAt = nil
            lastSampleAt = nil
            seeded = false
            lastQuantized = false
        }

        // Once we have absolute-counter history, ignore coarse %-only samples
        // (weekly integer %). They use a different reset and would zero the needle.
        if !sample.hasAbsoluteCounters,
           samples.contains(where: \.hasAbsoluteCounters)
        {
            return current
        }

        samples.append(sample)
        trim(now: sample.at)
        lastSampleAt = sample.at
        lastQuantized = !sample.hasAbsoluteCounters

        // Prefer a baseline that actually differs for %-only samples (skip flat
        // intermediate polls), but never look back more than 45 minutes.
        guard let baseline = baselineSample(for: sample) else {
            lastUpdateAt = sample.at
            return current
        }

        let wallDt = max(1, sample.at.timeIntervalSince(baseline.at))
        var rInst = BurnRate.instantRatio(prev: baseline, current: sample)

        // Integer-% jump over a long poll gap: short needle attributes burn to a
        // recent burst window so +1% after 15m idle still reads as real activity.
        if let r = rInst, r > 0, !sample.hasAbsoluteCounters, wallDt > BurnRate.quantBurstCap {
            let shortDt = BurnRate.quantBurstCap
            let scale = wallDt / shortDt
            rInst = min(3, r * scale)
            applyInstant(rInst, at: sample.at, shortDt: shortDt, longDt: wallDt, tau: tau)
        } else {
            applyInstant(rInst, at: sample.at, shortDt: wallDt, longDt: wallDt, tau: tau)
        }
        lastUpdateAt = sample.at
        return current
    }

    /// Live CLI activity when the usage API is integer-% flat (Claude).
    /// Does not invent usage fractions — only lifts the needle EWMA.
    mutating func noteLiveActivity(
        ratio: Double,
        at: Date,
        tau: TimeInterval = BurnRate.defaultTau
    ) -> BurnRate {
        let r = min(3, max(0, ratio))
        guard r > 0 else { return current }
        let dt: TimeInterval
        if let lastUpdateAt {
            dt = max(1, at.timeIntervalSince(lastUpdateAt))
        } else {
            dt = 60
        }
        // Local activity is a short-horizon signal — feed short EWMA harder.
        applyInstant(r, at: at, shortDt: min(dt, 90), longDt: max(dt, 60), tau: tau)
        lastUpdateAt = at
        return current
    }

    var current: BurnRate {
        BurnRate(
            ratio: seeded ? shortRatio : 0,
            sampleCount: samples.count,
            longRatio: seeded ? longRatio : 0,
            lastSampleAt: lastSampleAt,
            quantized: lastQuantized
        )
    }

    mutating func reset() {
        samples.removeAll()
        shortRatio = 0
        longRatio = 0
        lastUpdateAt = nil
        lastPositiveAt = nil
        lastSampleAt = nil
        seeded = false
        lastQuantized = false
    }

    // MARK: Private

    /// Last sample that differs enough for a signal, within 45 minutes.
    private func baselineSample(for current: BurnSample) -> BurnSample? {
        let oldest = current.at.addingTimeInterval(-45 * 60)
        let prior = samples.dropLast().reversed()
        // Prefer nearest prior with real Δ (absolute or ≥0.5%).
        for s in prior {
            if s.at < oldest { break }
            let du = BurnRate.deltaUsedFraction(from: s, to: current)
            if abs(du) >= 0.005 { return s }
            if current.hasAbsoluteCounters, s.hasAbsoluteCounters, abs(du) > 1e-12 {
                return s
            }
        }
        // Fall back to immediate predecessor.
        return samples.dropLast().last
    }

    private mutating func applyInstant(
        _ rInst: Double?,
        at: Date,
        shortDt: TimeInterval,
        longDt: TimeInterval,
        tau: TimeInterval
    ) {
        let longTau = tau
        let shortTau = BurnRate.shortTau
        if let rInst {
            if rInst > 0 {
                lastPositiveAt = at
                let capped = min(rInst, 3)
                if !seeded {
                    shortRatio = capped
                    longRatio = min(capped, 1.5) // don't seed long at redline from one tick
                    seeded = true
                } else {
                    shortRatio = BurnRate.ewmaStep(
                        previous: shortRatio,
                        instant: capped,
                        dt: max(shortDt, 1),
                        tau: shortTau
                    )
                    longRatio = BurnRate.ewmaStep(
                        previous: longRatio,
                        instant: capped,
                        dt: max(longDt, 1),
                        tau: longTau
                    )
                }
            } else if seeded {
                // Explicit drop in usage — ease toward rest.
                lastPositiveAt = nil
                shortRatio = BurnRate.ewmaStep(
                    previous: shortRatio,
                    instant: 0,
                    dt: max(shortDt, 1),
                    tau: shortTau
                )
                longRatio = BurnRate.ewmaStep(
                    previous: longRatio,
                    instant: 0,
                    dt: max(longDt, 1),
                    tau: longTau
                )
            }
        } else if seeded {
            // Flat: HOLD the needle. Only decay after prolonged idle.
            if let lastPositiveAt,
               at.timeIntervalSince(lastPositiveAt) >= Self.idleBeforeDecay
            {
                shortRatio = BurnRate.ewmaStep(
                    previous: shortRatio,
                    instant: 0,
                    dt: max(shortDt, 1),
                    tau: shortTau * 2
                )
                longRatio = BurnRate.ewmaStep(
                    previous: longRatio,
                    instant: 0,
                    dt: max(longDt, 1),
                    tau: longTau * 3
                )
            }
        }
    }

    private func shouldReset(for sample: BurnSample) -> Bool {
        guard let last = samples.last else { return false }

        // Absolute counters dropped hard → new billing period / window.
        if let u0 = last.usedTokens, let u1 = sample.usedTokens, u1 + 500 < u0 {
            return true
        }

        // Same kind, reset instant jumped (window rolled).
        if last.kind == sample.kind,
           let pr = last.resetAt, let nr = sample.resetAt,
           abs(pr.timeIntervalSince1970 - nr.timeIntervalSince1970) > 120
        {
            return true
        }
        return false
    }

    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.maxSpan)
        samples.removeAll { $0.at < cutoff }
        if samples.count > Self.maxSamples {
            samples = Array(samples.suffix(Self.maxSamples))
        }
    }
}
