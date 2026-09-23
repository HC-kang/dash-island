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

        failures += check("poll generations: a result started before reauth or removal is dropped") {
            let a = UUID(), b = UUID()
            var gens = PollGenerations()
            let started = gens.current(a)
            try assertTrue(gens.accepts(a, generation: started, live: [a, b]))
            gens.bump(a)                                     // reauth / refresh(accountID:)
            try assertTrue(!gens.accepts(a, generation: started, live: [a, b]))
            try assertTrue(gens.accepts(a, generation: gens.current(a), live: [a, b]))
            // Other accounts keep their in-flight results.
            try assertTrue(gens.accepts(b, generation: 0, live: [a, b]))
            // A removed account never takes a result.
            try assertTrue(!gens.accepts(b, generation: 0, live: [a]))
            gens.prune(live: [b])
            try assertEqual(gens.current(a), 0)
        }

        failures += check("a user poll that meets a running poll is queued, not dropped") {
            // Plain timer ticks just wait for the next tick.
            try assertTrue(UsageOrchestrator.queuedPoll(pending: nil, incoming: .background, forceActive: false) == nil)
            try assertEqual(UsageOrchestrator.queuedPoll(pending: .expand, incoming: .background, forceActive: false), .expand)
            // Launch / wake / account change / expand / refresh are queued.
            try assertEqual(UsageOrchestrator.queuedPoll(pending: nil, incoming: .background, forceActive: true), .background)
            try assertEqual(UsageOrchestrator.queuedPoll(pending: nil, incoming: .expand, forceActive: true), .expand)
            // The strongest request wins; one queued poll covers them all.
            try assertEqual(UsageOrchestrator.queuedPoll(pending: .expand, incoming: .force, forceActive: true), .force)
            try assertEqual(UsageOrchestrator.queuedPoll(pending: .force, incoming: .expand, forceActive: true), .force)
            try assertEqual(UsageOrchestrator.queuedPoll(pending: .expand, incoming: .background, forceActive: true), .expand)
        }

        return failures
    }

    /// Records how many jobs run at once.
    actor Gauge {
        private(set) var running = 0
        private(set) var peak = 0
        func enter() { running += 1; peak = max(peak, running) }
        func leave() { running -= 1 }
    }

    static func runAsync() async -> Int {
        var failures = 0

        // Item 0 is slow. Fixed pairs made items 2…4 wait for it; a sliding
        // window keeps the other slot busy and hands results over on arrival.
        let gauge = Gauge()
        let delaysMs: [UInt64] = [400, 20, 20, 20, 20]
        var started: [Int] = []
        var finished: [Int] = []
        await UsageOrchestrator.forEachBounded(
            Array(0..<5),
            limit: 2,
            start: { item -> Int? in
                started.append(item)
                return item
            },
            work: { item -> Int in
                await gauge.enter()
                try? await Task.sleep(nanoseconds: delaysMs[item] * 1_000_000)
                await gauge.leave()
                return item
            },
            finish: { _, result in finished.append(result) }
        )
        let peak = await gauge.peak
        failures += check("bounded fetch: a slow account holds one slot, not the batch") {
            try assertEqual(started, [0, 1, 2, 3, 4])
            try assertEqual(peak, 2)
            try assertEqual(finished, [1, 2, 3, 4, 0])
        }

        // `start` returning nil skips the item without spending a slot.
        var ran: [Int] = []
        await UsageOrchestrator.forEachBounded(
            Array(0..<4),
            limit: 1,
            start: { item -> Int? in item % 2 == 0 ? item : nil },
            work: { item -> Int in item },
            finish: { _, result in ran.append(result) }
        )
        failures += check("bounded fetch: skipped items do not run") {
            try assertEqual(ran, [0, 2])
        }

        return failures
    }
}
