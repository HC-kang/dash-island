# Changelog

All notable user-facing changes. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow `VERSION`; a `vX.Y.Z` tag publishes a release zip with a SHA-256 checksum.

## [Unreleased]

### Added
- Detail panel: the account's second window (Claude weekly) gets its own 7-day chart under its bar; each chart has its own hover readout.

## [0.1.0] - 2026-09-28

### Added
- Korean UI. Dates and weekdays follow the UI language.
- Detail panel: a 7-day usage trend with day lines, a 0/50/100% scale and a hover readout; costs in KRW (≈₩, daily rate from open.er-api.com, fetched only when KRW is selected).
- Limit resets for Codex and Claude: the count in the hover card and the detail panel, and **Use** behind a confirmation.
- The app updates an outdated usage collector by itself; a first connection is one button.
- At a glance: the rim turns amber at 80% and red at 95% or when an account needs sign-in. The expanded island shows the worst account (for example `Dev wk 100%`) and its reset countdown beside the notch; on displays without a notch the compact island shows them too (Preferences: Auto / Always / Never).
- Optional total across accounts of chosen vendors (for example `212/500%`), using each account's shortest window unless a longer one is nearly full.
- macOS notifications at 80% and 95%, after a window resets, and when an account needs sign-in (once per crossing; Preferences toggle).
- Run-out ETA in the hover card and the detail panel.
- Detail panel: collector health line (the app connects or updates the collector), vendor incident banner from the status page, and a chevron cue when more content is below.
- `status.json` in Application Support for scripts (sketchybar, tmux, Raycast).
- Move Left / Move Right in the widget menu and VoiceOver actions for every account action.
- App icon.
- Internal file log with levels and categories (`scripts/logs.sh`).

### Changed
- Vendor marks share one tone with the gauge palette.
- Hover tips appear after a short dwell and glide between widgets; the detail panel fades in and out; the expanded island's rim and shadow fade in after the body grows; gauges sweep to new readings.
- One wording for re-authentication: "Sign in again" / "needs sign-in".
- Titles, percent signs, and captions are larger and easier to read on 1x displays; the burn needle is grey at rest.
- The detail panel follows the Used / Remaining preference.
- Idle animations pause when the island is compact, hidden, in Low Power Mode, or with Reduce Motion; idle CPU dropped from about 6% to near 0%.
- Hovering expands after a short dwell and no longer takes keyboard focus.

### Fixed
- Two refreshes of the same account folder no longer race; a token file that the CLI rotated meanwhile is adopted.
- Clicking a widget while the app was inactive no longer closes and reopens its detail panel.
- Preferences scroll on short screens; dialogs grow to fit long messages.
- Adding an Antigravity account from a clean state now completes.
- Cancelling a login ends the CLI login process; a cancelled or failed reauthentication keeps the previous credentials.
- Token-server outages no longer show as "reconnect" or as a usage rate limit.
- A slow account no longer blocks updates of the others; network errors retry within minutes instead of 15.
- Local usage scanning no longer runs on the main thread.
- Credential folders are owner-only (0700 / 0600).
