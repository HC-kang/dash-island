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
