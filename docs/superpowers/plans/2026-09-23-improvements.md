# Improvements Implementation Plan (research report follow-up)

> **For agentic workers:** Execute one stream per agent. Each stream owns the files listed for it. Read the finding details before coding: `id` → full evidence/impact/recommendation in the findings file below.

**Goal:** Implement the roadmap and the findings from the 2026-09-23 research report (code audit 73 findings, UX review, benchmark ideas), in three phases, each landing as one PR.

**Source of truth:**
- Report: private artifact, link kept outside the repo (summary below)
- Findings with evidence and verifier notes: `$FINDINGS` (JSON; path given in each agent prompt). Each finding has `id`, `loc` (file:line), `ev` (evidence), `impact`, `rec` (recommendation), `vnote` (verifier note — when it says the claim is partial, follow the verifier).
- Project memory: `.agent/context.md` (read the headings and every section that mentions your files).

**User decisions (2026-09-23):**
- git history stays as is. Never write personal identifiers into tracked files (see the rule at the end of `.agent/context.md`).
- Distribution scope: PR CI + release zip with SHA-256 via tag. No Sparkle, no Homebrew cask.
- License: MIT.
- New alert features default ON: rim state color, compact ear summary, macOS notifications.

## Global constraints (every stream)

- Swift, no Xcode project. Build `./build.sh`, tests `scripts/run-tests.sh` (mini harness in `Tests/TestMain.swift`: `check`, `assertEqual`, `TestFailure`; register every new suite in `TestMain.main`). Run build and tests **sequentially** in the same checkout: `build.sh` deletes `build/`.
- TDD for logic: write the failing test first, watch it fail, then implement. Pure functions for policy (scheduling, alert decisions, ETA, classification) so they are testable without AppKit.
- Logging: use `Log.<category>.<level>("event key=value")` (`Sources/Infra/Log.swift`). No `NSLog`. Never log tokens, Authorization headers, response bodies, credential file contents. Accounts via `UUID.short`.
- Never launch the app against real accounts from a stream. Never touch `~/Library/Application Support/DashIsland/` or keychain items. Tests use temp dirs.
- Match surrounding code style; shortest diff that fixes the issue; mark deliberate ceilings with `// ponytail:`.
- Commit on your stream branch with conventional messages; end each commit message with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Do not push.
- If a finding turns out wrong or already fixed when you read the code, skip it and say why in your report.

## Phase 1 — stop the damage (branch `feat/improve-phase1`)

### Stream `auth` — owns `Sources/Adapters/{Claude,Codex,Grok,Agy}Adapter.swift` (auth/login/refresh code only), `Sources/Adapters/ClaudeActivity.swift` excluded, `Sources/Island/EdgeAddChrome.swift`, `Sources/Infra/CredentialStore.swift`, new `Sources/Adapters/LoginProcess.swift`
Findings: adapters-01, 03, 04, 05, 07, 08, 09, 11, 13, 14, 15, 17, 18, 19; core-13; ui-07.
Acceptance:
- Agy add from a clean folder can complete: visible login runs with the managed HOME; no model ping in the login path; reauth passes prior tokens and rejects the unchanged session (use `isAcceptableLogin`); UI copy matches behavior.
- One shared Process lifetime helper: cancellation terminates the child (withTaskCancellationHandler + defer terminate). All four adapters use it.
- Codex/Grok reauth move `auth.json` to a `.prior` file instead of deleting; restore on failure/cancel; delete on success. Test with temp dirs.
- Token-host failures (429/5xx/network on the OAuth token endpoint) classify as soft `unavailable`, never usage `rateLimited` or `authRequired`, in all adapters. One shared classifier with tests.
- Missing/null windows are "not reported", never a real 0% (adapters-08, 15).
- No unsynchronized static mutable caches (adapters-09); cache keys per account.
- Cancelled wait loops exit (adapters-11). Number parser never traps (adapters-18).
- Credential dirs 0700, files 0600 (adapters-19). Empty/invalid `credentialRef` cannot resolve to the root folder (core-13).
- Do NOT change usage GET request construction (stream `polling` owns timeouts there).

### Stream `polling` — owns `Sources/AppCore/UsageOrchestrator.swift`, `Sources/Adapters/ClaudeActivity.swift`, usage GET request timeouts in the four adapters (only the `URLRequest` for usage and the CLI ping call site), new pure policy files under `Sources/Domain/` if needed
Findings: core-01, 02, 03, 04, 05, 09, 14; adapters-10; plus: wake 60 s grace (codex-island `Sources/Usage/WakeScheduling.swift` pattern); log follow-ups: failed fetch line → `warn`, remove the duplicate adapter-level failure line or align its keys, `cliPing` logs `dir=` as `UUID.short`-style ref.
Acceptance:
- Local burn sampling never parses files on the MainActor (detached task; results applied on MainActor). Per-file offset cache so unchanged files are not re-read.
- After a network/transient error, retry follows a short backoff (e.g. 1, 2, 4 min capped below the idle interval), tested as a pure function.
- Usage GET has a timeout (≈20 s). CLI ping is not awaited inside the poll batch. A slow account does not block other accounts (replace fixed batches with a concurrency limit).
- A poll result that arrives after refresh/remove for that account is discarded (generation token).
- Active cadence really ≈60 s (tick/stamp fix) — test.
- Wake: first poll after wake waits ≈60 s grace; overdue detection pure + tested.
- Projection identity cache cleared on reauth.

### Stream `ui` — owns `Sources/Island/*` except `EdgeAddChrome.swift`, `Sources/Theme/*`
Findings: ui-01, 02, 03, 06, 08, 09, 12, 15, 17, 18, 20; log: `[window] notch refresh` only when geometry changes, at `debug`.
Acceptance:
- Hover: expand after a short dwell (~150–250 ms); app activation only on click or when a text field needs focus; previous app regains focus on collapse if we activated.
- All `TimelineView` animations (rim glow, gauge, LiveDot) pause when compact-and-idle, when the window is occluded, in Low Power Mode, and when Reduce Motion is on. Target idle CPU ≈0 when compact. A `MotionPolicy` pure function decides frame rate; test it.
- Reduce Motion: no sweeps, no needle swing, rings set without 0→value animation (ui-03, ui-15).
- Prefs `isOpen` resets when the panel hides (ui-06). Remove-account dialog: Cancel is default, Escape cancels (ui-08).
- Non-notch display: hide the fake pill in full-screen spaces and do not cover the menu bar center when compact (ui-12).
- Unit tests for notch geometry/hit area (ui-20).

### Stream `data` — owns `Sources/Infra/{LocalUsageReader,AccountUsageReader,ProviderUsageReaders,UsageLogLines,AccountsPersistence,Log}.swift`, `Sources/AppCore/{VendorStatusStore,LocalUsageStore,PreferencesStore}.swift`, `Sources/Domain/{UsageSnapshotMerge,UsageSnapshot,LocalUsage,WidgetViewModel}.swift`
Findings: core-06, 08, 10, 11, 12, 15, 16.
Acceptance:
- Archive re-reads only appended bytes of changed files; archive write is not a full rewrite per refresh (or bounded).
- Vendor status matching limited to named components per vendor; test that unrelated incidents do not mark Codex (core-08).
- Error severity/caption from typed data, not substring matching (core-10) — keep behavior, add tests.
- Codex price applied when reading captured rows so Codex projection works (core-11; coordinate with stream `scripts` which fixes the collector side).
- accounts.json decode tolerates one bad row (skip + log + backup), and new optional fields (core-12). Tests.
- Log sink failure is reported once at warn to unified log (core-15).
- Domain no longer imports AppCore types (core-16) if the change is small; otherwise skip with reason.

### Stream `scripts` — owns `scripts/*.py`, `scripts/account-cli.py`, `Tests` for python (`scripts/test-usage-collector.py`)
Findings: tooling-01, 03, 05, 06, 14, 15, 17, 18.
Acceptance:
- connect-usage re-installs the collector when the repo copy is newer (version stamp), checks Python ≥3.11, writes config files atomically without replacing symlinks (write through the resolved path), and offers `--disconnect` that restores backups and unloads the LaunchAgent.
- Collector stores Codex rows with price when available; DB gains a time index and a retention policy (e.g. 400 days); error log rotates.
- Bearer token in CLI config: document the risk; restrict file mode to 0600 where we write it.
- account-cli: document isolation limits; for agy do not replace HOME for the whole shell session.
- Python tests pass: `python3 scripts/test-usage-collector.py`.

## Phase 2 — at a glance (branch `feat/improve-phase2`)

Streams: `glance` (compact rim state color + ear summary + VoiceOver value; defaults ON), `alerts` (pure `AlertDecision`: thresholds 80/95 default, once per crossing per reset window, no alert on first read, recovery alert, stale-reading alert; island pulse; `UNUserNotificationCenter` default ON with permission request; per-account mute), `eta` (pure ETA + safe daily budget from BurnRate + resetAt; 30-min rounding; hidden with too few samples; hover + detail text), `clarity` (ui-05 used/remaining consistency, ui-10 menu/keyboard paths for add/reorder/remove, ui-11 legibility ≥10–11 pt and ≥60% opacity + shape for state, ring legend, burn needle rest color, error caption as a Reauth button, ui-13 onboarding, ui-16 a11y labels, tooling-07), `health` (Health section: collector reachability, last captured event, restart-needed hint, next poll per account; vendor incident badge in hover/detail; `status.json` export with an allowlist of fields; clicking "checked N ago" refreshes).

## Phase 3 — foundation (branch `feat/improve-phase3`)

Streams: `ci` (GitHub Actions PR checks on macos-15: tests → build → 1 s smoke; actionlint; actions pinned by SHA), `release` (MIT LICENSE; app icon `.icns` via script; CHANGELOG (Keep a Changelog); VERSION bump rules; git commit + version in Info.plist and launch log; tag-triggered release workflow producing zip + SHA-256; build.sh resource checks — tooling-08/10/11/12), `tests` (tooling-09 suite auto-registration or a guard test; e2e scripts share one prebuilt module, fixed /tmp path, pixel threshold normalized by backing scale), `refactor` (core-07 split UsageOrchestrator into scheduler/policy/persistence/presentation; adapters-12 inject URLSession/Process; adapters-16 dedupe shared adapter logic; adapters-02 per-folder flock + re-read before refresh; adapters-06), `i18n-docs` (ko/en string catalog for UI copy, date locale consistent with UI language (ui-14), KRW display currency, 7-day sparkline in detail, README drift + Privacy/network section (tooling-13, 16), ui-19 theme constants).

Deliberately excluded (report "hold" quadrant): WidgetKit widgets, share cards / yearly calendar, agent-session approval features, Codex app-server fallback.
