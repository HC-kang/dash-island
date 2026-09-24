import Foundation

/// Pure post-wake poll decisions (same pattern as codex-island).
///
/// Right after wake, Wi-Fi is still joining, every dormant Claude Code session
/// reconnects against the same per-account usage limiter, and an access token
/// may have expired during sleep. A poll in that minute tends to come back as
/// "network", "rate limited" or "token expired" and then costs a cooldown.
enum WakeScheduling {
    /// How late a repeating-timer fire must be before it counts as the catch-up
    /// fire after sleep rather than run-loop jitter. Jitter and a busy main
    /// thread cost seconds; only sleep costs minutes.
    static let overdueSlack: TimeInterval = 120

    /// How long after wake to hold network polls.
    static let graceDelay: TimeInterval = 60

    /// True when a repeating timer fires so far past its schedule that the Mac
    /// must have slept through it. Covers a wake whose notifications we missed.
    static func isOverdueFire(now: Date, expected: Date?) -> Bool {
        guard let expected else { return false }
        return now.timeIntervalSince(expected) > overdueSlack
    }

    /// Whether a poll must wait out the post-wake grace. A manual refresh is an
    /// explicit ask and always goes.
    static func holdsPoll(now: Date, graceUntil: Date?, manual: Bool) -> Bool {
        guard !manual, let graceUntil else { return false }
        return now < graceUntil
    }
}
