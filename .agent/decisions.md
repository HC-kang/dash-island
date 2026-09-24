# Decisions

Product, UX, and policy choices, with user choices marked. A later entry supersedes an earlier one only where it says so.

## Locked UX (spec summary)

- Account-only unit; 1–5 center-aligned square widgets.
- Flush dual rings (usage); outer speed ticks + red needle (burn vs cruise).
- First poll needle = 0. Hover tooltips open downward.
- Add: right chevron, dwell ≥500ms → glass `+` (no idle ghost slot).
- Claude: credential read-only (no OAuth refresh race). (Superseded 2026-07-20: see "Auto OAuth refresh".)
- Island UI: **compact by default** (thin bar); expand on hover; collapse ~350ms after leave; click-through outside hit area (2026-07-19 fix — must not stay fully open).

## Polish pass 1–7 (2026-07-19)

1. Fake removed from product Add menu (`VendorRegistry.all`); Fake remains in `allIncludingDev` for adapter lookup/tests.
2. `isHot` uses `usedPrimaryFraction` (not Remaining-flipped display %).
3. Prefs: Quit Dash Island.
4. Name Cancel aborts add + deletes credential dir; login failure cleans dir; progress Cancel cancels Task + cleanup.
5. NSMenu begin/end tracking holds expanded island.
6. Non-modal Sign-in progress panel during CLI OAuth (Cancel supported).
7. Add rail dwell 500ms; poll age TimelineView 1s; cold-start widget spinner + “waiting for first poll…”.

## Burn

### Burn window priority (2026-07-19)

- User rule: burn uses **5h → weekly → monthly** kind order.
- Was wrong: preferred absolute counters first (elevated Grok monthly over everything; ambiguous for multi-window).
- Now: pick first existing of fiveHour, weekly, monthly. Exception: coarse weekly % + monthly absolute counters → monthly (Grok needle signal).
- Claude needle stuck: (1) only full 5m poll, (2) API gives integer utilization only — no Δ while % flat. Fix: burn micro-poll includes Claude/Codex every ~3m; still needs a 1% tick to seed needle. (Superseded 2026-07-20: burn timer is local-only; see mistakes.md "Overnight rate-limit".)

### Burn needle vs integer % (2026-07-19)

- Same formula for 5h/wk/mo: ratio = (Δu/Δt) / v_cruise; v_cruise = remaining/ttr or 1/W(kind). Weekly W is 7d — not 5h constants on weekly samples.
- User cruise intuition: ~2% of 5h bar per 5 min ≈ cruise (300/ttr with ~4.2h left).
- Claude API whole-percent → often Δu=0 while actually using. Fixes: (1) coarse baseline = previous sample not 15m lookback, (2) ClaudeActivity from ~/.claude JSONL boosts needle via noteLiveActivity every burn tick, (3) Grok still absolute monthly counters.

### Burn motion UI (2026-07-29)

- `Sources/Domain/BurnMotion.swift` — continuous tier smoothstep (rest/cruise/hot/redline) from design brief; jitter envelope ≤ amp (weights sum 1); per-account phaseOffset 0.2–1.85s.
- `GaugeRingView` — energy trail, track highlight, rest breath 15fps / hot 30fps, bloom blur only past cruise, tip halo only deep overdrive.
- `AccountWidget` — continuous border warmth/fill lift from burn (no bounce).
- Brief: `notes/dash-island-burn-ui-motion-brief.md` (gitignored notes). DO-NOT: rainbow, bounce, strobe, particles, phase-lock all widgets.

### Needle base (2026-09-19)

- Decision: needle base = API Δ (all vendors); Claude local logs = fast assist only for identity-matched account. Do not shorten Claude polling (5 accounts, 429 → 2h cooldown).

## Polling

### Lazy expand poll policy (2026-07-20)

- Fixed background `UsageOrchestrator.backgroundPollSeconds = 15m` — poll interval prefs removed.
- Expand: IslandRootView dwells 400ms then `onIslandExpanded()` → poll mode `.expand` with interval max(120s, vendor minPoll); cooldowns respected.
- Fetch concurrency capped at 2. Launch/wake/account-change still seed.
- Prefs copy: "Background poll every 15m · fresh data when you expand".
- Later changes (2026-09-22): Claude minPoll 120s, scheduler tick 60s, expand re-asks every 60s while open. See mistakes.md "Usage was 30m stale".

## Auth and credentials

### Claude creds: file only (2026-07-19)

- User: stop poking Keychain every poll — just keep the token we got at login.
- Was: every `readCredentials` / 401 path hit scoped `Claude Code-credentials-<hash>` + security CLI fallback, rewrite file from keychain.
- Now: steady-state source of truth = `accounts/<uuid>/.credentials.json` only. Keychain touch only on (1) login capture once if CLI wrote keychain first, (2) reauth wipe of scoped item so CLI re-login is not short-circuited. Never the default global Claude keychain.
- Expired access token → authRequired / reauth; we still do not OAuth-refresh (would race CLI). (Superseded 2026-07-20.)

### Auto OAuth refresh (2026-07-20)

- Managed Claude accounts: proactive refresh when access token within 5m of expiry; reactive on 401. POST platform.claude.com/v1/oauth/token with public Claude Code client_id; persist rotated refresh_token to accounts/<uuid>/.credentials.json only — never default keychain (avoids dual-refresh with user CLI).
- Managed Codex: refresh via auth.openai.com/oauth/token (client app_EMoamEEZ73f0CkXaXp7hrann); throttle by last_refresh 45m unless force on 401.
- Reauth still required if refresh_token revoked/expired.

### File-only Claude credentials (2026-07-31)

- Steady-state: only `accounts/<uuid>/.credentials.json` — no Keychain read on poll/refresh.
- Keychain scoped item: login capture once + clear on reauth only (never global `Claude Code-credentials`).
- Multi-account = separate dirs/files; process-wide refresh gate still serializes token endpoint.
- Quiet UX: "Reauthenticate this account" (not "open Claude Code" for managed folders).

### Claude probe-first (2026-08-10)

- Live: token hosts both 429; personal access still OK → usage 200; Dev access dead → 401.
- Fix: `shouldProbeBeforeRefresh` — probe usage first; refresh only on expiry/401.
- Soft captions: "oauth rate limited" (not fake reauth / 0% rings).

### File-only Claude auth (2026-08-13)

- User: Keychain is too cumbersome; do not use it here.
- Harvest-once restored: after Add/Reauth, copy scoped `Claude Code-credentials-<sha8>` into the managed file. Poll/refresh stay file-only. (Reason: the CLI writes Keychain only; see constraints.md.)
- Recovered one account by copying that Keychain item into `.credentials.json` (pro, has refresh).

### Claude token recovery: recover silently, warn only for dead refresh paths (2026-09-17)

- User: browser login cannot be automated, but anything recoverable with stored keys must recover on its own, no blocking popups; warn only when login is truly needed. Poll path already did HTTP refresh_token recovery; most "token quiet" captions were self-inflicted by the app-wide 15-minute oauth/token gate (second Claude account expiring inside the window was deferred and then given a flat 30-minute soft cooldown).
- Gate is now per account (keyed by the managed config dir path), persisted as a dictionary; a token-host 429 still quiets every account. Local deferral is `RefreshOutcome.deferred(Date)`, distinct from server `.rateLimited`. Both produce a soft snapshot carrying `UsageSnapshot.retryAt`; the orchestrator sets the cooldown to that date instead of 30 minutes. "refresh pending" has no red caption (yellow "stale · refresh scheduled" notice only, status panel says "waiting to retry").
- No refresh token / unreadable managed file after a usage 401 now returns `.authRequired` (red "reconnect account"), not a soft "token quiet" string that failureKind classified hard but caption() rendered as token quiet.
- Trade-off: N accounts expiring together now POST together (previously serialized 15 minutes apart). Acceptable for a handful of accounts; the shared 429 quiet is the backstop.
- Tests: ClaudeRefreshGate made internal for `runGate()` (per-account spacing, shared 429 quiet, relaunch persistence, caption mapping). 237 Swift checks and build pass.

### Grok Add and Claude setup-token (2026-09-23, p1/auth)

- Supersedes Task 9: Grok Add no longer copies `~/.grok/auth.json` when the CLI is missing (shared refresh family). Claude setup-token paste code removed (no UI used it); stored long-lived files still work.

## Vendors and rings

### Gemini → Antigravity (2026-08-19)

- Codex was never removed. Gemini CLI was retired; Add menu now has Antigravity (`agy`) instead of Gemini.
- Usage: `fetchAvailableModels` on `daily-cloudcode-pa.googleapis.com`. Creds under managed `HOME/.gemini/oauth_creds.json`.
- Leftover guards same as Claude. `agy` binary may be missing until install.sh.

### Tertiary ring: Fable + Codex model limits (2026-08-10)

- Claude `limits[]` weekly_scoped Fable → `tertiary` amber ring (was hover-only extras).
- Codex `additional_rate_limits` (e.g. GPT-5.3-Codex-Spark → "Spark") → tertiary; `reset_after_seconds` fallback.
- GaugeRingView: outer brand / mid steel / inner amber when tertiary present.
- Burn stays primary/secondary only.

### Total mode and ears (2026-09-24, phase 2)

- Ears cover menu-bar widgets on notched displays. `EarsMode.auto` shows them only on displays without a notch; the expanded island shows the glance in its top band instead.
- Total mode: each account adds its shortest own window, unless its longer window is ≥ 0.95 (week 100% + 5h 0% must not read 0%). Model-scoped extras do not count.

## Accounts

### Horizontal account scroll (2026-08-09)

- maxAccounts / maxItems = 8; maxVisibleSlots = 5 (island body width). (Cap superseded 2026-09-16: 20.)
- GaugeClusterView: ScrollView when slotCount > 5; edge fades; scroll disabled while drag-reorder. (Drag auto-scroll added 2026-09-16; see patterns.md.)
- Drag hit-testing uses rowOriginX from GeometryReader in dragSpace.

### Account limit raised to 20 (2026-09-16)

- User selected a practical 20-account cap instead of unlimited accounts. AccountStore.maxAccounts is now the single source; IslandModel.maxItems references it. Keep five visible slots and horizontal scrolling, with the existing bounded polling concurrency.
- Existing cap test exercised 20 successful additions, rejected the 21st, and now reloads the saved store to check all IDs survive. Viewport check covers 20 entries with five visible. All 171 Swift checks and build passed; rebuilt app restarted. Follow-up is included in PR #11.

### Destructive confirm (2026-09-23, p1/ui)

- Destructive confirm: Return = Cancel, Remove is click-only, Escape goes through `DialogPanel.cancelOperation`. A scratch key-event check confirmed Return removed before the fix.

## Usage details

### Click usage details feasibility (2026-09-12)

- Review: `docs/notes/2026-09-12-usage-details-review.md`; source codex-island local `1a0634d` (0.2.5), app code unchanged.
- User priority: useful information presented beautifully; selective reuse, not feature parity. Recommended hover remains brief; click opens persistent small detail panel with quota, selected period, model contribution and API-equivalent estimate.
- Source ledger 47 checks pass, but Codex reader fixture double-counts repeated cumulative snapshots and discards `cache_write_input_tokens`; actual local samples contain both relevant patterns. Fix before porting. Missing model/price must not become a guessed model or a real $0.
- Dash Codex scoped-limit parser only reads primary; Spark Weekly requires secondary too. Primary/missing percentage currently becomes 0; preserve unavailable state before exposing detail. Prediction needs quota history, not local needle heuristic.
- The attribution rule from this review lives in constraints.md "Usage attribution".

### Keep usage details scoped to the clicked account (2026-09-15)

- User chose to remove the source selector entirely: selecting a widget already selects the account. Details now always load initial.id and show a small static “This account” caption with the period control. Removed All/transcript navigation, source state, and empty-state links to those views; keep the Grok/Agy account-launch command when needed.
- Historical archive files and collection stay intact. Updated README to describe the account-only UI. This supersedes the prior decision to expose three source choices; do not reintroduce them without a new user request.
- UI-only simplification: build and diff whitespace check passed, rebuilt app restarted from build/DashIsland.app at 23:27. No usage parser or attribution logic changed; no new tests added.

### Projection display (2026-09-22)

- The estimate is drawn as a faint thin arc past the measured one and labelled in the tip. Never the centre number. Reason: an estimate presented as a reading costs more trust than a stale number does. (Mechanics in patterns.md "Between-poll projection".)

## Collector lifecycle

- Decision (2026-09-23): disconnect does NOT restore backup files wholesale. Claude Code rewrites settings.json (permissions etc.), so a wholesale restore loses user changes.
- Collector (2026-09-24): the app reads the interpreter from the LaunchAgent plist and runs `connect-usage.py --update`. The user is never asked to reconnect. `--update` never touches CLI configs.

## Network retry floor (2026-09-24)

- `isDue` floors a network retry at the vendor `minPoll` (agy 300 s). Kept on purpose: a timed-out request may still have reached the vendor. The log prints `max(backoff, minPoll)`.

## Claude work-session restart (2026-09-14 → 2026-09-15)

- 2026-09-14: User confirmed the misattributed Claude activity is one work-repo session. Prepared a resume command using the existing account-cli with the Dev account and `--resume` pointing at the original JSONL. Installed Claude supports JSONL resume; isolated `auth status` reports logged in and email matches the managed Dev profile. No model request or user-session restart was performed. Restart approval was requested separately because it can interrupt active work; session identification alone is not restart approval.
- 2026-09-15: User explicitly chose “작업을 마친 뒤 진행” for restarting that work session under the Dev account. Leave the current Claude process untouched until task completion is confirmed; TUI idleness alone is not completion. After confirmation, refresh the live terminal/process identity and prepared resume command before acting, preserve the conversation, then verify fresh call attribution. No immediate restart authorization.
- 2026-09-15 (moot now): The original work-session process and Orca terminal are gone; the worktree directory was removed, while the transcript remains. No existing session remains to restart. Marked the previously prepared /tmp resume command stale. Latest collector inspection has new Dev-ID Claude records on Sep 15 14:22; Developer-ID records last arrived Sep 14 16:59. This is observed reported-identity collection, not retrospective proof of billed identity.

## Roadmap and research

### Feature benchmark inventory (2026-07-20)

- Living inventory: `docs/notes/feature-benchmark-inventory.md`
- References: codex-island (notch HUD, Sparkle, cost/alerts, poll≥5m), orca rate-limits service (15m default, inactive pause, error class, Fable/limits[], multi-account), CodexBar via orca docs (source planner — optional later).
- P0 closed recently: no network burn poll, cooldowns, 5h→wk→mo burn, file-only Claude creds.
- Top P1 gaps: Claude `limits[]`/Fable, auth expiry UX + vendor captions, sleep/inactive poll backoff, Grok dual-fetch thrift, status request budget, launch-at-login, Sparkle when public, needle source labeling.
- Explicit skips: Electron UI, full Orca provider zoo, Claude OAuth refresh, cost/year calendar in v1.

### P1 wave sequential (2026-07-20)

Implemented from feature-benchmark-inventory:
- U11 Claude limits[] Fable → snapshot.extras (hover only)
- A06/A07 token expiry notice + vendor reauth captions
- P06 sleep skip poll; screen lock 30m floor
- P09 Grok monthly fetch ≤15m cache
- P10 status budgetCaption + cooldown/next due rows
- B08 burnSource hover hint (api/local/both)
- S10 Launch at Login (SMAppService)
- M06/M08 prefs launch + refresh; default poll 15m
- R01/R02 plan only: docs/notes/SPARKLE-HOMEBREW-PLAN.md

### Research report — code/UX/benchmark (2026-09-23)

- Report: private artifact (link kept outside the repo). 73 findings (44 adversarially verified: 20 confirmed, 24 partial, 0 refuted; 4 final high: adapters-01 Agy add path, core-01 main-thread burn scan, ui-01 hover steals focus, ui-02 always-on 30fps rim glow).
- Measured baseline: 201 tests pass (42 s), build 124 s, 3/3 e2e scripts pass (each recompiles all Sources, 48–263 s), idle CPU ≈5.9% real / ≈4.9% with 0 accounts, fetch success 99.7% over 6.45 h.
- Biggest product gap vs market (CodexBar, codenotch, codex-island, Pulse, Codex Pulse variants): compact island shows no data; no threshold alerts; no ETA text; no Sparkle/CI. "Codex Pulse" is 11+ unrelated repos, not one product.
