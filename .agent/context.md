# Dash Island — agent memory

Entry point. Read this first, then open the topic file you need.

## Product

- Multi-vendor multi-account usage notch island (not a codex-island fork).
- Principles: simplicity → practicality → elegance.
- Stack: Swift 6, SwiftUI + AppKit island, in-process `VendorAdapter`s.
- Vendors: Claude, Codex, Grok, Antigravity (`agy`, replaced Gemini). Fake is for dev and tests only.
- Spec: `docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`

## Reference repos (read-only)

- `~/projects/personal/codex-island` — fetch + notch patterns
- `~/projects/personal/orca` — multi-account managed auth model

## Topic files

- `decisions.md` — locked UX, user choices, burn/polling/auth/usage-detail policy, roadmap. Superseded choices are marked.
- `constraints.md` — hard rules: privacy, credential storage, Keychain and vendor CLI facts, usage attribution, live-machine etiquette, build/test limits.
- `patterns.md` — architecture reference (v1 tasks 1–10, adapters, orchestrator, collector, logging, Phase 1–3 streams) and reusable implementation/test patterns.
- `mistakes.md` — bugs with root causes, user corrections, open Claude auth holes (H1–H10), review findings.

## Top constraints (details in constraints.md)

- The repo is PUBLIC. Never write account IDs, identity hashes, PIDs, session IDs, employer names, spend amounts, or absolute home paths. Use `<acct>` and `~/`.
- Never log tokens, auth headers, or response bodies.
- The managed `.credentials.json` is the Claude source of truth. Never touch the unsuffixed `Claude Code-credentials` Keychain item.
- Never attribute a machine-wide signal (logs, folders, telemetry identity) to an account without an identity match.
- Never restart the user's Orca/CLI sessions, and never rerun the collector connector, without explicit approval.
- Never leave `DASHISLAND_DEMO=1` running. Launch smoke tests with a clean env.
- Run build and tests one after the other. `build.sh` removes `build/`.
- The user works on the same Mac. Wait for an idle pointer and restore it; do not fight concurrent input.
- Claude tests never call `fetchUsage`. Use the gate/ping sandbox.
- Default to inline or low-effort code review. A high-effort `/code-review` hit the session limit (mistakes.md, 2026-09-17).

## Current state (2026-09-24)

- Branch `feat/improve-phase2` holds Phase 1 (`feat/improve-phase1`), Phase 3 adapter tests, and Phase 2. It is not merged into `main` yet.
- Polling: background 15m, scheduler tick 60s, expand re-asks every 60s, Claude minPoll 120s.
- Accounts: cap 20, five visible slots, horizontal scroll.
- Usage details: account-only panel, no source picker.

## Write policy

- Append a new dated entry to the topic file that fits. If unsure, append here and move it later.
- Keep this file short. Move content; do not duplicate it.
