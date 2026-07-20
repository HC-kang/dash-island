# Dash Island — feature benchmark inventory

**Date:** 2026-07-20  
**Purpose:** Fill a living inventory of what to learn / copy / deliberately skip from reference products, before more feature work.  
**References (read-only DNA, not forks):**

| Product | Path | Role for us |
|---------|------|-------------|
| **CodexIsland** | `/Users/ford/projects/personal/codex-island` | Notch-native usage HUD, Sparkle/shipping, cost/history, alerts |
| **Orca** | `/Users/ford/projects/personal/orca` | Multi-account managed auth, multi-provider rate-limits service, status-bar usage, poll/backoff discipline |
| **CodexBar** (via Orca docs) | cited in `orca/docs/claude-usage-tracking-codexbar-parity.md` | Source planner / OAuth→CLI fallback / credential hygiene |
| **Dash Island** | this repo | Multi-account multi-vendor notch gauges + burn needle |

**How to use this doc**

- Status: `done` · `partial` · `missing` · `n/a` (out of product scope) · `skip` (explicit non-goal)
- Priority: `P0` ship-blocker / reliability · `P1` high UX leverage · `P2` polish · `P3` later / optional
- “Benchmark” means: **compare behavior + copy the lesson**, not reimplement Electron/Orca wholesale.

---

## 0. Product positioning (so we don’t over-copy)

| | CodexIsland | Orca | Dash Island (target) |
|--|-------------|------|----------------------|
| Job | Claude+Codex limits in the **notch** | Full IDE + **status-bar** usage for many providers | **Multi-account** limits as **instrument gauges** in the notch |
| Unit | Provider (claude / codex) | Active runtime + managed accounts | **Account** (up to 5 widgets) |
| Depth | Usage + cost logs + year overview | Usage among hundreds of product surfaces | Usage first; cost/alerts deferred by design |
| Auth | Read default CLI/keychain | Managed homes + account switcher | Managed Application Support folders + reauth |
| Unique bet | Charts, cost, Sparkle ship loop | Source fallbacks, multi-provider service | Dual rings + **burn needle** + account cluster |

Design non-goals (from `docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`): not Electron; not session/worktree binding; not plugin marketplace; not cost/alerts in v1 unless promoted.

---

## 1. Master inventory

### 1.1 Shell / window / presence

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes / benchmark action |
|----|------------|-------------|------|------|-----|--------------------------|
| S01 | Notch-aligned borderless island | done | n/a (windowed app) | done | — | Keep; re-check multi-display when shipping |
| S02 | Compact rest → expand on interaction | done (hover peek + click expand) | n/a | partial | P1 | We have compact strip + hover expand; compare peek headline quality vs codex-island |
| S03 | Hover peek with 5h % + reset headline | done | n/a | partial | P1 | Our hover is per-widget tooltip; optional compact peek bar like codex-island |
| S04 | Always-show-usage at rest | done | n/a | missing | P2 | Optional pref |
| S05 | Click-through outside silhouette | done | n/a | done | — | Must never regress |
| S06 | Non-notched / menu-bar fallback layout | done | n/a | missing | P2 | External displays, Studio Display |
| S07 | Target display picker | done | n/a | missing | P2 | Multi-monitor pin |
| S08 | Island spacing modes (compact / notch-style width) | done | n/a | missing | P3 | |
| S09 | Occlusion / hide when covered | done (`WindowOcclusionStore`) | partial (window focus gates poll) | missing | P2 | |
| S10 | Launch at Login | done | done (app-level) | done | P1 | SMAppService toggle in prefs |
| S11 | LSUIElement / no Dock icon | done | n/a | done | — | |
| S12 | Glow / live activity during refresh | done | status bar spinners | partial (`LiveDot`/loading) | P2 | Soft “in flight” without burn glow spam |
| S13 | Low Power Mode (dim chrome) | done | n/a | missing | P2 | Hide steady glow; still show errors |

### 1.2 Usage data model & display

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| U01 | Dual windows (session/5h + week) | done | done (session/weekly + more) | done | — | |
| U02 | Window kind from API (not hardcoded 5h) | partial | done | done | — | Codex `limit_window_seconds` → kind |
| U03 | Used vs remaining display mode | done | done (display prefs) | done | — | |
| U04 | Plan badge / plan string | done | done | partial | P2 | We parse plan; surface on widget/hover |
| U05 | Absolute token counters in hover | partial | varies | partial | P2 | Grok monthly has; Claude % only |
| U06 | Live reset countdown formatting | done | done | done | — | `1d 5h` style |
| U07 | Soft-retain last good on error | done | done | done | — | |
| U08 | Per-provider visibility toggles | done | provider presence | n/a | skip | We use accounts, not global hide |
| U09 | Multi-account same vendor | missing (single creds) | done | done | — | Core differentiator |
| U10 | Inactive / non-selected accounts still queryable | n/a | done (managed) | done (all accounts polled) | P1 | Confirm we never poll removed dirs |
| U11 | Model-scoped windows (e.g. Claude Fable weekly) | missing | done (`limits[]` weekly_scoped) | done (hover extras) | P1 | Parsed into `extras`; rings/burn still 5h+week |
| U12 | Monthly window secondary | missing | done (several providers) | partial | P2 | Grok secondary monthly; not general |
| U13 | Usage history / sparkline from polls | done | missing (for bar) | missing | P3 | Design deferred cost/history |
| U14 | Year contribution calendar | done | n/a | skip | P3 | Out of v1 |
| U15 | Chart style switcher (ring/bar/spark…) | done | n/a | skip | P3 | Our metaphor is fixed gauges |

### 1.3 Burn / needle / rate math

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| B01 | Burn-rate needle (v / v_cruise) | n/a | n/a | done | — | Unique product bet |
| B02 | Kind priority 5h → wk → mo for burn | n/a | n/a | done | — | User rule; Grok = weekly |
| B03 | Window-correct cruise (W per kind) | n/a | n/a | done | — | Tests: weekly ≠ 5h constants |
| B04 | Integer-% APIs (Claude/Codex/Grok wk) | n/a | n/a | partial | P0 | Local Claude activity boost; still weak for Grok/Codex |
| B05 | Local log activity for needle | cost path only | n/a | partial (host-wide) | P1 | Still host-wide; labeled via B08 |
| B06 | Absolute-counter burn (Grok monthly) | n/a | n/a | skip for burn | — | User: weekly for Grok; monthly ring-only |
| B07 | Needle reveal / jitter UX | n/a | n/a | done | P2 | Polish OK |
| B08 | Document needle source (API Δ vs local) | n/a | n/a | done | P1 | Hover `needle: api|local|both` |

### 1.4 Polling, backoff, rate-limit hygiene

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| P01 | User poll presets ≥5m (Claude budget) | done 5/15/30 | default **15m**, clamp | done **fixed 15m bg** (no picker) | P0 | Expand lazy + 120s floor; no sub-5m |
| P02 | Per-adapter minPoll floor | implicit | strong | done | — | Claude/Grok 300s, Codex 120s |
| P03 | 429 cooldown + soft retry | done (~Claude) | done + exponential backoff | done 30m | P0 | Fixed overnight hammer |
| P04 | Auth-failure cooldown | partial | classify + backoff | done 30m | P0 | |
| P05 | Failure does not clear last-good | done | done | done | — | |
| P06 | Pause / slow poll when UI not useful | low-power only | **pause when window inactive** | done | P1 | Sleep skip; lock floors 30m |
| P07 | Debounce manual refresh bursts | click re-arm | MIN_REFETCH 5m | partial | P2 | Refresh button / reauth kick |
| P08 | Per-provider refresh (not always full fanout) | dual fetch | done (provider-targeted) | partial (due accounts only) | P2 | Good enough at ≤5 accounts |
| P09 | Dual HTTP for one vendor (Grok) | n/a | single-ish path | done (monthly ≤15m) | P1 | Throttled monthly cache |
| P10 | Request budget visibility | missing | missing | done | P1 | Status popover budget + per-row next/cooldown |
| P11 | No network micro-poll for needle | n/a | n/a | done | P0 | Local logs only after 2026-07-20 fix |

### 1.5 Credentials & auth lifecycle

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| A01 | Read-only Claude OAuth (no dual refresh) | done (hard rule) | done (managed care) | done | P0 | Never reintroduce refresh race |
| A02 | Managed isolated config dirs | n/a | done | done | — | |
| A03 | Add via CLI `auth login` | in-app reauth spawn | done | done | — | |
| A04 | Reauth wipes stale session first | partial | done | done | — | |
| A05 | Steady-state: file token only (no keychain poll) | keychain-centric | mixed | done | P0 | User preference; login capture only |
| A06 | Token expiry proactive warning | missing | partial | done (notice <2h) | P1 | Soft yellow caption |
| A07 | Vendor-correct reauth copy | Claude-centric | multi | done | P1 | claude / codex / grok specific |
| A08 | Multi-source Claude plan (OAuth→CLI/PTY) | keychain+file | planner + PTY | missing | P2 | CodexBar/Orca; only if OAuth alone insufficient |
| A09 | Codex managed CODEX_HOME | single default | done | done | — | |
| A10 | Grok managed GROK_HOME / auth.json | n/a | done | done | — | |
| A11 | Seed from default CLI home on first add | Claude/Codex default read | done | partial (Grok copy fallback) | P2 | |
| A12 | Credential dir cleanup on cancel/fail | n/a | careful | done | — | |

### 1.6 Vendors / adapters

| ID | Vendor | CodexIsland | Orca | Dash | Pri | Notes |
|----|--------|-------------|------|------|-----|-------|
| V01 | Claude `/api/oauth/usage` | done | done | done | — | |
| V02 | Claude `limits[]` / Fable / scoped weekly | missing | done | missing | P1 | Inventory gap vs live API we already saw |
| V03 | Claude PTY `/usage` supplement | missing | done | skip | P3 | Avoid unless OAuth broken |
| V04 | Codex `/wham/usage` | done | done | done | — | |
| V05 | Codex reset credits | done | done | missing | P2 | Footer/hover nicety |
| V06 | Grok billing credits + monthly | n/a | done | done | — | Burn = weekly |
| V07 | Gemini CLI OAuth usage | n/a | done | missing | P3 | Registry later |
| V08 | Kimi / MiniMax / OpenCode Go | n/a | done | skip | P3 | Not island v1 |
| V09 | Fake/demo adapter | n/a | n/a | done (dev) | — | Hidden from Add menu |
| V10 | Adapter registry + minPoll | n/a | service table | done | — | |

### 1.7 Cost / local logs (adjacent data path)

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| C01 | Claude JSONL cost scan | done | usage separate | partial (needle only) | P2 | Reuse patterns from `ClaudeLogReader` if we add cost |
| C02 | Codex session log cost | done | codex-usage scanner | missing | P3 | Design deferred |
| C03 | OpenCode logs | done | n/a | missing | P3 | |
| C04 | Pricing table / unpriced warning | done | n/a | skip | P3 | |
| C05 | Token count mode (cache in/out) | done | n/a | skip | P3 | |
| C06 | Account-scoped logs for managed dirs | n/a | runtime homes | missing | P1 | Needed if needle/cost must match widget account |

### 1.8 Alerts & attention

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| L01 | Threshold warning/critical on 5h | done | n/a | missing | P2 | Design deferred; easy port |
| L02 | Peek pulse on threshold cross | done | n/a | missing | P2 | |
| L03 | Hot chrome from used fraction / burn | partial | n/a | done | — | `isHot` |
| L04 | Notification center alerts | missing | app notifs elsewhere | skip | P3 | Island is the alert surface |

### 1.9 Manage / UX chrome

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| M01 | Add account (vendor menu) | n/a (auto detect) | account switcher | done | — | |
| M02 | Dwell → + add rail | n/a | n/a | done | — | |
| M03 | Rename / reauth / remove | reauth Claude | full | done | — | |
| M04 | Drag reorder accounts | n/a | project order | done | — | |
| M05 | Delete confirm | n/a | careful | done | — | |
| M06 | Prefs: mode + poll + quit | full settings | many | done (+launch, refresh) | P1 | Still no Sparkle toggle |
| M07 | Status: per-account last fetch | header “synced” | tooltip | done | P2 | Enrich with cooldown/next due |
| M08 | Manual refresh | done | done | done | P1 | Prefs + status popover |
| M09 | i18n en + zh | done | many langs | missing | P3 | |
| M10 | Accessibility labels | partial | partial | partial | P2 | |

### 1.10 Shipping / ops

| ID | Capability | CodexIsland | Orca | Dash | Pri | Notes |
|----|------------|-------------|------|------|-----|-------|
| R01 | Sparkle auto-update | done | electron-builder / own | missing (plan only) | P1 | `docs/notes/SPARKLE-HOMEBREW-PLAN.md` |
| R02 | Homebrew cask + quarantine strip | done | done | missing (plan only) | P1 | Same plan doc |
| R03 | Universal / arm64 build scripts | universal | multi-platform | arm64 build.sh | P2 | Intel if needed |
| R04 | Release VERSION discipline | strict | own | missing | P1 | Don’t brick updates later |
| R05 | Privacy: no telemetry | done | has product analytics surfaces | done intent | P1 | Keep local-first claim |
| R06 | CI smoke tests | scripts | heavy gates | `run-tests.sh` | P1 | Add parse fixtures for live JSON shapes |
| R07 | Uncommitted branch hygiene | shipping main | — | dirty feat branch | P0 | Inventory before more features |

---

## 2. Orca-specific lessons (rate-limits service)

From `src/main/rate-limits/service.ts` and Claude docs:

| Lesson | Orca behavior | Dash action |
|--------|---------------|-------------|
| Claude budget is tight | Default poll **15m**; keep last snapshot over aggressive refresh | Prefer default **15m** for multi-Claude installs; keep 5m as opt-in max |
| Don’t poll uselessly | Skip background refresh when window inactive | On sleep/lock/screensaver: pause or 30m floor |
| Classify errors | auth vs rate-limit vs transient | Map `UsageError` → cooldown + caption per class |
| Source planner | OAuth then CLI/PTY (CodexBar parity plan) | Only if file-token OAuth fails often; not default complexity |
| Scoped limits | `limits[]` weekly_scoped Fable | Parse into optional third hover line or secondary ring policy |
| Multi-account refresh targets | Refresh one account after switch | We poll all due; OK at n≤5 |
| Grok auth session | Dedicated auth reader | Already similar; keep read-only |

---

## 3. CodexIsland-specific lessons (notch product)

| Lesson | CodexIsland behavior | Dash action |
|--------|----------------------|-------------|
| Sub-5m poll is toxic | Documented hard rule | Enforce in prefs + code comments; no burn network |
| Soft retention | Keep numbers + show error | Already |
| Settings depth | General / Display / Providers | Grow only when needed; avoid tab bloat |
| Cost is separate page | Local logs ≠ usage API | Don’t mix into rings; optional later tab |
| Sparkle key immutability | Public key hard rules | When adding Sparkle, copy process from codex-island `docs/SPARKLE.md` |
| Localization | en + zh-Hans | After UX freezes |
| Alerts | Threshold engine pure + pulse | Port `AlertDecision` tests if we add alerts |

---

## 4. What we should **not** benchmark-copy

| Item | Why skip |
|------|----------|
| Electron status-bar UI | Different shell; steal **logic**, not DOM |
| Full Orca provider set (Kimi, MiniMax, …) | Expands support matrix without island focus |
| CodexBar web/cookie usage scrape | Fragile; privacy + maintenance cost |
| Year calendar / five chart styles | Conflicts with gauge metaphor |
| App OAuth refresh for Claude | Dual-refresh invalidates CLI (both codebases warn) |
| Session ↔ account binding (v1) | Explicit non-goal |
| Reintroducing 60s vendor HTTP micro-poll | Caused overnight 429/reauth storm |

---

## 5. Gap heatmap (prioritized backlog from inventory)

### P0 — reliability / truth

| ID | Item | Why |
|----|------|-----|
| P11/P01 | Keep network poll ≥ minPoll; no burn HTTP | Overnight failure mode |
| R07 | Commit / branch hygiene | Inventory of code vs disk drift |
| B04 | Integer-% burn honesty | Needle must not lie; document source |

### P1 — high leverage next

| ID | Item | Source DNA |
|----|------|------------|
| A06/A07 | Expiry warning + vendor-correct reauth copy | Claude creds + Orca captions |
| U11 | Claude `limits[]` / Fable-style scoped windows | Orca scoped OAuth doc |
| P06 | Sleep / inactive poll backoff | Orca inactive window |
| P09 | Grok: avoid dual fetch when monthly unused for burn | Orca/Grok fetcher thrift |
| P10 | Status: cooldown + next due + rough QPS | Both, neither has enough |
| B05/B08 | Account-scoped or labeled local burn | CodexIsland log readers |
| S10 | Launch at Login | CodexIsland |
| R01/R02 | Sparkle + Homebrew when public | CodexIsland release loop |
| M06/M08 | Prefs completeness + manual refresh control | CodexIsland |

### P2 — polish

| ID | Item |
|----|------|
| S03/S04 | Peek / always-show |
| S06/S07 | Non-notch + display pin |
| L01/L02 | Threshold alerts + pulse |
| V05 | Codex reset credits |
| U04 | Plan on chrome |
| S12/S13 | Refresh glow + low power |
| M10 | A11y pass |

### P3 / skip for now

Cost page, year overview, chart styles, Gemini/Kimi/MiniMax, i18n, PTY usage fallback, web scrapers.

---

## 6. Suggested benchmark “workouts” (concrete checks)

Use these as acceptance scripts when implementing a gap—not abstract “be better.”

### Workout A — Poll budget (P0)

1. 5 accounts (2 Claude, 2 Codex, 1 Grok), poll=5m, leave overnight.  
2. Count HTTP by logging or proxy: expect ≤ ~12×5×2 ≈ **order 100s/night**, not 1000s.  
3. Force 429 once: that account silent ≥30m; others continue.  
4. Force 401 once: caption + 30m cooldown; no 401 storm.

### Workout B — Claude windows (P1)

1. Capture live `/api/oauth/usage` with `limits[]` weekly_scoped.  
2. Assert parser surfaces Fable (or active scoped) without dropping session/week.  
3. Hover shows correct labels; burn still prefers **5h**.

### Workout C — Needle honesty (P1)

1. Idle Claude API % flat, local JSONL active → needle moves; caption or hover says “local activity” if we add label.  
2. No Claude accounts → no filesystem scan thrash (or scan is no-op).  
3. Grok burn sample uses **weekly** kind in logs (`kind=weekly`).

### Workout D — Notch shell parity (P2)

1. Notched Mac: compact → expand, click-through outside.  
2. External non-notch: island still usable (fallback).  
3. Launch at Login survives reboot.

### Workout E — Auth lifecycle (P1)

1. Cancel mid-login → no orphan account row / empty dir.  
2. Reauth → new token only (not stale short-circuit).  
3. Expired access, valid refresh only in CLI → Dash shows reauth, does **not** refresh itself.

---

## 7. Inventory maintenance

- Update status cells when shipping; don’t leave “partial” forever without a note.  
- When promoting a design non-goal → feature, move row and set Pri.  
- Keep Orca/CodexIsland paths as **references only**—no code copies that pull Electron/TS into the Swift app.

---

## 8. Snapshot: Dash vs design doc (2026-07-20)

| Design v1 claim | Reality |
|-----------------|---------|
| Claude/Codex/Grok adapters | done |
| Account max 5, managed dirs | done |
| Used/remaining + 5/15/30 poll | done |
| Dual rings + burn needle | done |
| No cost/alerts/Sparkle in v1 | still true (good) |
| No network burn micro-poll | **fixed** after overnight incident |
| 5h→wk→mo burn priority | done (Grok weekly) |
| File-only Claude steady-state | done |
| Scoped Claude limits / Fable | **gap** |
| Launch at login / multi-display | **gap** |
| Sleep-aware poll | **gap** |

---

*Next step when ready: pick one P1 wave (recommend **U11 Claude limits + A06/A07 auth UX + P06 sleep backoff**) and turn it into a short implementation plan—not a second mega-inventory.*
