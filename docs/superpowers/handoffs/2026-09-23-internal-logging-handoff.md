# Handoff — internal logging overhaul (2026-09-23)

Read this first, then the spec. Nothing is implemented yet.

## Where things are

- Spec (approved, revised after code check): `docs/superpowers/specs/2026-09-23-internal-logging-design.md`
- Plan: `docs/superpowers/plans/2026-09-23-internal-logging.md` (follow this; it supersedes the insertion list below)
- Project memory: `.agent/context.md` (559 lines; read the tail first)
- Branch: still on `main`, working tree clean except untracked `notes/`.
  Create `feat/internal-logging` before touching code.
- Identity: commit as HC-kang, `gh` via HC-kang token per command (see memory).

## What was decided

User asked: "자체 내부 로그 기능 대폭 보강, 나(에이전트)도 디버깅에 참고할 수준, 구조도 우아하게".
Three options were offered; user picked **"이대로 진행"**:

- one module `Sources/Infra/Log.swift`, stdlib only (Foundation + os)
- file sink with 2 MB × 3 rotation at `~/Library/Application Support/DashIsland/logs/dashisland.log`
  plus unified log mirror
- categories `app accounts poll fetch auth burn local window`, levels `debug info warn error`
- level via `DASHISLAND_LOG` env or `defaults write dev.dashisland.DashIsland DashIsland.logLevel`
- **no Prefs UI**, no JSON, no remote
- replace all 53 `NSLog` calls, add the missing signals listed in spec §5
- `scripts/logs.sh` (tail/follow/grep) + README "Logs" section
- one test file `Tests/LogTests.swift`

## Inventory of call sites to replace

```
grep -rn 'NSLog' Sources --include='*.swift'
```

| File | NSLog count |
|---|---|
| Sources/Adapters/ClaudeAdapter.swift | 20 |
| Sources/Adapters/AgyAdapter.swift | 8 |
| Sources/Adapters/GrokAdapter.swift | 7 |
| Sources/Adapters/CodexAdapter.swift | 5 |
| Sources/AppCore/AccountStore.swift | 4 |
| Sources/Island/IslandWindowController.swift | 2 |
| Sources/Infra/AccountsPersistence.swift | 2 |
| Sources/AppCore/UsageOrchestrator.swift | 2 |
| Sources/App/App.swift | 2 |
| Sources/AppCore/LaunchAtLoginStore.swift | 1 |

Where to add the new signals (spec §5):

- `UsageOrchestrator.pollDueAccounts` (L459) — due/skip reasons, mode, cooldown set (L580–640 `apply`)
- `UsageOrchestrator.fetchAccounts` (L543) — per-fetch http/ms/outcome (adapters return `UsageSnapshot`; time the call here)
- `UsageOrchestrator.installPowerObservers` (L206) — sleep/wake/lock
- `UsageOrchestrator.rescheduleTimer` / `onIslandExpanded` — mode + interval
- `UsageOrchestrator.restoreLastGoodSnapshots` / `persistLastGood` (L408–425)
- `AccountStore.load` / add / remove / rename / applyOrder
- `LocalUsageStore` refresh path
- `IslandWindowController.pinCanvas` (display/notch changes)
- `App.swift` launch line: add version, pid, log level, log file path

## Process expectations (from the loaded skills)

- **TDD**: write `Tests/LogTests.swift` first, watch it fail
  (`scripts/run-tests.sh`), then implement `Log.swift`. Tests cover: line format,
  level filter (autoclosure not evaluated), rotation in a temp dir, `redact`, `UUID.short`.
- **Ponytail** is active: shortest working diff, no abstractions beyond the spec.
  Mark deliberate ceilings with `// ponytail:` comments (e.g. single actor, size-based rotation).
- Build and tests must run **sequentially**: `./build.sh` deletes `build/`, which
  holds the test binary.
- Never launch smoke tests with `DASHISLAND_DEMO=1` left in the env.
- Before claiming done: `scripts/run-tests.sh` green, `./build.sh` green, then
  launch `build/DashIsland.app` with a clean env and confirm
  `logs/dashisland.log` receives the launch line and one `fetch` line.

## Secrets rule (non-negotiable)

Never log tokens, `Authorization` headers, response bodies, or credential
file contents at any level. Only `Log.redact(...)` (6 chars + `…`) and
`UUID.short` for identities.

## Wrap-up for the next session

After landing: append a short "Internal logging (2026-09-xx)" entry to
`.agent/context.md` with the log path, level toggle, category list, and any
mistakes found on the way. Then open a PR from `feat/internal-logging` to `main`.
