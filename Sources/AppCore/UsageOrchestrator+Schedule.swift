import Foundation

extension UsageOrchestrator {
    // MARK: - Due helper (pure, testable)

    /// Whether an account should be fetched at `now`.
    ///
    /// Due if never fetched, or `now - lastFetch >= max(userInterval, minPoll) - tolerance`.
    /// `retryAt` is the retry time a soft failure named (token gate, CLI ping).
    /// It is due then, even when the idle interval is longer; `minPoll` stays
    /// the floor.
    nonisolated static func isDue(
        lastFetch: Date?,
        now: Date,
        userInterval: TimeInterval,
        minPoll: TimeInterval,
        tolerance: TimeInterval = 0,
        retryAt: Date? = nil
    ) -> Bool {
        guard let lastFetch else { return true }
        if let retryAt, now >= retryAt,
           now.timeIntervalSince(lastFetch) >= minPoll - tolerance
        {
            return true
        }
        let interval = max(userInterval, minPoll)
        guard interval > 0 else { return true }
        return now.timeIntervalSince(lastFetch) >= interval - tolerance
    }

    /// Slack for `isDue`. Ticks land on a fixed grid with run-loop jitter, and a
    /// fetch may start a few seconds after its tick; an exact comparison missed
    /// the 60s slot by milliseconds and polled at 80s. Half a tick can never
    /// pull a poll a whole tick early.
    nonisolated static let dueTolerance: TimeInterval = schedulerTickSeconds / 2

    /// Interval used for expand lazy-refresh: never below `expandDebounceFloor`
    /// or the vendor's `minPollSeconds`.
    nonisolated static func expandInterval(minPoll: TimeInterval) -> TimeInterval {
        max(expandDebounceFloor, minPoll)
    }

    /// Cooldown seconds after a rate limit. Local 2h/4h/6h backoff is capped;
    /// an explicit vendor `Retry-After` is authoritative even when longer.
    nonisolated static func rateLimitWait(
        streak: Int,
        retryAfter: Date?,
        now: Date
    ) -> TimeInterval {
        let vendor = retryAfter.map { $0.timeIntervalSince(now) } ?? 0
        // First 429 with an explicit Retry-After: the vendor knows its own window.
        if streak <= 1, vendor > 0 { return max(60, vendor) }
        // Repeats double: 15m, 30m, 1h, 2h, 4h — capped locally, never below the
        // vendor's own ask.
        let steps = max(0, min(streak, 5) - 1)
        let local = min(rateLimitCooldownMax, rateLimitCooldown * pow(2, Double(steps)))
        return max(60, max(local, vendor))
    }

    /// Spacing after `streak` network errors in a row: 1m, 2m, 4m, then 8m.
    nonisolated static func transientRetryWait(streak: Int) -> TimeInterval {
        let steps = max(0, min(streak, 4) - 1)
        return min(transientRetryMax, transientRetryBase * pow(2, Double(steps)))
    }

    /// Background spacing for one account: fast while it burns or just after its
    /// window rolls over, slow while it sits still.
    ///
    /// Two independent activity signals, because neither alone is complete —
    /// captured calls are accurate but blind to web use and to processes that
    /// predate telemetry, while the last API step is always available but one
    /// sample behind.
    nonisolated static func backgroundInterval(
        spentSinceAnchor: Double?,
        lastPrimaryDelta: Double?,
        windowResetAt: Date?,
        screenLocked: Bool,
        networkFailures: Int = 0,
        now: Date
    ) -> TimeInterval {
        // A failing network is its own schedule: sooner than idle, later than busy.
        if networkFailures > 0 { return transientRetryWait(streak: networkFailures) }
        if let windowResetAt, now >= windowResetAt,
           now.timeIntervalSince(windowResetAt) <= postResetGrace
        {
            return activePollSeconds
        }
        // A locked screen does not stop an agent from burning tokens, and this
        // user's longest runs happen while they are away from the Mac. The
        // inactive floor is for accounts that are genuinely doing nothing.
        if let spentSinceAnchor, spentSinceAnchor > 0 { return activePollSeconds }
        if let lastPrimaryDelta, lastPrimaryDelta >= activeDeltaThreshold { return activePollSeconds }
        return screenLocked
            ? max(backgroundPollSeconds, inactivePollFloor)
            : backgroundPollSeconds
    }
}
