import Foundation

enum CollectorHealthSuite {
    static func run() -> Int {
        print("CollectorHealth")
        var f = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        f += check("no status file: not connected") {
            try assertEqual(CollectorHealth.assess(status: nil, bundledVersion: 2, now: now).state, .notConnected)
        }
        f += check("missing or older version: outdated, even if recent") {
            try assertEqual(CollectorHealth.assess(status: ["lastBatchAt": 1_799_999_000], bundledVersion: 2, now: now).state, .outdated)
            try assertEqual(CollectorHealth.assess(status: ["version": 1, "lastBatchAt": 1_799_999_000], bundledVersion: 2, now: now).state, .outdated)
        }
        f += check("current version with a recent batch: active") {
            let h = CollectorHealth.assess(status: ["version": 2, "lastBatchAt": now.timeIntervalSince1970 - 300], bundledVersion: 2, now: now)
            try assertEqual(h.state, .active)
            try assertEqual(h.message, "Tracking active · last call 5m ago")
        }
        f += check("no batch for over a day: quiet") {
            let h = CollectorHealth.assess(status: ["version": 2, "lastBatchAt": now.timeIntervalSince1970 - 3 * 86_400], bundledVersion: 2, now: now)
            try assertEqual(h.state, .quiet)
        }
        f += check("bundled version parsed from the collector script") {
            try assertEqual(CollectorHealth.version(inScript: "x = 1\nVERSION = 7\n"), 7)
            try assertEqual(CollectorHealth.version(inScript: "no version"), nil)
        }
        return f
    }
}
