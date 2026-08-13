import Foundation

/// Semantic usage window — drives hover labels (not hardcoded "5h"/"wk").
enum UsageWindowKind: String, Codable, Equatable, Sendable {
    case fiveHour
    case weekly
    case monthly
    case unknown

    /// Compact tooltip prefix.
    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "wk"
        case .monthly: return "mo"
        case .unknown: return "—"
        }
    }

    /// Nominal full-window length when the API omits `resetAt`.
    /// Used only for cruise fallback: even pace = `1 / duration`.
    var nominalDuration: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .weekly: return 7 * 24 * 3600
        case .monthly: return 30 * 24 * 3600
        case .unknown: return 5 * 3600
        }
    }

    /// Infer from a vendor's `limit_window_seconds` (Codex / similar).
    static func fromLimitSeconds(_ seconds: Double?) -> UsageWindowKind {
        guard let seconds, seconds > 0 else { return .unknown }
        // 5h = 18_000; allow up to ~6h for short rolling windows.
        if seconds <= 6 * 3600 { return .fiveHour }
        // Week = 604_800; allow up to ~10 days.
        if seconds <= 10 * 24 * 3600 { return .weekly }
        return .monthly
    }
}

struct WindowUsage: Codable, Equatable, Sendable {
    /// Always normalized to 0...1 (used fraction of the window).
    var usedFraction: Double
    var resetAt: Date?
    var usedTokens: Int64?
    var limitTokens: Int64?
    /// What this window is (5h / week / month). Hover uses `displayLabel`.
    var kind: UsageWindowKind
    /// Optional hover label override (e.g. Claude scoped model name "Fable").
    var labelOverride: String? = nil

    init(
        usedFraction: Double,
        resetAt: Date? = nil,
        usedTokens: Int64? = nil,
        limitTokens: Int64? = nil,
        kind: UsageWindowKind = .unknown,
        labelOverride: String? = nil
    ) {
        self.usedFraction = usedFraction
        self.resetAt = resetAt
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.kind = kind
        self.labelOverride = labelOverride
    }

    var displayLabel: String {
        if let labelOverride, !labelOverride.isEmpty { return labelOverride }
        return kind.shortLabel
    }

    var hasAbsoluteCounters: Bool {
        guard let usedTokens, let limitTokens, limitTokens > 0, usedTokens >= 0 else {
            return false
        }
        return true
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var primary: WindowUsage
    var secondary: WindowUsage?
    /// Optional third ring (Claude Fable, Codex model-scoped limits, …).
    /// Not used for burn / needle.
    var tertiary: WindowUsage? = nil
    /// Extra hover-only windows (more model scopes after tertiary). Not rings, not burn.
    var extras: [WindowUsage] = []
    var plan: String?
    var fetchedAt: Date
    var error: UsageError?
    /// Soft non-fatal notice (e.g. token expiring soon).
    var notice: String? = nil

    /// Window used for burn / needle.
    ///
    /// Kind priority only: **5h → weekly → monthly**. No absolute-counter
    /// shortcuts — Grok credits are weekly, so burn stays on weekly even when
    /// a monthly `used`/`limit` secondary exists (rings still show both).
    /// `tertiary` / `extras` never participate.
    var preferredBurnWindow: WindowUsage {
        let windows: [WindowUsage] = {
            var list = [primary]
            if let secondary { list.append(secondary) }
            return list
        }()

        func first(_ kind: UsageWindowKind) -> WindowUsage? {
            windows.first { $0.kind == kind }
        }

        if let fiveHour = first(.fiveHour) { return fiveHour }
        if let weekly = first(.weekly) { return weekly }
        if let monthly = first(.monthly) { return monthly }
        return primary
    }
}

/// Pure helpers for promoting model-scoped windows onto the third ring.
enum UsageRingLayout {
    /// Prefer a window labeled "Fable" (Claude), else the first scoped extra.
    static func preferredTertiary(from extras: [WindowUsage]) -> WindowUsage? {
        if let fable = extras.first(where: { isFableLabel($0.displayLabel) }) {
            return fable
        }
        return extras.first
    }

    /// Extras left for hover after promoting one to the tertiary ring.
    static func remainingExtras(
        extras: [WindowUsage],
        tertiary: WindowUsage?
    ) -> [WindowUsage] {
        guard let tertiary else { return extras }
        var removed = false
        return extras.filter { extra in
            if !removed, sameScopedWindow(extra, tertiary) {
                removed = true
                return false
            }
            return true
        }
    }

    static func isFableLabel(_ label: String) -> Bool {
        label.range(of: "fable", options: .caseInsensitive) != nil
    }

    private static func sameScopedWindow(_ a: WindowUsage, _ b: WindowUsage) -> Bool {
        if let la = a.labelOverride, let lb = b.labelOverride, la == lb {
            return true
        }
        return a.displayLabel == b.displayLabel
            && abs(a.usedFraction - b.usedFraction) < 0.000_1
    }
}

/// Where the needle signal came from (for hover honesty).
enum BurnSignalSource: String, Equatable, Sendable {
    case none
    case api
    case local
    case both

    var hoverHint: String? {
        switch self {
        case .none: return nil
        case .api: return "needle: api Δ"
        case .local: return "needle: local activity"
        case .both: return "needle: api + local"
        }
    }
}

enum UsageError: Codable, Equatable, Sendable {
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
