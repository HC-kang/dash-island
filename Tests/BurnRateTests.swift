import Foundation

enum BurnRateSuite {
    static func run() -> Int {
        print("BurnRate")
        var failures = 0

        failures += check("ratio is 0 when only one sample / no prev") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let burn = BurnRate.compute(
                prev: nil,
                current: (usedFraction: 0.40, at: now),
                resetAt: now.addingTimeInterval(5 * 3600)
            )
            try assertEqual(burn.ratio, 0, accuracy: 1e-9)
            try assertEqual(Double(burn.sampleCount), 1, accuracy: 0)
        }

        failures += check("ratio is 1 when Δ matches cruise-to-reset") {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let dt: TimeInterval = 3600
            let timeToReset: TimeInterval = 4 * 3600
            let t1 = t0.addingTimeInterval(dt)
            let resetAt = t1.addingTimeInterval(timeToReset)
            let u0 = 0.20
            let u1 = (u0 * timeToReset + dt) / (timeToReset + dt)

            let burn = BurnRate.compute(
                prev: (usedFraction: u0, at: t0),
                current: (usedFraction: u1, at: t1),
                resetAt: resetAt,
                kind: .fiveHour
            )
            try assertEqual(burn.ratio, 1.0, accuracy: 1e-9)
            try assertEqual(Double(burn.sampleCount), 2, accuracy: 0)
        }

        failures += check("5h empty bar: ~1.67% per 5m poll → cruise (ratio≈1)") {
            // User model: 5h / 5m = 60 ticks → ~1.667% per poll at even pace.
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let dt: TimeInterval = 5 * 60
            let t1 = t0.addingTimeInterval(dt)
            let du = dt / (5 * 3600) // 300/18000 = 1/60
            let r = BurnRate.instantRatio(
                prev: BurnSample(usedFraction: 0, at: t0, resetAt: nil, kind: .fiveHour),
                current: BurnSample(usedFraction: du, at: t1, resetAt: nil, kind: .fiveHour)
            )
            try assertEqual(r ?? -1, 1.0, accuracy: 1e-9)
        }

        failures += check("needleUnit: 0 → rest, 1 → cruise, ≥2 soft-cap redline") {
            try assertEqual(BurnRate.needleUnit(ratio: 0), 0.0, accuracy: 1e-12)
            try assertEqual(BurnRate.needleUnit(ratio: 1), 0.5, accuracy: 1e-12)
            try assertEqual(BurnRate.needleUnit(ratio: 2), 1.0, accuracy: 1e-12)
            try assertEqual(BurnRate.needleUnit(ratio: 3), 1.0, accuracy: 1e-12)
            try assertEqual(BurnRate.needleUnit(ratio: -1), 0.0, accuracy: 1e-12)
        }

        failures += check("negative usage delta yields ratio 0") {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let t1 = t0.addingTimeInterval(3600)
            let burn = BurnRate.compute(
                prev: (usedFraction: 0.50, at: t0),
                current: (usedFraction: 0.40, at: t1),
                resetAt: t1.addingTimeInterval(4 * 3600)
            )
            try assertEqual(burn.ratio, 0, accuracy: 1e-9)
        }

        failures += check("flat usage is no-signal (nil), not forced rest") {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let t1 = t0.addingTimeInterval(3600)
            let r = BurnRate.instantRatio(
                prev: BurnSample(usedFraction: 0.12, at: t0, resetAt: t1.addingTimeInterval(4 * 3600), kind: .fiveHour),
                current: BurnSample(usedFraction: 0.12, at: t1, resetAt: t1.addingTimeInterval(4 * 3600), kind: .fiveHour)
            )
            try assertTrue(r == nil, "flat whole-percent should be nil signal")
        }

        failures += check("absolute counters detect tiny monthly burn") {
            // Live Grok: +8 units / 15s on 150k limit → strong ratio.
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let t1 = t0.addingTimeInterval(15)
            let reset = t1.addingTimeInterval(300 * 3600)
            let r = BurnRate.instantRatio(
                prev: BurnSample(
                    usedFraction: 29_176.0 / 150_000.0,
                    at: t0,
                    resetAt: reset,
                    kind: .monthly,
                    usedTokens: 29_176,
                    limitTokens: 150_000
                ),
                current: BurnSample(
                    usedFraction: 29_184.0 / 150_000.0,
                    at: t1,
                    resetAt: reset,
                    kind: .monthly,
                    usedTokens: 29_184,
                    limitTokens: 150_000
                )
            )
            try assertTrue((r ?? 0) > 1.0, "active monthly burn should exceed cruise, got \(String(describing: r))")
        }

        failures += check("preferredBurnWindow: 5h beats weekly and monthly") {
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.26, kind: .fiveHour),
                secondary: WindowUsage(usedFraction: 0.02, kind: .weekly),
                plan: nil,
                fetchedAt: Date(),
                error: nil
            )
            try assertEqual(snap.preferredBurnWindow.kind, UsageWindowKind.fiveHour)
            try assertEqual(snap.preferredBurnWindow.usedFraction, 0.26, accuracy: 1e-9)
        }

        failures += check("preferredBurnWindow: weekly when no 5h") {
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.12, kind: .weekly),
                secondary: WindowUsage(usedFraction: 0.40, kind: .monthly),
                plan: nil,
                fetchedAt: Date(),
                error: nil
            )
            try assertEqual(snap.preferredBurnWindow.kind, UsageWindowKind.weekly)
        }

        failures += check("preferredBurnWindow: Grok weekly beats monthly absolute") {
            // Grok primary is weekly credits; monthly secondary may have finer
            // counters but burn must follow weekly (user rule).
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.12, kind: .weekly),
                secondary: WindowUsage(
                    usedFraction: 0.19,
                    usedTokens: 28_892,
                    limitTokens: 150_000,
                    kind: .monthly
                ),
                plan: nil,
                fetchedAt: Date(),
                error: nil
            )
            try assertEqual(snap.preferredBurnWindow.kind, UsageWindowKind.weekly)
            try assertEqual(snap.preferredBurnWindow.usedFraction, 0.12, accuracy: 1e-9)
        }

        failures += check("preferredBurnWindow: monthly when only monthly") {
            let snap = UsageSnapshot(
                primary: WindowUsage(usedFraction: 0.33, kind: .monthly),
                secondary: nil,
                plan: nil,
                fetchedAt: Date(),
                error: nil
            )
            try assertEqual(snap.preferredBurnWindow.kind, UsageWindowKind.monthly)
        }

        failures += check("weekly cruise is 1/7d not 1/5h") {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let dt: TimeInterval = 5 * 60
            let t1 = t0.addingTimeInterval(dt)
            // +1% of weekly limit in 5 minutes is a massive burn vs even weekly pace.
            let r = BurnRate.instantRatio(
                prev: BurnSample(usedFraction: 0.05, at: t0, resetAt: nil, kind: .weekly),
                current: BurnSample(usedFraction: 0.06, at: t1, resetAt: nil, kind: .weekly)
            )
            // du/dt / (1/W) = 0.01/300 * 604800 = 20.16
            try assertEqual(r ?? -1, 0.01 / dt * (7 * 24 * 3600), accuracy: 1e-6)
        }

        failures += check("5h +1% over 5m is ~0.6 cruise (not dead)") {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let dt: TimeInterval = 5 * 60
            let t1 = t0.addingTimeInterval(dt)
            let r = BurnRate.instantRatio(
                prev: BurnSample(usedFraction: 0.26, at: t0, resetAt: nil, kind: .fiveHour),
                current: BurnSample(usedFraction: 0.27, at: t1, resetAt: nil, kind: .fiveHour)
            )
            // 0.01/300 / (1/18000) = 0.6
            try assertEqual(r ?? -1, 0.6, accuracy: 1e-9)
        }

        failures += check("coarse +1% uses previous sample (not 15m dilute)") {
            var sm = BurnSmoother()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let reset = t0.addingTimeInterval(4 * 3600)
            _ = sm.push(BurnSample(usedFraction: 0.26, at: t0, resetAt: reset, kind: .fiveHour))
            // Flat samples every 3 min would previously pick a 15m-old baseline.
            _ = sm.push(BurnSample(usedFraction: 0.26, at: t0.addingTimeInterval(180), resetAt: reset, kind: .fiveHour))
            _ = sm.push(BurnSample(usedFraction: 0.26, at: t0.addingTimeInterval(360), resetAt: reset, kind: .fiveHour))
            let b = sm.push(BurnSample(usedFraction: 0.27, at: t0.addingTimeInterval(540), resetAt: reset, kind: .fiveHour))
            try assertTrue(b.ratio > 0.4, "integer tick vs previous sample should seed, got \(b.ratio)")
        }

        failures += check("noteLiveActivity seeds needle without API delta") {
            var sm = BurnSmoother()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let b = sm.noteLiveActivity(ratio: 1.2, at: t0)
            try assertEqual(b.ratio, 1.2, accuracy: 1e-9)
        }

        failures += check("ewmaAlpha grows with dt toward 1") {
            let aShort = BurnRate.ewmaAlpha(dt: 60, tau: 45 * 60)
            let aLong = BurnRate.ewmaAlpha(dt: 45 * 60, tau: 45 * 60)
            try assertTrue(aShort < aLong)
            try assertTrue(aShort > 0 && aShort < 1)
            // One full τ: α = 1 − e⁻¹ ≈ 0.632
            try assertEqual(aLong, 1 - exp(-1), accuracy: 1e-9)
        }

        failures += check("ewmaStep seeds then damps a spike") {
            let t = 5 * 60.0 // 5 min poll
            let s0 = BurnRate.ewmaStep(previous: nil, instant: 1.0, dt: t)
            try assertEqual(s0, 1.0, accuracy: 1e-12)
            // Spike to 4, but τ=45m so one 5m step only moves a little.
            let s1 = BurnRate.ewmaStep(previous: s0, instant: 4.0, dt: t, tau: 45 * 60)
            try assertTrue(s1 > s0 && s1 < 2.0, "spike should be heavily damped, got \(s1)")
        }

        failures += check("BurnSmoother absolute path holds on flat (no drop to 0)") {
            var sm = BurnSmoother()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let reset = t0.addingTimeInterval(300 * 3600)
            let lim: Int64 = 150_000

            _ = sm.push(BurnSample(
                usedFraction: 0.19, at: t0, resetAt: reset, kind: .monthly,
                usedTokens: 28_500, limitTokens: lim
            ))
            let b1 = sm.push(BurnSample(
                usedFraction: 0.1905, at: t0.addingTimeInterval(60), resetAt: reset, kind: .monthly,
                usedTokens: 28_575, limitTokens: lim
            ))
            try assertTrue(b1.ratio > 0.5, "should seed from absolute Δ, got \(b1.ratio)")

            // Flat poll 60s later — must HOLD, not slam to 0.
            let held = b1.ratio
            let b2 = sm.push(BurnSample(
                usedFraction: 0.1905, at: t0.addingTimeInterval(120), resetAt: reset, kind: .monthly,
                usedTokens: 28_575, limitTokens: lim
            ))
            try assertEqual(b2.ratio, held, accuracy: 1e-6)

            // Coarse weekly sample with different reset must not wipe absolute history.
            let weekReset = t0.addingTimeInterval(7 * 24 * 3600)
            let b3 = sm.push(BurnSample(
                usedFraction: 0.12, at: t0.addingTimeInterval(130), resetAt: weekReset, kind: .weekly
            ))
            try assertEqual(b3.ratio, held, accuracy: 1e-6)
            try assertTrue(sm.samples.contains(where: \.hasAbsoluteCounters))
        }

        failures += check("dual EWMA: short reacts faster than long") {
            var s = BurnSmoother()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            // Absolute reset epoch must stay stable (API resets_at), not now+remaining.
            let reset = t0.addingTimeInterval(5 * 3600)
            _ = s.push(BurnSample(usedFraction: 0.10, at: t0, resetAt: reset, kind: .fiveHour))
            // Spike: +2% in 60s.
            let t1 = t0.addingTimeInterval(60)
            _ = s.push(BurnSample(usedFraction: 0.12, at: t1, resetAt: reset, kind: .fiveHour))
            let afterSpike = s.current
            try assertTrue(afterSpike.ratio + 1e-9 >= afterSpike.longRatio, "short should be ≥ long after spike")
            try assertTrue(afterSpike.sampleCount >= 2, "keeps samples")
            try assertTrue(afterSpike.quantized, "percent-only samples are quantized")
        }

        failures += check("quant jump over long gap inflates short needle") {
            var s = BurnSmoother()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let reset = t0.addingTimeInterval(4 * 3600)
            _ = s.push(BurnSample(usedFraction: 0.20, at: t0, resetAt: reset, kind: .fiveHour))
            // +1% after 15 minutes idle — without quantBurstCap short would look dead.
            let t1 = t0.addingTimeInterval(15 * 60)
            let r = s.push(BurnSample(usedFraction: 0.21, at: t1, resetAt: reset, kind: .fiveHour))
            try assertTrue(r.ratio > 0.3, "quant burst should still move short needle, got \(r.ratio)")
        }

        failures += check("BurnSmoother resets on large absolute drop") {
            var sm = BurnSmoother()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let reset = t0.addingTimeInterval(300 * 3600)
            _ = sm.push(BurnSample(
                usedFraction: 0.5, at: t0, resetAt: reset, kind: .monthly,
                usedTokens: 75_000, limitTokens: 150_000
            ))
            _ = sm.push(BurnSample(
                usedFraction: 0.51, at: t0.addingTimeInterval(60), resetAt: reset, kind: .monthly,
                usedTokens: 76_500, limitTokens: 150_000
            ))
            try assertTrue(sm.current.ratio > 0)

            // New month: used collapses.
            let b = sm.push(BurnSample(
                usedFraction: 0.01, at: t0.addingTimeInterval(120),
                resetAt: reset.addingTimeInterval(30 * 24 * 3600), kind: .monthly,
                usedTokens: 1_500, limitTokens: 150_000
            ))
            try assertEqual(b.ratio, 0, accuracy: 1e-9)
            try assertEqual(Double(sm.samples.count), 1, accuracy: 0)
        }

        return failures
    }
}
