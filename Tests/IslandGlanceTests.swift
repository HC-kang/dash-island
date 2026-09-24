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
        f += check("total mode sums the shortest window of the selected vendors") {
            let g = IslandGlance.make(accounts: [
                A(title: "a", used: 0.9, resetAt: nil, health: .ok, vendor: "claude", shortUsed: 0.40, shortResetAt: now.addingTimeInterval(7_200)),
                A(title: "b", used: 0.5, resetAt: nil, health: .ok, vendor: "claude", shortUsed: 0.72, shortResetAt: now.addingTimeInterval(1_800)),
                A(title: "c", used: 0.2, resetAt: nil, health: .ok, vendor: "codex", shortUsed: 0.10, shortResetAt: now.addingTimeInterval(600)),
                A(title: "d", used: 0.3, resetAt: nil, health: .ok, vendor: "grok", shortUsed: 0.30, shortResetAt: now.addingTimeInterval(60)),
            ], now: now, totalVendors: ["claude", "codex"])
            try assertEqual(g.leading, "122/300%")
            try assertEqual(g.trailing, "↻ 10m")          // earliest reset among the counted accounts
            try assertEqual(g.level, .warning)            // rim still follows the worst account (a at 90%)
            try assertEqual(g.accessibility, "122 of 300 percent used across 3 accounts")
        }
        f += check("total mode: a nearly full longer window overrides an empty short one") {
            // wk 100% + 5h 0%: the account cannot be used, so it counts as full.
            let g = IslandGlance.make(accounts: [
                A(title: "a", used: 1.0, resetAt: nil, health: .ok, vendor: "claude", shortUsed: 0.0, shortResetAt: nil),
                A(title: "b", used: 0.6, resetAt: nil, health: .ok, vendor: "claude", shortUsed: 0.1, shortResetAt: nil),
            ], now: now, totalVendors: ["claude"])
            try assertEqual(g.leading, "110/200%")  // a: 100 (blocked), b: 10 (wk 60% is not binding)
        }
        f += check("ears: auto shows them only without a physical notch") {
            try assertEqual(IslandGlance.EarsMode.auto.shows(hasNotch: false), true)
            try assertEqual(IslandGlance.EarsMode.auto.shows(hasNotch: true), false)
            try assertEqual(IslandGlance.EarsMode.always.shows(hasNotch: true), true)
            try assertEqual(IslandGlance.EarsMode.never.shows(hasNotch: false), false)
        }
        f += check("total mode leaves out accounts with nothing reported") {
            let g = IslandGlance.make(accounts: [
                A(title: "a", used: 0.4, resetAt: nil, health: .ok, vendor: "claude", shortUsed: 0.40, shortResetAt: nil),
                A(title: "b", used: nil, resetAt: nil, health: .ok, vendor: "claude", shortUsed: nil, shortResetAt: nil),
            ], now: now, totalVendors: ["claude"])
            try assertEqual(g.leading, "40/100%")
            try assertEqual(g.trailing, nil)
        }
        f += check("total mode with no matching account falls back to the worst account") {
            let g = IslandGlance.make(accounts: [A(title: "a", used: 0.4, resetAt: nil, health: .ok, vendor: "grok", shortUsed: 0.4)],
                                      now: now, totalVendors: ["claude"])
            try assertEqual(g.leading, "a 40%")
        }
        f += check("total mode still shows reauth first") {
            let g = IslandGlance.make(accounts: [
                A(title: "a", used: 0.4, resetAt: nil, health: .ok, vendor: "claude", shortUsed: 0.4, shortResetAt: now.addingTimeInterval(600)),
                A(title: "b", used: nil, resetAt: nil, health: .error, vendor: "claude"),
            ], now: now, totalVendors: ["claude"])
            try assertEqual(g.trailing, "reauth 1")
        }
        return f
    }
}
