# Dash Island

macOS notch island for **multi-vendor, multi-account** AI usage rate limits.

Each account is one instrument-cluster widget (up to five, center-aligned). Vendors plug in via adapters (Claude, Codex, Grok, …).

**Principles:** simplicity → practicality → elegance.

## Requirements

- Apple Silicon Mac (arm64)
- macOS 13+
- Xcode CLT / `swiftc`

## Build

```bash
./build.sh
```

Produces `build/DashIsland.app` (bundle id `dev.dashisland.DashIsland`, `LSUIElement`, ad-hoc signed).

## Run

```bash
open build/DashIsland.app
```

Or:

```bash
./build/DashIsland.app/Contents/MacOS/DashIsland
```

The island floats top-center on a notched display (falls back to the main screen). Gear (bottom-left of the island) → display mode (used / remaining) and poll interval (5 / 15 / 30 min).

## Demo mode

Fake gauges without accounts (screenshots / layout):

```bash
DASHISLAND_DEMO=1 open build/DashIsland.app
# or
DASHISLAND_DEMO=1 ./build/DashIsland.app/Contents/MacOS/DashIsland
```

Widget count: `DASHISLAND_DEMO_COUNT` ∈ `1` | `3` | `5` (default `3`).

```bash
DASHISLAND_DEMO=1 DASHISLAND_DEMO_COUNT=5 ./build/DashIsland.app/Contents/MacOS/DashIsland
```

## Tests

```bash
./scripts/run-tests.sh
```

## Design

- Spec: [`docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`](docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md)

## License

TBD.
