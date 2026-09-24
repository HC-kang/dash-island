# Mistakes

Bugs with root causes, user corrections, and known open holes. Each entry keeps its date. Reusable rules learned from a bug stay with the bug.

## Accounts and demo mode

### Menus + restart “missing accounts” (2026-07-19)

- Root cause of “accounts gone after restart”: process often relaunched with `DASHISLAND_DEMO=1` (inherits from agent shells). Demo replaced UI widgets; disk untouched.
- Fix: real accounts always win — `useDemoWidgets = DEMO && accounts.isEmpty`. Never mask registered accounts.
- Menus dead: full-cell `Color.clear` DragGesture overlay ate right-click / Menu hits. Removed; reorder is long-press (~180ms) then drag on the widget itself (offset push, stable cell identity).
- Accessory app menus need `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` on hover / add rail / alerts. (macOS 15+ corrected 2026-09-23; see patterns.md "Island UI pass".)

## Polling and rate limits

### Overnight rate-limit / reauth (2026-07-20)

- Root cause: burn micro-poll hit vendor APIs every 60s (Grok, dual billing) / ~3m (Claude) and on 429/401 only skipped updating lastGood — **no cooldown** → hammered all night.
- Fix: burn timer is **local Claude logs only** (no network). Usage HTTP only via user poll interval × minPoll (Claude/Grok 5m, Codex 2m). 429 default cooldown 30m; authRequired cooldown 30m (cleared on manual refresh/reauth).
- Reauth overnight also expected when access tokens expire (we never OAuth-refresh Claude). (Auto refresh added 2026-07-20; see decisions.md.)

### Usage was 30m stale, not real-time (2026-09-22)

- User report: ring read 80%, a reauth made it 100%. The value never changed — reauth calls `refresh(accountID:)`, which clears `lastFetchAt` + `cooldownUntil` and forces a poll. That was the first fresh read in half an hour.
- Measured twice on the live app: 13:40:15 → 14:17:57 (37m42s) and 14:17:57 → 14:49:45 (31m48s) between successful Claude reads. A direct `oauth/usage` GET with the same stored token returned 200 during that window, and every access token was valid until 18:16. Nothing failed; the app simply did not ask.
- Dominant cause: `ClaudeAdapter.minPollSeconds = 1_800`. `isDue` uses `max(userInterval, minPoll)`, so the 15m background setting was dead and expand refresh (`max(120, minPoll)`) was also 30m. The constant's own comment says it existed to protect `oauth/token` from 429 storms — but a poll only touches that endpoint when `shouldProactiveRefresh` fires, and the access token lives ~8h. Refresh spacing already has its own gates (`ClaudeRefreshNextAllowedAtByAccount`, `globalRefresh429Quiet`). The GET was throttled for a problem it does not cause.
- Secondary cause: the scheduler `Timer` period equalled `backgroundPollSeconds`. `lastFetchAt` is stamped *after* the HTTP round trip, so the next tick was always a few hundred ms early and skipped. Rule: a scheduler tick must be well below the interval it schedules.
- Third: expand refresh fired once per compact→expanded transition. Watching the island for twenty minutes produced one refresh.
- Fourth: a healthy widget showed no age at all. `captionSlot` renders only for error/notice, so a 1s-old ring and a 30m-old ring looked identical. That is why the number "felt" wrong long before the interval was suspected.

Fixes landed: Claude `minPollSeconds` 120 (usage GET only); `schedulerTickSeconds` 60; expand re-asks every 60s while open; `rateLimitWait` starts at 15m and doubles (was a flat 2h, so one usage 429 cost a 2h blackout) while a first 429's `Retry-After` is taken at face value; freshness line in the usage tip.

## Island layout and hit-testing

### Lateral drift fix (2026-07-20)

Root cause: expand/collapse resized `NSWindow` while SwiftUI content laid out at full target size (left-biased during intermediate frames). midX-pin on setFrame was not enough; prior binary also lagged source.

Fix (codex-island pattern):
- `IslandModel.canvasSize` = max expanded footprint (5 slots + rail + bleed).
- `IslandWindowController.pinCanvas` only on screen/notch/display changes — **never** on compact↔expanded.
- Root view: draw `model.size` top-centered inside fixed canvas (`.frame(maxWidth: .infinity, …, alignment: .top)`).
- Hover still hit-tests the visual island, not the full canvas.

### Hover hit tightened (2026-07-20)

Fixed canvas made window huge; expanded hit used `model.size` (incl. dragBleed) and root `onHover` filled the canvas → expand-on-near-miss / stole menu-bar area.

- `IslandModel.hitSize`: compact = notch pill; expanded = black body + 52pt tooltip pad (no bleed).
- AppKit passthrough uses `hitSize` only; drag still opens full window via `dragActive`.
- SwiftUI `onHover` on black-body frame only, not outer canvas.

### Island widgets pierce right edge (2026-08-09)

- **Symptom:** expanded island — gauges shift right, paint past black body.
- **Cause:** (1) hang-below tips as ZStack children with large `fixedSize` inflated cluster layout width; (2) `expandedWidth` pad (`horizontalPadding=32`) didn't match real chrome (`14` / `4+6` + AddRail).
- **Fix:** tips via `.overlay` (no layout width); GeometryReader available-width + center-or-scroll + `.clipped()`; `expandedWidth` = lead pad + slots + trail pad + chevron/rail.
- Tests: `IslandClusterLayout.needsScroll` / `centeredRowOrigin`.

### Island right-shift pierce v2 (2026-08-10)

- User: 6 accounts → needs scroll; widgets still pierced right edge.
- Root: SwiftUI `ScrollView` ideal width = full 6-cell row → HStack blew past black body.
- Fix: slot/scroll rows use `Color.clear` fixed frame + `overlay` ScrollView/HStack; `minWidth: 0` on flexible band; AddRail `fixedSize`.
- Belt: expanded content masked to `IslandShape` + full-width tip strip under body.
- Domain: `islandBodyWidth` / `slotBandWidth` / `rowWidth` pure helpers + tests (6 accts body == 5-slot viewport).

### Drag/trash coordinate fix (2026-08-11)

- Bug: layout overflow fix pinned drag canvas to `cellH` → trash `.position(y: cellH+52)` outside named space; magnet + icon misaligned; float jump.
- Fix: expand canvas by `trashZoneH` while dragging; trash centered in zone; lift from finger `startLocation` / track `drag.location`; clearer dashed drop seat.

### Tooltip clipping — user correction (2026-09-12)

- User correction: do not move tooltips inward to hide clipping. Preserve widget center. Root mask was clipping the balloon (including its upper part overlapping the body); remove duplicate root mask, retain existing slot-row clip, and render tips in the transparent fixed canvas. Anchor tip top directly instead of measuring half-height, which lagged on card changes.

## Claude auth

### Reauth false-positive + error tooltip (2026-07-20)

Live: personal Claude access expired; OAuth refresh returned **HTTP 429**, but adapter treated any failed refresh after 401 as `authRequired` → "reauth: claude auth login". Double refresh per poll (proactive+reactive) worsened 429.

Fixes:
- `ClaudeAdapter.refreshManagedCredentialsDetailed`: distinguish success / 429 rateLimited / 400–403 rejected / other unavailable.
- One refresh attempt per poll; 429 → `.rateLimited` (auto retry, not reauth).
- Widget: short `errorCaption` under gauge; full `detailCaption` in downward body hover tooltip (commands + path).

### Claude hashed Keychain pollution (2026-08-30)

- CLI 2.1+ writes `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>`. Each account UUID (and each failed Add) is a **new Keychain item** + password sheet (the suffix is the first 8 hex of sha256(config dir), not the account UUID).
- Access ~8h; **refresh ~27d** (`refreshTokenExpiresAt`). Waiting for usage 401 never rotates refresh → the reference client's 27–30d death. Token-host 429 then Reauth wiped the file and harvested Keychain again.
- Fix: file is SoT. After harvest (or any poll that already has a file) **delete the hashed item**. Wait-loop harvest is silent; one prompt only after CLI exit on first Add. Reauth tries HTTP refresh first and does **not** wipe the file on failure. Proactive refresh: Orca 5m access skew + 24h-before-refresh-expiry. `invalid_grant` is fatal; other 400s try the next token host.
- Related hard rules (unsuffixed item, ad-hoc codesign ACL) live in constraints.md.

### Reauth must not fail on token-host 429 (2026-08-30)

- Bug: HTTP-first reauth `throw reauthFailed("token host is rate-limited…")` → "Reauthenticate failed" sheet. User still has a ~27d refresh_token.
- Fix: `reauthStep` — 429/unavailable → **keep existing** (return ref, no alert). User-initiated refresh uses `force: true` (one POST, skip 20m/3h poll gate). `invalid_grant` still opens browser. Progress copy is "Extending this Claude session", not "browser required".

### Token-host 429 must not hide usage for 4h (2026-08-31)

- Symptom: tooltip “retry in 3h 59m / last ok 20h ago”. First token host 429 aborted the loop; adapter returned `.rateLimited(3h)`; orchestrator streak×2h = **4h lock**. Access already dead → no usage.
- Fix: try **console.anthropic.com then platform.claude.com**, form + JSON. 429 on one host continues. Cap quiet at **15m**. Token-host 429 → `.unavailable("token quiet")` not usage-quota 429 (no 2h/4h/6h streak). Drop persisted 3h UserDefaults gate on launch. Expand retries if last success ≥2h stale.

## Claude auth holes (H1–H10, 2026-08-16)

### Orchestration auth graph (2026-08-16)

- Run `<run>`: graph → harden → verify (3 Grok workers, ~20 min).
- Landed on feat: leftover refresh rejected (H1), usage smoke after harvest (H2), last-good wiped on clear (H6), rollback rejected harvest, scoped KC wipe on cancel/remove (H4).
- Still open: leftover that rotates *both* tokens; `runLogout` fire-and-forget (H3); global Claude Code KC clone (H7); adopt+401 skip POST (H8).

### Claude auth graph (2026-08-16)

- Audit: `docs/notes/claude-auth-state-graph.md` (states, transitions, holes, unit-test list).
- Same-access leftover after reauth is rejected (8148deb). Still open: leftover session that **rotates** access; browser add/reauth skips usage smoke test; logout/remove do not guarantee scoped-session death; last-good not cleared on identity change.
- Next tests: temp-dir file only. Never write the unsuffixed `Claude Code-credentials` item.

### Claude auth holes H1/H2/H6 (2026-08-16)

- H1: `isAcceptableLogin` now rejects same `refreshToken` even when access rotated. beginAdd (`prior == nil`) still accepts any non-empty harvest.
- H2: `beginAdd` / `reauthenticate` call `verifyUsageAccess` after harvest. Policy extracted as `usageSmokeDecision` (401 reject; 429/network soft keep).
- H6: `clearManagedCredentials` also deletes `.dash-island-usage.json` so wipe/reauth cannot keep the previous identity's rings.
- Tests: temp-dir file only. Never wrote unsuffixed `Claude Code-credentials`.
- Remaining: leftover that rotates **both** access and refresh still passes H1 (needs logout/H3); beginAdd clone of global CLI session still accepted; H8 adopted+401 still skips oauth/token; `runLogout` still best-effort.

### Claude auth graph walk (2026-08-16)

- Walked `docs/notes/claude-auth-state-graph.md` against `1d04401` + cheap fixes. Report: `docs/notes/claude-auth-graph-walk.md`.
- Graph stale vs code: H2 smoke is on browser add/reauth; H6 wipe clears last-good (tokenless no longer keeps old rings).
- Cheap fixes: smoke-reject rollback (`clearManagedCredentials` on add/reauth catch); `requireCredentials` file-only (H10); add-cancel + `AccountStore.remove` wipe scoped KC (H4 file/KC).
- Still open: H1 residual (both tokens rotate), H3 logout fire-and-forget, H7 global KC, H8 adopted+401, H9 429 soft-keep, live CLI/HTTP untested.

## Antigravity (agy)

### Agy reauth harvested a leftover session (2026-08-19)

- Reauth bug: wipe file only → `auth login` opens browser then harvests leftover scoped Keychain. Fix: snapshot access token, logout + delete scoped item, accept only a *different* access token.

### Agy client-id scan ate a leading `it` (2026-09-02)

- Tooltip: `token refresh failed — retrying`, last ok 5d 8h. Access `expiry_date` 2026-08-28. Refresh still valid.
- Scanner walked back through letters → `it1071006060591-….apps.googleusercontent.com` (invalid). Real Gemini CLI id is `1071006060591-…`. Pair **id[1] × secret[0]** HTTP 200; usage `fetchAvailableModels` 200.
- Strip leading non-digits from embedded googleusercontent IDs.

## Usage details and collection

### Usage details — source scope user correction (2026-09-12)

- User correction: provider-wide totals under each account were misleading. Default reads only selected managed folder, with separate per-account archive keys. Shared CLI logs are opt-in “All … on this Mac”; no inferred allocation to whoever is currently signed in. Missing account-linked history is not zero usage. Quotas remain per-account. (Source picker later removed 2026-09-15; see decisions.md.)

### Real account collection — correction and live-format regression (2026-09-12)

- User explicitly wants both Orca and ordinary CLI calls connected; a scope picker alone is not account support. Claude's nearly identical totals were separate authentication refresh pings (3 calls per account), not shared event IDs. Stop presenting these as the user's work.
- Critical live-format regression: Codex OTLP body is null and timeUnixNano is "0"; fields are in attributes, including ISO `event.timestamp`. Python dict.get's default expression evaluated a null body even with event.name present. Use short-circuit/default-null normalization and stable event.timestamp fallback; never receipt time (retry doubles totals). Loopback fake-provider test with the installed Codex produced expected (input70, output5, cacheRead30). Source completion emits both a timing-only and a token-bearing event; only latter counts. Reasoning remains part of output, cached input subtracted once.

### Missing usage: process startup versus history discovery (2026-09-14)

- Live diagnosis: telemetry installed Sep 12 18:24 KST; all still-running Codex processes started earlier (latest main process Sep 12 17:28). Their rollout files continued receiving token snapshots Sep 14, but the account collector had only one Codex event that day. Claude started Sep 14 12:54 and exported dozens of account-matched calls. Collector was running, configs/auth headers matched, error log empty; installed Codex 0.154.0 passed the local fake-provider parser check (70 input + 5 output + 30 cache read). Old processes omit NEW calls too until reopened, not merely historical backfill. Do not restart working Orca/CLI sessions to hide this gap.
- Separate real bug: Mac-wide roots omitted Orca managed Codex/Claude homes and Codex runtime home, so the fallback also missed available history. Add these only to Mac scope; reuse archive event IDs to deduplicate bridged copies. Never infer account ownership from these shared folders.
- UI now labels populated account figures as captured tokens and keeps process-reopen guidance next to the period selector. Empty state says no captured calls in this period, rather than implying setup is connected/complete or usage is zero.
- Regression check covers Orca root discovery and a hardlinked transcript counted once, alongside existing account isolation. (FileManager /var note moved to constraints.md.)
- Verification: 171 Swift checks, Python collector checks, real installed Codex with a loopback fake provider, and build passed. Restarted Dash Island only; native screenshot confirmed the captured-only explanation is visible directly above the account figure. Working provider processes and account history were left intact.

### Account larger than “All on this Mac” (2026-09-15)

- User caught one account's Claude total exceeding the All-Claude total. Root cause was incomparable sources: account scope read completed-call telemetry, while “All” read the transcript archive with a slower 120s refresh. Live comparison found 565 shared request IDs, 72 captured-only IDs, 7 transcript-only IDs, and differing token totals for 2 shared IDs. Neither source is a superset; blindly adding them would double-count shared calls.
- Claude/Codex account and All scopes now use one SQLite read grouped by provider identity. LocalUsageStore publishes every registered account and the full provider total together at the same cadence; the total includes identities no longer in AccountStore. No attribution is guessed and no logs/database records are rewritten. Retain the original transcript archive under the separate “Local transcript history” picker item, explicitly labeled as a different source. Grok/Agy retain their existing folder scopes.
- Extended the native Swift reader check to verify account isolation, cross-provider exclusion, distinct transcript cache keys, and whole-total >= account tokens/cost across Today/7d/30d. All 171 checks passed; build passed. Running app replaced. Live UI showed the Dev account total and later a slightly larger All total as new calls arrived; both displayed captured-source guidance. A same-read SQLite query showed one contributing Claude identity today, so current account and All are equal for that snapshot. Do not claim the sequential UI readings were simultaneous.
- (Source picker removed 2026-09-15; see decisions.md.)

## Clicks and focus

### First click was consumed by focus (2026-09-15)

- User correction: details still needed two clicks to close. Direct CGEvent clicks without restoring/activating the target reproduced first-click activation only (click1 no details, click2 opens, click3 stays open). Earlier Orca click checks concealed this because the tool can restore window focus first. Native panel.toggle() checks alone do not test AppKit event delivery.
- Root cause: default NSHostingView consumes first mouse when the island is inactive. Use an IslandHostingView subclass with acceptsFirstMouse=true. Keep the prior outside-monitor fix too; these are separate causes. Extend native smoke check to assert the actual island hosting view accepts first mouse, then verify live raw clicks with no preactivation.
- Validation: native first-mouse/panel smoke and build passed; running app replaced. First raw post-fix open→close pair passed with Orca initially focused. Longer physical-pointer repetitions were inconclusive: recorded mouse positions moved away from injected coordinates between clicks (including fractional trackpad-like positions); stop fighting concurrent pointer input. Do not report repeated physical-click QA as fully passed. No additional speculative event-routing changes were made.

### SwiftUI activation clicks need their own opt-in (2026-09-15)

- Correction to the preceding first-mouse entry: `NSHostingView.acceptsFirstMouse=true` alone was insufficient. SwiftUI tap gestures filter the click activating their window separately. Set native `.allowsWindowActivationEvents()` at the IslandRootView hierarchy (macOS 15+ availability guard; retain existing AppKit first-mouse fallback). User was right that the rebuilt app still only changed focus on the close click.
- Added `swift scripts/check-detail-clicks.swift 300 85`: real CGEvent mouse clicks on the running app, with window-local widget coordinates, no target preactivation per click, visible detail-window assertions, and pointer-interference detection. Method-only panel checks do not prove gesture delivery. Hover itself may activate the app; the crucial case is switching key window from details back to the island. (Hover activation corrected for macOS 15+ on 2026-09-23; see patterns.md.)
- Observed regression before replacement: the old process opened on click 1 and stayed open on click 2, check failed. With the SwiftUI modifier, build succeeded, old process exited, and the replacement started from this repo's build/DashIsland.app. Identical real-click check passed open→close→open→close; native panel smoke also passed. macOS 13/14 fallback compiles but was not runtime-tested on those OS versions.

## Reviews and PRs

### Commit and PR review (2026-09-16)

- Created feat/account-usage-details from origin/main and committed the account-only detail UI, collection/readers, reset-credit and quota fixes, and hover/click fixes. Left the pre-existing unrelated notes/dash-island-burn-ui-motion-brief.md untracked; ignored Python bytecode.
- Local review found a real collector stall: HTTPServer accepted a connection without a request/header timeout, so an idle socket blocked all subsequent exports. Moved the 5s timeout to accepted sockets via get_request. A loopback subprocess regression timed out before the fix and then stored the next export after the fix. Documented the already-known Claude external-login/stale-identity limitation in README.
- Final checks passed: 171 Swift checks, Python collection/configuration/launcher checks plus real HTTP regression, native panel first-mouse/toggle smoke, build, diff whitespace, and credential-pattern scan (no matches). No remaining blocking findings in this local review. Runtime behavior on macOS 13/14 remains unverified.
- PR targets main. Existing open PR #10 overlaps tooltip files and should be considered during merge ordering; it was not modified or closed. No user CLI sessions or installed collector configuration were changed during review.

### Pre-merge review of PR #11 (2026-09-17)

- Ran /code-review at high effort; it fanned out many agents and hit the session limit. User: "리뷰 적당히만 돌려". Default to inline review or low effort here.
- Salvaged one confirmed finding: `apply` success path took any error-free snapshot as last-good. A Codex response with no windows yields a placeholder primary (`reported = false`), which replaced real rings, was written to disk, and pushed 0% into burn. Now placeholders only fill an empty last-good, are never persisted (`encodeLastGood` guards `isReported`), and never feed burn. Regression in ClaudeAdapterTests.
- Not acted on: LocalUsageStore per-account loop / roots simplification (efficiency, no behavior change); context.md now well past the ~200 line soft limit and should be split per Memory Scaling Policy in a separate housekeeping change. (Split done 2026-09-24.)
- PR #10 (older tooltip mask fix on feat/v1-implementation) conflicts with this branch in GaugeClusterView/IslandRootView/context.md and is superseded by the overlay tip approach here. Left open for the user to close.

## Widgets and rendering

### Stale widgets after reorder: review and regressions (2026-09-16)

- Reproduced A=12/B=87 reordered to B=73/A=12 during the 80ms reveal: old code painted B=12/A=87. Slot-index ForEach identity transferred account state, and the delayed reveal captured old view inputs. Filled cells now use account UUID identity; percentage reads the current model directly; the delay only enables reveal, whose onChange reads current ring/needle inputs.
- Drag freezes account order AND slot count. Incoming membership changes queue until drop; losing the dragged account cancels the gesture. Without frozen slot count, adding accounts switched the centered row to ScrollView mid-gesture and mouse-up never cleared dragActive (native regression failed). Drop reconciles pending IDs before persisting; teardown explicitly releases drag capture. Disable inherited drop animations so old neighbor offsets do not linger.
- AccountStore mutations now save a normalized copy, then publish one complete state. Failed rename/move/reorder/auth/remove/add must leave memory unchanged; failed removal must retain credentials. applyOrder deduplicates IDs, ignores unknown IDs, and preserves omitted accounts. Both duplicate-order and failed-save regressions failed before the fix.
- `bash scripts/check-widget-render.sh` uses isolated fake widgets and posts NSEvents only inside its test process. It compares rendered pixels against current-value reference widgets, exercises native drag with concurrent membership/scroll-mode changes, removal of the dragged account, and unmount cleanup. It needs a GUI session; opt into SwiftUI activation events, activate its window, and send more than one drag-motion event. Never substitute panel-method checks for actual gesture delivery or move the user's pointer for this test.
- Verification: all 172 Swift checks passed; native rendering/drag check passed; build and diff checks passed. Replaced only Dash Island with the rebuilt binary. User CLI processes, account order, and credentials were untouched by tests. Multi-display/Space transitions and macOS 13/14 runtime remain outside this verification.

### Follow-up review: hover tips after drop (2026-09-16)

- Broad pass over Island views after the reorder fix found one more stale path: `elevatedChrome` was cleared at drag start and only rewritten by `onPreferenceChange`. SwiftUI `onHover` does not fire during a mouse-down drag, so the dropped widget stays "hovered" under the pointer, the preference never changes, and its usage tip never returns until leave + re-enter. Now the cluster stores the raw hover list always and derives the active chrome (`nil` while dragging). Rule: never cache a value that is only refreshed by a change callback if a gesture can suppress that callback.
- Left as-is (cosmetic, not stale-state): LiveDot bump uses `asyncAfter`, so two bumps inside 140ms cut the second short; GaugeRingView applies value changes during the 80ms pre-reveal window without the reveal sweep.
- Verified: build, 172 Swift checks, native render/drag check. Hover-after-drop itself is not covered by the native script (posted NSEvents do not generate tracking-area enter/exit), so it was fixed by reasoning and confirmed in the running app only by the user.

### Rings blank when 5h = 0% (2026-09-19)

- Symptom: Claude accounts with 5h 0% showed empty weekly/Fable rings although `lastGood` had 79% / 100%.
- Root cause 1: `GaugeRingView` read `drawn*` ring @State only inside the Canvas closure → state change did not invalidate the view. Fix: read them in `body` and pass `DrawnRings` into `drawUsageRings`.
- Root cause 2: old-style `onChange(of:) { _ in }` closures captured the previous inputs → late data applied stale values. Fix: one `onChange` over `DrawnRings`, use the delivered value.
- Why a non-zero primary masked it is not understood; do not rely on it.
- Check: `scripts/check-ring-zero-primary.sh` (fails without fix). Pattern: SwiftUI state used by Canvas must be read in `body`.

## Burn needle

### Claude needles identical across accounts (2026-09-19)

- Root cause: `ClaudeActivity.recentWeightedTokens` fell back to host `~/.claude/projects` for every account with no recent scoped logs → all Claude accounts got the same live ratio each 60s tick.
- Fix: host fallback only when the managed `.claude.json` identity (`AccountUsageReader.identity`) equals `~/.claude.json`. Others get API signal only.
- Codex/Grok/Agy needles are API-only per account (`pushBurn`); no shared source.
- Pattern: never assign a machine-wide signal to an account without an identity match.

### Quantized burst inflation (2026-09-19)

- Bug: `BurnSmoother.push` scaled the whole %-only jump by `wallDt/5m` → steady 5h cruise over 15m polls (+5%) read 3.0 redline.
- Fix: inflate only one integer tick (`quantTick` 0.01): `r * (1 + (scale-1) * min(1, tick/du))`. +1%/15m policy unchanged (~0.57); cruise reads ~1.3. Monotonic in du.
- (Needle base decision from this entry moved to decisions.md.)
