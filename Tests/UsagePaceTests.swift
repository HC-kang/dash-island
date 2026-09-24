import Foundation

enum UsagePaceSuite {
    static func run() -> Int {
        print("UsagePace")
        var f = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12, minute: 0))!
        let reset = now.addingTimeInterval(4 * 3_600)  // 16:00

        f += check("ratio 2 runs out at half the time to reset") {
            let eta = UsagePace.exhaustion(used: 0.5, resetAt: reset, ratio: 2, now: now)
            try assertEqual(eta, now.addingTimeInterval(2 * 3_600))
        }
        f += check("ratio at or below 1 lasts until reset") {
            try assertEqual(UsagePace.exhaustion(used: 0.5, resetAt: reset, ratio: 1, now: now), nil)
            try assertEqual(UsagePace.exhaustion(used: 0.5, resetAt: reset, ratio: 0.3, now: now), nil)
        }
        f += check("no reset, exhausted, or no pace: no ETA") {
            try assertEqual(UsagePace.exhaustion(used: 0.5, resetAt: nil, ratio: 3, now: now), nil)
            try assertEqual(UsagePace.exhaustion(used: 1.0, resetAt: reset, ratio: 3, now: now), nil)
            try assertEqual(UsagePace.exhaustion(used: 0.5, resetAt: reset, ratio: 0, now: now), nil)
        }
        f += check("ETA rounds to 10 minutes") {
            let eta = UsagePace.exhaustion(used: 0.5, resetAt: reset, ratio: 3, now: now)!  // 80 min
            try assertEqual(eta, now.addingTimeInterval(80 * 60))
            let odd = UsagePace.exhaustion(used: 0.5, resetAt: reset, ratio: 2.9, now: now)!  // 82.8 min
            try assertEqual(odd, now.addingTimeInterval(80 * 60))
        }
        f += check("pace line copy") {
            try assertEqual(UsagePace.line(used: 0.5, resetAt: reset, ratio: 2, now: now, calendar: cal),
                            "out at 14:00, before the 16:00 reset")
            try assertEqual(UsagePace.line(used: 0.5, resetAt: reset, ratio: 0.8, now: now, calendar: cal),
                            "lasts until the 16:00 reset")
            try assertEqual(UsagePace.line(used: 0.5, resetAt: reset, ratio: 0, now: now, calendar: cal), nil)
        }
        return f
    }
}
