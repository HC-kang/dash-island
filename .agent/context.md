# Dash Island — agent memory

## Product

- Multi-vendor multi-account usage notch island (not a codex-island fork).
- Principles: simplicity → practicality → elegance.
- Stack: Swift 6, SwiftUI + AppKit island, in-process `VendorAdapter`s.

## Spec

- `docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`

## Locked UX (summary)

- Account-only unit; 1–5 center-aligned square widgets.
- Flush dual rings (usage); outer speed ticks + red needle (burn vs cruise).
- First poll needle = 0. Hover tooltips open downward.
- Add: right chevron, dwell ≥500ms → glass `+` (no idle ghost slot).
- Claude: credential read-only (no OAuth refresh race).

## Reference repos (read-only)

- `/Users/ford/projects/personal/codex-island` — fetch + notch patterns
- `/Users/ford/projects/personal/orca` — multi-account managed auth model

## Do not

- Commit design or app code into codex-island for this product.
- Introduce Electron, Rust core, or session-binding in v1.

## Implementation progress (2026-07-19)

Branch `feat/v1-implementation` — plan tasks 1–10 landed via subagent-driven development.

- Scaffold + domain + accounts + gauges + orchestrator + add chrome
- Adapters: Fake, Claude (read-only OAuth usage), Codex (wham/usage), Grok (cli-chat-proxy billing; no live verify)
- Prefs sheet: used/remaining + 5/15/30 poll
- Demo: `DASHISLAND_DEMO=1` only (empty → centered +)
- Grok concern: contract from Orca; no live HTTP probe this session
- Island UI: **compact by default** (thin bar); expand on hover; collapse ~350ms after leave; click-through outside hit area (2026-07-19 fix — must not stay fully open)

## Scaffold (Task 1)

- arm64-only `build.sh` → `build/DashIsland.app`, bundle id `dev.dashisland.DashIsland`, LSUIElement, ad-hoc codesign.
- Window: borderless clear floating at top-center of notched screen (`safeAreaInsets.top > 0`); level `.popUpMenu`; activation `.accessory`.
- Sources: `App/App.swift`, `Island/{BorderlessFloatingWindow,IslandWindowController,IslandRootView}.swift`.

## Domain (Task 2)

- `Sources/Domain/`: Types, Account, UsageSnapshot (+UsageError), BurnRate, WidgetViewModel, VendorAdapter (+AddAccountResult).
- Burn math locked: `ratio = v/v_cruise`; first sample ratio 0; negative Δ → 0.
- Needle: `needleUnit = min(1, ratio/2)` → 0 rest, 1 cruise (0.5), ≥2 redline cap.
- Tests: `scripts/run-tests.sh` compiles Domain + Tests only (no XCTest).
- `.gitignore`: `build/`, `.DS_Store`, `.superpowers/`.

## Accounts / credentials (Task 3)

- Layout: `~/Library/Application Support/DashIsland/{accounts.json,accounts/<uuid>/}`.
- `CredentialRef` = folder name under `accounts/` (usually account UUID string).
- `Account` is `Codable` (ISO8601 dates). Cap **5** accounts (`AccountStoreError.maxAccountsReached`).
- `FakeAdapter` id `"fake"`, `minPollSeconds` 300; `fetchUsage` fraction = stable FNV-1a of ref.
- `AccountStore` `@MainActor ObservableObject`; `shared.load()` on launch.
- Tests: `run-tests.sh` compiles Domain+Infra+AppCore+Adapters+Tests; single `@main` in `TestMain.swift`.

## Gauge widgets (Task 4)

- Views: `GaugeRingView`, `AccountWidget`, `GaugeClusterView`; `IslandRootView` hosts cluster.
- v5 balance: flush dual rings (outer brand, inner steel #3a6580), ticks ~0.34α, needle #ef4444 1.35pt.
- Needle piecewise angles (screen deg, 0=east): unit0→135° (7:30), 0.5→300° (1:00), 1→45° (4:30).
- Demo: `DASHISLAND_DEMO=1` only → fake VMs (`DASHISLAND_DEMO_COUNT` ∈ 1|3|5); empty without env → add UI (Task 6).
- Window `600×200`, `acceptsMouseMovedEvents` for hover tooltips below widgets.

## Usage orchestrator (Task 5)

- `PreferencesStore`: `pollSeconds` ∈ {300,900,1800}, `displayMode` used|remaining; UserDefaults keys `DashIsland.*`.
- `UsageOrchestrator`: one timer; due = `now-last >= max(userInterval, adapter.minPoll)`; parallel fetch via VendorRegistry.
- Soft error: retain last-good rings + `errorCaption`; auth → "reauth required"; 429 → 15m cooldown map, skip fetch.
- Burn: prev+last good snapshots only (error-free); first poll ratio 0.
- Pure helpers for tests: `isDue`, `displayFraction`, `formatTokens` (k/m hover).
- App: `startAutoRefresh` after `AccountStore.load`; IslandRootView shows orchestrator widgets when accounts non-empty.
- `refresh(accountID:)` clears due timers and polls (used after reauth).

## Edge add chrome + context menu (Task 6)

- `EdgeAddChrome`: right-edge chevron, dwell ≥500ms → glass `+` menu (VendorRegistry); no width-stealing empty slot.
- Empty (0 accounts, not demo): `CenteredAddButton` only.
- At 5 accounts: hide add chrome. Demo forced (`DASHISLAND_DEMO=1`): hide add chrome.
- Widget context menu (real accounts only): Rename (NSAlert), Reauth, Remove (confirm).
- `AccountStore.markAuthenticated`; add via `beginAdd` → `add(from:)` → accounts sink refreshes orchestrator.

## Claude adapter (Task 7)

- `ClaudeAdapter` id `"claude"`, `minPollSeconds` 300; registered after Fake in `VendorRegistry`.
- Managed auth: `accounts/<uuid>/` as `CLAUDE_CONFIG_DIR`; credentials in `.credentials.json`.
- `beginAdd` / `reauthenticate`: spawn `claude auth login --claudeai` with managed dir; poll ≤180s for creds (file or CLAUDE_CONFIG_DIR-scoped keychain `Claude Code-credentials-<sha256[0:8]>`); copy into managed file. Never write default keychain. Never OAuth refresh.
- Fallback error text includes manual `CLAUDE_CONFIG_DIR=… claude auth login --claudeai`.
- Usage: `GET https://api.anthropic.com/api/oauth/usage` with Bearer + `anthropic-beta: oauth-2025-04-20` + UA `claude-code/2.1.121`.
- Map: 401/403 → `.authRequired`, 429 → `.rateLimited`, utilization always ÷100.
- Parse unit tests in `Tests/ClaudeAdapterTests.swift`; build needs `-framework Security`.

## Codex adapter (Task 8)

- `CodexAdapter` id `"codex"`, `minPollSeconds` 120; registered after Claude in `VendorRegistry`.
- Managed auth: `accounts/<uuid>/` as `CODEX_HOME`; credentials in `auth.json` (`tokens.access_token`, optional `tokens.account_id`). Fallback path: `managed/.codex/auth.json` if HOME-isolated login.
- `beginAdd` / `reauthenticate`: spawn `codex login` with `CODEX_HOME` + strip `OPENAI_API_KEY`/`CODEX_API_KEY`/`CODEX_ACCESS_TOKEN`; poll ≤180s for auth.json; terminate CLI after creds appear.
- Fallback error text: `CODEX_HOME='…' codex login`.
- Usage: `GET https://chatgpt.com/backend-api/wham/usage` Bearer (+ optional `ChatGPT-Account-Id`). 401/403 → `.authRequired`, 429 → `.rateLimited`.
- Parse: `rate_limit.primary_window` / `secondary_window`; `used_percent` always ÷100; `reset_at` unix; `plan_type` → plan. No OAuth refresh from app.
- Parse unit tests in `Tests/CodexAdapterTests.swift`.

## Grok adapter (Task 9)

- Spike: `docs/notes/grok-usage-spike.md` (Orca grok-auth/fetcher + `~/.grok/auth.json`).
- `GrokAdapter` id `"grok"`, `minPollSeconds` **300**; registered after Codex in `VendorRegistry`.
- Managed auth: `accounts/<uuid>/` as `GROK_HOME`; credentials in `auth.json` (issuer map; prefer `https://auth.x.ai…`; field `key` = access token). Fallback path: `managed/.grok/auth.json`.
- `beginAdd` / `reauthenticate`: spawn `grok login --oauth` with `GROK_HOME`; poll ≤180s. If binary missing on add, copy usable `~/.grok/auth.json` into managed folder; else instruct `GROK_HOME=… grok login --oauth`.
- No OIDC refresh in app; expired access → `.authRequired` (5m skew).
- Usage: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` then monthly fallback `/v1/billing`. Headers: Bearer + `X-XAI-Token-Auth: xai-grok-cli` + optional `x-userid`.
- Map: `creditUsagePercent` ÷100 → primary; confirmed weekly with omitted % → 0; monthly `used.val/monthlyLimit.val` when weekly absent; `subscriptionTier` → plan.
- 401/403 → `.authRequired`, 429 → `.rateLimited`. Parse tests in `Tests/GrokAdapterTests.swift`.

## Prefs + polish (Task 10)

- `PrefsSheet`: display mode (used|remaining) + poll interval segmented 5/15/30 min; binds `PreferencesStore.shared`.
- Quiet gear bottom-leading of island chrome → sheet; activates app so sheet can key.
- Gauge rings/needle spring settle (`response: 0.55`, `dampingFraction: 0.88`) via drawn state; first paint snaps.
- Demo env unchanged: `DASHISLAND_DEMO=1`, optional `DASHISLAND_DEMO_COUNT` ∈ {1,3,5}.
- README: build/run/demo/tests.

## Drag reorder UX (2026-07-19)

- **Downward push bug**: was `minHeight` growing when drag started (trash zone). Fix: fixed cluster height = `cellH`; trash/float paint into window `dragBleed` only.
- **Drop preview + push**: freeze `baseOrder` mid-drag; `gapSlot` under finger; non-dragged widgets keep stable identity and animate `.position` to packed seats around the gap; gap skeleton highlighted with ring.
- **Gesture continuity**: dragged id stays mounted at home slot at opacity ~0 (same ForEach identity) so DragGesture does not die when neighbors pack.
- Commit only on drop via `AccountStore.applyOrder`; no mid-drag store mutation. Demo order local-only.

## Credential persistence (2026-07-19)

- Real path: `~/Library/Application Support/DashIsland/{accounts.json,accounts/<uuid>/}` — outside the `.app` bundle; rebuild never wipes it.
- Never launch user-facing smoke tests with `DASHISLAND_DEMO=1` — it replaces UI with fake widgets while leaving disk alone (looks like "accounts wiped").
- Hardening: refuse empty `accounts.json` overwrite unless last account explicitly removed; corrupt file → `accounts.corrupt.<ts>.json` backup, no clobber; orphan folders with valid vendor creds rehydrate into the list on live load only.
- On launch log: Application Support path + account count.

## Menus + restart “missing accounts” (2026-07-19)

- Root cause of “accounts gone after restart”: process often relaunched with `DASHISLAND_DEMO=1` (inherits from agent shells). Demo replaced UI widgets; disk untouched.
- Fix: real accounts always win — `useDemoWidgets = DEMO && accounts.isEmpty`. Never mask registered accounts.
- Menus dead: full-cell `Color.clear` DragGesture overlay ate right-click / Menu hits. Removed; reorder is long-press (~180ms) then drag on the widget itself (offset push, stable cell identity).
- Accessory app menus need `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` on hover / add rail / alerts.
- Launch smoke tests with clean env (`env -i …` or unset DASHISLAND_DEMO). Never leave DEMO=1 processes running for the user.

## Polish pass 1–7 (2026-07-19)

1. Fake removed from product Add menu (`VendorRegistry.all`); Fake remains in `allIncludingDev` for adapter lookup/tests.
2. `isHot` uses `usedPrimaryFraction` (not Remaining-flipped display %).
3. Prefs: Quit Dash Island.
4. Name Cancel aborts add + deletes credential dir; login failure cleans dir; progress Cancel cancels Task + cleanup.
5. NSMenu begin/end tracking holds expanded island.
6. Non-modal Sign-in progress panel during CLI OAuth (Cancel supported).
7. Add rail dwell 500ms; poll age TimelineView 1s; cold-start widget spinner + “waiting for first poll…”.

## Burn window priority (2026-07-19)

- User rule: burn uses **5h → weekly → monthly** kind order.
- Was wrong: preferred absolute counters first (elevated Grok monthly over everything; ambiguous for multi-window).
- Now: pick first existing of fiveHour, weekly, monthly. Exception: coarse weekly % + monthly absolute counters → monthly (Grok needle signal).
- Claude needle stuck: (1) only full 5m poll, (2) API gives integer utilization only — no Δ while % flat. Fix: burn micro-poll includes Claude/Codex every ~3m; still needs a 1% tick to seed needle.

## Claude creds: file only (2026-07-19)

- User: stop poking Keychain every poll — just keep the token we got at login.
- Was: every `readCredentials` / 401 path hit scoped `Claude Code-credentials-<hash>` + security CLI fallback, rewrite file from keychain.
- Now: steady-state source of truth = `accounts/<uuid>/.credentials.json` only. Keychain touch only on (1) login capture once if CLI wrote keychain first, (2) reauth wipe of scoped item so CLI re-login is not short-circuited. Never the default global Claude keychain.
- Expired access token → authRequired / reauth; we still do not OAuth-refresh (would race CLI).

## Burn needle vs integer % (2026-07-19)

- Same formula for 5h/wk/mo: ratio = (Δu/Δt) / v_cruise; v_cruise = remaining/ttr or 1/W(kind). Weekly W is 7d — not 5h constants on weekly samples.
- User cruise intuition: ~2% of 5h bar per 5 min ≈ cruise (300/ttr with ~4.2h left).
- Claude API whole-percent → often Δu=0 while actually using. Fixes: (1) coarse baseline = previous sample not 15m lookback, (2) ClaudeActivity from ~/.claude JSONL boosts needle via noteLiveActivity every burn tick, (3) Grok still absolute monthly counters.

## Overnight rate-limit / reauth (2026-07-20)

- Root cause: burn micro-poll hit vendor APIs every 60s (Grok, dual billing) / ~3m (Claude) and on 429/401 only skipped updating lastGood — **no cooldown** → hammered all night.
- Fix: burn timer is **local Claude logs only** (no network). Usage HTTP only via user poll interval × minPoll (Claude/Grok 5m, Codex 2m). 429 default cooldown 30m; authRequired cooldown 30m (cleared on manual refresh/reauth).
- Reauth overnight also expected when access tokens expire (we never OAuth-refresh Claude).

## Feature benchmark inventory (2026-07-20)

- Living inventory: `docs/notes/feature-benchmark-inventory.md`
- References: codex-island (notch HUD, Sparkle, cost/alerts, poll≥5m), orca rate-limits service (15m default, inactive pause, error class, Fable/limits[], multi-account), CodexBar via orca docs (source planner — optional later).
- P0 closed recently: no network burn poll, cooldowns, 5h→wk→mo burn, file-only Claude creds.
- Top P1 gaps: Claude `limits[]`/Fable, auth expiry UX + vendor captions, sleep/inactive poll backoff, Grok dual-fetch thrift, status request budget, launch-at-login, Sparkle when public, needle source labeling.
- Explicit skips: Electron UI, full Orca provider zoo, Claude OAuth refresh, cost/year calendar in v1.

## P1 wave sequential (2026-07-20)

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

## Lazy expand poll policy (2026-07-20)

- Fixed background `UsageOrchestrator.backgroundPollSeconds = 15m` — poll interval prefs removed.
- Expand: IslandRootView dwells 400ms then `onIslandExpanded()` → poll mode `.expand` with interval max(120s, vendor minPoll); cooldowns respected.
- Fetch concurrency capped at 2. Launch/wake/account-change still seed.
- Prefs copy: "Background poll every 15m · fresh data when you expand".

## Auto OAuth refresh (2026-07-20)

- Managed Claude accounts: proactive refresh when access token within 5m of expiry; reactive on 401. POST platform.claude.com/v1/oauth/token with public Claude Code client_id; persist rotated refresh_token to accounts/<uuid>/.credentials.json only — never default keychain (avoids dual-refresh with user CLI).
- Managed Codex: refresh via auth.openai.com/oauth/token (client app_EMoamEEZ73f0CkXaXp7hrann); throttle by last_refresh 45m unless force on 401.
- Reauth still required if refresh_token revoked/expired.

## Lateral drift fix (2026-07-20)

Root cause: expand/collapse resized `NSWindow` while SwiftUI content laid out at full target size (left-biased during intermediate frames). midX-pin on setFrame was not enough; prior binary also lagged source.

Fix (codex-island pattern):
- `IslandModel.canvasSize` = max expanded footprint (5 slots + rail + bleed).
- `IslandWindowController.pinCanvas` only on screen/notch/display changes — **never** on compact↔expanded.
- Root view: draw `model.size` top-centered inside fixed canvas (`.frame(maxWidth: .infinity, …, alignment: .top)`).
- Hover still hit-tests the visual island, not the full canvas.

## Hover hit tightened (2026-07-20)

Fixed canvas made window huge; expanded hit used `model.size` (incl. dragBleed) and root `onHover` filled the canvas → expand-on-near-miss / stole menu-bar area.

- `IslandModel.hitSize`: compact = notch pill; expanded = black body + 52pt tooltip pad (no bleed).
- AppKit passthrough uses `hitSize` only; drag still opens full window via `dragActive`.
- SwiftUI `onHover` on black-body frame only, not outer canvas.

## Reauth false-positive + error tooltip (2026-07-20)

Live: personal Claude access expired; OAuth refresh returned **HTTP 429**, but adapter treated any failed refresh after 401 as `authRequired` → "reauth: claude auth login". Double refresh per poll (proactive+reactive) worsened 429.

Fixes:
- `ClaudeAdapter.refreshManagedCredentialsDetailed`: distinguish success / 429 rateLimited / 400–403 rejected / other unavailable.
- One refresh attempt per poll; 429 → `.rateLimited` (auto retry, not reauth).
- Widget: short `errorCaption` under gauge; full `detailCaption` in downward body hover tooltip (commands + path).

## Burn motion UI (2026-07-29)

- `Sources/Domain/BurnMotion.swift` — continuous tier smoothstep (rest/cruise/hot/redline) from design brief; jitter envelope ≤ amp (weights sum 1); per-account phaseOffset 0.2–1.85s.
- `GaugeRingView` — energy trail, track highlight, rest breath 15fps / hot 30fps, bloom blur only past cruise, tip halo only deep overdrive.
- `AccountWidget` — continuous border warmth/fill lift from burn (no bounce).
- Brief: `notes/dash-island-burn-ui-motion-brief.md` (gitignored notes). DO-NOT: rainbow, bounce, strobe, particles, phase-lock all widgets.

## Claude adopt-before-refresh (2026-07-31)

- Hermes pattern ported to `ClaudeAdapter`: re-read scoped keychain+file before any `oauth/token` POST; if live access/refresh is fresher & usable (60s buffer), adopt+persist and skip refresh.
- `RefreshOutcome.adopted`; reactive path adopts first then refreshes.
- Hard-expired quiet still avoids POST unless adopt heals.
- Web landscape: usage monitors (ccusage local JSONL; VS Code tracker / Claude-Code-Usage-Monitor / claude-usage crate hit `/api/oauth/usage`); 3rd-party inference OAuth increasingly ToS-restricted; subprocess/CLI ownership is the compliant alternative for agents.

## File-only Claude credentials (2026-07-31)

- Steady-state: only `accounts/<uuid>/.credentials.json` — no Keychain read on poll/refresh.
- Keychain scoped item: login capture once + clear on reauth only (never global `Claude Code-credentials`).
- Multi-account = separate dirs/files; process-wide refresh gate still serializes token endpoint.
- Quiet UX: "Reauthenticate this account" (not "open Claude Code" for managed folders).

## Horizontal account scroll (2026-08-09)

- maxAccounts / maxItems = 8; maxVisibleSlots = 5 (island body width).
- GaugeClusterView: ScrollView when slotCount > 5; edge fades; scroll disabled while drag-reorder.
- Drag hit-testing uses rowOriginX from GeometryReader in dragSpace.
