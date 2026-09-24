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
        var vendor: String = ""
        /// The account's shortest reported window, for the total across accounts.
        var shortUsed: Double? = nil
        var shortResetAt: Date? = nil
        /// Highest of the account's own windows (5h / wk / mo), without
        /// model-scoped extras such as Fable; nil falls back to `used`.
        var longUsed: Double? = nil
    }

    static let warnAt = 0.80
    static let criticalAt = 0.95

    /// When the compact ears draw. Auto: only without a physical notch, where the
    /// menu-bar center is empty; on a notched display they would cover menu items.
    enum EarsMode: String, CaseIterable, Sendable {
        case auto, always, never
        func shows(hasNotch: Bool) -> Bool {
            switch self {
            case .auto: return !hasNotch
            case .always: return true
            case .never: return false
            }
        }
    }

    var level: Level
    /// Worst account, e.g. "work 72%".
    var leading: String?
    /// "reauth N" when accounts need sign-in, else the worst window's reset countdown.
    var trailing: String?
    var accessibility: String

    /// `totalVendors` non-empty: the leading ear sums the shortest window of every
    /// reporting account of those vendors ("212/500%") and the trailing ear shows
    /// the earliest reset among them. The level still follows the worst account,
    /// so one exhausted account cannot hide inside the total.
    static func make(accounts: [Account], now: Date, totalVendors: Set<String> = []) -> IslandGlance {
        let worst = accounts.filter { $0.used != nil }.max { ($0.used ?? 0) < ($1.used ?? 0) }
        let broken = accounts.filter { $0.health == .error }.count

        var level = Level.normal
        for a in accounts {
            if a.health == .error { level = max(level, .critical) }
            if a.health == .warn && !a.awaiting { level = max(level, .warning) }
            if let u = a.used, u >= criticalAt { level = max(level, .critical) }
            else if let u = a.used, u >= warnAt { level = max(level, .warning) }
        }

        let counted = accounts.filter { totalVendors.contains($0.vendor) && $0.shortUsed != nil }
        let total = !counted.isEmpty
        let sum = counted.reduce(0) { $0 + percent(effectiveShort($1)) }
        let leading = total ? "\(sum)/\(counted.count * 100)%" : worst.map(label)
        let reset = total ? counted.compactMap(\.shortResetAt).filter { $0 > now }.min() : worst?.resetAt
        let trailing: String?
        if broken > 0 {
            trailing = "reauth \(broken)"
        } else if let reset {
            trailing = "↻ " + countdown(reset.timeIntervalSince(now))
        } else {
            trailing = nil
        }
        var spoken = total ? "\(sum) of \(counted.count * 100) percent used across \(counted.count) accounts"
            : worst.map { label($0) + " used" } ?? "No usage reported"
        if broken > 0 { spoken += ", \(broken) need sign-in" }
        return IslandGlance(level: level, leading: leading, trailing: trailing, accessibility: spoken)
    }

    /// Shortest window, unless a longer window is nearly full: wk 100% with 5h 0%
    /// still means the account cannot be used now. (Units differ between windows,
    /// so only a blocking long window overrides.)
    private static func effectiveShort(_ a: Account) -> Double {
        let short = a.shortUsed ?? 0
        guard let top = a.longUsed ?? a.used, top >= criticalAt else { return short }
        return max(short, top)
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
        // The total uses the account's own windows only; model-scoped extras
        // (Fable, reserve) limit one model, not the account.
        let own = usageSnapshot.map { s in [s.primary, s.secondary].compactMap { $0 }.filter(\.isReported) } ?? []
        let shortest = own.min { $0.kind.nominalDuration < $1.kind.nominalDuration }
        return .init(title: title, used: top?.usedFraction, resetAt: top?.resetAt,
                     health: health, awaiting: isAwaitingFirstSample, window: top?.displayLabel,
                     vendor: vendorID, shortUsed: shortest?.usedFraction, shortResetAt: shortest?.resetAt,
                     longUsed: own.map(\.usedFraction).max())
    }
}
