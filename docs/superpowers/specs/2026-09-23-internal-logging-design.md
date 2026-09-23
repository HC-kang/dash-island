# Internal logging design (2026-09-23)

Status: approved in chat (option "이대로 진행"), not yet implemented.
Revised 2026-09-23 after checking against the code (see "Revisions" at the end).

## Goal

Make the app's own log good enough that an agent can debug a live incident from
the log file alone: poll cadence, cooldowns, auth/refresh outcomes, poll modes,
power events, account lifecycle. Keep the structure small: one module, one
convention, no UI.

## Current state (baseline)

- 53 `NSLog("DashIsland: …")` calls across 10 files. ClaudeAdapter 20, AgyAdapter 8,
  GrokAdapter 7, CodexAdapter 5, AccountStore 4, IslandWindowController 2,
  AccountsPersistence 2, UsageOrchestrator 2, App 2, LaunchAtLoginStore 1.
- Output goes only to unified log. No file, no level, no category, no
  redaction helper. Account IDs are shortened by hand with `prefix(8)`.
- Missing signals: poll due/skip decisions, per-fetch latency + outcome,
  poll mode per tick, sleep/wake/lock, add/remove/rename/reorder,
  last-good persist/restore, local usage reads.

## Design

### 1. `Sources/Infra/Log.swift` (stdlib only: Foundation + os)

```swift
enum LogLevel: Int, Comparable { case debug, info, warn, error }

struct LogCategory {
    let name: String
    func debug(_ m: @autoclosure () -> String)
    func info(_ m: @autoclosure () -> String)
    func warn(_ m: @autoclosure () -> String)
    func error(_ m: @autoclosure () -> String)
}

enum Log {
    static let app      = LogCategory("app")      // launch, env, version, paths
    static let accounts = LogCategory("accounts") // load/save/add/remove/rename/reorder
    static let poll     = LogCategory("poll")     // scheduler: due/skip/cooldown/mode/power
    static let fetch    = LogCategory("fetch")    // one line per usage call
    static let auth     = LogCategory("auth")     // login/harvest/refresh/reauth per vendor
    static let burn     = LogCategory("burn")     // needle math, local activity
    static let local    = LogCategory("local")    // LocalUsageStore / readers / sqlite
    static let window   = LogCategory("window")   // notch/display geometry

    static var level: LogLevel = .info             // set once at launch, see §3
    static func resolveLevel(env: [String: String], defaults: UserDefaults) -> LogLevel
    static func startFile(at url: URL, maxBytes: Int = 2_000_000, keep: Int = 3)
    static func format(_ level: LogLevel, _ category: String, _ message: String, at: Date) -> String
    static func redact(_ secret: String?) -> String   // "abcdef…" (6 chars) or "nil"
}

extension UUID { var short: String }      // first 8 chars of uuidString
```

No `#file`/`#line` parameters: the line format does not print them, and a
category + event word is enough to find the call site with grep.

Call-site shape, one line, `key=value` pairs, no prose:

```swift
Log.fetch.info("ok vendor=claude account=\(id.short) ms=\(ms)")
Log.poll.debug("skip account=\(id.short) reason=cooldown in=\(Int(until.timeIntervalSince(now)))s")
```

### 2. Sinks

- **Unified log**: `os_log("%{public}@", log: category.osLog, type:)`, one
  `OSLog(subsystem: "dev.dashisland.DashIsland", category:)` per category.
  Public so `log show` prints the text.
- **File**: `~/Library/Application Support/DashIsland/logs/dashisland.log`.
  Off until `Log.startFile(at:)` is called. Only `AppDelegate` calls it, so the
  test binary never writes into the user's real log.
  One `final class LogFile` guarded by `NSLock` appends synchronously with
  `FileHandle`. Synchronous so lines keep call order (fire-and-forget
  `Task { await actor.append }` does not). Rotate when size > `maxBytes`:
  `.log.2`→`.log.3`, `.log.1`→`.log.2`, `.log`→`.log.1`, old `.log.3` dropped.
  The directory is created on start. Any file error disables the file sink
  silently; the unified log keeps working. Logging never crashes the app.
- Line format:
  `2026-09-22T10:11:12.345+0900 I [poll] skip account=9C11FBE9 reason=cooldown in=812s`
  Level letter is one of `D I W E`. Timestamp is local time with offset so it
  lines up with what the user sees. Newlines inside a message are replaced
  with `⏎` so one event is one line.
- Both sinks receive the same message. Filtering happens before
  formatting; a filtered `debug` call never evaluates its autoclosure.

### 3. Level control (no Prefs UI)

Resolved once at launch by `Log.resolveLevel`, in this order:

1. `DASHISLAND_LOG` env = `debug|info|warn|error`
2. `UserDefaults` key `DashIsland.logLevel` (same values;
   `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug`)
3. default `info`

Unknown values fall through to the next source.

### 4. Secrets

- Never log access/refresh tokens, `Authorization` headers, response bodies,
  or credential file contents at any level. `Log.redact` is the only way a
  token fragment reaches a line.
- Account identity: `UUID.short` only. Credential refs keep today's
  `prefix(8)`. Paths are fine (they already appear today).

### 5. Replace + add signals

Replace all 53 `NSLog` calls, mapping each to a category and level
(errors/failures → `warn` or `error`, routine outcomes → `info`, chatty → `debug`).
Then add, at minimum:

| Category | Level | Event | Where |
|---|---|---|---|
| app | info | launch: version, pid, appSupport path, demo flag, log level, log file path | `AppDelegate.applicationDidFinishLaunching` |
| poll | debug | tick skipped whole: `reason=inflight` (coalesced) or `reason=asleep` | `pollDueAccounts` guards |
| poll | debug | per account: `skip reason=cooldown in=…s` or `skip reason=interval` | `pollDueAccounts` loop |
| poll | info | tick that fetches: `mode`, `due` count, `locked` flag | `pollDueAccounts` before `fetchAccounts` |
| poll | info | cooldown set: kind (`429`/`auth`/`soft`), streak, wait | `apply` error branch |
| poll | info | power: sleep / wake / lock / unlock | `installPowerObservers` |
| fetch | info | one line per usage call: vendor, account, ms, outcome (`ok`/`rateLimited`/`authRequired`/`network`/`parse`/`unavailable`) | `fetchAccounts` task body |
| auth | info/warn | existing Claude/Codex/Grok/Agy refresh, harvest, recovery lines, moved to `auth` | adapters |
| accounts | info | load (count, rebuilt-from-folders), add, remove, rename, reorder, corrupt backup | `AccountStore`, `AccountsPersistence` |
| accounts | info/warn | last-good restore (count) / persist failure | `restoreLastGoodSnapshots` / `persistLastGood` |
| burn | debug | existing burn line | `pushBurn` |
| local | info | load: provider, rows, ms | `LocalUsageStore.load` |
| window | info | notch geometry at init and on refresh (existing lines) | `IslandWindowController` |

HTTP status stays in the adapter lines that already print it. The orchestrator
only sees `UsageSnapshot`, so the `fetch` line carries outcome, not status.
`PollMode` is a per-call argument, not stored state, and the timer ticks at a
fixed 20 s; there is no "mode transition" or "reschedule" event to log. The
per-tick `mode=` field covers it.

### 6. `scripts/logs.sh`

```
scripts/logs.sh            # tail -n 200
scripts/logs.sh -f         # follow
scripts/logs.sh -f fetch   # follow + grep
```

About 10 lines. README gets a short "Logs" section: path, level toggle, script.

### 7. Tests — `Tests/LogTests.swift`

- Line format: level letter, category, message, ISO timestamp with offset, newline escaped.
- Level filter: `debug` autoclosure not evaluated when level is `info`.
- `resolveLevel`: env wins over defaults; unknown env falls through; default `info`.
- Rotation: small `maxBytes` in a temp dir → `.log` restarted, `.log.1` holds old content, nothing past `.3`.
- `redact`: 6 chars + `…`; nil → `nil`; strings of 6 or fewer chars → `…` only.
- `UUID.short` is 8 chars.

Tests run through `scripts/run-tests.sh` (compiles Infra). Build and tests
must run sequentially — `build.sh` wipes `build/`.

## Out of scope (deliberate)

- Prefs toggle / "Open log folder" button.
- JSON structured logs (grep-able `key=value` is enough).
- Remote upload.
- Python collector logging (separate process; has its own error log).
- Capturing spawned CLI stdout/stderr beyond what adapters already read.
- Per-tick full state dump (cooldowns, lastGood ages). The per-account `skip`
  lines at debug already give the same answer; add a dump only if an incident
  shows they are not enough.

## Revisions (2026-09-23, checked against code)

- NSLog count is 53, not 62 (`grep -rho NSLog Sources | wc -l`).
- File sink: `actor` → `NSLock` class, for ordered lines. File sink is opt-in
  via `startFile` so tests do not write into the real log.
- `fetch` line drops `http=`: not visible at the orchestrator.
- "mode change" and "timer rescheduled" events removed: neither exists in code.
  Skip reasons `sleep`/`locked` replaced by `asleep` (whole tick) and a
  `locked` flag on the tick line; screen lock lengthens the interval, it does not skip.
- `window`: `pinCanvas` has no log; the existing notch lines in
  `init`/`refreshNotchGeometry` already cover display changes.
- `#fileID`/`#line` parameters dropped (not printed).
- Per-tick state snapshot moved to out of scope.
