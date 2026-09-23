import Foundation

/// Poll-path policy that is not part of the due/interval math.
enum PollingPathSuite {
    static func run() -> Int {
        print("PollingPath")
        var failures = 0
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        failures += check("CLI ping registry: one ping per folder, released on finish") {
            let registry = CLIPingRegistry()
            let end = t0.addingTimeInterval(60)
            let first = registry.reserve("a", until: end, now: t0)
            try assertTrue(first.started)
            try assertEqual(first.end, end)
            // A second poll joins the running ping instead of spawning another.
            let second = registry.reserve("a", until: end.addingTimeInterval(30), now: t0.addingTimeInterval(5))
            try assertTrue(!second.started)
            try assertEqual(second.end, end)
            try assertEqual(registry.runningUntil("a", now: t0.addingTimeInterval(5)), end)
            try assertTrue(registry.runningUntil("b", now: t0) == nil)
            registry.finish("a")
            try assertTrue(registry.runningUntil("a", now: t0.addingTimeInterval(5)) == nil)
        }

        failures += check("CLI ping registry: a ping past its budget no longer blocks") {
            let registry = CLIPingRegistry()
            let end = t0.addingTimeInterval(60)
            _ = registry.reserve("a", until: end, now: t0)
            try assertTrue(registry.runningUntil("a", now: end.addingTimeInterval(1)) == nil)
            try assertTrue(registry.reserve("a", until: end.addingTimeInterval(90), now: end.addingTimeInterval(1)).started)
        }

        failures += check("poll waits for a running CLI ping instead of reading the folder") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("di-ping-\(UUID().uuidString)", isDirectory: true)
            try assertTrue(ClaudeAdapter.pingPendingSnapshot(configDir: dir, now: t0) == nil)
            let end = t0.addingTimeInterval(ClaudeAdapter.cliPingBudget)
            _ = ClaudeAdapter.cliPings.reserve(dir.path, until: end, now: t0)
            defer { ClaudeAdapter.cliPings.finish(dir.path) }
            guard let snap = ClaudeAdapter.pingPendingSnapshot(configDir: dir, now: t0.addingTimeInterval(10)) else {
                throw TestFailure(description: "expected a pending snapshot")
            }
            // Soft, no red caption, retry once the ping could have landed.
            try assertEqual(snap.error, UsageError.unavailable("refresh pending"))
            try assertEqual(snap.retryAt, end)
            try assertEqual(UsageSnapshotMerge.failureKind(snap.error!), UsageFailureKind.soft)
            try assertTrue(UsageOrchestrator.caption(for: snap.error, vendorID: "claude") == nil)
        }

        return failures
    }
}
