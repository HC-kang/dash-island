# Dash Island — multi-vendor usage island design

**Date:** 2026-07-19  
**Status:** Accepted · living in `dash-island`  
**Repo:** `/Users/ford/projects/personal/dash-island` (`HC-kang/dash-island`)  
**Principles:** 1) Simplicity 2) Practicality 3) Elegance  
**Stack:** Swift 6 · SwiftUI + AppKit island · in-process vendor adapters  

Reference DNA: `codex-island` (usage fetch, notch window, Sparkle lessons).  
Account model hints: Orca (`ClaudeManagedAccount` / managed auth dirs / add·reauth·remove).

---

## 1. Product

### 1.1 What it is

A **macOS notch island** that shows **rate-limit usage for multiple AI vendor accounts** at a glance. Each account is one **widget** (square instrument cluster). Feels like a first-party Apple HUD, not a settings dashboard.

### 1.2 What it is not (v1)

- Not a fork/evolution of the shipping codex-island binary (new app / new repo).
- Not multi-session / worktree binding (accounts only).
- Not Electron.
- Not cost history, alerts, token-cap correction, plugin marketplace, or Rust core.

### 1.3 Success criteria

- Add up to **5** accounts across vendors (Claude, Codex, Grok minimum target).
- Read usage without babysitting; burn-rate needle is secondary “fun” signal.
- Add/remove/reauth without a heavy accounts window.
- Extending a vendor = one adapter + registry entry.

---

## 2. UX (locked)

### 2.1 Shell

- **Notch island** (borderless floating window over the menu-bar notch), codex-island-class positioning.
- Compact / expanded details can follow later; **v1 focus = expanded cluster of widgets**.

### 2.2 Widget cluster

| Rule | Detail |
|------|--------|
| Unit | **Account** only |
| Cell | One **square widget** per account |
| Count | **1–5** live widgets |
| Layout | Always **center-aligned** |
| Rings | **Flush** dual concentric (no gap): outer = primary window (e.g. 5h), inner = secondary (e.g. week). Single window → one ring |
| Ring color | Outer = brand-warm tint + glow; inner = **cool steel** (not same-hue alpha) |
| Center | Primary **0–100%** (after display mode) |
| Speed scale | **Outside** usage rings: small ticks; rest **7–8h**, cruise mark **~1h**, redline **4–5h** |
| Needle | Always **red**, medium-noticeable (not hero, not invisible) |
| First poll | Needle at **0** (rest); rings may already show API % |
| Hover | Tooltip **below** widget: token lines in **k/m** when known |
| Display mode | Global: **used (0→100)** vs **remaining (100→0)** |

### 2.3 Burn rate (needle math)

On primary window between polls `t0→t1`:

```
v        = (u1 − u0) / (t1 − t0)          // used-fraction per second
v_cruise = (1 − u1) / (resetAt − t1)      // empties exactly at reset
ratio    = v / v_cruise                   // 0 if no previous sample
```

Map `ratio` → needle angle: `0 → rest`, `1 → cruise (~1 o’clock)`, `≳2 → soft-cap redline (4–5h)`. No wild overshoot.

### 2.4 Add account chrome (Apple-quiet)

- **No idle empty skeleton slot** (does not reserve layout width).
- Live widgets stay center-aligned.
- Right edge: low-contrast **chevron** (“something here”).
- Cursor dwell on right edge **≥ 500ms** → chevron fades, glass **`+`** appears.
- Click `+` → vendor menu (blur material) → adapter `beginAdd`.
- At **5** accounts: hide add chrome (or manage-only later).
- At **0** accounts: single centered `+` (no dwell game).

### 2.5 Manage

- **Context menu on widget:** rename, reauthenticate, remove.
- Optional tiny **gear** → prefs sheet: display mode + poll interval only.
- No full Accounts table window in v1.

---

## 3. Architecture

### 3.1 Approach

**Native Swift, thin modules, single app target.**  
No SwiftPM split until a second client exists. No Electron.

```
Presentation  →  Application  →  Domain
                      ↓              ↑
                   Infra      Vendor Adapters
```

| Layer | Owns | Does not |
|-------|------|----------|
| Presentation | Island window, cluster, widget, dwell+, menus, prefs sheet | Network, token parse |
| Application | `AccountStore`, `UsageOrchestrator`, `PreferencesStore` | Vendor HTTP details |
| Domain | `Account`, `UsageSnapshot`, `BurnRate`, `VendorAdapter` | URLSession |
| Adapters | Claude / Codex / Grok / … | UI, global schedule |
| Infra | Credential folders, `accounts.json`, networking helpers | Business policy |

### 3.2 Domain types

```swift
struct Account: Identifiable, Equatable {
  let id: AccountID                 // UUID
  var vendorID: VendorID            // "claude" | "codex" | "grok" | …
  var label: String
  var credentialRef: CredentialRef  // path under Application Support
  var sortIndex: Int
  var createdAt: Date
  var lastAuthenticatedAt: Date?
}

struct WindowUsage: Equatable {
  var usedFraction: Double          // always 0...1
  var resetAt: Date?
  var usedTokens: Int64?
  var limitTokens: Int64?
}

struct UsageSnapshot: Equatable {
  var primary: WindowUsage
  var secondary: WindowUsage?       // nil → single ring
  var plan: String?
  var fetchedAt: Date
  var error: UsageError?
}

struct BurnRate: Equatable {
  var ratio: Double                 // 0 if first sample
  var sampleCount: Int
}

struct WidgetViewModel: Identifiable, Equatable {
  var id: AccountID
  var title: String
  var tint: VendorTint
  var primaryFraction: Double       // after display mode
  var secondaryFraction: Double?
  var centerPercent: Int
  var burnRatio: Double
  var hoverLines: [String]
  var errorCaption: String?
}

protocol VendorAdapter: Sendable {
  var id: VendorID { get }
  var displayName: String { get }
  var minPollSeconds: Int { get }

  func fetchUsage(_ ref: CredentialRef) async -> UsageSnapshot
  func beginAdd() async throws -> AddAccountResult
  func reauthenticate(_ ref: CredentialRef) async throws -> CredentialRef
}
```

**Rules**

1. Fractions always normalized 0…1; used/remaining is view-model mapping only.
2. Absolute tokens optional; hover degrades to % if missing.
3. Max **5** accounts at store level.
4. Views never fetch; they only render `[WidgetViewModel]`.

### 3.3 UsageOrchestrator

- One object; one repeating timer from user interval `{300, 900, 1800}` seconds.
- Per account due if `now - lastFetch >= max(userInterval, adapter.minPollSeconds)`.
- Parallel fetch for due accounts.
- Keep `prev` + `last` snapshots per account for burn math.
- Soft error: retain last good rings + caption.
- Terminal auth error: surface reauth.
- HTTP 429: per-account cooldown (e.g. 15 minutes), skip fetch.
- Publish view models on `MainActor`.

**Skipped (ponytail):** priority queues, per-account interval UI, adaptive global circuit-breaker types.

### 3.4 Credentials

```
~/Library/Application Support/<AppName>/
  accounts.json
  accounts/<uuid>/          ← CredentialRef (adapter-owned files inside)
```

- Add: `adapter.beginAdd()` writes isolated folder → `AccountStore` appends metadata.
- Remove: delete folder + metadata row.
- **Claude (and similar):** do **not** call OAuth refresh from this app; read credentials only (codex-island lesson: dual refresh invalidates CLI login).
- Credentials are CLI-compatible files on disk. The app never reads or writes macOS Keychain.

### 3.5 Preferences

`UserDefaults` only:

- `displayMode`: used | remaining  
- `pollSeconds`: 300 | 900 | 1800  

### 3.6 Vendor registry (v1)

| Vendor | Notes |
|--------|--------|
| Claude | Port codex-island `/api/oauth/usage` behavior + multi-account isolated auth dirs (Orca-style) |
| Codex | Port `/wham/usage` + multi-account home/auth isolation |
| Grok | CLI session / usage probe (Orca Grok status as hint); define minPoll conservatively |

Add menu = `registry.filter { $0 }`.map — layout unchanged when a vendor ships.

---

## 4. Presentation map

| Component | Role |
|-----------|------|
| `IslandWindowController` | AppKit borderless notch placement |
| `GaugeClusterView` | Centers 1–5 widgets |
| `AccountWidget` | Flush rings + quiet speed ticks + red needle |
| `EdgeAddChrome` | Chevron → dwell 500ms → `+` → vendor menu |
| `WidgetContextMenu` | Rename / reauth / remove |
| `PrefsSheet` | Display mode + poll interval |

---

## 5. Suggested source layout (single target)

```
Sources/
  App/
  Domain/           # models + VendorAdapter
  AppCore/          # AccountStore, UsageOrchestrator, PreferencesStore
  Adapters/         # Claude, Codex, Grok
  Infra/            # CredentialStore, JSON IO
  Island/           # window + SwiftUI
Tests/
  Domain/           # burn rate, fraction mapping, due scheduling
  Adapters/         # parse fixtures where cheap
```

---

## 6. Non-goals / later

| Later | Why deferred |
|-------|----------------|
| Session → account binding (C-lite) | Account core first |
| Cost / log spend | Different data path |
| Threshold alerts | codex-island has it; port when needed |
| Web-estimated max-token correction | User-marked future |
| SwiftPM core / CLI twin | Second client not real yet |
| Cursor / Gemini adapters | Registry seats only until APIs proven |
| Sparkle / Homebrew | After app identity + bundle id exist |

---

## 7. Open decisions

| Item | Status |
|------|--------|
| Repo | **Locked:** `dash-island` / `HC-kang/dash-island` |
| Marketing name | **Dash Island** (working) |
| Bundle id | Tentative `dev.dashisland.DashIsland` — confirm before first signed build |
| Compact/peek notch | **v1 = cluster-only** expanded island; compact later if needed |
| Grok usage endpoint | Spike before Grok adapter merge |

---

## 8. Implementation order (high level)

1. App skeleton + island window + empty cluster.  
2. Domain types + burn-rate pure functions + tests.  
3. `AccountStore` + credential folders + fake adapter.  
4. Widget rendering (rings, needle, hover, center layout).  
5. `UsageOrchestrator` + polling.  
6. Real Claude adapter → Codex → Grok.  
7. Dwell `+` add flow + context menu.  
8. Prefs sheet.  
9. Polish motion / materials (Apple-quiet).

---

## 9. Spec self-review

| Check | Result |
|-------|--------|
| Placeholders | Open decisions listed explicitly in §7 (product identity only) |
| Consistency | Account-only unit; no session binding; Swift only; max 5 widgets |
| Scope | Single product: notch multi-account usage island |
| Ambiguity | Burn formula, dwell timing, credential layout, error retention pinned |

---

## 10. Principle checklist

| Principle | How |
|-----------|-----|
| Simplicity | One process, one orchestrator, folder = credential, no plugin loader |
| Practicality | Real multi-account + multi-vendor; Orca/codex-island battle lessons |
| Elegance | Flush dual rings, red needle, dwell add, center cluster — instrument, not spreadsheet |
