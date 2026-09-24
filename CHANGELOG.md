# Changelog

All notable user-facing changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow `VERSION`; a `vX.Y.Z` tag publishes a release zip with a SHA-256 checksum.

## [Unreleased]

## [0.1.0] - 2026-09-24

### Added
- At-a-glance compact island: the rim turns amber at 80% and red at 95% or when an account needs sign-in; ears beside the notch show the worst account (for example `Dev wk 100%`) and its reset countdown. Both can be turned off in Preferences.
- macOS notifications at 80% and 95%, after a window resets, and when an account needs sign-in (once per crossing; Preferences toggle).
- Run-out ETA and a per-day budget for weekly/monthly windows in the hover card and the detail panel.
- Detail panel: collector health line with a reconnect command, vendor incident banner from the status page, and a chevron cue when more content is below.
- `status.json` in Application Support for scripts (sketchybar, tmux, Raycast).
- Move Left / Move Right in the widget menu and VoiceOver actions for every account action.
- App icon.
- Internal file log with levels and categories (`scripts/logs.sh`).

### Changed
- Titles, percent signs, and captions are larger and easier to read on 1x displays; the burn needle is grey at rest.
- The detail panel follows the Used / Remaining preference.
- Dates in the UI are English, matching the rest of the copy.
- Idle animations pause when the island is compact, hidden, in Low Power Mode, or with Reduce Motion; idle CPU dropped from about 6% to near 0%.
- Hovering expands after a short dwell and no longer takes keyboard focus.

### Fixed
- Adding an Antigravity account from a clean state now completes.
- Cancelling a login ends the CLI login process; a cancelled or failed reauthentication keeps the previous credentials.
- Token-server outages no longer show as "reconnect" or as a usage rate limit.
- A slow account no longer blocks updates of the others; network errors retry within minutes instead of 15.
- Local usage scanning no longer runs on the main thread.
- Credential folders are owner-only (0700 / 0600).
