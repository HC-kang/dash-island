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
    var ratio: Double
    var sampleCount: Int

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

    /// ~30 min time-constant (half-life ~21 min).
    static let defaultTau: TimeInterval = 30 * 60

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
    private(set) var smoothedRatio: Double = 0
    private(set) var lastUpdateAt: Date?
    private(set) var lastPositiveAt: Date?
    private var seeded = false

    mutating func push(_ sample: BurnSample, tau: TimeInterval = BurnRate.defaultTau) -> BurnRate {
        // Period rollover: large absolute drop, or same-kind reset jump.
        // Do NOT wipe when switching weekly% → monthly counters (different resetAt).
        if shouldReset(for: sample) {
            samples.removeAll()
            smoothedRatio = 0
            lastUpdateAt = nil
            lastPositiveAt = nil
            seeded = false
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

        // Always compare to the previous sample. A 15‑minute lookback diluted
        // integer +1% ticks (Claude/Codex) into ~0.2× cruise — needle looked dead.
        guard let baseline = samples.dropLast().last else {
            lastUpdateAt = sample.at
            return current
        }

        let rInst = BurnRate.instantRatio(prev: baseline, current: sample)
        let dt: TimeInterval
        if let lastUpdateAt {
            dt = max(0, sample.at.timeIntervalSince(lastUpdateAt))
        } else {
            dt = sample.at.timeIntervalSince(baseline.at)
        }

        applyInstant(rInst, at: sample.at, dt: dt, tau: tau)
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
        applyInstant(r, at: at, dt: dt, tau: tau)
        lastUpdateAt = at
        return current
    }

    var current: BurnRate {
        BurnRate(ratio: seeded ? smoothedRatio : 0, sampleCount: samples.count)
    }

    mutating func reset() {
        samples.removeAll()
        smoothedRatio = 0
        lastUpdateAt = nil
        lastPositiveAt = nil
        seeded = false
    }

    // MARK: Private

    private mutating func applyInstant(
        _ rInst: Double?,
        at: Date,
        dt: TimeInterval,
        tau: TimeInterval
    ) {
        if let rInst {
            if rInst > 0 {
                lastPositiveAt = at
                if !seeded {
                    // Soft-cap seed so one noisy minute doesn't peg redline forever.
                    smoothedRatio = min(rInst, 3)
                    seeded = true
                } else {
                    smoothedRatio = BurnRate.ewmaStep(
                        previous: smoothedRatio,
                        instant: min(rInst, 3),
                        dt: max(dt, 1),
                        tau: tau
                    )
                }
            } else if seeded {
                // Explicit drop in usage — ease toward rest.
                lastPositiveAt = nil
                smoothedRatio = BurnRate.ewmaStep(
                    previous: smoothedRatio,
                    instant: 0,
                    dt: max(dt, 1),
                    tau: tau
                )
            }
        } else if seeded {
            // Flat: HOLD the needle. Only decay after prolonged idle.
            if let lastPositiveAt,
               at.timeIntervalSince(lastPositiveAt) >= Self.idleBeforeDecay
            {
                smoothedRatio = BurnRate.ewmaStep(
                    previous: smoothedRatio,
                    instant: 0,
                    dt: max(dt, 1),
                    tau: tau * 3
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
