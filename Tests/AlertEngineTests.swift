import Foundation

enum AlertEngineSuite {
    static func run() -> Int {
        print("AlertEngine")
        var f = 0
        let reset1 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset2 = reset1.addingTimeInterval(5 * 3_600)
        func step(_ used: Double, _ reset: Date?, _ memory: AlertMemory?) -> (UsageAlert?, AlertMemory) {
            AlertEngine.usage(account: "work", window: "5h", used: used, resetAt: reset, memory: memory)
        }

        f += check("first reading only records, never alerts") {
            let (alert, memory) = step(0.97, reset1, nil)
            try assertEqual(alert, nil)
            try assertEqual(memory, AlertMemory(level: 2, resetAt: reset1))
        }
        f += check("crossing 80% then 95% alerts once each") {
            var m = step(0.50, reset1, nil).1
            let (a1, m1) = step(0.81, reset1, m); m = m1
            try assertEqual(a1, .crossed(account: "work", window: "5h", percent: 81, critical: false))
            let (a2, m2) = step(0.83, reset1, m); m = m2
            try assertEqual(a2, nil)
            let (a3, _) = step(0.96, reset1, m)
            try assertEqual(a3, .crossed(account: "work", window: "5h", percent: 96, critical: true))
        }
        f += check("dipping below 80% and back does not re-alert in the same window") {
            var m = step(0.50, reset1, nil).1
            m = step(0.85, reset1, m).1
            m = step(0.78, reset1, m).1
            try assertEqual(step(0.82, reset1, m).0, nil)
        }
        f += check("window reset after a warning sends one recovery") {
            var m = step(0.50, reset1, nil).1
            m = step(0.90, reset1, m).1
            let (a, m2) = step(0.02, reset2, m)
            try assertEqual(a, .recovered(account: "work", window: "5h"))
            try assertEqual(step(0.03, reset2, m2).0, nil)
        }
        f += check("reset without a prior warning is silent") {
            let m = step(0.40, reset1, nil).1
            try assertEqual(step(0.01, reset2, m).0, nil)
        }
        f += check("sign-in alert once per episode") {
            let (a0, m0) = AlertEngine.signIn(account: "work", needsSignIn: false, memory: nil)
            try assertEqual(a0, nil)
            let (a1, m1) = AlertEngine.signIn(account: "work", needsSignIn: true, memory: m0)
            try assertEqual(a1, .signIn(account: "work"))
            try assertEqual(AlertEngine.signIn(account: "work", needsSignIn: true, memory: m1).0, nil)
            let m2 = AlertEngine.signIn(account: "work", needsSignIn: false, memory: m1).1
            try assertEqual(AlertEngine.signIn(account: "work", needsSignIn: true, memory: m2).0, .signIn(account: "work"))
        }
        f += check("sign-in already broken at first read is not an alert") {
            try assertEqual(AlertEngine.signIn(account: "work", needsSignIn: true, memory: nil).0, nil)
        }
        f += check("notification copy") {
            try assertEqual(UsageAlert.crossed(account: "work", window: "5h", percent: 96, critical: true).title, "work: 5h at 96%")
            try assertEqual(UsageAlert.recovered(account: "work", window: "wk").title, "work: wk limit reset")
            try assertEqual(UsageAlert.signIn(account: "side").title, "side needs sign-in")
            try assertTrue(UsageAlert.crossed(account: "a", window: "wk", percent: 100, critical: true).body.hasPrefix("Limit reached"))
            try assertTrue(UsageAlert.crossed(account: "a", window: "wk", percent: 96, critical: true).body.hasPrefix("Almost out"))
        }
        return f
    }
}
