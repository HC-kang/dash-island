# Internal Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all 53 `NSLog` calls with a leveled, categorized logger that writes a rotating file plus the unified log, and add the missing poll/fetch/power/account signals.

**Architecture:** One file `Sources/Infra/Log.swift` holds `LogLevel`, `LogCategory`, `Log`, a lock-guarded `LogFile`, and `UUID.short`. The file sink is off until `AppDelegate` calls `Log.startFile(at:)`. Call sites use `Log.<category>.<level>("event key=value …")`.

**Tech Stack:** Swift (language mode 5, compiled by swiftc 6.3 via `build.sh` / `scripts/run-tests.sh`), Foundation, `os`. No new dependencies. Custom mini test harness in `Tests/TestMain.swift` (`check`, `assertEqual`, `TestFailure`).

**Spec:** `docs/superpowers/specs/2026-09-23-internal-logging-design.md` (read the "Revisions" section).

## Global Constraints

- Stdlib only: Foundation + os. No packages.
- Log file: `~/Library/Application Support/DashIsland/logs/dashisland.log`, rotate at 2 MB, keep `.1` … `.3`.
- Categories exactly: `app accounts poll fetch auth burn local window`.
- Levels exactly: `debug info warn error`; letters `D I W E`.
- Level source order: `DASHISLAND_LOG` env → `UserDefaults` key `DashIsland.logLevel` → `info`.
- Line format: `yyyy-MM-dd'T'HH:mm:ss.SSSZ <L> [<category>] <message>`, local time, newlines in message → `⏎`.
- Message shape: event word first, then `key=value` pairs. No prose, no `DashIsland:` prefix.
- Never log tokens, `Authorization` headers, response bodies, or credential file contents at any level. Tokens only via `Log.redact`. Accounts only via `UUID.short`. Credential refs keep `String(ref.prefix(8))`.
- No Prefs UI, no JSON, no remote upload.
- Run `scripts/run-tests.sh` and `./build.sh` sequentially, never in parallel: `build.sh` deletes `build/`.
- Never smoke-launch with `DASHISLAND_DEMO=1` in the env.
- Commit as HC-kang on branch `feat/internal-logging`.
- Ponytail: mark deliberate ceilings with `// ponytail:` comments.

## Review Focus

1. Log directory missing or not writable → the app runs normally, the file sink is off, the unified log still works. (Task 1 test: `startFile` on an unwritable path.)
2. Concurrent writes from the fetch task group (2 parallel adapters) → no interleaved or lost lines. (Task 1 test: 8 threads × 200 lines → 1600 complete lines.)
3. Filtered `debug` calls in the hot 20 s poll loop cost nothing → autoclosure not evaluated. (Task 1 test.)
4. Test binary must not write into the user's real log file. (Task 1: sink is opt-in; only `AppDelegate` calls `startFile`. Task 6 check: no `startFile` outside `App.swift`.)
5. A secret reaching the log through an interpolated error or snapshot description. (Task 5 step: grep the diff for `token`, `Authorization`, `body`, `data` interpolations; every token fragment goes through `Log.redact`.)

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/Infra/Log.swift` | create | level, category, format, file sink, rotation, redact, `UUID.short` |
| `Tests/LogTests.swift` | create | `LogSuite` |
| `Tests/TestMain.swift` | modify | register `LogSuite.run()` |
| `Sources/App/App.swift` | modify | resolve level, start file sink, launch line |
| `scripts/logs.sh` | create | tail / follow / grep the log |
| `README.md` | modify | "Logs" subsection in English and 한국어 parts |
| `Sources/AppCore/AccountStore.swift`, `Sources/Infra/AccountsPersistence.swift`, `Sources/AppCore/LaunchAtLoginStore.swift`, `Sources/Island/IslandWindowController.swift`, `Sources/AppCore/LocalUsageStore.swift` | modify | replace NSLog, add account + local signals |
| `Sources/AppCore/UsageOrchestrator.swift` | modify | poll/fetch/power/cooldown/last-good signals |
| `Sources/Adapters/{Claude,Codex,Grok,Agy}Adapter.swift` | modify | replace NSLog → `auth` / `fetch` |
| `.agent/context.md` | modify | wrap-up entry |

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feat/internal-logging
```

- [ ] **Step 2: Commit the docs**

```bash
git add docs/superpowers/specs/2026-09-23-internal-logging-design.md docs/superpowers/handoffs/2026-09-23-internal-logging-handoff.md docs/superpowers/plans/2026-09-23-internal-logging.md .agent/context.md
git commit -m "docs: internal logging spec, handoff, plan"
```

Do not add `notes/`; it is the user's scratch folder.

---

### Task 1: `Log.swift` core (TDD)

**Files:**
- Create: `Sources/Infra/Log.swift`
- Create: `Tests/LogTests.swift`
- Modify: `Tests/TestMain.swift` (add one line after `LocalUsageSuite`)

**Interfaces:**
- Produces:
  - `enum LogLevel: Int, Comparable { case debug, info, warn, error }`, `init?(name: String)`, `var letter: String`
  - `struct LogCategory { let name: String; func debug/info/warn/error(_ m: @autoclosure () -> String) }`
  - `Log.app/accounts/poll/fetch/auth/burn/local/window: LogCategory`
  - `Log.level: LogLevel` (settable)
  - `Log.resolveLevel(env: [String: String], defaults: UserDefaults) -> LogLevel`
  - `Log.defaultFileURL: URL`
  - `Log.startFile(at: URL, maxBytes: Int = 2_000_000, keep: Int = 3)`, `Log.fileURL: URL?` (nil when the sink is off)
  - `Log.format(_ level: LogLevel, _ category: String, _ message: String, at: Date) -> String`
  - `Log.redact(_ secret: String?) -> String`
  - `final class LogFile { init?(url: URL, maxBytes: Int, keep: Int); func append(_ line: String) }`
  - `extension UUID { var short: String }`

- [ ] **Step 1: Write the failing tests**

`Tests/LogTests.swift`:

```swift
import Foundation

enum LogSuite {
    static func run() -> Int {
        print("Log")
        var failures = 0

        failures += check("format: timestamp, letter, category, escaped newline") {
            let line = Log.format(.warn, "poll", "skip a=1\nb=2", at: Date(timeIntervalSince1970: 0))
            let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{4} W \[poll\] skip a=1⏎b=2$"#
            guard line.range(of: pattern, options: .regularExpression) != nil else {
                throw TestFailure(description: "bad line: \(line)")
            }
        }

        failures += check("level filter skips debug autoclosure at info") {
            let saved = Log.level
            defer { Log.level = saved }
            Log.level = .info
            var evaluated = false
            Log.poll.debug({ evaluated = true; return "x" }())
            try assertEqual(evaluated, false)
            Log.level = .debug
            Log.poll.debug({ evaluated = true; return "x" }())
            try assertEqual(evaluated, true)
        }

        failures += check("resolveLevel: env > defaults > info, unknown falls through") {
            let suite = "LogTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try assertEqual(Log.resolveLevel(env: [:], defaults: defaults), .info)
            defaults.set("warn", forKey: "DashIsland.logLevel")
            try assertEqual(Log.resolveLevel(env: [:], defaults: defaults), .warn)
            try assertEqual(Log.resolveLevel(env: ["DASHISLAND_LOG": "debug"], defaults: defaults), .debug)
            try assertEqual(Log.resolveLevel(env: ["DASHISLAND_LOG": "loud"], defaults: defaults), .warn)
        }

        failures += check("rotation keeps .1….3 and restarts .log") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("t.log")
            let file = LogFile(url: url, maxBytes: 100, keep: 3)!
            // 60-byte lines: a rotation after every 2nd line (after L1, L3, L5, L7, L9).
            for i in 0..<10 {
                file.append("L\(i)" + String(repeating: "x", count: 57))
            }
            func read(_ suffix: String) -> String? {
                try? String(contentsOf: URL(fileURLWithPath: url.path + suffix), encoding: .utf8)
            }
            try assertEqual(read(""), "")
            try assertEqual(read(".1")?.contains("L9"), true)
            try assertEqual(read(".3")?.contains("L4"), true)
            try assertEqual(read(".4"), nil)
        }

        failures += check("concurrent appends keep whole lines") {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("c.log")
            let file = LogFile(url: url, maxBytes: 10_000_000, keep: 3)!
            DispatchQueue.concurrentPerform(iterations: 8) { t in
                for i in 0..<200 { file.append("t=\(t) i=\(i) end") }
            }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            try assertEqual(lines.count, 1600)
            try assertEqual(lines.allSatisfy { $0.hasPrefix("t=") && $0.hasSuffix(" end") }, true)
        }

        failures += check("startFile on unwritable path leaves sink off") {
            Log.startFile(at: URL(fileURLWithPath: "/dev/null/nope/x.log"))
            try assertEqual(Log.fileURL, nil)
            Log.app.error("still no crash")
        }

        failures += check("redact and UUID.short") {
            try assertEqual(Log.redact(nil), "nil")
            try assertEqual(Log.redact("abcdefghij"), "abcdef…")
            try assertEqual(Log.redact("abc"), "…")
            try assertEqual(Log.redact("abcdef"), "…")
            let id = UUID(uuidString: "9C11FBE9-0000-0000-0000-000000000000")!
            try assertEqual(id.short, "9C11FBE9")
        }

        return failures
    }

    // Same private helper pattern as the other suites (each suite owns its copy).
    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-island-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

In `Tests/TestMain.swift`, after `failures += await LocalUsageSuite.run()`, add:

```swift
        failures += LogSuite.run()
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/run-tests.sh`
Expected: compile error, `cannot find 'Log' in scope` (and `LogFile`).

- [ ] **Step 3: Write `Sources/Infra/Log.swift`**

```swift
import Foundation
import os

/// App log: one line per event, `key=value` pairs, to the unified log and
/// (after `Log.startFile`) a rotating file. See
/// docs/superpowers/specs/2026-09-23-internal-logging-design.md.
enum LogLevel: Int, Comparable {
    case debug, info, warn, error

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    init?(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "warn": self = .warn
        case "error": self = .error
        default: return nil
        }
    }

    var letter: String { ["D", "I", "W", "E"][rawValue] }

    /// info → `.default` so `log show` prints it, like the old NSLog lines.
    var osType: OSLogType { [.debug, .default, .default, .error][rawValue] }
}

struct LogCategory {
    let name: String
    let osLog: OSLog

    init(_ name: String) {
        self.name = name
        osLog = OSLog(subsystem: "dev.dashisland.DashIsland", category: name)
    }

    func debug(_ m: @autoclosure () -> String) { Log.write(.debug, self, m) }
    func info(_ m: @autoclosure () -> String) { Log.write(.info, self, m) }
    func warn(_ m: @autoclosure () -> String) { Log.write(.warn, self, m) }
    func error(_ m: @autoclosure () -> String) { Log.write(.error, self, m) }
}

enum Log {
    static let app = LogCategory("app")
    static let accounts = LogCategory("accounts")
    static let poll = LogCategory("poll")
    static let fetch = LogCategory("fetch")
    static let auth = LogCategory("auth")
    static let burn = LogCategory("burn")
    static let local = LogCategory("local")
    static let window = LogCategory("window")

    // ponytail: plain statics set once at launch before other threads log; no lock.
    nonisolated(unsafe) static var level: LogLevel = .info
    nonisolated(unsafe) private static var file: LogFile?

    static var defaultFileURL: URL {
        CredentialStore.appSupportURL.appendingPathComponent("logs/dashisland.log")
    }

    static var fileURL: URL? { file?.url }

    static func resolveLevel(env: [String: String], defaults: UserDefaults) -> LogLevel {
        env["DASHISLAND_LOG"].flatMap(LogLevel.init(name:))
            ?? defaults.string(forKey: "DashIsland.logLevel").flatMap(LogLevel.init(name:))
            ?? .info
    }

    static func startFile(at url: URL, maxBytes: Int = 2_000_000, keep: Int = 3) {
        file = LogFile(url: url, maxBytes: maxBytes, keep: keep)
    }

    static func redact(_ secret: String?) -> String {
        guard let secret else { return "nil" }
        return secret.count > 6 ? String(secret.prefix(6)) + "…" : "…"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    static func format(_ level: LogLevel, _ category: String, _ message: String, at date: Date) -> String {
        let text = message.replacingOccurrences(of: "\n", with: "⏎")
        return "\(stamp.string(from: date)) \(level.letter) [\(category)] \(text)"
    }

    static func write(_ level: LogLevel, _ category: LogCategory, _ message: () -> String) {
        guard level >= Log.level else { return }
        let text = message()
        os_log("%{public}@", log: category.osLog, type: level.osType, text)
        file?.append(format(level, category.name, text, at: Date()))
    }
}

/// Append-only file with size-based rotation (`.1` newest … `.keep` oldest).
// ponytail: one lock around synchronous writes keeps call order; a writer queue if logging ever shows up in profiles.
final class LogFile: @unchecked Sendable {
    let url: URL
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private var handle: FileHandle?

    init?(url: URL, maxBytes: Int, keep: Int) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        guard let handle = try? Self.open(url) else { return nil }
        self.handle = handle
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
            if try handle.offset() > UInt64(maxBytes) { try rotate() }
        } catch {
            // Disk full / file gone: stop writing, never crash. Unified log still works.
            self.handle = nil
        }
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        func path(_ i: Int) -> URL { i == 0 ? url : URL(fileURLWithPath: url.path + ".\(i)") }
        try? fm.removeItem(at: path(keep))
        for i in stride(from: keep - 1, through: 0, by: -1) {
            try? fm.moveItem(at: path(i), to: path(i + 1))
        }
        handle = try Self.open(url)
    }

    private static func open(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

extension UUID {
    var short: String { String(uuidString.prefix(8)) }
}
```

If `nonisolated(unsafe)` fails to compile under the project's language mode, drop the keyword and keep the `ponytail:` comment.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `scripts/run-tests.sh`
Expected: `Log` section with 7 `✓` lines and `✓ All tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Infra/Log.swift Tests/LogTests.swift Tests/TestMain.swift
git commit -m "feat: add Log module with file sink and rotation"
```

---

### Task 2: Launch wiring, `logs.sh`, README

**Files:**
- Modify: `Sources/App/App.swift:17-27`
- Create: `scripts/logs.sh`
- Modify: `README.md` (English part under `## English`, Korean part under `## 한국어`)

**Interfaces:**
- Consumes: `Log.resolveLevel`, `Log.startFile`, `Log.defaultFileURL`, `Log.fileURL`, `Log.level`, `Log.app`.

- [ ] **Step 1: Replace the two NSLog calls in `applicationDidFinishLaunching`**

Replace from `NSApp.setActivationPolicy(.accessory)` through the end of the `DASHISLAND_DEMO` `if` block with:

```swift
        NSApp.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        Log.level = Log.resolveLevel(env: env, defaults: .standard)
        Log.startFile(at: Log.defaultFileURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.app.info(
            "launch version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier) level=\(Log.level) demo=\(env["DASHISLAND_DEMO"] == "1") support=\(CredentialStore.appSupportURL.path) file=\(Log.fileURL?.path ?? "off")"
        )
```

`\(Log.level)` prints the case name (`info`), which is what we want.

- [ ] **Step 2: Create `scripts/logs.sh`**

```bash
#!/usr/bin/env bash
# Tail the DashIsland log. Usage: logs.sh [-f] [pattern]
set -euo pipefail
LOG="$HOME/Library/Application Support/DashIsland/logs/dashisland.log"
follow=0
if [[ "${1:-}" == "-f" ]]; then follow=1; shift; fi
pattern="${1:-}"
if (( follow )); then
  tail -n 200 -F "$LOG" | { if [[ -n "$pattern" ]]; then grep --line-buffered -- "$pattern"; else cat; fi; }
else
  tail -n 200 "$LOG" | { if [[ -n "$pattern" ]]; then grep -- "$pattern"; else cat; fi; }
fi
```

```bash
chmod +x scripts/logs.sh
```

- [ ] **Step 3: Add a README "Logs" subsection**

Find where the English part lists runtime paths or troubleshooting (`grep -n 'Application Support' README.md`) and add after it:

```markdown
### Logs

- File: `~/Library/Application Support/DashIsland/logs/dashisland.log` (2 MB × 3 rotation). Also mirrored to the unified log (`log show --predicate 'subsystem == "dev.dashisland.DashIsland"'`).
- Level: `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug` (or `DASHISLAND_LOG=debug` in the env). Values: `debug info warn error`. Default `info`. Restart the app to apply.
- Tail: `scripts/logs.sh`, follow: `scripts/logs.sh -f`, filter: `scripts/logs.sh -f fetch`.
- The log never contains tokens or response bodies.
```

Add the same in the Korean part:

```markdown
### 로그

- 파일: `~/Library/Application Support/DashIsland/logs/dashisland.log` (2 MB × 3 회전). 통합 로그에도 같은 내용이 기록됩니다 (`log show --predicate 'subsystem == "dev.dashisland.DashIsland"'`).
- 레벨: `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug` 또는 환경 변수 `DASHISLAND_LOG=debug`. 값은 `debug info warn error`이고 기본값은 `info`입니다. 앱을 다시 시작해야 적용됩니다.
- 보기: `scripts/logs.sh`, 따라가기: `scripts/logs.sh -f`, 필터: `scripts/logs.sh -f fetch`.
- 로그에는 토큰과 응답 본문이 기록되지 않습니다.
```

- [ ] **Step 4: Build and smoke-launch**

```bash
./build.sh
pkill -x DashIsland || true
env -u DASHISLAND_DEMO open build/DashIsland.app
```

Wait ~5 s, then:

```bash
scripts/logs.sh app
```

Expected: one line like `… I [app] launch version=0.0.1 pid=… level=info demo=false support=… file=…/logs/dashisland.log`.

- [ ] **Step 5: Run tests, then commit**

Run: `scripts/run-tests.sh` → `✓ All tests passed`.

```bash
git add Sources/App/App.swift scripts/logs.sh README.md
git commit -m "feat: start file log at launch; add logs.sh and README section"
```

---

### Task 3: Accounts, local, window, launch-at-login

**Files:**
- Modify: `Sources/AppCore/AccountStore.swift` (`load` L29–81, `add` L91/L102, `remove` L121, `rename` L143, `move` L151, `applyOrder` L162)
- Modify: `Sources/Infra/AccountsPersistence.swift:47,67`
- Modify: `Sources/AppCore/LaunchAtLoginStore.swift:29`
- Modify: `Sources/Island/IslandWindowController.swift:35,316`
- Modify: `Sources/AppCore/LocalUsageStore.swift` (`load` L31–67)

**Interfaces:**
- Consumes: `Log.accounts`, `Log.app`, `Log.window`, `Log.local`, `UUID.short`.

- [ ] **Step 1: Replace NSLog in these files**

| Old | New |
|---|---|
| `AccountStore` recovered orphans | `Log.accounts.warn("recovered orphans=\(recovered.count)")` |
| `AccountStore` loaded N | `Log.accounts.info("load count=\(accounts.count) path=\(path)")` |
| `AccountStore` failed to load | `Log.accounts.error("load failed error=\(error) path=\(path) file=kept")` |
| `AccountStore` rebuilt | `Log.accounts.warn("rebuilt fromFolders=\(accounts.count)")` |
| `AccountsPersistence` refused empty save | `Log.accounts.warn("save refused reason=empty-over-existing path=\(fileURL.path)")` |
| `AccountsPersistence` corrupt backup | `Log.accounts.error("corrupt backup=\(backup.path)")` |
| `LaunchAtLoginStore` failed | `Log.app.warn("launchAtLogin failed enabled=\(enabled) error=\(error.localizedDescription)")` |
| `IslandWindowController` init notch | `Log.window.info("notch width=\(notch.width) height=\(notch.height) hasNotch=\(notch.hasNotch) minX=\(notch.screenMinX.map { String(format: "%.1f", $0) } ?? "nil")")` |
| `IslandWindowController` notch refresh | `Log.window.info("notch refresh width=\(next.width) height=\(next.height) minX=\(next.screenMinX.map { String(format: "%.1f", $0) } ?? "nil") screen=\(screen?.localizedName ?? "?")")` |

`error` here is the Swift error from JSON decoding or file IO, not a response body, so it is safe to print.

- [ ] **Step 2: Add account lifecycle lines**

Add one line after each successful `try persist(...)`:

```swift
// add(_ account:)
Log.accounts.info("add account=\(copy.id.short) vendor=\(copy.vendorID)")
// add(from:)
Log.accounts.info("add account=\(account.id.short) vendor=\(account.vendorID)")
// remove(id:) — after `try persist(next)`
Log.accounts.info("remove account=\(removed.id.short) vendor=\(removed.vendorID)")
// rename(id:label:)
Log.accounts.info("rename account=\(id.short)")
// move(id:toIndex:)
Log.accounts.info("reorder account=\(id.short) from=\(from) to=\(target)")
// applyOrder(_:)
Log.accounts.info("reorder count=\(after.count)")
```

Do not log the label text in `rename`: it may hold an e-mail address.

- [ ] **Step 3: Add the local load line**

In `LocalUsageStore.load`, time both branches. At the start of the captured branch (after `loading.insert(provider)`) add `let started = Date()`, and before its `return` add:

```swift
Log.local.info("load provider=\(provider) scope=captured events=\(captured.accounts.values.reduce(0) { $0 + $1.count }) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
```

In the archive branch, add `let started = Date()` after `loading.insert(key)` and at the end:

```swift
Log.local.info("load provider=\(provider) scope=\(archiveScope) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
```

- [ ] **Step 4: Run tests and build**

```bash
scripts/run-tests.sh && ./build.sh
```

Expected: `✓ All tests passed`, then a successful build. `grep -n NSLog` on the five files returns nothing.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/AccountStore.swift Sources/Infra/AccountsPersistence.swift Sources/AppCore/LaunchAtLoginStore.swift Sources/Island/IslandWindowController.swift Sources/AppCore/LocalUsageStore.swift
git commit -m "feat: log account lifecycle, local loads, notch geometry"
```

---

### Task 4: Orchestrator — poll, fetch, power, cooldown, last-good

**Files:**
- Modify: `Sources/AppCore/UsageOrchestrator.swift` (`installPowerObservers` L206, `pushBurn` NSLog L380, `restoreLastGoodSnapshots` L408, `persistLastGood` L419, `pollDueAccounts` L459, `fetchAccounts` L543, `apply` L580)

**Interfaces:**
- Consumes: `Log.poll`, `Log.fetch`, `Log.burn`, `Log.accounts`, `UUID.short`.

- [ ] **Step 1: Power events**

In each of the four observer closures, add a line inside the `Task { @MainActor in … }` before the state change:

```swift
Log.poll.info("power event=sleep")    // willSleep
Log.poll.info("power event=wake")     // didWake
Log.poll.info("power event=lock")     // screenIsLocked
Log.poll.info("power event=unlock")   // screenIsUnlocked
```

- [ ] **Step 2: Burn line**

Replace the NSLog at L380 with:

```swift
Log.burn.debug(
    "sample account=\(accountID.short) kind=\(burnWin.kind.rawValue) u=\(String(format: "%.4f", burnWin.usedFraction)) abs=\(burnWin.hasAbsoluteCounters ? "y" : "n") ratio=\(String(format: "%.3f", result.ratio)) samples=\(result.sampleCount)"
)
```

- [ ] **Step 3: Last-good restore / persist**

In `restoreLastGoodSnapshots`, count restored snapshots and log once at the end if any:

```swift
    private func restoreLastGoodSnapshots() {
        var restored = 0
        for account in accountStore.accounts where lastGood[account.id] == nil {
            // … existing body unchanged …
            restored += 1   // last line inside the loop
        }
        if restored > 0 { Log.accounts.info("lastGood restore count=\(restored)") }
    }
```

In `persistLastGood`, replace `_ = Self.saveLastGood(...)` with:

```swift
        if !Self.saveLastGood(
            snapshot,
            to: CredentialStore.lastGoodUsageURL(for: account.credentialRef)
        ) {
            Log.accounts.warn("lastGood persist failed account=\(accountID.short)")
        }
```

- [ ] **Step 4: Poll decisions in `pollDueAccounts`**

Change the two early guards:

```swift
        guard !polling else {
            Log.poll.debug("tick skip reason=inflight mode=\(mode)")
            return
        }
        if systemAsleep, !forceActive {
            Log.poll.debug("tick skip reason=asleep mode=\(mode)")
            return
        }
```

Inside the per-account loop, in the cooldown `if`, before `continue`:

```swift
                if !(mode == .expand && veryStale) {
                    Log.poll.debug("skip account=\(account.id.short) reason=cooldown in=\(Int(until.timeIntervalSince(now)))s")
                    continue
                }
```

Change the `isDue` `if` to add an `else`:

```swift
            ) {
                due.append(account)
            } else {
                Log.poll.debug("skip account=\(account.id.short) reason=interval every=\(Int(interval))s")
            }
```

Before `let results = await fetchAccounts(due)`:

```swift
        Log.poll.info("tick mode=\(mode) due=\(due.count)/\(accounts.count) locked=\(inactive)")
```

- [ ] **Step 5: One `fetch` line per usage call**

In `fetchAccounts`, replace the `group.addTask` body with a timed version:

```swift
                    group.addTask {
                        let started = Date()
                        let snapshot: UsageSnapshot
                        if let adapter = VendorRegistry.adapter(for: vendorID) {
                            snapshot = await adapter.fetchUsage(ref)
                        } else {
                            snapshot = UsageSnapshot(
                                primary: WindowUsage(usedFraction: 0, kind: .unknown),
                                secondary: nil,
                                plan: nil,
                                fetchedAt: Date(),
                                error: .unavailable("unknown vendor")
                            )
                        }
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        let outcome: String
                        switch snapshot.error {
                        case nil: outcome = "ok"
                        case .rateLimited?: outcome = "rateLimited"
                        case .authRequired?: outcome = "authRequired"
                        case .network?: outcome = "network"
                        case .parse?: outcome = "parse"
                        case .unavailable?: outcome = "unavailable"
                        }
                        Log.fetch.info("usage vendor=\(vendorID) account=\(id.short) ms=\(ms) outcome=\(outcome)")
                        return (id, snapshot)
                    }
```

`UsageError` has exactly five cases (`authRequired`, `rateLimited`, `network`, `parse`, `unavailable`); the switch is exhaustive on purpose, so a new case breaks the build here instead of hiding under a default.

- [ ] **Step 6: Cooldown set in `apply`**

Replace the rate-limit NSLog with:

```swift
                Log.poll.info("cooldown account=\(accountID.short) kind=429 streak=\(streak) wait=\(Int(wait / 60))m")
```

After `cooldownUntil[accountID] = now.addingTimeInterval(Self.authFailureCooldown)`:

```swift
                Log.poll.info("cooldown account=\(accountID.short) kind=auth wait=\(Int(Self.authFailureCooldown / 60))m")
```

In the soft branch, after the `if let retryAt … else if …` block:

```swift
                if let until = cooldownUntil[accountID] {
                    Log.poll.info("cooldown account=\(accountID.short) kind=soft wait=\(Int(until.timeIntervalSince(now) / 60))m")
                }
```

- [ ] **Step 7: Run tests, build, smoke-launch at debug**

```bash
scripts/run-tests.sh && ./build.sh
pkill -x DashIsland || true
defaults write dev.dashisland.DashIsland DashIsland.logLevel debug
env -u DASHISLAND_DEMO open build/DashIsland.app
```

Wait ~30 s (one 20 s scheduler tick), then `scripts/logs.sh | tail -40`.
Expected: `[app] launch … level=debug`, at least one `[poll] tick mode=…`, one `[fetch] usage vendor=… outcome=…` per due account, and `[poll] skip … reason=interval` lines on the next tick.

Then restore the default:

```bash
defaults delete dev.dashisland.DashIsland DashIsland.logLevel
```

- [ ] **Step 8: Commit**

```bash
git add Sources/AppCore/UsageOrchestrator.swift
git commit -m "feat: log poll decisions, fetch outcomes, power events, cooldowns"
```

---

### Task 5: Adapters → `auth` / `fetch`

**Files:**
- Modify: `Sources/Adapters/ClaudeAdapter.swift` (20 sites), `AgyAdapter.swift` (8), `GrokAdapter.swift` (7), `CodexAdapter.swift` (5)

**Interfaces:**
- Consumes: `Log.auth`, `Log.fetch`, `Log.redact`.

- [ ] **Step 1: List the sites**

```bash
grep -n -A6 'NSLog' Sources/Adapters/*.swift
```

- [ ] **Step 2: Convert every site with these rules**

- Category: refresh, recovery, harvest, token smoke-test, login, CLI ping, clear creds → `Log.auth`. Usage HTTP errors (`usage error`, HTTP status lines) → `Log.fetch`.
- Level: routine success (`recovery ok`, `ping finished`, `cleared … creds`) → `info`. Expected soft states (`rate-limited (keeping)`, `refresh quiet`, `soft error`) → `info`. Rejected / impossible / failed → `warn`. Nothing is `error` unless the account becomes unusable without user action.
- Message: drop the `DashIsland: ` and vendor-name prose, lead with an event word, then `vendor=<id>` and `key=value` pairs. Convert `%@`/`%d`/`%.1f` arguments to interpolation; keep `String(format:)` only for fixed decimals.
- Keep `ref=\(String(ref.prefix(8)))` as the identity.

Examples:

```swift
// before
NSLog("DashIsland: Claude refresh rejected ref=%@", String(ref.prefix(8)))
// after
Log.auth.warn("refresh vendor=claude outcome=rejected ref=\(String(ref.prefix(8)))")

// before
NSLog("DashIsland: Claude usage error ref=%@ %@", String(ref.prefix(8)), String(describing: err))
// after
Log.fetch.warn("usage error vendor=claude ref=\(String(ref.prefix(8))) error=\(err)")
```

- [ ] **Step 3: Check for secrets in the diff**

```bash
git diff Sources/Adapters | grep '^+' | grep -inE 'token|authorization|bearer|body|data\)|json'
```

Read every hit. Allowed: the words as event names (`token smoke-test`), `Log.redact(...)`, status codes. Not allowed: an interpolated token, header, `Data`, or response string. If an existing NSLog printed such a value, replace it with `Log.redact(value)` or drop it, and say so in the commit message.

- [ ] **Step 4: Confirm no NSLog remains anywhere**

```bash
grep -rn 'NSLog' Sources
```

Expected: no output.

- [ ] **Step 5: Run tests and build**

```bash
scripts/run-tests.sh && ./build.sh
```

Expected: `✓ All tests passed`, build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Adapters
git commit -m "feat: route adapter logs to auth and fetch categories"
```

---

### Task 6: Verify, memory, PR

- [ ] **Step 1: Sink is opt-in only in the app**

```bash
grep -rn 'startFile' Sources Tests
```

Expected: `Sources/App/App.swift` (call), `Sources/Infra/Log.swift` (definition), `Tests/LogTests.swift` (unwritable-path test only).

- [ ] **Step 2: Final sequential run**

```bash
scripts/run-tests.sh && ./build.sh
pkill -x DashIsland || true
env -u DASHISLAND_DEMO open build/DashIsland.app
```

Wait ~30 s. `scripts/logs.sh` shows the `[app] launch` line and at least one `[fetch] usage` line. Record the exact lines for the PR description.

- [ ] **Step 3: Append the wrap-up to `.agent/context.md`**

Replace nothing. Append:

```markdown
## Internal logging — shipped (2026-09-23)

- `Log.<category>.<level>("event key=value")` in `Sources/Infra/Log.swift`. Categories `app accounts poll fetch auth burn local window`.
- File `~/Library/Application Support/DashIsland/logs/dashisland.log` (2 MB × 3), plus unified log subsystem `dev.dashisland.DashIsland`. `scripts/logs.sh [-f] [pattern]`.
- Level: `DASHISLAND_LOG` env > `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug` > `info`. Poll skip reasons appear only at `debug`.
- File sink is opt-in (`Log.startFile` in `AppDelegate` only) so the test binary never writes the real log.
- <mistakes found during implementation, one line each>
```

Fill the last bullet with real findings or delete it.

- [ ] **Step 4: Commit and open the PR**

```bash
git add .agent/context.md
git commit -m "docs: record internal logging in project memory"
git push -u origin feat/internal-logging
```

Open the PR with the `gh` identity rule from memory (HC-kang token per command). Body: summary, the verification lines from Step 2, the secrets check result from Task 5 Step 3.
