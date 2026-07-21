# Dash Island

macOS **menu-bar / notch island** for multi-vendor, multi-account AI usage limits.

Each linked account is one gauge (up to five). Adapters today: **Claude**, **Codex**, **Grok**.

**Principles:** simplicity → practicality → elegance.

> Not on the Mac App Store. Unsigned / ad-hoc signed build for local install and GitHub distribution.

---

## Requirements

| | |
|--|--|
| Mac | **Apple Silicon** (arm64) |
| OS | macOS **13** Ventura or newer |
| Tools | Xcode Command Line Tools (`swiftc`, `codesign`) |

```bash
xcode-select --install   # if swiftc is missing
```

Optional for **adding** accounts from the app:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (`claude`)
- [OpenAI Codex](https://github.com/openai/codex) CLI (`codex`)
- [Grok](https://grok.com) CLI (`grok`)

---

## Build from source

```bash
git clone https://github.com/HC-kang/dash-island.git
cd dash-island
./build.sh
```

Output:

```text
build/DashIsland.app
```

- Bundle id: `dev.dashisland.DashIsland`
- Menu bar agent (`LSUIElement` — no Dock icon)
- **Ad-hoc** code signature (`codesign -s -`) so Gatekeeper is less angry on *your* machine

### Run

```bash
open build/DashIsland.app
```

### First open on another Mac (downloaded / cloned build)

macOS may block an ad-hoc signed app from the internet:

1. **System Settings → Privacy & Security** → “Open Anyway”, or  
2. Right-click the app → **Open** → confirm, or  
3. Strip quarantine after download:

```bash
xattr -dr com.apple.quarantine build/DashIsland.app
open build/DashIsland.app
```

### Install (optional)

```bash
cp -R build/DashIsland.app /Applications/
# or
cp -R build/DashIsland.app ~/Applications/
```

Launch at Login is available in the island preferences (gear in the notch ears when expanded).

---

## Use

1. Hover the island (or the top-center fallback bar on non-notch displays) to expand.
2. **+** / chevron → add Claude, Codex, or Grok (browser login into a **managed** folder under Application Support — not your default CLI home).
3. Rings = quota used (or remaining — prefs). **Red needle** = burn pace vs even cruise (not a debug dump).
4. Gear in the notch ear → display mode, rim accent, target display, launch at login.

Credentials live only on your Mac:

```text
~/Library/Application Support/DashIsland/
  accounts.json
  accounts/<uuid>/     # per-account tokens (file only)
```

---

## Demo mode (no accounts)

```bash
DASHISLAND_DEMO=1 open build/DashIsland.app
DASHISLAND_DEMO=1 DASHISLAND_DEMO_COUNT=5 open build/DashIsland.app
```

`DASHISLAND_DEMO_COUNT` ∈ `1` | `3` | `5` (default `3`).

---

## Tests

```bash
./scripts/run-tests.sh
```

---

## Version

Marketing / bundle version is a single line in [`VERSION`](VERSION) (`X.Y.Z`). `build.sh` injects it into `Info.plist`.

---

## What this repo is *not* (yet)

| | |
|--|--|
| Mac App Store | No (sandbox + entitlement path not set up) |
| Developer ID / notarization | No — ad-hoc only; fine for “build it yourself” |
| Sparkle auto-update | Planned notes only (`docs/notes/SPARKLE-HOMEBREW-PLAN.md`) |
| Homebrew cask | Not wired for public tap yet |

If you only want **GitHub + README build instructions**, you already have the intended v0 distribution model: clone → `./build.sh` → `open`.

Later (optional) ladder:

1. **GitHub Releases** — attach a zip of `DashIsland.app` + release notes (still ad-hoc or later Developer ID).
2. **Notarized Developer ID** — `$99/year` Apple program; fewer Gatekeeper clicks for zip downloads.
3. **Sparkle** — in-app updates from GitHub Releases (see notes plan).
4. **Homebrew** — `brew install --cask` from a personal tap.

---

## Design / internals

- Spec: [`docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`](docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md)
- Rate limits: background poll ~15m; expand lazy-refresh; long quiet window after vendor **429** (usage or OAuth refresh) so we do not hammer APIs.

---

## License

TBD — set before a public “release” tag if you care about reuse terms (MIT is a common choice for this style of tool).
