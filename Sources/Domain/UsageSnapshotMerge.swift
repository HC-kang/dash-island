import Foundation

/// Soft vs hard failure policy for usage polls (reference-client style).
///
/// - **soft**: keep last-good rings; surface quiet caption; do not demand reauth.
/// - **hard**: keep last-good rings if any, but always show reauth / terminal caption.
enum UsageFailureKind: Equatable, Sendable {
    case soft
    case hard
}

/// Why an `.unavailable` poll failed. Adapters still report free text; it is
/// classified here once so severity, stale notice and captions cannot disagree.
enum UnavailableReason: Equatable, Sendable {
    /// Scope / login-family failure — only a browser login for this account helps.
    case needsLogin
    /// Token host quiet (oauth/token 429) — keep rings, retry later.
    case tokenQuiet
    /// Our own refresh spacing — a retry is already scheduled.
    case refreshPending
    /// Anything else transient.
    case temporary

    init(message: String) {
        let lower = message.lowercased()
        if ["setup-token", "user:profile", "need browser", "reauthenticate", "invalid_grant", "token family"]
            .contains(where: lower.contains)
        {
            self = .needsLogin
        } else if ["token quiet", "rate limit", "rate-limit", "ratelimit"].contains(where: lower.contains) {
            // Not a bare "rate": that also matches "generate" and "separate".
            self = .tokenQuiet
        } else if lower.contains("refresh pending") {
            self = .refreshPending
        } else {
            self = .temporary
        }
    }
}

extension UsageError {
    var unavailableReason: UnavailableReason? {
        if case .unavailable(let message) = self { return UnavailableReason(message: message) }
        return nil
    }
}

enum UsageSnapshotMerge {
    /// Classify a vendor error for retention / UX.
    static func failureKind(_ error: UsageError) -> UsageFailureKind {
        switch error {
        case .authRequired:
            return .hard
        case .rateLimited:
            return .soft
        case .network, .parse:
            return .soft
        case .unavailable(let message):
            // Login-family failures — user must reconnect this account. Token quiet,
            // hard-expired access and transient refresh failures keep rings.
            return UnavailableReason(message: message) == .needsLogin ? .hard : .soft
        }
    }

    /// Soft notice when we display previous rings after a failed poll.
    static func softStaleNotice(for error: UsageError) -> String {
        switch error {
        case .rateLimited:
            return String(localized: "stale · oauth rate limited (last-good rings)")
        case .network:
            return String(localized: "stale · network blip (last-good rings)")
        case .parse:
            return String(localized: "stale · bad response (last-good rings)")
        case .unavailable(let message):
            switch UnavailableReason(message: message) {
            case .tokenQuiet: return String(localized: "stale · token host quiet (last-good rings)")
            case .refreshPending: return String(localized: "stale · refresh scheduled (last-good rings)")
            case .needsLogin, .temporary: return String(localized: "stale · temporary (last-good rings)")
            }
        case .authRequired:
            return String(localized: "reconnect this account")
        }
    }

    /// Whether `previous` (error-free good sample) should remain the ring source.
    /// Always true when previous exists — both soft and hard keep visual last-good.
    /// Hard only changes caption severity (caller uses `failureKind`).
    static func shouldRetainPreviousRings(previous: UsageSnapshot?) -> Bool {
        guard let previous, previous.error == nil else { return false }
        // Require a real fraction so we never "retain" an empty cold error.
        return previous.primary.usedFraction >= 0 || previous.secondary != nil
    }
}
