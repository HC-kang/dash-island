import Foundation

/// What the compact island shows at rest: a severity for the rim and two short
/// ear strings. Pure so thresholds and copy are unit-tested.
struct IslandGlance: Equatable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case normal, warning, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Account: Equatable, Sendable {
        var title: String
        /// Highest reported window used fraction; nil while nothing is reported.
        var used: Double?
        /// Reset of that window.
        var resetAt: Date?
        var health: AccountHealth
        var awaiting: Bool = false
        /// Short window name ("5h", "wk", "Fable") of `used`.
        var window: String? = nil
    }

    static let warnAt = 0.80
    static let criticalAt = 0.95

    var level: Level
    /// Worst account, e.g. "work 72%".
    var leading: String?
    /// "reauth N" when accounts need sign-in, else the worst window's reset countdown.
    var trailing: String?
    var accessibility: String

    static func make(accounts: [Account], now: Date) -> IslandGlance {
        let worst = accounts.filter { $0.used != nil }.max { ($0.used ?? 0) < ($1.used ?? 0) }
        let broken = accounts.filter { $0.health == .error }.count

        var level = Level.normal
        for a in accounts {
            if a.health == .error { level = max(level, .critical) }
            if a.health == .warn && !a.awaiting { level = max(level, .warning) }
            if let u = a.used, u >= criticalAt { level = max(level, .critical) }
            else if let u = a.used, u >= warnAt { level = max(level, .warning) }
        }

        let leading = worst.map(label)
        let trailing: String?
        if broken > 0 {
            trailing = "reauth \(broken)"
        } else if let reset = worst?.resetAt {
            trailing = "↻ " + countdown(reset.timeIntervalSince(now))
        } else {
            trailing = nil
        }
        var spoken = worst.map { label($0) + " used" } ?? "No usage reported"
        if broken > 0 { spoken += ", \(broken) need sign-in" }
        return IslandGlance(level: level, leading: leading, trailing: trailing, accessibility: spoken)
    }

    private static func label(_ a: Account) -> String {
        [a.title, a.window, "\(percent(a.used ?? 0))%"].compactMap { $0 }.joined(separator: " ")
    }

    static func percent(_ f: Double) -> Int { Int((min(max(f, 0), 1) * 100).rounded()) }

    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "now" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
        let h = m / 60
        return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h"
    }
}

extension WidgetViewModel {
    /// Glance input: the highest reported window, not the display-mapped ring.
    var glanceAccount: IslandGlance.Account {
        let windows = usageSnapshot.map { s in
            ([s.primary] + [s.secondary, s.tertiary].compactMap { $0 } + s.extras).filter(\.isReported)
        } ?? []
        let top = windows.max { $0.usedFraction < $1.usedFraction }
        return .init(title: title, used: top?.usedFraction, resetAt: top?.resetAt,
                     health: health, awaiting: isAwaitingFirstSample, window: top?.displayLabel)
    }
}
