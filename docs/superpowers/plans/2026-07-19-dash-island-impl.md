# Dash Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS notch island that shows multi-vendor, multi-account AI rate-limit usage as instrument-cluster widgets (≤5, center-aligned).

**Architecture:** Single Swift app target. Presentation observes `UsageOrchestrator` view models only. Vendors implement `VendorAdapter`. Credentials live in per-account folders under Application Support.

**Tech Stack:** Swift 6, SwiftUI, AppKit (borderless window), Foundation/URLSession, UserDefaults. No SPM split, no Electron, no Sparkle in first milestone.

**Spec:** `docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`

**Reference (read-only):** `/Users/ford/projects/personal/codex-island`, `/Users/ford/projects/personal/orca`

**Principles:** simplicity → practicality → elegance (ponytail: fewest files that work).

---

## File map (create)

```
Sources/
  App/App.swift
  Domain/
    Types.swift              # AccountID, VendorID, CredentialRef aliases
    Account.swift
    UsageSnapshot.swift      # WindowUsage, UsageSnapshot, UsageError
    BurnRate.swift           # pure math + needle mapping
    WidgetViewModel.swift
    VendorAdapter.swift      # protocol + AddAccountResult + registry protocol
  AppCore/
    AccountStore.swift
    PreferencesStore.swift
    UsageOrchestrator.swift
  Infra/
    CredentialStore.swift
    AccountsPersistence.swift
  Adapters/
    VendorRegistry.swift
    FakeAdapter.swift        # dev / tests
    ClaudeAdapter.swift
    CodexAdapter.swift
    GrokAdapter.swift        # after spike
  Island/
    IslandWindowController.swift
    BorderlessFloatingWindow.swift
    IslandRootView.swift
    GaugeClusterView.swift
    AccountWidget.swift
    GaugeRingView.swift      # rings + needle + ticks
    EdgeAddChrome.swift
    PrefsSheet.swift
build.sh
Info.plist (or generated)
Tests/
  BurnRateTests.swift
  OrchestratorDueTests.swift
  AccountsPersistenceTests.swift
```

---

### Task 1: App skeleton + island window

**Files:**
- Create: `Sources/App/App.swift`
- Create: `Sources/Island/BorderlessFloatingWindow.swift`
- Create: `Sources/Island/IslandWindowController.swift`
- Create: `Sources/Island/IslandRootView.swift`
- Create: `build.sh`
- Create: `VERSION` → `0.0.1`

- [ ] **Step 1:** Add `build.sh` that compiles a macOS 13+ app bundle `DashIsland.app` with bundle id `dev.dashisland.DashIsland`, ad-hoc codesign. Mirror codex-island’s lipo/universal pattern only if needed; **start arm64-only if faster**.

```bash
#!/usr/bin/env bash
set -euo pipefail
# swiftc Sources/**/*.swift -o DashIsland … package into .app
```

- [ ] **Step 2:** `NSApplication` + `@main` that shows a borderless, non-activating (or activating—match codex-island) floating window centered on the notched screen (`safeAreaInsets.top > 0` prefer).

- [ ] **Step 3:** `IslandRootView` shows a black rounded capsule with text `Dash Island` so window placement is visible.

- [ ] **Step 4:** Run `./build.sh && open dist/DashIsland.app` (or local path). Confirm notch alignment on main display.

- [ ] **Step 5:** Commit `chore: scaffold Dash Island window`

---

### Task 2: Domain types + burn rate tests

**Files:**
- Create: `Sources/Domain/*.swift` as in file map
- Create: `Tests/BurnRateTests.swift`
- Create: `scripts/run-tests.sh` (swift test or `swiftc` test runner — pick one, keep simple)

- [ ] **Step 1:** Write failing tests for burn math:

```swift
// ratio == 0 when only one sample
// ratio == 1 when Δ matches cruise to reset
// ratio soft-caps mapping for needle (e.g. ≥2 → redline angle)
```

- [ ] **Step 2:** Implement `BurnRate.compute(prev:current:now:)` and `needleUnit(ratio:) -> Double` in `0...1` along the speed arc.

- [ ] **Step 3:** Implement remaining domain types (no networking).

- [ ] **Step 4:** Run tests; commit `feat: domain models and burn rate`

---

### Task 3: AccountStore + credentials + fake adapter

**Files:**
- Create: `Sources/Infra/CredentialStore.swift`
- Create: `Sources/Infra/AccountsPersistence.swift`
- Create: `Sources/AppCore/AccountStore.swift`
- Create: `Sources/Adapters/FakeAdapter.swift`
- Create: `Sources/Adapters/VendorRegistry.swift`
- Create: `Tests/AccountsPersistenceTests.swift`

- [ ] **Step 1:** `CredentialStore.rootURL` → `Application Support/DashIsland/accounts/<uuid>/`.

- [ ] **Step 2:** Persist `accounts.json` list of `Account` (Codable). Cap at 5; reject add beyond.

- [ ] **Step 3:** `FakeAdapter`: `beginAdd` creates folder + dummy token file; `fetchUsage` returns deterministic % from hash(id) so UI can develop offline.

- [ ] **Step 4:** Wire `AccountStore.shared` load on launch; unit test round-trip persistence.

- [ ] **Step 5:** Commit `feat: account store and fake adapter`

---

### Task 4: Gauge widget UI

**Files:**
- Create: `Sources/Island/GaugeRingView.swift`
- Create: `Sources/Island/AccountWidget.swift`
- Create: `Sources/Island/GaugeClusterView.swift`
- Modify: `IslandRootView.swift`

- [ ] **Step 1:** `GaugeRingView` draws flush dual rings (outer brand, inner steel), outer tick scale, red needle from `burnRatio` unit.

- [ ] **Step 2:** `AccountWidget` square cell: gauge + label + hover tooltip **below** with `hoverLines`.

- [ ] **Step 3:** `GaugeClusterView` `HStack` center, 1–5 widgets from `[WidgetViewModel]`.

- [ ] **Step 4:** Preview with 1 / 3 / 5 fake view models in demo mode (`DASHISLAND_DEMO=1` or in-app flag).

- [ ] **Step 5:** Commit `feat: gauge cluster widgets`

---

### Task 5: UsageOrchestrator

**Files:**
- Create: `Sources/AppCore/UsageOrchestrator.swift`
- Create: `Sources/AppCore/PreferencesStore.swift`
- Create: `Tests/OrchestratorDueTests.swift`
- Modify: `IslandRootView` to observe orchestrator

- [ ] **Step 1:** Preferences: `pollSeconds` ∈ {300,900,1800}, `displayMode` used|remaining.

- [ ] **Step 2:** Orchestrator: timer; per-account due = `max(userInterval, adapter.minPoll)`; parallel fetch; prev/last for burn; soft-error retention; 429 cooldown map.

- [ ] **Step 3:** Map snapshots → `WidgetViewModel` (display mode, hover k/m formatting).

- [ ] **Step 4:** Test due/skip pure helper with fixed dates.

- [ ] **Step 5:** Commit `feat: usage orchestrator polling`

---

### Task 6: Edge add chrome + context menu

**Files:**
- Create: `Sources/Island/EdgeAddChrome.swift`
- Modify: `GaugeClusterView.swift`, `AccountWidget.swift`, `AccountStore.swift`

- [ ] **Step 1:** Right-edge chevron always (if count < 5). Dwell ≥500ms → glass `+`.

- [ ] **Step 2:** Menu lists `VendorRegistry` adapters; selecting runs `beginAdd` → append account → refresh.

- [ ] **Step 3:** Empty state: single centered `+`.

- [ ] **Step 4:** Context menu: Rename (alert/field), Reauth, Remove (confirm).

- [ ] **Step 5:** Commit `feat: add account chrome and widget menu`

---

### Task 7: Claude adapter

**Files:**
- Create: `Sources/Adapters/ClaudeAdapter.swift`
- Optional fixtures under `Tests/Fixtures/claude-usage.json`

- [ ] **Step 1:** Port parse + request headers from codex-island `UsageFetcher` / `ClaudeCredentials` **read-only** (no refresh).

- [ ] **Step 2:** `beginAdd`: spawn `claude auth login` with `CLAUDE_CONFIG_DIR` (or equivalent) pointed at managed folder; poll until credentials appear (Orca-style isolation, simplified).

- [ ] **Step 3:** Manual test with real login; surface reauth errors as captions.

- [ ] **Step 4:** Commit `feat: Claude vendor adapter`

---

### Task 8: Codex adapter

**Files:**
- Create: `Sources/Adapters/CodexAdapter.swift`

- [ ] **Step 1:** Port `/wham/usage` fetch; token from managed `auth.json`.

- [ ] **Step 2:** `beginAdd`: isolated home + `codex login` (or documented path); keep simplest path that works.

- [ ] **Step 3:** Commit `feat: Codex vendor adapter`

---

### Task 9: Grok adapter (after spike)

**Files:**
- Create: `Sources/Adapters/GrokAdapter.swift`
- Create: `docs/notes/grok-usage-spike.md` (or `notes/` if gitignored later)

- [ ] **Step 1:** Spike Grok CLI auth path + usage API (see Orca `grokAccounts` / rate limits). Document endpoint + fields.

- [ ] **Step 2:** Implement adapter with conservative `minPollSeconds` (≥300 unless proven safe).

- [ ] **Step 3:** Commit `feat: Grok vendor adapter`

---

### Task 10: Prefs + polish

**Files:**
- Create: `Sources/Island/PrefsSheet.swift`
- Modify: island chrome for optional gear

- [ ] **Step 1:** Sheet: display mode toggle, poll interval segmented 5/15/30.

- [ ] **Step 2:** Motion: needle spring, dwell fade — keep subtle (Apple-quiet).

- [ ] **Step 3:** Demo mode env for screenshots.

- [ ] **Step 4:** Commit `feat: prefs and polish`

---

## Out of scope this plan

Sparkle, Homebrew cask, cost screen, alerts, session binding, compact peek, extra vendors beyond Claude/Codex/Grok.

---

## Plan self-review

| Spec area | Tasks |
|-----------|--------|
| Island + cluster UX | 1, 4, 6, 10 |
| Domain + burn | 2, 5 |
| Accounts + credentials | 3, 6 |
| Adapters | 7–9 |
| Prefs / poll | 5, 10 |
| No session/Electron/Rust | honored |
