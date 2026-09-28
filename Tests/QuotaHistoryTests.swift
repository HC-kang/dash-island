import Foundation

enum QuotaHistorySuite {
    static func run() -> Int {
        print("QuotaHistory")
        var f = 0
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        f += check("keeps at most one sample per 15 minutes per window (latest wins)") {
            var h = QuotaHistory()
            h.record(window: "5h", used: 0.10, at: t0)
            h.record(window: "5h", used: 0.12, at: t0.addingTimeInterval(300))
            h.record(window: "5h", used: 0.20, at: t0.addingTimeInterval(16 * 60))
            try assertEqual(h.samples["5h"]?.map(\.used), [0.12, 0.20])
        }
        f += check("drops samples older than 8 days") {
            var h = QuotaHistory()
            h.record(window: "wk", used: 0.5, at: t0)
            h.record(window: "wk", used: 0.6, at: t0.addingTimeInterval(9 * 86_400))
            try assertEqual(h.samples["wk"]?.count, 1)
        }
        f += check("series returns the last 7 days in time order") {
            var h = QuotaHistory()
            for day in 0..<9 { h.record(window: "wk", used: Double(day) / 10, at: t0.addingTimeInterval(Double(day) * 86_400)) }
            let now = t0.addingTimeInterval(8 * 86_400)
            let s = h.series(window: "wk", days: 7, now: now)
            try assertEqual(s.first?.used, 0.1)
            try assertEqual(s.last?.used, 0.8)
            try assertEqual(s.count, 8)  // day 1 ... day 8 inclusive at the 7-day edge
        }
        f += check("round-trips as JSON") {
            var h = QuotaHistory()
            h.record(window: "5h", used: 0.3, at: t0)
            let data = try JSONEncoder().encode(h)
            try assertEqual(try JSONDecoder().decode(QuotaHistory.self, from: data), h)
        }
        f += check("nearest sample: closest within tolerance, gap reads as none") {
            let samples = [QuotaHistory.Sample(at: t0, used: 0.1),
                           QuotaHistory.Sample(at: t0.addingTimeInterval(900), used: 0.2),
                           QuotaHistory.Sample(at: t0.addingTimeInterval(7200), used: 0.5)]
            try assertEqual(QuotaHistory.nearest(samples, to: t0.addingTimeInterval(700))?.used ?? -1, 0.2, accuracy: 1e-9)
            try assertEqual(QuotaHistory.nearest(samples, to: t0.addingTimeInterval(7000))?.used ?? -1, 0.5, accuracy: 1e-9)
            // 45 minutes from both neighbours: beyond the 30-minute tolerance.
            try assertTrue(QuotaHistory.nearest(samples, to: t0.addingTimeInterval(900 + 2700)) == nil)
            try assertTrue(QuotaHistory.nearest([], to: t0) == nil)
        }
        return f
    }
}
