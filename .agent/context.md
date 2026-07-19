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
