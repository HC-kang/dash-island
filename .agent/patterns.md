# Patterns

Architecture reference and reusable implementation and testing patterns. Sections run from the v1 build to the latest phase. Later sections may supersede earlier ones where marked.

## v1 build (2026-07-19)

Branch `feat/v1-implementation` — plan tasks 1–10 landed via subagent-driven development.

- Scaffold + domain + accounts + gauges + orchestrator + add chrome
- Adapters: Fake, Claude (read-only OAuth usage), Codex (wham/usage), Grok (cli-chat-proxy billing; no live verify)
- Prefs sheet: used/remaining + 5/15/30 poll
- Demo: `DASHISLAND_DEMO=1` only (empty → centered +)
- Grok concern: contract from Orca; no live HTTP probe this session

### Scaffold (Task 1)

- arm64-only `build.sh` → `build/DashIsland.app`, bundle id `dev.dashisland.DashIsland`, LSUIElement, ad-hoc codesign.
- Window: borderless clear floating at top-center of notched screen (`safeAreaInsets.top > 0`); level `.popUpMenu`; activation `.accessory`.
- Sources: `App/App.swift`, `Island/{BorderlessFloatingWindow,IslandWindowController,IslandRootView}.swift`.

### Domain (Task 2)

- `Sources/Domain/`: Types, Account, UsageSnapshot (+UsageError), BurnRate, WidgetViewModel, VendorAdapter (+AddAccountResult).
- Burn math locked: `ratio = v/v_cruise`; first sample ratio 0; negative Δ → 0.
- Needle: `needleUnit = min(1, ratio/2)` → 0 rest, 1 cruise (0.5), ≥2 redline cap.
- Tests: `scripts/run-tests.sh` compiles Domain + Tests only (no XCTest).
- `.gitignore`: `build/`, `.DS_Store`, `.superpowers/`.

### Accounts / credentials (Task 3)

- Layout: `~/Library/Application Support/DashIsland/{accounts.json,accounts/<uuid>/}`.
- `CredentialRef` = folder name under `accounts/` (usually account UUID string).
- `Account` is `Codable` (ISO8601 dates). Cap **5** accounts (`AccountStoreError.maxAccountsReached`). (Cap now 20; see decisions.md.)
- `FakeAdapter` id `"fake"`, `minPollSeconds` 300; `fetchUsage` fraction = stable FNV-1a of ref.
- `AccountStore` `@MainActor ObservableObject`; `shared.load()` on launch.
- Tests: `run-tests.sh` compiles Domain+Infra+AppCore+Adapters+Tests; single `@main` in `TestMain.swift`.

### Gauge widgets (Task 4)

- Views: `GaugeRingView`, `AccountWidget`, `GaugeClusterView`; `IslandRootView` hosts cluster.
- v5 balance: flush dual rings (outer brand, inner steel #3a6580), ticks ~0.34α, needle #ef4444 1.35pt.
- Needle piecewise angles (screen deg, 0=east): unit0→135° (7:30), 0.5→300° (1:00), 1→45° (4:30).
- Demo: `DASHISLAND_DEMO=1` only → fake VMs (`DASHISLAND_DEMO_COUNT` ∈ 1|3|5); empty without env → add UI (Task 6).
- Window `600×200`, `acceptsMouseMovedEvents` for hover tooltips below widgets.

### Usage orchestrator (Task 5)

- `PreferencesStore`: `pollSeconds` ∈ {300,900,1800}, `displayMode` used|remaining; UserDefaults keys `DashIsland.*`.
- `UsageOrchestrator`: one timer; due = `now-last >= max(userInterval, adapter.minPoll)`; parallel fetch via VendorRegistry.
- Soft error: retain last-good rings + `errorCaption`; auth → "reauth required"; 429 → 15m cooldown map, skip fetch.
- Burn: prev+last good snapshots only (error-free); first poll ratio 0.
- Pure helpers for tests: `isDue`, `displayFraction`, `formatTokens` (k/m hover).
- App: `startAutoRefresh` after `AccountStore.load`; IslandRootView shows orchestrator widgets when accounts non-empty.
- `refresh(accountID:)` clears due timers and polls (used after reauth).
- Stale (noted 2026-09-19): background poll is fixed 15m (`backgroundPollSeconds`); the "5/15/30 user interval" above no longer applies.

### Edge add chrome + context menu (Task 6)

- `EdgeAddChrome`: right-edge chevron, dwell ≥500ms → glass `+` menu (VendorRegistry); no width-stealing empty slot.
- Empty (0 accounts, not demo): `CenteredAddButton` only.
- At 5 accounts: hide add chrome. Demo forced (`DASHISLAND_DEMO=1`): hide add chrome.
- Widget context menu (real accounts only): Rename (NSAlert), Reauth, Remove (confirm).
- `AccountStore.markAuthenticated`; add via `beginAdd` → `add(from:)` → accounts sink refreshes orchestrator.

### Claude adapter (Task 7)

- `ClaudeAdapter` id `"claude"`, `minPollSeconds` 300; registered after Fake in `VendorRegistry`.
- Managed auth: `accounts/<uuid>/` as `CLAUDE_CONFIG_DIR`; credentials in `.credentials.json`.
- `beginAdd` / `reauthenticate`: spawn `claude auth login --claudeai` with managed dir; poll ≤180s for creds (file or CLAUDE_CONFIG_DIR-scoped keychain `Claude Code-credentials-<sha256[0:8]>`); copy into managed file. Never write default keychain. Never OAuth refresh.
- Fallback error text includes manual `CLAUDE_CONFIG_DIR=… claude auth login --claudeai`.
- Usage: `GET https://api.anthropic.com/api/oauth/usage` with Bearer + `anthropic-beta: oauth-2025-04-20` + UA `claude-code/2.1.121`.
- Map: 401/403 → `.authRequired`, 429 → `.rateLimited`, utilization always ÷100.
- Parse unit tests in `Tests/ClaudeAdapterTests.swift`; build needs `-framework Security`.

### Codex adapter (Task 8)

- `CodexAdapter` id `"codex"`, `minPollSeconds` 120; registered after Claude in `VendorRegistry`.
- Managed auth: `accounts/<uuid>/` as `CODEX_HOME`; credentials in `auth.json` (`tokens.access_token`, optional `tokens.account_id`). Fallback path: `managed/.codex/auth.json` if HOME-isolated login.
- `beginAdd` / `reauthenticate`: spawn `codex login` with `CODEX_HOME` + strip `OPENAI_API_KEY`/`CODEX_API_KEY`/`CODEX_ACCESS_TOKEN`; poll ≤180s for auth.json; terminate CLI after creds appear.
- Fallback error text: `CODEX_HOME='…' codex login`.
- Usage: `GET https://chatgpt.com/backend-api/wham/usage` Bearer (+ optional `ChatGPT-Account-Id`). 401/403 → `.authRequired`, 429 → `.rateLimited`.
- Parse: `rate_limit.primary_window` / `secondary_window`; `used_percent` always ÷100; `reset_at` unix; `plan_type` → plan. No OAuth refresh from app.
- Parse unit tests in `Tests/CodexAdapterTests.swift`.

### Grok adapter (Task 9)

- Spike: `docs/notes/grok-usage-spike.md` (Orca grok-auth/fetcher + `~/.grok/auth.json`).
- `GrokAdapter` id `"grok"`, `minPollSeconds` **300**; registered after Codex in `VendorRegistry`.
- Managed auth: `accounts/<uuid>/` as `GROK_HOME`; credentials in `auth.json` (issuer map; prefer `https://auth.x.ai…`; field `key` = access token). Fallback path: `managed/.grok/auth.json`.
- `beginAdd` / `reauthenticate`: spawn `grok login --oauth` with `GROK_HOME`; poll ≤180s. If binary missing on add, copy usable `~/.grok/auth.json` into managed folder; else instruct `GROK_HOME=… grok login --oauth`. (Copy removed 2026-09-23; see decisions.md.)
- No OIDC refresh in app; expired access → `.authRequired` (5m skew).
- Usage: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` then monthly fallback `/v1/billing`. Headers: Bearer + `X-XAI-Token-Auth: xai-grok-cli` + optional `x-userid`.
- Map: `creditUsagePercent` ÷100 → primary; confirmed weekly with omitted % → 0; monthly `used.val/monthlyLimit.val` when weekly absent; `subscriptionTier` → plan.
- 401/403 → `.authRequired`, 429 → `.rateLimited`. Parse tests in `Tests/GrokAdapterTests.swift`.

### Prefs + polish (Task 10)

- `PrefsSheet`: display mode (used|remaining) + poll interval segmented 5/15/30 min; binds `PreferencesStore.shared`.
- Quiet gear bottom-leading of island chrome → sheet; activates app so sheet can key.
- Gauge rings/needle spring settle (`response: 0.55`, `dampingFraction: 0.88`) via drawn state; first paint snaps. (These springs never animated; see "Island UI pass" below.)
- Demo env unchanged: `DASHISLAND_DEMO=1`, optional `DASHISLAND_DEMO_COUNT` ∈ {1,3,5}.
- README: build/run/demo/tests.

## Drag reorder

### Drag reorder UX (2026-07-19)

- **Downward push bug**: was `minHeight` growing when drag started (trash zone). Fix: fixed cluster height = `cellH`; trash/float paint into window `dragBleed` only.
- **Drop preview + push**: freeze `baseOrder` mid-drag; `gapSlot` under finger; non-dragged widgets keep stable identity and animate `.position` to packed seats around the gap; gap skeleton highlighted with ring.
- **Gesture continuity**: dragged id stays mounted at home slot at opacity ~0 (same ForEach identity) so DragGesture does not die when neighbors pack.
- Commit only on drop via `AccountStore.applyOrder`; no mid-drag store mutation. Demo order local-only.

### Drag auto-scroll at viewport edges (2026-09-16)

- User: dragging to the edge should scroll the row; previously required drop + re-drag. Implemented with `ScrollViewReader` (macOS 13 target, no `scrollPosition`): hold within 30pt of either band edge steps one cell every 300ms via `scrollTo(id, anchor:)`; after each step the drop preview is recomputed from the still pointer. Gate is real overflow (`IslandClusterLayout.needsScroll` against `viewportWidth`), not `slotCount > maxVisible`, because the test band is narrower than five cells.
- `rowOriginX` is now live during a drag (old freeze comment predates the current gesture; only changes on real row movement). Native check with 7 fake widgets in a 324pt band did not hang.
- `onOrderCommitted` callback on GaugeClusterView exists so the native script can observe a demo/local-only reorder; it also fires after a persisted reorder.
- Verified: native render/drag check (right-edge hold lands at last slot, left-edge hold returns to first), 172 Swift checks, build. App restarted.

## Claude auth flow

### Claude adopt-before-refresh (2026-07-31)

- Hermes pattern ported to `ClaudeAdapter`: re-read scoped keychain+file before any `oauth/token` POST; if live access/refresh is fresher & usable (60s buffer), adopt+persist and skip refresh.
- `RefreshOutcome.adopted`; reactive path adopts first then refreshes.
- Hard-expired quiet still avoids POST unless adopt heals.
- Web landscape: usage monitors (ccusage local JSONL; VS Code tracker / Claude-Code-Usage-Monitor / claude-usage crate hit `/api/oauth/usage`); 3rd-party inference OAuth increasingly ToS-restricted; subprocess/CLI ownership is the compliant alternative for agents.

### Claude session-expiry port (2026-08-13)

- Codex worktree implemented probe-always + file-only adopt + persist last-good + UserDefaults refresh gate.
- Ported Swift core onto `feat/v1-implementation` (uncommitted). Tests/docs still only in worker worktree.
- Rebuilt `build/DashIsland.app` 0.0.1 and relaunched (pid after 10:46).
- Review notes: adopt only helps if *this* managed file rotates; `canAttemptRefresh` still cuts after 7d stale; vendor Retry-After now uncapped (can quiet >6h).

### CLI ping recovery when oauth/token 429s for days (2026-09-02)

- Live: both token hosts 429 (no Retry-After) for ~3 days. Access 401 “expired”. Refresh_token still valid (~24d).
- The CLI can still rotate tokens (fact in constraints.md "Keychain and Claude CLI facts").
- Harvest with `/usr/bin/security find-generic-password -w` (no Dash password sheet), persist file, delete hashed KC. Usage then 200 (max 32%/17%, pro 0%/2%).
- Adapter: on HTTP 429/fail, `pingCLIThenAdopt` then security harvest. Never poll-path `SecItem` Allow.

## Usage details and collection

### Usage details implementation (2026-09-12)

- Click opens a separate persistent panel; Today/7d/30d, model/token/cache rows, metadata-only history and API values. All four providers supported. Codex/Claude parsers deduplicate cumulative/streaming rows, preserve cache buckets, and leave unknown prices unpriced. Grok real logs use `params.update` → `turn_completed` and `cachedReadTokens`; `costUsdTicks / 1e10` supplies recorded API value. Agy SQLite reads require WAL stamp tracking and one read transaction; one generation is one call.
- Drawing padding (200pt) is separate from hover retention (20pt). Window-level pointer boundary notification handles exits lost when `ignoresMouseEvents` flips; collapse waits for no pointer/drag/detail/other overlay. Never enlarge mouse retention to fix drawing.
- Codex reset count: GET `/backend-api/wham/rate-limit-reset-credits` with selected account bearer and `ChatGPT-Account-Id`; actual accounts returned 1 and 3. Optional snapshot field, read failure is unavailable, not zero; no reset consumption action. Keep quota even if credit request fails.
- Verification: build passed; 169 checks passed, including history isolation across accounts/restart, reset count invalid/zero, all four readers, WAL refresh and saved-history failure paths. Native screenshots verified both edge tooltips unclipped, separate account/Mac scopes, reset count display and collapse after moving to y205 (body bottom168).
- User corrections from this work are in mistakes.md "Usage details — source scope user correction" and "Tooltip clipping".

### Real account collection, Orca + CLI (2026-09-12)

- Implemented native completed-call OTLP/JSON collection for Codex/Claude, shared by Orca and ordinary CLI. Python stdlib collector binds loopback only, authenticates a local token, stores only identity hashes + model/tokens/cost/event IDs in SQLite. LaunchAgent keeps it alive without the UI. Connection script validates all configs before changes, preserves unrelated config/hooks, backs up changes, refuses existing third-party exporters, and is idempotent. It configures default, custom-env, Dash managed, and Orca managed homes. (Process-reopen rule in constraints.md.)
- AccountUsageReader joins Codex user.account_id or Claude accountUuid+organizationUuid against call-time identity. It replaces old folder-derived account archives for these two vendors, preserving old files but not mixing them in. Detail refreshes every 15s. Authentication refresh ping supplies dash_island.purpose=auth_refresh and collector excludes it.
- Live proof: Codex personal events joined only personal (Developer stayed empty); Claude Dev events joined only Dev (other two empty). Claude CLI's headline token/cost total matched two captured API calls, including a subsidiary request. Native completed-call events can include actual auxiliary inference beyond the CLI's headline last-turn count.
- Grok/Antigravity account-cli launcher selects managed GROK_HOME/HOME, clears competing API-key variables, keeps cwd/arguments, and works in either kind of terminal; detail provides copy command. Ordinary launches outside that selected home stay machine-wide. No global login/account switch was performed.
- Final verification: 170 Swift checks + Python collector/config/launcher checks passed; native detail UI showed per-account Codex and Claude totals from the new SQLite source. Collector settings were installed into 12 homes with original configurations backed up. Existing Orca/CLI provider processes still require a restart to load exporter settings; collector/app restart alone cannot retrofit those processes.
- Ownership facts and the user correction are in constraints.md "Usage attribution" and mistakes.md "Real account collection".

### Detail toggle (2026-09-14)

- Same-widget click should close details; another widget should switch content. Track the displayed account ID and use toggle for pointer/accessibility activation, keeping explicit context-menu Open idempotent. Crucial: skip the detail outside-click dismissal for island left mouse-down; otherwise it closes before the widget mouse-up and the toggle reopens it. Outside-app clicks and other window clicks still dismiss.
- `bash scripts/check-detail-toggle.sh` compiles the real native panel against fake accounts and checks open/close, account switch, explicit Open, close/reopen without provider requests. Passed.
- Build passed and Dash Island restarted. Real mouse checks verified: first widget opens Developer, same widget closes (detail window absent), reopen then second widget changes the same panel to Dev, second click closes. No Claude/Orca session was interrupted.

### Between-poll projection from captured calls (2026-09-22)

- `Sources/Domain/UsageProjection.swift` — learns primary-window fraction per captured dollar from two consecutive API samples of the same window, then extends the ring by locally captured spend until the next sample. Cost, not tokens: utilization is model- and cache-weighted, and the collector already prices each call.
- Guards, all deliberate: every API sample re-anchors and drops the drawing; a projection is never persisted to last-good and never feeds burn; it only adds; `maxProjectedGain` 0.25 bounds a bad fit; `minLearnableDelta` 0.02 refuses to divide by one quantum of integer-% noise; window reset clears the rate; pairs older than 2h are not fitted.
- `AccountUsageReader.capturedDollars(provider:identity:from:to:)` — single SUM, served by the `(provider, identity, event_id)` primary-key index. 15k rows total, a few hundred per identity; no extra index needed.
- Only `claude` and `codex` project. Grok and Antigravity have folder scopes, not per-account identities — never project from those.
- Known under-counts, all in the same direction (the projection lags, it cannot overshoot): processes started before telemetry was installed, claude.ai web/mobile use, rows stored without a price. Live check found 0 null-price rows in 6h of Claude data.
- Display rule is in decisions.md "Projection display".
- Pre-existing flake fixed on the way: `ClaudeRefreshGate` dates round-trip through UserDefaults as doubles, so exact `Date` equality in `runGate` failed about one run in three. Compare with tolerance.

## Logging

### Internal logging overhaul — designed (2026-09-23)

- Baseline: 53 `NSLog("DashIsland: …")` across 10 files, unified log only, no file/level/category. Poll due/skip, per-fetch http/ms, mode transitions, sleep/wake, add/reauth stages are not logged at all — the reason past incidents (overnight 429, 4h lock, stale needle) were hard to trace.
- Approved design: `docs/superpowers/specs/2026-09-23-internal-logging-design.md`. One `Sources/Infra/Log.swift`, file sink `Application Support/DashIsland/logs/dashisland.log` (2 MB × 3) + os_log mirror, categories `app accounts poll fetch auth burn local window`, level via `DASHISLAND_LOG` env / `DashIsland.logLevel` default. No Prefs UI. `scripts/logs.sh` for tailing.
- Handoff for the implementing session: `docs/superpowers/handoffs/2026-09-23-internal-logging-handoff.md` (call-site inventory, insertion points, TDD order, secrets rule).

### Internal logging — shipped (2026-09-23, branch feat/internal-logging)

- `Log.<category>.<level>("event key=value")` in `Sources/Infra/Log.swift`. Categories `app accounts poll fetch auth burn local window`. `NSLog` is gone from `Sources/`; do not add it back.
- File `~/Library/Application Support/DashIsland/logs/dashisland.log` (2 MB × 3), plus unified log subsystem `dev.dashisland.DashIsland`. `scripts/logs.sh [-f] [pattern]`.
- Level: `DASHISLAND_LOG` env > `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug` > `info`. Poll skip reasons (`inflight asleep cooldown interval`) and burn samples appear only at `debug`. Restart the app after changing the level.
- Rotation must fail closed: if `.log`→`.log.1` rename fails, the sink turns off. Otherwise every append rotates again and the file grows without limit. Each append seeks to end, because a dev build and the installed app can write the same file. (Seek superseded by O_APPEND + inode reopen; see "Phase 1 stream data" core-15.)
- Deferred: `local load` info lines run every ~15 s while the detail panel is open; soft cooldown line also prints when the cooldown was already set; `local load scope=` holds a full account UUID.
- Deferred items above resolved in PR #16 (2026-09-23): `local load` → debug with `account=<short>`; soft cooldown logs only when newly set. Pure log-line changes, verified by build + live launch, no unit test (no log-capture harness; not worth adding one for message text).
- Secrets rules and the opt-in file sink are in constraints.md.

## Testing and demo

- For clean demo screenshots set `CFFIXED_USER_HOME` to an empty fake home (UserDefaults are not isolated by this). `DASHISLAND_DEMO=1` alone still shows real accounts: demo turns on only when accounts are empty (2026-09-23).
- Native check scripts: `scripts/check-detail-toggle.sh`, `swift scripts/check-detail-clicks.swift 300 85`, `scripts/check-widget-render.sh`, `scripts/check-ring-zero-primary.sh`. Each is described in its dated entry (here or in mistakes.md).

## Phase 1 (2026-09-23)

### Phase 1 auth stream (branch p1/auth)

- `LoginProcess.supervise` / `waitForExit`: every CLI child (login, logout, ping, `security`) ends on return, throw and task cancel. Old loops skipped terminate when cancel hit `try await Task.sleep`, and `try?` sleep loops spun to their deadline.
- Agy add/reauth: visible `agy` in Terminal with HOME = managed folder (`.dash-island-agy-login.command` writes its PID so Cancel can kill it). No `agy --print` model ping on the login path. Reauth tries HTTP refresh first; login only if Google rejects, with old files moved aside and `isAcceptableLogin` rejecting the prior session. Unverified live: whether `agy` in a fresh HOME reads the global `gemini/antigravity` Keychain item instead of showing sign-in.
- Reauth never deletes a working session: `CredentialStore.PriorFiles` moves files to `<name>.prior`, restore on failure/cancel, discard on success (Codex, Grok, Agy). A `.prior` left by a crash is adopted by the next stash.
- `TokenHostFailure.classify` is the one token-endpoint classifier: only invalid_grant / invalid_token / refresh_token_* reject; 429/5xx/network/unknown are soft "token quiet" with retryAt (429 capped 15m). Grok 429 is no longer a usage 429; Codex busy host is no longer red "reconnect".
- Credential writes go through `CredentialStore.writeSecret` (atomic, 0600, read-back). Claude deletes its hashed Keychain item only after the file verifies. New account folders are 0700; old 0755 folders tighten only when `createDirectory` runs (reauth). `credentialRef` "", ".", ".." or with "/" is refused, so remove cannot wipe the accounts root.
- Missing windows: Claude null `seven_day` → no weekly ring; no window at all → `reported = false`. A null `five_hour` beside a live week stays 0% (idle window, unverified API shape). Agy daily/unlabeled → `.unknown`; resetTime without remainingFraction → exhausted.
- Tests: `StubHTTP` (URLProtocol) answers `URLSession.shared` in-process, so adapter refresh paths are tested with temp dirs and no vendor traffic.

### Phase 1 stream polling (branch p1/polling)

- Local burn scan runs in a detached utility task. `ClaudeActivity.LogCache` keeps an (inode, offset) cursor and parsed events (15m retention) per file, so an unchanged file costs one `stat`. The sampler no longer skips while a poll runs: both timers fire on the same second, and that guard dropped most samples of a busy account.
- Fetch uses `forEachBounded`: 2 in flight, each result applied on arrival. Usage GET `timeoutInterval = 20` (Claude/Codex/Grok; Agy already 12).
- The Claude CLI ping runs detached (`startBackgroundCLIPing`). While it runs, `CLIPingRegistry` makes polls return "refresh pending" and `discardCLIKeychainCopy` does nothing. Reason: the CLI may delete `.credentials.json` during the ping, and a poll then read "no credentials" (false red reauth + 30m auth cooldown). Keep this guard if the ping moves again.
- Cadence: `lastFetchAt` = fetch start; `isDue` tolerance = half a tick. A cadence test must walk an absolute tick grid with jitter. Walking `lastFetch + k·tick` hid the 80s aliasing.
- Network errors back off 1/2/4/8m (`networkFailureStreak`); any other answer resets the streak.
- `PollGenerations`: reauth (`refresh(accountID:)`) bumps it and in-flight results are dropped. Event polls that meet a running poll are queued (`queuedPoll`); timer ticks are not.
- Reauth clears the projection identity, projection, primary delta, and burn. Last-good (memory + file) goes only when both identities are known and differ.
- Wake: `WakeScheduling` holds polls 60s (manual refresh bypasses it). A tick >120s late counts as a wake and clears `systemAsleep`.
- `UsageProjection.applyRead` drops a SQLite read when a poll re-anchored during the await.

### Island UI pass — Phase 1 stream `ui` (branch p1/ui)

- Canvas is not Animatable. `withAnimation` on @State that only a Canvas reads never interpolates. The ring/needle "springs" (Task 10, Burn motion UI) only blanked the rings ~80 ms per expand, then snapped (pixel probe). GaugeRingView now draws its inputs directly. To animate Canvas drawing, use an Animatable wrapper or TimelineView math.
- `MotionPolicy` (Domain, tested) sets frame intervals. Compact rim: still unless a fetch is in flight. Expanded rim: 30 fps. Gauge: still at rest (energy < 0.05, jitter < 0.25pt), 15/30 fps above. Everything is still under Reduce Motion, Low Power, an occluded window, or sleeping displays. A TimelineView keeps ticking in an ordered-out window, so pause it explicitly. Scratch host: still rim 0.0% CPU, animated rim 4.1%.
- Correction to 2026-07-19 ("activate on hover") and 2026-09-15 ("Hover itself may activate the app"): on macOS 15+ hover no longer activates. SwiftUI hover tracking areas are `.activeAlways`, the add Menu's popup button accepts first mouse, and clicks reach SwiftUI via `allowsWindowActivationEvents`. macOS 13/14 keep hover activation (not runtime-tested). Hover expands after 200 ms. After a pointer collapse, the previously frontmost app gets focus back. A space change clears that app, because activating it would swipe spaces.
- A closed NSPanel keeps its SwiftUI view mounted, so `.task` loops keep running. Set `contentViewController = nil` on close. The detail panel reloaded usage every 15 s forever before this.
- Floating panels hide on deactivate, but `isOpen` stayed true and held the island open. Prefs and details now close on resign active. Dialogs release the island on resign active and hold it again on become active.
- `IslandGeometry` (Domain, tested) owns island geometry. Non-notch displays show a 64×4 top-edge handle. The handle and its hit area are hidden while a layer-0 window covers the display (CGWindowList bounds only, no window names, no permission prompt).
- Destructive confirm keys are in decisions.md; known limits and script permissions are in constraints.md.

### Phase 1 stream `data` (branch p1/data)

- core-08 status: exact component names only (`VendorStatusStore.claudeComponents`, `openAIComponents` = Codex API, Codex Web, Codex in ChatGPT Desktop, CLI, VS Code extension; names checked on the live page, CLI/VS Code share creation IDs with the Codex entries). Incidents count only when their `components` list one of ours. The page-wide indicator is used only when none of our names is on the page.
- core-12 persistence: accounts.json decodes per row; a bad row is skipped, backed up and logged at warn; an all-bad list still throws (AccountStore folder rebuild). `UsageSnapshot` and `LocalUsageArchive.Archive` decode missing defaulted keys. Rule: a persisted Codable type with a defaulted non-optional field needs a `decodeIfPresent` `init(from:)` (in an extension, to keep the memberwise init).
- core-15 log: `LogFile` opens with O_APPEND and reopens when the path inode differs from the fd inode (the other process rotated). This supersedes "each append seeks to end". Sink off is reported once to the unified log through the `report` closure, never through `Log.write` (the lock is not reentrant).
- core-11 projection: `capturedDollars` prices NULL-dollar rows by model from `AccountUsageReader.prices` (cache, else bundle; loaded once; shared with LocalUsageStore). Unknown models stay unpriced. Not done (orchestrator file): a COUNT-based active-poll signal for unpriced rows.
- core-10 errors: `UnavailableReason` is the one classifier for `.unavailable` text; a bare "rate" no longer matches ("generate"). `UsageOrchestrator.caption/detailCaption` still run their own substring checks; switch them to `error.unavailableReason` when that file is next changed. `.parse` keeps the red dot (behavior kept).
- core-06 archive: only Grok logs resume from the last complete line (`Stamp.inode` + `readThrough`). Codex lines depend on earlier session lines and Claude parse drops lines newer than `now` itself, so both keep full reads. The archive is written only on change; events older than 90 days and stamps of unseen files are pruned. An event dated after the refresh's `now` keeps the old stamp, so the next refresh reads it again.
- core-16: PreferencesStore writes to the injected defaults. `ServiceLevel`/`VendorServiceSnapshot` live in Domain. Left: `WidgetViewModel.hoverLines` still calls `UsageOrchestrator.formatResetRemaining` (move its body to Domain from the orchestrator side).

### Scripts hardening — Phase 1 stream `scripts` (branch p1/scripts)

- Collector carries `VERSION` (now 2) and writes `version`/`startedAt` to `tracking/collector-status.json` at start (`lastBatchAt` survives restarts). `connect-usage.py` replaces an installed copy with a lower version and keeps a newer one. Bump `VERSION` on every collector behavior change. The app does not read the status file yet (Phase 2 `health` can compare it with the bundled script).
- Codex rows are priced at ingest from the app's cached `usage-prices.json` (the parent of `tracking/`, reloaded on mtime change). Same rule as `UsagePriceCatalog.price(for:)`: exact model, else strip `-YYYYMMDD`. Unknown model or no catalog → NULL. Claude keeps the CLI's `cost_usd`. Rows written before this change stay NULL; read-time pricing (stream `data`) covers them.
- Connector order: validate every config → write token/script/launcher/plist → start the LaunchAgent (bootstrap retried) → back up → write configs. A failed start changes no config. Each write first re-reads the file; a concurrent edit aborts and rolls back. Writes go through symlinks.
- `--disconnect`: strips the Codex BEGIN/END block and only the Claude env values that still equal ours. A key the file had before connecting gets its value from the earliest backup manifest. A file the connector created is deleted when nothing else remains. It keeps the DB and backups, and removes the plist and token. (No wholesale restore; see decisions.md.)
- DB: index `(provider, timestamp)`; hourly prune of rows older than 400 days, counted from min(now, newest row); `collector-errors.log` copied to `.1` and truncated above 1 MB.

### Phase 1 integration (branch feat/improve-phase1)

- Merge order: auth → polling → ui → data → scripts. Conflicts only in this file, `Tests/TestMain.swift` (suite lines, keep all) and the `ClaudeAdapter` CLI ping region.
- `ClaudeAdapter` resolution: the polling background ping (`startBackgroundCLIPing` + `CLIPingRegistry`) stays; the child ends through `LoginProcess.waitForExit`; the `refreshPingSpawner` hook is gone (auth removed it as dead). The resulting test constraint is in constraints.md.
- Verified: 284 Swift tests pass (two runs), `python3 scripts/test-usage-collector.py` passes, `./build.sh` passes with only the old `kSecUseAuthenticationUI*` deprecation warnings. The app was not launched.
- Left for later: `clearCreds` logs in all four adapters still print the absolute folder path (`dir=`). `UsageOrchestrator.caption/detailCaption` still match substrings instead of `error.unavailableReason`. Not checked live: the island collapses while the Agy Terminal login has the focus (ui dialog release).

### Phase 1 review fixes (branch feat/improve-phase1)

- Reauth hold: `UsageOrchestrator.beginReauth` / `endReauth` wrap every Reauthenticate (`EdgeAddChrome`). While held (`PollGenerations.hold`, counted), the account is not polled and takes no result. Reason: the adapters move session files to `.prior`, and a poll in that gap read "no credentials" and left a red "reauth" with a 30m cooldown after Cancel. `beginReauth` also waits (≤30s) for a fetch already running, because its token refresh could write a file that the login wait takes for the new sign-in. Only a success calls `refresh(accountID:)`.
- Soft `retryAt` is a due time now (`retryDueAt`, `isDue(retryAt:)`), with `minPoll` as the floor. Before, an idle account waited the 15m interval after the cooldown ended.
- Claude: `refreshThenProbe` returns the ping's "refresh pending" when a CLI ping runs. The proactive step starts the ping, and a second refresh only met the gate that step closed (+15m). (Test rule in constraints.md.)
- Agy: `TokenRefreshResult.clientRejected` (every pair refused the client, or no client in the binary). Reauth goes on to sign-in for it; polls stay soft "retrying". A refused cached pair falls back to every embedded pair. Timeout copy is split: Add "not added", reauth "stored session was kept"; no folder path, no Terminal step.
- Follow cursor: `IslandGeometry.pointer(_:isOn:)` (`NSMouseInRect`) counts the top edge (y == maxY). A failed candidate clears `lastPointerScreenFrame`.
- Left: Codex/Grok/Claude timeout copy still names the folder, which Add deletes (older issue).

## Phase 3 adapter tests + folder lock (2026-09-24, branch p3/adapter-tests)

- adapters-12 seams (test-only reasons): `CodexAdapter.fetchUsage(codexHome:)`, `GrokAdapter.fetchUsage(grokHome:)`, swappable `ClaudeAdapter.refreshGate` / `backgroundPing`, `AgyAdapter.freshCredentials(home:refresh:)`. `StubHTTP.with(route:)` answers per request (by host or `Authorization`) and records `requestURLs`.
- adapters-02: `CredentialStore.acquireRefreshLock` (`flock` on `<folder>/.dash-refresh.lock`, non-blocking tries, 20s, nil on timeout/cancel; unwritable folder runs unlocked). Codex/Grok hold it across read → POST → write and adopt the file when its refresh token differs from `knownRefreshToken` (the caller's read). Claude holds it from its post-gate re-read; its existing re-read/adopt logic covers a rotated file, so no extra comparison was added.
- Agy has no lock (Google refresh tokens rarely rotate; not in scope). The account-cli lock rule and the Claude test sandbox rule are in constraints.md.

## Phase 2 UI + core (2026-09-24, branch feat/improve-phase2)

- E2E: a scratch driver (`drive info/hover/away/click/scroll/shot`) plus `screencapture -v` + ffmpeg frames checks transitions. (Pointer etiquette in constraints.md.)
- SwiftUI `ScrollView` on macOS is NSScrollView-backed; preference keys set inside do not reach the outside. The scroll cue uses an NSViewRepresentable probe on the clip view, and writes state on the next runloop (writes during layout are dropped).
- Island transitions: `IslandReveal` masks chrome and content only while progress < 0.999. A mask at rest clipped hover balloons. Wings shrink through an `IslandShape` mask so corners stay round.
- Localization without Xcode: `swiftc -emit-localized-strings` extracts keys; keys are the English copy; `Locale.ui` follows the running language.
- core-07: `UsageOrchestrator` pure helpers live in `+Schedule`, `+LastGood`, `+Format`; `PollGenerations.swift` holds the generation and status types.
- Ears, total mode, collector auto-update, and the network retry floor are in decisions.md.
