import Foundation

/// Fills the gap between two quantized API samples with locally captured spend.
///
/// The vendor reports whole-percent utilization and we may only ask every
/// `minPollSeconds`. Between samples the ring is flat even while the account
/// burns. The completed-call collector already records every call per account
/// identity, so we learn how far one captured dollar moves the primary window,
/// then extend the ring by that much until the next real sample lands.
///
/// Rules that keep this honest — the projection is a hint, never a reading:
/// - Every API sample re-anchors, so a projection never outlives one interval.
/// - It is never written to last-good and never feeds the burn smoother.
/// - It only ever adds to the anchor. It cannot walk a ring backwards.
/// - A window reset drops the anchor; the new window starts from the API value.
/// - `maxProjectedGain` bounds a wrong rate, so a bad fit cannot run to 100%.
///
/// Known under-counts (all in the same direction — the projection lags, it never
/// overshoots): calls from processes started before telemetry was installed, use
/// from claude.ai web or mobile, and rows the collector stored without a price.
struct UsageProjection: Equatable, Sendable {
    /// Learned primary-window fraction per captured dollar. Nil until we fit one.
    var rate: Double?
    /// Last API sample: its used fraction and the instant we read it.
    var anchorFraction: Double = 0
    var anchorAt: Date = .distantPast
    /// Reset instant of the window `anchorFraction` belongs to.
    var windowResetAt: Date?
    /// Sample before the anchor, kept only until the next tick can fit a rate.
    var pendingPreviousFraction: Double?
    var pendingPreviousAt: Date?
    /// Value the gauge should extend to, or nil when there is nothing to add.
    var projected: Double?
    /// Spend captured since the anchor. Non-zero means this account is burning
    /// right now, which is what earns it the fast poll interval — the rings only
    /// need frequent reads while the number is actually moving.
    var spentSinceAnchor: Double = 0

    /// Smallest API movement worth dividing by. The API reports whole percent,
    /// so a 1% step is one quantum of noise and a terrible denominator.
    static let minLearnableDelta = 0.02
    /// EWMA weight for a new fit. Low, because the model mix shifts constantly.
    static let smoothing = 0.3
    /// Hard ceiling on how far a projection may run past its anchor.
    static let maxProjectedGain = 0.25
    /// Ignore a fit from a gap this long — the anchor pair is too coarse to trust.
    static let maxLearnableGap: TimeInterval = 2 * 60 * 60

    /// Rate implied by two consecutive API samples of the same window.
    static func learnedRate(
        previousFraction: Double,
        currentFraction: Double,
        dollarsBetween: Double
    ) -> Double? {
        let delta = currentFraction - previousFraction
        guard delta >= minLearnableDelta, dollarsBetween > 0 else { return nil }
        let rate = delta / dollarsBetween
        guard rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// Fold a fresh fit into the EWMA.
    func blending(_ candidate: Double) -> Double {
        guard let rate else { return candidate }
        return rate * (1 - Self.smoothing) + candidate * Self.smoothing
    }

    /// Where to draw the projected end of the primary ring, if anywhere.
    func projectedFraction(spentSinceAnchor: Double, now: Date) -> Double? {
        guard let rate, anchorFraction < 1, spentSinceAnchor > 0 else { return nil }
        // Past the reset the anchor describes a window that no longer exists.
        if let windowResetAt, now >= windowResetAt { return nil }
        let gain = min(Self.maxProjectedGain, rate * spentSinceAnchor)
        let value = min(1, anchorFraction + gain)
        // Sub-half-percent additions are invisible and just make the ring jitter.
        return value > anchorFraction + 0.005 ? value : nil
    }

    /// Re-anchor on a fresh API sample. Keeps the old anchor so the next tick can
    /// fit a rate over the interval we just closed.
    mutating func anchor(fraction: Double, resetAt: Date?, at date: Date) {
        let sameWindow = windowResetAt == resetAt
        if sameWindow, anchorAt > .distantPast {
            pendingPreviousFraction = anchorFraction
            pendingPreviousAt = anchorAt
        } else {
            // New window (or first ever sample): nothing comparable to fit.
            pendingPreviousFraction = nil
            pendingPreviousAt = nil
            if !sameWindow { rate = nil }
        }
        anchorFraction = fraction
        anchorAt = date
        windowResetAt = resetAt
        projected = nil
        spentSinceAnchor = 0
    }

    /// Apply a captured-spend read that was started for `readAnchor` and
    /// `learnFrom`. The read runs off the main actor; if a fresh API sample
    /// re-anchored meanwhile, its `since` would add spend the new value already
    /// counts and its `learn` would fit the wrong pair. Then drop it and return
    /// false; the next tick reads again.
    mutating func applyRead(
        learn: Double?,
        since: Double?,
        anchorAt readAnchor: Date,
        learnFrom: Date?,
        now: Date
    ) -> Bool {
        guard anchorAt == readAnchor, pendingPreviousAt == learnFrom else { return false }
        if let learn { self.learn(dollarsBetween: learn) }
        spentSinceAnchor = since ?? 0
        projected = since.flatMap { projectedFraction(spentSinceAnchor: $0, now: now) }
        return true
    }

    /// Consume a pending pair once the caller has summed the spend across it.
    mutating func learn(dollarsBetween: Double) {
        guard let previous = pendingPreviousFraction, let since = pendingPreviousAt else { return }
        defer {
            pendingPreviousFraction = nil
            pendingPreviousAt = nil
        }
        guard anchorAt.timeIntervalSince(since) <= Self.maxLearnableGap else { return }
        guard let candidate = Self.learnedRate(
            previousFraction: previous,
            currentFraction: anchorFraction,
            dollarsBetween: dollarsBetween
        ) else { return }
        rate = blending(candidate)
    }
}
