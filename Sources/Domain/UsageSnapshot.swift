import Foundation

struct WindowUsage: Equatable, Sendable {
    /// Always normalized to 0...1 (used fraction of the window).
    var usedFraction: Double
    var resetAt: Date?
    var usedTokens: Int64?
    var limitTokens: Int64?
}

struct UsageSnapshot: Equatable, Sendable {
    var primary: WindowUsage
    var secondary: WindowUsage?
    var plan: String?
    var fetchedAt: Date
    var error: UsageError?
}

enum UsageError: Equatable, Sendable {
    /// Credential missing or rejected; user should reauthenticate.
    case authRequired
    /// Rate limited; optional earliest retry time.
    case rateLimited(retryAfter: Date?)
    /// Transient network failure.
    case network(String)
    /// Response could not be parsed.
    case parse(String)
    /// Soft / vendor-unavailable with caption.
    case unavailable(String)
}
