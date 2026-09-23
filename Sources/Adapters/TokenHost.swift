import Foundation

/// What a refused OAuth token-endpoint call means for the account.
///
/// Shared by all four adapters. A busy token host is not a usage 429 (that fed
/// the 2h/4h streak) and not a dead login (that painted a red "reconnect").
/// Only a spent or revoked grant needs the user; everything else keeps the
/// session and retries (Claude learned this 2026-08-30/31).
enum TokenHostFailure: Equatable {
    /// The refresh grant is spent or revoked. Only a new sign-in helps.
    case rejected
    /// The client id / secret was refused. Another client may still work.
    case badClient
    /// 429, 5xx, network, or an answer we do not know. Keep the session.
    case unavailable(retryAt: Date?)

    /// Longest quiet one token-host `Retry-After` may impose (was 3h, then 15m).
    static let maxQuiet: TimeInterval = 15 * 60

    private static let grantMarkers = [
        "invalid_grant", "invalid_token",
        // OpenAI (Codex) refresh-token family errors.
        "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
    ]
    private static let clientMarkers = ["invalid_client", "unauthorized_client"]

    static func classify(
        status: Int,
        body: Data,
        retryAfter: String?,
        now: Date = Date()
    ) -> TokenHostFailure {
        if (400...403).contains(status) {
            let text = (String(data: body, encoding: .utf8) ?? "").lowercased()
            if grantMarkers.contains(where: text.contains) { return .rejected }
            if clientMarkers.contains(where: text.contains) { return .badClient }
        }
        if status == 429 {
            return .unavailable(retryAt: quietUntil(retryAfter: retryAfter, now: now))
        }
        return .unavailable(retryAt: nil)
    }

    /// `Retry-After` seconds, capped at `maxQuiet`; no header → `maxQuiet`.
    static func quietUntil(retryAfter: String?, now: Date = Date()) -> Date {
        let cap = now.addingTimeInterval(maxQuiet)
        guard let raw = retryAfter?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0
        else { return cap }
        return min(now.addingTimeInterval(seconds), cap)
    }

    /// Caption text for a soft failure. "token quiet" keeps rings and a yellow
    /// notice (`UsageSnapshotMerge`); it never demands a reconnect.
    static func quietMessage(status: Int?) -> String {
        switch status {
        case nil: return "token quiet — network error"
        case 429?: return "token quiet — oauth rate limited"
        case let code?: return "token quiet — token host HTTP \(code)"
        }
    }

    /// Poll result for a soft refresh failure: last-good rings stay and the
    /// orchestrator retries at `retryAt` (its own soft spacing when nil).
    static func quietSnapshot(message: String, retryAt: Date?, fetchedAt: Date) -> UsageSnapshot {
        var snap = UsageSnapshot(
            primary: WindowUsage(usedFraction: 0, kind: .unknown),
            plan: nil,
            fetchedAt: fetchedAt,
            error: .unavailable(message)
        )
        snap.retryAt = retryAt
        return snap
    }
}
