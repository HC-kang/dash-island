import Foundation

/// What we remember per (account, window) so an alert fires once per crossing.
/// `level`: 0 normal, 1 warning (80%), 2 critical (95%); for sign-in, 1 = broken.
struct AlertMemory: Codable, Equatable, Sendable {
    var level: Int
    var resetAt: Date?
}

enum UsageAlert: Equatable, Sendable {
    case crossed(account: String, window: String, percent: Int, critical: Bool)
    case recovered(account: String, window: String)
    case signIn(account: String)

    var kind: String {
        switch self {
        case .crossed(_, _, _, let critical): return critical ? "critical" : "warning"
        case .recovered: return "recovered"
        case .signIn: return "signIn"
        }
    }

    var title: String {
        switch self {
        case .crossed(let a, let w, let p, _): return "\(a): \(w) at \(p)%"
        case .recovered(let a, let w): return "\(a): \(w) limit reset"
        case .signIn(let a): return "\(a) needs sign-in"
        }
    }

    var body: String {
        switch self {
        case .crossed(_, _, let percent, let critical):
            if percent >= 100 { return "Limit reached. Requests are refused until the window resets." }
            return critical ? "Almost out. Requests may be refused until the window resets." : "Usage passed 80% of this window."
        case .recovered: return "The window reset. Usage is back below 80%."
        case .signIn: return "Open Dash Island and choose Reauthenticate."
        }
    }
}

/// Pure alert policy. First reading only records; a level rise within one reset
/// window alerts once; a reset after a warning sends one recovery.
enum AlertEngine {
    static func level(_ used: Double) -> Int {
        used >= IslandGlance.criticalAt ? 2 : used >= IslandGlance.warnAt ? 1 : 0
    }

    static func usage(account: String, window: String, used: Double, resetAt: Date?,
                      memory: AlertMemory?) -> (UsageAlert?, AlertMemory) {
        let now = level(used)
        guard let memory else { return (nil, AlertMemory(level: now, resetAt: resetAt)) }
        if let old = memory.resetAt, let new = resetAt, abs(new.timeIntervalSince(old)) > 60 {
            let alert: UsageAlert? = memory.level >= 1 && now == 0 ? .recovered(account: account, window: window) : nil
            return (alert, AlertMemory(level: now, resetAt: resetAt))
        }
        guard now > memory.level else { return (nil, memory) }  // keep the max within a window
        let alert = UsageAlert.crossed(account: account, window: window,
                                       percent: IslandGlance.percent(used), critical: now == 2)
        return (alert, AlertMemory(level: now, resetAt: resetAt ?? memory.resetAt))
    }

    static func signIn(account: String, needsSignIn: Bool, memory: AlertMemory?) -> (UsageAlert?, AlertMemory) {
        let now = AlertMemory(level: needsSignIn ? 1 : 0, resetAt: nil)
        guard let memory else { return (nil, now) }
        return (needsSignIn && memory.level == 0 ? .signIn(account: account) : nil, now)
    }
}
