import Foundation

/// Lifetime of a CLI child we spawn (login, logout, refresh ping, `security`).
///
/// Cancel used to land in `try await Task.sleep`, skip the loop's terminate and
/// leave `claude/codex/grok login` listening on localhost. Finishing sign-in in
/// that orphan wrote a session into a folder we had already deleted. Every exit
/// path here terminates the child: return, throw and task cancellation.
enum LoginProcess {
    /// Run `body` while `task` lives; the child never outlives it.
    static func supervise<T>(
        _ task: Process,
        _ body: () async throws -> T
    ) async throws -> T {
        defer { terminate(task) }
        return try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            terminate(task)
        }
    }

    /// Wait for exit up to `timeout`. Timeout or cancel terminates the child
    /// and returns at once (the old `try?` sleep spun until the deadline).
    /// `true` only when the child exited on its own.
    @discardableResult
    static func waitForExit(
        _ task: Process,
        timeout: TimeInterval,
        pollNanos: UInt64 = 100_000_000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let exited = try? await supervise(task) { () async throws -> Bool in
            while task.isRunning {
                if Date() >= deadline { return false }
                try await Task.sleep(nanoseconds: pollNanos)
            }
            return true
        }
        return exited ?? false
    }

    /// Safe on a finished child; never call `terminate` on one not yet launched.
    static func terminate(_ task: Process) {
        if task.isRunning { task.terminate() }
    }
}
