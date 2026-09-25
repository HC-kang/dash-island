import Foundation

/// Reset credits one account can spend now. A reset clears a usage limit at
/// once and cannot be undone.
///
/// Built to the vendor contracts (Codex `wham/rate-limit-reset-credits`,
/// Claude `cedar_ember`); not yet exercised against a live account.
struct LimitResetOffer: Equatable, Sendable {
    var available: Int
    /// Claude: the grant the vendor spends next (`next_grant_id`). Codex: nil,
    /// the backend picks the next credit.
    var grantID: String? = nil
    /// Claude: the vendor refuses unless a limit is full (`use_requires_limit`).
    var requiresLimit = false
    /// Claude: `at_limit`. Nil when the vendor does not say.
    var atLimit: Bool? = nil
    /// Claude limit kinds the grant clears, e.g. `five_hour`, `seven_day`.
    var clears: [String] = []
    var expiresAt: Date? = nil
    /// Vendor reason when the account cannot use resets at all.
    var ineligibleReason: String? = nil

    /// Whether a Use button can do anything. The vendor still decides.
    var canUse: Bool {
        guard available > 0, ineligibleReason == nil else { return false }
        return !(requiresLimit && atLimit == false)
    }
}

/// Definite vendor answers. Only `reset` and `alreadyDone` spend a credit.
enum LimitResetResult: Equatable, Sendable {
    case reset(left: Int?)
    /// The same request id already completed; count it as success.
    case alreadyDone
    case notLimited
    case noCredit
    /// Ineligible, cooldown, expired grant, …: nothing was spent.
    case refused(reason: String)
}

/// The call did not produce a definite answer. After `network` or `http` the
/// vendor may have spent the credit, so a retry must reuse the request id.
enum LimitResetFailure: Error, Equatable, Sendable {
    case authRequired
    case rateLimited
    case http(Int)
    case network
    case parse
    /// Credentials or the organization id are missing, or a refresh is running.
    case unavailable

    /// Whether the credit may already be spent.
    var outcomeUnknown: Bool {
        switch self {
        case .network, .http, .parse: return true
        case .authRequired, .rateLimited, .unavailable: return false
        }
    }
}

/// Vendors that support spending reset credits.
protocol LimitResetting: Sendable {
    func limitResetOffer(_ ref: CredentialRef) async -> Result<LimitResetOffer, LimitResetFailure>
    /// Spends one credit. `requestID` is the idempotency key: reuse it when
    /// retrying the same attempt.
    func useLimitReset(
        _ ref: CredentialRef,
        offer: LimitResetOffer,
        requestID: String
    ) async -> Result<LimitResetResult, LimitResetFailure>
}

extension LimitResetFailure {
    /// Maps an HTTP status of a reset call. Nil means 2xx.
    static func from(status: Int) -> LimitResetFailure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .authRequired
        case 429: return .rateLimited
        default: return .http(status)
        }
    }
}
