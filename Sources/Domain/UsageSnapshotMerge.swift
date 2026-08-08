import Foundation

/// Soft vs hard failure policy for usage polls (Certilife-style).
///
/// - **soft**: keep last-good rings; surface quiet caption; do not demand reauth.
/// - **hard**: keep last-good rings if any, but always show reauth / terminal caption.
enum UsageFailureKind: Equatable, Sendable {
    case soft
    case hard
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
            let lower = message.lowercased()
            // Scope / login-family failures — user must reconnect this account.
            if lower.contains("setup-token")
                || lower.contains("user:profile")
                || lower.contains("need browser")
                || lower.contains("reauthenticate")
                || lower.contains("invalid_grant")
                || lower.contains("token family")
            {
                return .hard
            }
            // token quiet / hard-expired / transient refresh — keep rings.
            return .soft
        }
    }

    /// Soft notice when we display previous rings after a failed poll.
    static func softStaleNotice(for error: UsageError) -> String {
        switch error {
        case .rateLimited:
            return "stale · rate limited (last-good rings)"
        case .network:
            return "stale · network blip (last-good rings)"
        case .parse:
            return "stale · bad response (last-good rings)"
        case .unavailable:
            return "stale · temporary (last-good rings)"
        case .authRequired:
            return "reconnect this account"
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
