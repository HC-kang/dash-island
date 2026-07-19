import Foundation

/// Burn vs cruise for the primary usage window between two polls.
///
/// ```
/// v        = (u1 − u0) / (t1 − t0)     // used-fraction per second
/// v_cruise = (1 − u1) / (resetAt − t1) // empties exactly at reset
/// ratio    = v / v_cruise              // 0 if no previous sample
/// ```
struct BurnRate: Equatable, Sendable {
    /// Relative burn speed. `0` on first sample or when undefined.
    var ratio: Double
    /// Number of samples involved (`1` first poll, `2` when Δ is defined).
    var sampleCount: Int

    /// Compute burn ratio from previous and current primary-window samples.
    ///
    /// - Parameters:
    ///   - prev: Prior used-fraction and fetch time; `nil` → first sample (ratio 0).
    ///   - current: Current used-fraction (0...1) and fetch time.
    ///   - resetAt: Primary window reset instant; required for a non-zero cruise.
    static func compute(
        prev: (usedFraction: Double, at: Date)?,
        current: (usedFraction: Double, at: Date),
        resetAt: Date?
    ) -> BurnRate {
        guard let prev else {
            return BurnRate(ratio: 0, sampleCount: 1)
        }

        let dt = current.at.timeIntervalSince(prev.at)
        guard dt > 0 else {
            return BurnRate(ratio: 0, sampleCount: 2)
        }

        guard let resetAt else {
            return BurnRate(ratio: 0, sampleCount: 2)
        }

        let timeToReset = resetAt.timeIntervalSince(current.at)
        let remaining = 1.0 - current.usedFraction
        // No meaningful cruise if already empty of budget or reset is not ahead.
        guard timeToReset > 0, remaining > 0 else {
            return BurnRate(ratio: 0, sampleCount: 2)
        }

        let v = (current.usedFraction - prev.usedFraction) / dt
        let vCruise = remaining / timeToReset
        guard vCruise > 0, vCruise.isFinite else {
            return BurnRate(ratio: 0, sampleCount: 2)
        }

        let ratio = v / vCruise
        guard ratio.isFinite else {
            return BurnRate(ratio: 0, sampleCount: 2)
        }

        // Negative burn (usage dropped) → rest.
        return BurnRate(ratio: max(0, ratio), sampleCount: 2)
    }

    /// Map burn `ratio` → unit position along the speed arc in `0...1`.
    ///
    /// - `0` → rest
    /// - `1` → cruise (~mid arc / ~1 o'clock)
    /// - `≥2` → soft-capped redline
    static func needleUnit(ratio: Double) -> Double {
        let r = max(0, ratio)
        // Linear 0...2 → 0...1, hard soft-cap at redline.
        return min(1.0, r / 2.0)
    }
}
