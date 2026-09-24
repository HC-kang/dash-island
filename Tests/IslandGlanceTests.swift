import Foundation

enum IslandGlanceSuite {
    static func run() -> Int {
        print("IslandGlance")
        var f = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        typealias A = IslandGlance.Account

        f += check("no accounts: normal, no ears") {
            let g = IslandGlance.make(accounts: [], now: now)
            try assertEqual(g.level, .normal)
            try assertEqual(g.leading, nil)
            try assertEqual(g.trailing, nil)
        }
        f += check("worst account leads with its percent and reset countdown") {
            let g = IslandGlance.make(accounts: [
                A(title: "home", used: 0.18, resetAt: now.addingTimeInterval(3_600), health: .ok),
                A(title: "work", used: 0.72, resetAt: now.addingTimeInterval(2 * 3_600 + 600), health: .ok),
            ], now: now)
            try assertEqual(g.level, .normal)
            try assertEqual(g.leading, "work 72%")
            try assertEqual(g.trailing, "↻ 2h 10m")
        }
        f += check("leading names the window when known") {
            let g = IslandGlance.make(accounts: [A(title: "Dev", used: 1.0, resetAt: nil, health: .ok, window: "wk")], now: now)
            try assertEqual(g.leading, "Dev wk 100%")
            try assertEqual(g.accessibility, "Dev wk 100% used")
        }
        f += check("80% is warning, 95% is critical") {
            try assertEqual(IslandGlance.make(accounts: [A(title: "a", used: 0.8, resetAt: nil, health: .ok)], now: now).level, .warning)
            try assertEqual(IslandGlance.make(accounts: [A(title: "a", used: 0.95, resetAt: nil, health: .ok)], now: now).level, .critical)
            try assertEqual(IslandGlance.make(accounts: [A(title: "a", used: 0.79, resetAt: nil, health: .ok)], now: now).level, .normal)
        }
        f += check("reauth needed is critical and replaces the countdown") {
            let g = IslandGlance.make(accounts: [
                A(title: "work", used: 0.30, resetAt: now.addingTimeInterval(600), health: .ok),
                A(title: "side", used: nil, resetAt: nil, health: .error),
            ], now: now)
            try assertEqual(g.level, .critical)
            try assertEqual(g.leading, "work 30%")
            try assertEqual(g.trailing, "reauth 1")
        }
        f += check("warn health (not awaiting first sample) is warning") {
            try assertEqual(IslandGlance.make(accounts: [A(title: "a", used: 0.1, resetAt: nil, health: .warn)], now: now).level, .warning)
            try assertEqual(IslandGlance.make(accounts: [A(title: "a", used: nil, resetAt: nil, health: .warn, awaiting: true)], now: now).level, .normal)
        }
        f += check("accessibility summary names the worst account") {
            let g = IslandGlance.make(accounts: [A(title: "work", used: 0.72, resetAt: nil, health: .ok)], now: now)
            try assertEqual(g.accessibility, "work 72% used")
        }
        f += check("countdown formats minutes and days") {
            try assertEqual(IslandGlance.countdown(45 * 60), "45m")
            try assertEqual(IslandGlance.countdown(3 * 86_400 + 5 * 3_600), "3d 5h")
            try assertEqual(IslandGlance.countdown(-5), "now")
        }
        return f
    }
}
