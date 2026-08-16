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

        failures += check("background poll fixed at 15m") {
            try assertEqual(UsageOrchestrator.backgroundPollSeconds, 15 * 60, accuracy: 0)
        }

        failures += check("expand interval floors at 120s and respects minPoll") {
            try assertEqual(UsageOrchestrator.expandInterval(minPoll: 60), 120, accuracy: 0)
            try assertEqual(UsageOrchestrator.expandInterval(minPoll: 300), 300, accuracy: 0)
            try assertEqual(UsageOrchestrator.expandInterval(minPoll: 120), 120, accuracy: 0)
        }

        failures += check("budget caption mentions 15m background") {
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
            try assertTrue(cap.contains("15m"), "got \(cap)")
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

        failures += check("rateLimitWait local backoff caps at 6h; vendor Retry-After may exceed") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            // streak 1 → 2h local
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 1, retryAfter: nil, now: now),
                2 * 3600,
                accuracy: 0.001
            )
            // streak 3 → 6h local cap
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 3, retryAfter: nil, now: now),
                6 * 3600,
                accuracy: 0.001
            )
            // streak 10 still 6h (local cap)
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 10, retryAfter: nil, now: now),
                6 * 3600,
                accuracy: 0.001
            )
            // Vendor Retry-After of 8h is authoritative and may exceed the 6h local cap.
            let eightHours = now.addingTimeInterval(8 * 3600)
            try assertEqual(
                UsageOrchestrator.rateLimitWait(streak: 1, retryAfter: eightHours, now: now),
                8 * 3600,
                accuracy: 0.001
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
