import Foundation

enum OrchestratorDueSuite {
    static func run() -> Int {
        print("UsageOrchestrator.due")
        var failures = 0

        failures += check("usage soft vs hard failure kinds") {
            try assertEqual(
                UsageSnapshotMerge.failureKind(.rateLimited(retryAfter: nil)),
                UsageFailureKind.soft
            )
            try assertEqual(
                UsageSnapshotMerge.failureKind(.authRequired),
                UsageFailureKind.hard
            )
            try assertEqual(
                UsageSnapshotMerge.failureKind(.network("timeout")),
                UsageFailureKind.soft
            )
            try assertEqual(
                UsageSnapshotMerge.failureKind(
                    .unavailable("access expired — token quiet (no refresh storm)")
                ),
                UsageFailureKind.soft
            )
            try assertEqual(
                UsageSnapshotMerge.failureKind(
                    .unavailable("setup-token can’t read usage (no user:profile)")
                ),
                UsageFailureKind.hard
            )
            try assertTrue(
                UsageSnapshotMerge.shouldRetainPreviousRings(
                    previous: UsageSnapshot(
                        primary: WindowUsage(usedFraction: 0.4, kind: .fiveHour),
                        secondary: nil,
                        plan: nil,
                        fetchedAt: Date()
                    )
                )
            )
            try assertTrue(
                !UsageSnapshotMerge.shouldRetainPreviousRings(previous: nil)
            )
        }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        failures += check("never fetched is always due") {
            try assertTrue(
                UsageOrchestrator.isDue(
                    lastFetch: nil,
                    now: t0,
                    userInterval: 300,
                    minPoll: 300
                ),
                "nil lastFetch should be due"
            )
        }

        failures += check("not due when elapsed < userInterval") {
            let last = t0
            let now = t0.addingTimeInterval(299)
            try assertTrue(
                !UsageOrchestrator.isDue(
                    lastFetch: last,
                    now: now,
                    userInterval: 300,
                    minPoll: 300
                ),
                "299s < 300s should skip"
            )
        }

        failures += check("due when elapsed == userInterval") {
            let last = t0
            let now = t0.addingTimeInterval(300)
            try assertTrue(
                UsageOrchestrator.isDue(
                    lastFetch: last,
                    now: now,
                    userInterval: 300,
                    minPoll: 300
                ),
                "exactly 300s should be due"
            )
        }

        failures += check("minPoll floors interval above userInterval") {
            // user wants 300s but adapter min is 900s; 500s elapsed → skip
            let last = t0
            let mid = t0.addingTimeInterval(500)
            try assertTrue(
                !UsageOrchestrator.isDue(
                    lastFetch: last,
                    now: mid,
                    userInterval: 300,
                    minPoll: 900
                ),
                "500s < max(300,900)=900 should skip"
            )

            let ready = t0.addingTimeInterval(900)
            try assertTrue(
                UsageOrchestrator.isDue(
                    lastFetch: last,
                    now: ready,
                    userInterval: 300,
                    minPoll: 900
                ),
                "900s >= max(300,900) should be due"
            )
        }

        failures += check("userInterval floors when larger than minPoll") {
            // user 1800, min 300; elapsed 1000 → skip; 1800 → due
            let last = t0
            try assertTrue(
                !UsageOrchestrator.isDue(
                    lastFetch: last,
                    now: t0.addingTimeInterval(1000),
                    userInterval: 1800,
                    minPoll: 300
                ),
                "1000s < max(1800,300)=1800 should skip"
            )
            try assertTrue(
                UsageOrchestrator.isDue(
                    lastFetch: last,
                    now: t0.addingTimeInterval(1800),
                    userInterval: 1800,
                    minPoll: 300
                ),
                "1800s >= 1800 should be due"
            )
        }

        failures += check("displayFraction used vs remaining") {
            try assertEqual(
                UsageOrchestrator.displayFraction(used: 0.25, mode: .used),
                0.25,
                accuracy: 1e-12
            )
            try assertEqual(
                UsageOrchestrator.displayFraction(used: 0.25, mode: .remaining),
                0.75,
                accuracy: 1e-12
            )
            try assertEqual(
                UsageOrchestrator.displayFraction(used: 1.5, mode: .used),
                1.0,
                accuracy: 1e-12
            )
        }

        failures += check("formatTokens k/m compact") {
            try assertEqual(UsageOrchestrator.formatTokens(42), "42")
            try assertEqual(UsageOrchestrator.formatTokens(1_800), "1.8k")
            try assertEqual(UsageOrchestrator.formatTokens(10_000), "10k")
            try assertEqual(UsageOrchestrator.formatTokens(1_200_000), "1.2m")
        }

        failures += check("formatResetRemaining compact 1d 5h style") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let d5h = now.addingTimeInterval(1 * 86_400 + 5 * 3_600)
            try assertEqual(
                UsageOrchestrator.formatResetRemaining(until: d5h, now: now),
                "1d 5h"
            )
            let h12m = now.addingTimeInterval(5 * 3_600 + 12 * 60)
            try assertEqual(
                UsageOrchestrator.formatResetRemaining(until: h12m, now: now),
                "5h 12m"
            )
            let mOnly = now.addingTimeInterval(42 * 60)
            try assertEqual(
                UsageOrchestrator.formatResetRemaining(until: mOnly, now: now),
                "42m"
            )
            try assertEqual(
                UsageOrchestrator.formatResetRemaining(until: now.addingTimeInterval(-10), now: now),
                "now"
            )
        }

        failures += check("idle 15m, busy 1m, and a busy account still clears its floor") {
            try assertEqual(UsageOrchestrator.backgroundPollSeconds, 15 * 60, accuracy: 0)
            try assertEqual(UsageOrchestrator.activePollSeconds, 60, accuracy: 0)
            // The vendor floor is the hard limit; the active interval never beats it.
            let grokFloor = TimeInterval(VendorRegistry.adapter(for: "grok")?.minPollSeconds ?? 0)
            try assertEqual(
                max(UsageOrchestrator.activePollSeconds, grokFloor),
                300,
                accuracy: 0
            )
            let claudeFloor = TimeInterval(VendorRegistry.adapter(for: "claude")?.minPollSeconds ?? 0)
            try assertEqual(
                max(UsageOrchestrator.activePollSeconds, claudeFloor),
                60,
                accuracy: 0
            )
        }

        failures += check("expand interval floors at 120s and respects minPoll") {
            try assertEqual(UsageOrchestrator.expandInterval(minPoll: 60), 120, accuracy: 0)
            try assertEqual(UsageOrchestrator.expandInterval(minPoll: 300), 300, accuracy: 0)
            try assertEqual(UsageOrchestrator.expandInterval(minPoll: 120), 120, accuracy: 0)
        }

        failures += check("budget caption states the busy worst case and the idle rate") {
            let a = Account(
                id: UUID(),
                vendorID: "claude",
                label: "t",
                credentialRef: "x",
                sortIndex: 0,
                createdAt: Date(),
                lastAuthenticatedAt: nil
            )
            let cap = UsageOrchestrator.estimateBudgetCaption(accounts: [a])
            try assertTrue(cap.contains("15m idle"), "got \(cap)")
            // One Claude account at the 60s floor is 60 calls/h at worst.
            try assertTrue(cap.contains("≤60"), "got \(cap)")
        }

        failures += check("AccountHealth: ok / warn / error mapping") {
            let ok = AccountHealth.resolve(error: nil, notice: nil, awaitingFirst: false)
            try assertEqual(ok.health, AccountHealth.ok)
            let wait = AccountHealth.resolve(error: nil, notice: nil, awaitingFirst: true)
            try assertEqual(wait.health, AccountHealth.warn)
            let rate = AccountHealth.resolve(error: .rateLimited(retryAfter: nil), notice: nil, awaitingFirst: false)
            try assertEqual(rate.health, AccountHealth.warn)
            let auth = AccountHealth.resolve(error: .authRequired, notice: nil, awaitingFirst: false)
            try assertEqual(auth.health, AccountHealth.error)
            let notice = AccountHealth.resolve(error: nil, notice: "token expires soon", awaitingFirst: false)
            try assertEqual(notice.health, AccountHealth.warn)
        }

        failures += check("AccountHealth merges vendor service degradation") {
            let svc = VendorServiceSnapshot(
                level: .degraded,
                summary: "OpenAI: Partial System Degradation",
                fetchedAt: Date(),
                sourceURL: "https://status.openai.com"
            )
            let r = AccountHealth.resolve(
                error: nil,
                notice: nil,
                awaitingFirst: false,
                service: svc
            )
            try assertEqual(r.health, AccountHealth.warn)
            try assertTrue(r.tooltip.contains("OpenAI"), "got \(r.tooltip)")
        }

        failures += check("statuspage indicator mapping") {
            try assertEqual(VendorStatusStore.levelFromIndicator("none"), ServiceLevel.operational)
            try assertEqual(VendorStatusStore.levelFromIndicator("minor"), ServiceLevel.degraded)
            try assertEqual(VendorStatusStore.levelFromIndicator("major"), ServiceLevel.outage)
            try assertEqual(
                VendorStatusStore.levelFromComponentStatus("degraded_performance"),
                ServiceLevel.degraded
            )
        }

        failures += check("statuspage parse overall description") {
            let json = """
            {
              "status": { "indicator": "none", "description": "All Systems Operational" },
              "components": [
                { "name": "Claude API (api.anthropic.com)", "status": "operational" }
              ],
              "incidents": []
            }
            """
            let snap = VendorStatusStore.parseStatuspage(
                data: Data(json.utf8),
                vendorLabel: "Claude",
                preferredComponentNames: ["Claude API"],
                sourceURL: "https://status.claude.com"
            )
            try assertEqual(snap.level, ServiceLevel.operational)
            try assertTrue(snap.summary.contains("All Systems Operational"))
        }

        failures += check("rateLimitWait doubles from 15m; vendor Retry-After honoured") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            // First 429 costs 15m, not the old 2h blackout.
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 1, retryAfter: nil, now: now),
                15 * 60,
                accuracy: 0.001
            )
            // Repeats double: 30m, 1h, 2h, 4h.
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 2, retryAfter: nil, now: now),
                30 * 60,
                accuracy: 0.001
            )
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 3, retryAfter: nil, now: now),
                3600,
                accuracy: 0.001
            )
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 10, retryAfter: nil, now: now),
                4 * 3600,
                accuracy: 0.001
            )
            // A first 429 that names its own window is taken at face value, even
            // when that is shorter than the local floor.
            try assertEqual(
                UsageOrchestrator.rateLimitWait(
                    streak: 1,
                    retryAfter: now.addingTimeInterval(90),
                    now: now
                ),
                90,
                accuracy: 0.001
            )
            // Vendor Retry-After of 8h is authoritative and may exceed the 6h local cap.
            let eightHours = now.addingTimeInterval(8 * 3600)
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 1, retryAfter: eightHours, now: now),
                8 * 3600,
                accuracy: 0.001
            )
            // Once we are in a streak the local backoff still wins over a short ask.
            try assertEqual(
                UsageOrchestrator.rateLimitWait(
                    streak: 4,
                    retryAfter: now.addingTimeInterval(60),
                    now: now
                ),
                2 * 3600,
                accuracy: 0.001
            )
        }

        failures += check("cadence follows activity, not the clock") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let fast = UsageOrchestrator.activePollSeconds
            let slow = UsageOrchestrator.backgroundPollSeconds

            // Nothing known, nothing moving → idle.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: nil, lastPrimaryDelta: nil,
                    windowResetAt: nil, screenLocked: false, now: now
                ),
                slow, accuracy: 0
            )
            // Captured calls since the last sample → busy.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0.02, lastPrimaryDelta: 0,
                    windowResetAt: nil, screenLocked: false, now: now
                ),
                fast, accuracy: 0
            )
            // No telemetry at all, but the API jumped → still busy.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0, lastPrimaryDelta: 0.02,
                    windowResetAt: nil, screenLocked: false, now: now
                ),
                fast, accuracy: 0
            )
            // A sub-threshold step is noise, not activity.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0, lastPrimaryDelta: 0.001,
                    windowResetAt: nil, screenLocked: false, now: now
                ),
                slow, accuracy: 0
            )
            // Just after a rollover we look again, so a full ring does not linger.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0, lastPrimaryDelta: 0,
                    windowResetAt: now.addingTimeInterval(-30), screenLocked: false, now: now
                ),
                fast, accuracy: 0
            )
            // Well past the rollover, an idle account is idle again.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0, lastPrimaryDelta: 0,
                    windowResetAt: now.addingTimeInterval(-UsageOrchestrator.postResetGrace - 60),
                    screenLocked: false, now: now
                ),
                slow, accuracy: 0
            )
            // A rollover still ahead of us changes nothing.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0, lastPrimaryDelta: 0,
                    windowResetAt: now.addingTimeInterval(600), screenLocked: false, now: now
                ),
                slow, accuracy: 0
            )
            // A locked screen slows an idle account further …
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0, lastPrimaryDelta: 0,
                    windowResetAt: nil, screenLocked: true, now: now
                ),
                max(slow, UsageOrchestrator.inactivePollFloor), accuracy: 0
            )
            // … but never a burning one. Long agent runs happen while away.
            try assertEqual(
                UsageOrchestrator.backgroundInterval(
                    spentSinceAnchor: 0.05, lastPrimaryDelta: 0,
                    windowResetAt: nil, screenLocked: true, now: now
                ),
                fast, accuracy: 0
            )
        }

        failures += check("scheduler ticks far below the poll interval") {
            // A tick equal to the interval skipped every other slot, because the
            // lastFetch stamp lands after the HTTP round trip.
            // Must beat the *shortest* interval, not just the idle one.
            try assertTrue(
                UsageOrchestrator.schedulerTickSeconds < UsageOrchestrator.activePollSeconds
            )
            try assertTrue(
                UsageOrchestrator.schedulerTickSeconds < UsageOrchestrator.backgroundPollSeconds
            )
            let tick = UsageOrchestrator.schedulerTickSeconds
            let interval = UsageOrchestrator.activePollSeconds
            let minPoll: TimeInterval = 60
            // Walk real ticks: a 0.4s fetch must not push the account a whole slot.
            var lastFetch = Date(timeIntervalSince1970: 1_700_000_000)
            var fired = 0
            for step in 1...Int(interval * 2 / tick) {
                let now = lastFetch.addingTimeInterval(tick * Double(step))
                if UsageOrchestrator.isDue(
                    lastFetch: lastFetch,
                    now: now,
                    userInterval: interval,
                    minPoll: minPoll
                ) {
                    fired += 1
                    lastFetch = now.addingTimeInterval(0.4)
                    break
                }
            }
            try assertEqual(fired, 1)
        }

        failures += check("freshness line shows age and marks an estimate") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try assertEqual(
                UsageOrchestrator.formatFreshnessLine(
                    lastSuccessAt: now.addingTimeInterval(-180),
                    projectedFraction: nil,
                    now: now
                ),
                "checked 3m ago"
            )
            try assertEqual(
                UsageOrchestrator.formatFreshnessLine(
                    lastSuccessAt: now.addingTimeInterval(-60),
                    projectedFraction: 0.86,
                    now: now
                ),
                "checked 1m ago · ≈86% est. from local calls"
            )
            try assertTrue(
                UsageOrchestrator.formatFreshnessLine(
                    lastSuccessAt: nil,
                    projectedFraction: 0.5,
                    now: now
                ) == nil
            )
        }

        failures += check("xAI RSS treats resolved items as operational") {
            let xml = """
            <rss><channel>
            <item>
              <title>Something broke</title>
              <description><![CDATA[<h3>Status: RESOLVED</h3>]]></description>
              <category>resolved</category>
            </item>
            </channel></rss>
            """
            let snap = VendorStatusStore.parseXAIRSS(xml: xml)
            try assertEqual(snap.level, ServiceLevel.operational)
        }

        return failures
    }
}
