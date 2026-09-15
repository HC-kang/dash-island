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

## Island widgets pierce right edge (2026-08-09)

- **Symptom:** expanded island — gauges shift right, paint past black body.
- **Cause:** (1) hang-below tips as ZStack children with large `fixedSize` inflated cluster layout width; (2) `expandedWidth` pad (`horizontalPadding=32`) didn't match real chrome (`14` / `4+6` + AddRail).
- **Fix:** tips via `.overlay` (no layout width); GeometryReader available-width + center-or-scroll + `.clipped()`; `expandedWidth` = lead pad + slots + trail pad + chevron/rail.
- Tests: `IslandClusterLayout.needsScroll` / `centeredRowOrigin`.

## Island right-shift pierce v2 (2026-08-10)

- User: 6 accounts → needs scroll; widgets still pierced right edge.
- Root: SwiftUI `ScrollView` ideal width = full 6-cell row → HStack blew past black body.
- Fix: slot/scroll rows use `Color.clear` fixed frame + `overlay` ScrollView/HStack; `minWidth: 0` on flexible band; AddRail `fixedSize`.
- Belt: expanded content masked to `IslandShape` + full-width tip strip under body.
- Domain: `islandBodyWidth` / `slotBandWidth` / `rowWidth` pure helpers + tests (6 accts body == 5-slot viewport).

## Claude probe-first (2026-08-10)

- Live: token hosts both 429; personal access still OK → usage 200; Dev access dead → 401.
- Fix: `shouldProbeBeforeRefresh` — probe usage first; refresh only on expiry/401.
- Soft captions: "oauth rate limited" (not fake reauth / 0% rings).

## Tertiary ring: Fable + Codex model limits (2026-08-10)

- Claude `limits[]` weekly_scoped Fable → `tertiary` amber ring (was hover-only extras).
- Codex `additional_rate_limits` (e.g. GPT-5.3-Codex-Spark → "Spark") → tertiary; `reset_after_seconds` fallback.
- GaugeRingView: outer brand / mid steel / inner amber when tertiary present.
- Burn stays primary/secondary only.

## Drag/trash coordinate fix (2026-08-11)

- Bug: layout overflow fix pinned drag canvas to `cellH` → trash `.position(y: cellH+52)` outside named space; magnet + icon misaligned; float jump.
- Fix: expand canvas by `trashZoneH` while dragging; trash centered in zone; lift from finger `startLocation` / track `drag.location`; clearer dashed drop seat.

## Claude session-expiry port (2026-08-13)

- Codex worktree implemented probe-always + file-only adopt + persist last-good + UserDefaults refresh gate.
- Ported Swift core onto `feat/v1-implementation` (uncommitted). Tests/docs still only in worker worktree.
- Rebuilt `build/DashIsland.app` 0.0.1 and relaunched (pid after 10:46).
- Review notes: adopt only helps if *this* managed file rotates; `canAttemptRefresh` still cuts after 7d stale; vendor Retry-After now uncapped (can quiet >6h).

## File-only Claude auth (2026-08-13)

- User: Keychain is too cumbersome; do not use it here.
- Claude CLI 2.1.229 on macOS writes login to scoped Keychain only — **no** `.credentials.json`. Pure file capture made Reauth fail (`credentialsMissing`).
- Harvest-once restored: after Add/Reauth, copy scoped `Claude Code-credentials-<sha8>` into the managed file. Poll/refresh stay file-only.
- Recovered `9C11FBE9-…` by copying that Keychain item into `.credentials.json` (pro, has refresh).

## Gemini → Antigravity (2026-08-19)

- Codex was never removed. Gemini CLI was retired; Add menu now has Antigravity (`agy`) instead of Gemini.
- Usage: `fetchAvailableModels` on `daily-cloudcode-pa.googleapis.com`. Creds under managed `HOME/.gemini/oauth_creds.json`.
- Leftover guards same as Claude. `agy` binary may be missing until install.sh.
- Reauth bug: wipe file only → `auth login` opens browser then harvests leftover scoped Keychain. Fix: snapshot access token, logout + delete scoped item, accept only a *different* access token.

## Orchestration auth graph (2026-08-16)

- Run `run_43471c922fa7`: graph → harden → verify (3 Grok workers, ~20 min).
- Landed on feat: leftover refresh rejected (H1), usage smoke after harvest (H2), last-good wiped on clear (H6), rollback rejected harvest, scoped KC wipe on cancel/remove (H4).
- Still open: leftover that rotates *both* tokens; `runLogout` fire-and-forget (H3); global Claude Code KC clone (H7); adopt+401 skip POST (H8).

## Claude auth graph (2026-08-16)

- Audit: `docs/notes/claude-auth-state-graph.md` (states, transitions, holes, unit-test list).
- Same-access leftover after reauth is rejected (8148deb). Still open: leftover session that **rotates** access; browser add/reauth skips usage smoke test; logout/remove do not guarantee scoped-session death; last-good not cleared on identity change.
- Next tests: temp-dir file only. Never write the unsuffixed `Claude Code-credentials` item.

## Claude auth holes H1/H2/H6 (2026-08-16)

- H1: `isAcceptableLogin` now rejects same `refreshToken` even when access rotated. beginAdd (`prior == nil`) still accepts any non-empty harvest.
- H2: `beginAdd` / `reauthenticate` call `verifyUsageAccess` after harvest. Policy extracted as `usageSmokeDecision` (401 reject; 429/network soft keep).
- H6: `clearManagedCredentials` also deletes `.dash-island-usage.json` so wipe/reauth cannot keep the previous identity's rings.
- Tests: temp-dir file only. Never wrote unsuffixed `Claude Code-credentials`.
- Remaining: leftover that rotates **both** access and refresh still passes H1 (needs logout/H3); beginAdd clone of global CLI session still accepted; H8 adopted+401 still skips oauth/token; `runLogout` still best-effort.

## Claude auth graph walk (2026-08-16)

- Walked `docs/notes/claude-auth-state-graph.md` against `1d04401` + cheap fixes. Report: `docs/notes/claude-auth-graph-walk.md`.
- Graph stale vs code: H2 smoke is on browser add/reauth; H6 wipe clears last-good (tokenless no longer keeps old rings).
- Cheap fixes: smoke-reject rollback (`clearManagedCredentials` on add/reauth catch); `requireCredentials` file-only (H10); add-cancel + `AccountStore.remove` wipe scoped KC (H4 file/KC).
- Still open: H1 residual (both tokens rotate), H3 logout fire-and-forget, H7 global KC, H8 adopted+401, H9 429 soft-keep, live CLI/HTTP untested.

## Claude hashed Keychain pollution (2026-08-30)

- CLI 2.1+ writes `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>`. Each account UUID (and each failed Add) is a **new Keychain item** + password sheet (`321711bc` = `90A3EF8C-…`).
- Access ~8h; **refresh ~27d** (`refreshTokenExpiresAt`). Waiting for usage 401 never rotates refresh → certilife 27–30d death. Token-host 429 then Reauth wiped the file and harvested Keychain again.
- Fix: file is SoT. After harvest (or any poll that already has a file) **delete the hashed item**. Wait-loop harvest is silent; one prompt only after CLI exit on first Add. Reauth tries HTTP refresh first and does **not** wipe the file on failure. Proactive refresh: Orca 5m access skew + 24h-before-refresh-expiry. `invalid_grant` is fatal; other 400s try the next token host.
- Never touch unsuffixed `Claude Code-credentials` (user's real Claude Code).
- Ad-hoc codesign still resets ACL on every rebuild — that's why Always Allow dies in dev. Don't re-read Keychain after the file exists.

## Reauth must not fail on token-host 429 (2026-08-30)

- Bug: HTTP-first reauth `throw reauthFailed("token host is rate-limited…")` → "Reauthenticate failed" sheet. User still has a ~27d refresh_token.
- Fix: `reauthStep` — 429/unavailable → **keep existing** (return ref, no alert). User-initiated refresh uses `force: true` (one POST, skip 20m/3h poll gate). `invalid_grant` still opens browser. Progress copy is "Extending this Claude session", not "browser required".

## Token-host 429 must not hide usage for 4h (2026-08-31)

- Symptom: tooltip “retry in 3h 59m / last ok 20h ago”. First token host 429 aborted the loop; adapter returned `.rateLimited(3h)`; orchestrator streak×2h = **4h lock**. Access already dead → no usage.
- Fix: try **console.anthropic.com then platform.claude.com**, form + JSON. 429 on one host continues. Cap quiet at **15m**. Token-host 429 → `.unavailable("token quiet")` not usage-quota 429 (no 2h/4h/6h streak). Drop persisted 3h UserDefaults gate on launch. Expand retries if last success ≥2h stale.

## HTTP oauth/token 429 for days; CLI still refreshes (2026-09-02)

- Live: both token hosts 429 (no Retry-After) for ~3 days. Access 401 “expired”. Refresh_token still valid (~24d).
- `claude -p ok --model haiku` with `CLAUDE_CONFIG_DIR` **does** rotate tokens. Darwin CLI writes scoped Keychain and **deletes** `.credentials.json`.
- Harvest with `/usr/bin/security find-generic-password -w` (no Dash password sheet), persist file, delete hashed KC. Usage then 200 (max 32%/17%, pro 0%/2%).
- Adapter: on HTTP 429/fail, `pingCLIThenAdopt` then security harvest. Never poll-path `SecItem` Allow.

## Agy client-id scan ate a leading `it` (2026-09-02)

- Tooltip: `token refresh failed — retrying`, last ok 5d 8h. Access `expiry_date` 2026-08-28. Refresh still valid.
- Scanner walked back through letters → `it1071006060591-….apps.googleusercontent.com` (invalid). Real Gemini CLI id is `1071006060591-…`. Pair **id[1] × secret[0]** HTTP 200; usage `fetchAvailableModels` 200.
- Strip leading non-digits from embedded googleusercontent IDs.

## Click usage details feasibility (2026-09-12)

- Review: `docs/notes/2026-09-12-usage-details-review.md`; source codex-island local `1a0634d` (0.2.5), app code unchanged.
- User priority: useful information presented beautifully; selective reuse, not feature parity. Recommended hover remains brief; click opens persistent small detail panel with quota, selected period, model contribution and API-equivalent estimate.
- Source TokenEvent/CostStore are provider-wide, not account-aware. Never attribute global local logs to the clicked account; label machine/provider scope unless ownership is proven. Grok `usedTokens` may contain monetary counters, not token counts.
- Source ledger 47 checks pass, but Codex reader fixture double-counts repeated cumulative snapshots and discards `cache_write_input_tokens`; actual local samples contain both relevant patterns. Fix before porting. Missing model/price must not become a guessed model or a real $0.
- Dash Codex scoped-limit parser only reads primary; Spark Weekly requires secondary too. Primary/missing percentage currently becomes 0; preserve unavailable state before exposing detail. Prediction needs quota history, not local needle heuristic.

## Usage details, source scope and hover regression (2026-09-12)

- Click opens a separate persistent panel; Today/7d/30d, model/token/cache rows, metadata-only history and API values. All four providers supported. Codex/Claude parsers deduplicate cumulative/streaming rows, preserve cache buckets, and leave unknown prices unpriced. Grok real logs use `params.update` → `turn_completed` and `cachedReadTokens`; `costUsdTicks / 1e10` supplies recorded API value. Agy SQLite reads require WAL stamp tracking and one read transaction; one generation is one call.
- User correction: provider-wide totals under each account were misleading. Default reads only selected managed folder, with separate per-account archive keys. Shared CLI logs are opt-in “All … on this Mac”; no inferred allocation to whoever is currently signed in. Missing account-linked history is not zero usage. Quotas remain per-account.
- User correction: do not move tooltips inward to hide clipping. Preserve widget center. Root mask was clipping the balloon (including its upper part overlapping the body); remove duplicate root mask, retain existing slot-row clip, and render tips in the transparent fixed canvas. Anchor tip top directly instead of measuring half-height, which lagged on card changes.
- Drawing padding (200pt) is separate from hover retention (20pt). Window-level pointer boundary notification handles exits lost when `ignoresMouseEvents` flips; collapse waits for no pointer/drag/detail/other overlay. Never enlarge mouse retention to fix drawing.
- Codex reset count: GET `/backend-api/wham/rate-limit-reset-credits` with selected account bearer and `ChatGPT-Account-Id`; actual accounts returned 1 and 3. Optional snapshot field, read failure is unavailable, not zero; no reset consumption action. Keep quota even if credit request fails.
- Verification: build passed; 169 checks passed, including history isolation across accounts/restart, reset count invalid/zero, all four readers, WAL refresh and saved-history failure paths. Native screenshots verified both edge tooltips unclipped, separate account/Mac scopes, reset count display and collapse after moving to y205 (body bottom168).
- Build and tests must run sequentially: build.sh removes build/, including the test linker output directory. Never run these concurrently.

## Real account collection, Orca + CLI (2026-09-12)

- User explicitly wants both Orca and ordinary CLI calls connected; a scope picker alone is not account support. Claude's nearly identical totals were separate authentication refresh pings (3 calls per account), not shared event IDs. Stop presenting these as the user's work.
- Orca Codex account homes hardlink other accounts' history for resume (`codex-account-session-bridge.ts`). A log's folder is NOT proof of ownership. Claude Orca uses `claude-accounts/<id>/auth` as CLAUDE_CONFIG_DIR even when it initially contains no settings/projects. Root `orca-data.json` can be stale; active profile data lives under profiles/local-default.
- Implemented native completed-call OTLP/JSON collection for Codex/Claude, shared by Orca and ordinary CLI. Python stdlib collector binds loopback only, authenticates a local token, stores only identity hashes + model/tokens/cost/event IDs in SQLite. LaunchAgent keeps it alive without the UI. Connection script validates all configs before changes, preserves unrelated config/hooks, backs up changes, refuses existing third-party exporters, and is idempotent. It configures default, custom-env, Dash managed, and Orca managed homes. Existing processes must be reopened once to inherit config; never restart the user's working Orca automatically.
- Critical live-format regression: Codex OTLP body is null and timeUnixNano is "0"; fields are in attributes, including ISO `event.timestamp`. Python dict.get's default expression evaluated a null body even with event.name present. Use short-circuit/default-null normalization and stable event.timestamp fallback; never receipt time (retry doubles totals). Loopback fake-provider test with the installed Codex produced expected (input70, output5, cacheRead30). Source completion emits both a timing-only and a token-bearing event; only latter counts. Reasoning remains part of output, cached input subtracted once.
- AccountUsageReader joins Codex user.account_id or Claude accountUuid+organizationUuid against call-time identity. It replaces old folder-derived account archives for these two vendors, preserving old files but not mixing them in. Detail refreshes every 15s. Authentication refresh ping supplies dash_island.purpose=auth_refresh and collector excludes it.
- Live proof: Codex personal events joined only personal (Developer stayed empty); Claude Dev events joined only Dev (other two empty). Claude CLI's 8,779 tokens/$0.016881 matched two captured API calls, including a subsidiary request. Native completed-call events can include actual auxiliary inference beyond the CLI's headline last-turn count.
- Grok/Antigravity account-cli launcher selects managed GROK_HOME/HOME, clears competing API-key variables, keeps cwd/arguments, and works in either kind of terminal; detail provides copy command. Ordinary launches outside that selected home stay machine-wide. No global login/account switch was performed.
- Final verification: 170 Swift checks + Python collector/config/launcher checks passed; native detail UI showed Codex personal 30.6K/$0.31 and Claude Dev 8.8K/$0.02 from the new SQLite source. Collector settings were installed into 12 homes with original configurations backed up. Existing Orca/CLI provider processes still require a restart to load exporter settings; collector/app restart alone cannot retrofit those processes.

## Missing usage: process startup versus history discovery (2026-09-14)

- Live diagnosis: telemetry installed Sep 12 18:24 KST; all still-running Codex processes started earlier (latest main process Sep 12 17:28). Their rollout files continued receiving token snapshots Sep 14, but the account collector had only one Codex event that day. Claude started Sep 14 12:54 and exported dozens of account-matched calls. Collector was running, configs/auth headers matched, error log empty; installed Codex 0.154.0 passed the local fake-provider parser check (70 input + 5 output + 30 cache read). Old processes omit NEW calls too until reopened, not merely historical backfill. Do not restart working Orca/CLI sessions to hide this gap.
- Separate real bug: Mac-wide roots omitted Orca managed Codex/Claude homes and Codex runtime home, so the fallback also missed available history. Add these only to Mac scope; reuse archive event IDs to deduplicate bridged copies. Never infer account ownership from these shared folders.
- UI now labels populated account figures as captured tokens and keeps process-reopen guidance next to the period selector. Empty state says no captured calls in this period, rather than implying setup is connected/complete or usage is zero.
- Regression check covers Orca root discovery and a hardlinked transcript counted once, alongside existing account isolation. FileManager enumeration resolves /var to /private/var on macOS; normalize symlinks when asserting temporary URL equality.
- Verification: 171 Swift checks, Python collector checks, real installed Codex with a loopback fake provider, and build passed. Restarted Dash Island only; native screenshot confirmed the captured-only explanation is visible directly above the 12.3K account figure. Working provider processes and account history were left intact.

## Claude telemetry identity can lag an account switch (2026-09-14)

- User observed using Dev while Developer API estimate rose. Server `/api/oauth/profile` verified Dash Dev/Developer credential identities match their labels (hashes 86dd1b8566f2 / 9b45aa6f0dfd). Orca active selection and global ~/.claude.json were Dev, yet all new telemetry was Developer. Between live reads Dev five-hour quota increased 18→19%, Developer stayed 13%; collector Developer rose to 136 calls/$19.909 while Dev still had only Sep 12 smoke calls. Do NOT claim the collector's account ID proves actual billed account.
- Request IDs in Developer-attributed records matched the active ai-core/fix-translate-api transcript and its subagent transcript. The main Claude PID 98541 started Sep 14 12:54, uses default config, installed binary 2.1.270.
- Correction to Sep 12 memory: on macOS Orca materializes selected managed Claude credentials/profile into the SHARED runtime (normally ~/.claude / ~/.claude.json); `runtime-auth-preparation.ts` returns paths.configDir/paths.envPatch for host. Dedicated auth directory launch applies to WSL; auth folders on Mac are account snapshots, not each host process's config home.
- Installed Claude code builds telemetry identity from PN() (credentialSlots.authenticatedAccount, stamped from bootstrap account_uuid) before the profile fallback. Credential store change handling vEe/jG/Pw clears credential caches but does not clear that stamped identity via AX(null). Thus an external account switch can leave reported identity stale. Receiver cannot reconstruct actual historical request bearer from these events. Preserve records; never relabel all Developer history as Dev based on current selection.
- Current mitigation: restart the affected Claude process after selecting the desired account, or use the existing account-cli launcher with a dedicated managed home to isolate it from Orca global switches. Working user sessions were not restarted. A fresh post-restart call still needs verification before claiming end-to-end correctness.

## Detail toggle and confirmed Claude session (2026-09-14)

- User confirmed the misattributed Claude activity is ai-core/fix-translate-api, session 913ee571-5b2a-4151-ab0f-242ebb9b2a40. Prepared /tmp/dash-island-resume-dev.txt using the existing account-cli with Dev ID 90A3EF8C… and `--resume` pointing at the original JSONL. Installed Claude supports JSONL resume; isolated `auth status` reports logged in and email matches the managed Dev profile. No model request or user-session restart was performed. Restart approval was requested separately because it can interrupt active work; session identification alone is not restart approval.
- Same-widget click should close details; another widget should switch content. Track the displayed account ID and use toggle for pointer/accessibility activation, keeping explicit context-menu Open idempotent. Crucial: skip the detail outside-click dismissal for island left mouse-down; otherwise it closes before the widget mouse-up and the toggle reopens it. Outside-app clicks and other window clicks still dismiss.
- `bash scripts/check-detail-toggle.sh` compiles the real native panel against fake accounts and checks open/close, account switch, explicit Open, close/reopen without provider requests. Passed.
- Build passed and Dash Island restarted. Real mouse checks verified: first widget opens Developer, same widget closes (detail window absent), reopen then second widget changes the same panel to Dev, second click closes. No Claude/Orca session was interrupted.

## Claude restart deferred by user (2026-09-15)

- User explicitly chose “작업을 마친 뒤 진행” for restarting ai-core/fix-translate-api under the Dev account. Leave the current Claude process untouched until task completion is confirmed; TUI idleness alone is not completion. After confirmation, refresh the live terminal/process identity and prepared resume command before acting, preserve the conversation, then verify fresh call attribution. No immediate restart authorization.

## First click was consumed by focus (2026-09-15)

- User correction: details still needed two clicks to close. Direct CGEvent clicks without restoring/activating the target reproduced first-click activation only (click1 no details, click2 opens, click3 stays open). Earlier Orca click checks concealed this because the tool can restore window focus first. Native panel.toggle() checks alone do not test AppKit event delivery.
- Root cause: default NSHostingView consumes first mouse when the island is inactive. Use an IslandHostingView subclass with acceptsFirstMouse=true. Keep the prior outside-monitor fix too; these are separate causes. Extend native smoke check to assert the actual island hosting view accepts first mouse, then verify live raw clicks with no preactivation.
- The original fix-translate-api process and Orca terminal are gone; the worktree directory was removed, while the transcript remains. No existing session remains to restart. Marked the previously prepared /tmp resume command stale. Latest collector inspection has new Dev-ID Claude records on Sep 15 14:22; Developer-ID records last arrived Sep 14 16:59. This is observed reported-identity collection, not retrospective proof of billed identity.
- Validation: native first-mouse/panel smoke and build passed; running app replaced. First raw post-fix open→close pair passed with Orca initially focused. Longer physical-pointer repetitions were inconclusive: recorded mouse positions moved away from injected coordinates between clicks (including fractional trackpad-like positions); stop fighting concurrent pointer input. Do not report repeated physical-click QA as fully passed. No additional speculative event-routing changes were made.

## SwiftUI activation clicks need their own opt-in (2026-09-15)

- Correction to the preceding first-mouse entry: `NSHostingView.acceptsFirstMouse=true` alone was insufficient. SwiftUI tap gestures filter the click activating their window separately. Set native `.allowsWindowActivationEvents()` at the IslandRootView hierarchy (macOS 15+ availability guard; retain existing AppKit first-mouse fallback). User was right that the rebuilt app still only changed focus on the close click.
- Added `swift scripts/check-detail-clicks.swift 300 85`: real CGEvent mouse clicks on the running app, with window-local widget coordinates, no target preactivation per click, visible detail-window assertions, and pointer-interference detection. Method-only panel checks do not prove gesture delivery. Hover itself may activate the app; the crucial case is switching key window from details back to the island.
- Observed regression before replacement: PID 39063 opened on click 1 and stayed open on click 2, check failed. With the SwiftUI modifier, build succeeded, old process exited, replacement PID 62665 started at 14:32:18 from this repo's build/DashIsland.app. Identical real-click check passed open→close→open→close; native panel smoke also passed. macOS 13/14 fallback compiles but was not runtime-tested on those OS versions.

## Account larger than “All on this Mac” (2026-09-15)

- User caught Dev 93.3M/$83.16 exceeding All Claude 88.7M/$75.99. Root cause was incomparable sources: account scope read completed-call telemetry, while “All” read the transcript archive with a slower 120s refresh. Live comparison found 565 shared request IDs, 72 captured-only IDs, 7 transcript-only IDs, and differing token totals for 2 shared IDs. Neither source is a superset; blindly adding them would double-count shared calls.
- Claude/Codex account and All scopes now use one SQLite read grouped by provider identity. LocalUsageStore publishes every registered account and the full provider total together at the same cadence; the total includes identities no longer in AccountStore. No attribution is guessed and no logs/database records are rewritten. Retain the original transcript archive under the separate “Local transcript history” picker item, explicitly labeled as a different source. Grok/Agy retain their existing folder scopes.
- Extended the native Swift reader check to verify account isolation, cross-provider exclusion, distinct transcript cache keys, and whole-total >= account tokens/cost across Today/7d/30d. All 171 checks passed; build passed. Running app replaced at 16:43 (PID 46257). Live UI showed Dev captured 100.5M/$86.27 and later All captured 101.2M/$86.66 as new calls arrived; both displayed captured-source guidance. A same-read SQLite query showed one contributing Claude identity today, so current account and All are equal for that snapshot. Do not claim the sequential UI readings were simultaneous.
- Computer-use bundle lookup omits this accessory app; PID selection works. Prefer AX widget actions when the user is moving the cursor. Raw mouse checks during concurrent user input are inconclusive; stop repeating pointer manipulation. Source-picker semantic action alone did not prove selection; the subsequent fresh UI state did.

## Keep usage details scoped to the clicked account (2026-09-15)

- User chose to remove the source selector entirely: selecting a widget already selects the account. Details now always load initial.id and show a small static “This account” caption with the period control. Removed All/transcript navigation, source state, and empty-state links to those views; keep the Grok/Agy account-launch command when needed.
- Historical archive files and collection stay intact. Updated README to describe the account-only UI. This supersedes the prior decision to expose three source choices; do not reintroduce them without a new user request.
- UI-only simplification: build and diff whitespace check passed, rebuilt app restarted from build/DashIsland.app at 23:27. No usage parser or attribution logic changed; no new tests added.

## Commit and PR review (2026-09-16)

- Created feat/account-usage-details from origin/main and committed the account-only detail UI, collection/readers, reset-credit and quota fixes, and hover/click fixes. Left the pre-existing unrelated notes/dash-island-burn-ui-motion-brief.md untracked; ignored Python bytecode.
- Local review found a real collector stall: HTTPServer accepted a connection without a request/header timeout, so an idle socket blocked all subsequent exports. Moved the 5s timeout to accepted sockets via get_request. A loopback subprocess regression timed out before the fix and then stored the next export after the fix. Documented the already-known Claude external-login/stale-identity limitation in README.
- Final checks passed: 171 Swift checks, Python collection/configuration/launcher checks plus real HTTP regression, native panel first-mouse/toggle smoke, build, diff whitespace, and credential-pattern scan (no matches). No remaining blocking findings in this local review. Runtime behavior on macOS 13/14 remains unverified.
- PR targets main. Existing open PR #10 overlaps tooltip files and should be considered during merge ordering; it was not modified or closed. No user CLI sessions or installed collector configuration were changed during review.
