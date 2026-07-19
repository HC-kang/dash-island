import Foundation

enum OrchestratorDueSuite {
    static func run() -> Int {
        print("UsageOrchestrator.due")
        var failures = 0

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

        failures += check("PreferencesStore clamps pollSeconds") {
            try assertEqual(PreferencesStore.clampPoll(300), 300)
            try assertEqual(PreferencesStore.clampPoll(900), 900)
            try assertEqual(PreferencesStore.clampPoll(1800), 1800)
            try assertEqual(PreferencesStore.clampPoll(60), 300)
            try assertEqual(PreferencesStore.clampPoll(999), 300)
        }

        return failures
    }
}
