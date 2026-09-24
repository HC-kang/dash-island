import Foundation

enum LoginProcessSuite {
    static func run() async -> Int {
        print("LoginProcessSuite")
        var failures = 0

        failures += await checkAsync("cancel during the wait terminates the CLI child") {
            let child = try spawn("/bin/sleep", ["30"])
            let waiter = Task {
                try await LoginProcess.supervise(child) {
                    while true { try await Task.sleep(nanoseconds: 50_000_000) }
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            waiter.cancel()
            _ = await waiter.result
            try await assertExits(child)
        }

        failures += await checkAsync("body return and throw both terminate the child") {
            let returned = try spawn("/bin/sleep", ["30"])
            try await LoginProcess.supervise(returned) {}
            try await assertExits(returned)

            let thrown = try spawn("/bin/sleep", ["30"])
            _ = try? await LoginProcess.supervise(thrown) { throw TestFailure(description: "boom") }
            try await assertExits(thrown)
        }

        failures += await checkAsync("waitForExit reports a child that exits on its own") {
            let child = try spawn("/usr/bin/true", [])
            try assertTrue(await LoginProcess.waitForExit(child, timeout: 5))
        }

        failures += await checkAsync("waitForExit terminates a child past its timeout") {
            let child = try spawn("/bin/sleep", ["30"])
            try assertTrue(!(await LoginProcess.waitForExit(child, timeout: 0.3)))
            try await assertExits(child)
        }

        failures += await checkAsync("cancelled waitForExit returns at once, not at the deadline") {
            let child = try spawn("/bin/sleep", ["30"])
            let started = Date()
            let waiter = Task { await LoginProcess.waitForExit(child, timeout: 30) }
            try await Task.sleep(nanoseconds: 100_000_000)
            waiter.cancel()
            let exited = await waiter.value
            try assertTrue(!exited)
            try assertTrue(Date().timeIntervalSince(started) < 3, "wait loop must not spin to the deadline")
            try await assertExits(child)
        }

        return failures
    }

    private static func spawn(_ path: String, _ args: [String]) throws -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return task
    }

    private static func assertExits(_ task: Process) async throws {
        let deadline = Date().addingTimeInterval(3)
        while task.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if task.isRunning {
            task.terminate()
            throw TestFailure(description: "child pid still running")
        }
    }
}

/// Async twin of `check` for suites that await.
func checkAsync(_ name: String, body: () async throws -> Void) async -> Int {
    do {
        try await body()
        print("  ✓ \(name)")
        return 0
    } catch {
        print("  ✗ \(name): \(error)")
        return 1
    }
}
