import Foundation

enum UsageProjectionSuite {
    static func run() -> Int {
        print("UsageProjection")
        var failures = 0
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = t0.addingTimeInterval(4 * 3600)

        failures += check("no rate until two samples move the window enough") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            // Nothing to fit from the first sample.
            p.learn(dollarsBetween: 4.0)
            try assertTrue(p.rate == nil)
            try assertTrue(p.projectedFraction(spentSinceAnchor: 9.0, now: t0) == nil)

            // A 1% step is one quantum of API noise — refuse to divide by it.
            p.anchor(fraction: 0.11, resetAt: reset, at: t0.addingTimeInterval(120))
            p.learn(dollarsBetween: 2.0)
            try assertTrue(p.rate == nil)
        }

        failures += check("rate fits from a real move and projects forward") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)            // 10 points over $5 → 0.02/$
            try assertEqual(p.rate ?? 0, 0.02, accuracy: 1e-9)

            let at = t0.addingTimeInterval(400)
            try assertEqual(
                p.projectedFraction(spentSinceAnchor: 2.5, now: at) ?? 0,
                0.25,
                accuracy: 1e-9
            )
        }

        failures += check("projection only adds, and only above the noise floor") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)
            let at = t0.addingTimeInterval(400)
            // No spend, or spend too small to see, draws nothing.
            try assertTrue(p.projectedFraction(spentSinceAnchor: 0, now: at) == nil)
            try assertTrue(p.projectedFraction(spentSinceAnchor: -3, now: at) == nil)
            try assertTrue(p.projectedFraction(spentSinceAnchor: 0.1, now: at) == nil)
            // It can never land below its own anchor.
            let value = p.projectedFraction(spentSinceAnchor: 1.0, now: at) ?? 0
            try assertTrue(value > p.anchorFraction)
        }

        failures += check("a wrong rate cannot run the ring away") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)
            let at = t0.addingTimeInterval(400)
            try assertEqual(
                p.projectedFraction(spentSinceAnchor: 10_000, now: at) ?? 0,
                0.20 + UsageProjection.maxProjectedGain,
                accuracy: 1e-9
            )
        }

        failures += check("a fresh API sample replaces whatever we drew") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)
            p.projected = 0.24
            p.anchor(fraction: 0.31, resetAt: reset, at: t0.addingTimeInterval(600))
            try assertTrue(p.projected == nil)
            try assertEqual(p.anchorFraction, 0.31, accuracy: 1e-9)
        }

        failures += check("window reset drops the anchor and the learned rate") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)
            try assertTrue(p.rate != nil)

            let nextWindow = reset.addingTimeInterval(5 * 3600)
            p.anchor(fraction: 0.02, resetAt: nextWindow, at: reset.addingTimeInterval(60))
            try assertTrue(p.rate == nil)
            // Nothing to fit across a window boundary.
            p.learn(dollarsBetween: 9.0)
            try assertTrue(p.rate == nil)
        }

        failures += check("an anchor past its own reset projects nothing") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)
            try assertTrue(
                p.projectedFraction(spentSinceAnchor: 3, now: reset.addingTimeInterval(1)) == nil
            )
        }

        failures += check("a full window never projects further") {
            var p = UsageProjection()
            p.anchor(fraction: 0.90, resetAt: reset, at: t0)
            p.anchor(fraction: 1.0, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)
            try assertTrue(
                p.projectedFraction(spentSinceAnchor: 5, now: t0.addingTimeInterval(400)) == nil
            )
        }

        failures += check("rate blends instead of jumping to the newest fit") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            p.learn(dollarsBetween: 5.0)                  // 0.02/$
            p.anchor(fraction: 0.40, resetAt: reset, at: t0.addingTimeInterval(600))
            p.learn(dollarsBetween: 2.0)                  // candidate 0.10/$
            let expected = 0.02 * (1 - UsageProjection.smoothing)
                + 0.10 * UsageProjection.smoothing
            try assertEqual(p.rate ?? 0, expected, accuracy: 1e-9)
        }

        failures += check("a stale sample pair is not fitted") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(
                fraction: 0.40,
                resetAt: reset,
                at: t0.addingTimeInterval(UsageProjection.maxLearnableGap + 60)
            )
            p.learn(dollarsBetween: 3.0)
            try assertTrue(p.rate == nil)
        }

        failures += check("a spend read taken before a re-anchor is dropped") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            // The SQLite read starts for this anchor and pending pair …
            let readAnchor = p.anchorAt
            let readLearnFrom = p.pendingPreviousAt
            // … and a poll lands a fresh API sample while it runs.
            p.anchor(fraction: 0.30, resetAt: reset, at: t0.addingTimeInterval(360))
            let applied = p.applyRead(
                learn: 5.0,
                since: 4.0,
                anchorAt: readAnchor,
                learnFrom: readLearnFrom,
                now: t0.addingTimeInterval(370)
            )
            try assertTrue(!applied)
            // Spend the new API value already counts is not added again, and the
            // new pending pair is not consumed with the old pair's dollars.
            try assertTrue(p.projected == nil)
            try assertEqual(p.spentSinceAnchor, 0, accuracy: 0)
            try assertTrue(p.rate == nil)
            try assertEqual(p.pendingPreviousAt, t0.addingTimeInterval(300))
        }

        failures += check("a spend read for the current anchor learns and projects") {
            var p = UsageProjection()
            p.anchor(fraction: 0.10, resetAt: reset, at: t0)
            p.anchor(fraction: 0.20, resetAt: reset, at: t0.addingTimeInterval(300))
            let applied = p.applyRead(
                learn: 5.0,
                since: 2.5,
                anchorAt: p.anchorAt,
                learnFrom: p.pendingPreviousAt,
                now: t0.addingTimeInterval(400)
            )
            try assertTrue(applied)
            try assertEqual(p.rate ?? 0, 0.02, accuracy: 1e-9)
            try assertEqual(p.spentSinceAnchor, 2.5, accuracy: 1e-9)
            try assertEqual(p.projected ?? 0, 0.25, accuracy: 1e-9)
        }

        failures += check("captured spend read is absent, not zero, without a database") {
            let missing = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dash-island-projection-\(UUID().uuidString)")
            let value = AccountUsageReader.capturedDollars(
                provider: "claude",
                identity: "deadbeef",
                from: t0,
                to: t0.addingTimeInterval(300),
                directory: missing
            )
            // nil means "unknown" — the projection must not treat that as no spend.
            try assertTrue(value == nil)
        }

        return failures
    }
}
