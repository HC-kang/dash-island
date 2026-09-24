# Constraints

Hard rules and non-obvious facts. Vendor, platform, and live-machine limits live here. Dated headings keep the source context.

## Scope (spec, 2026-07-19)

- Do not commit design or app code into codex-island for this product.
- Do not introduce Electron, Rust core, or session-binding in v1.

## Privacy (2026-09-23, chore/scrub-sensitive)

- The repo is PUBLIC and tracks this file. The scrub removed employer name, account ID prefixes, identity hashes, work repo/branch names, session UUID, PIDs, spend amounts, and `/Users/<name>` paths from this file, docs, test fixtures, and code comments. Old values remain in git history until a history rewrite is decided.
- Rule: never write real account IDs, identity hashes, PIDs, session IDs, work repo/branch names, employer names, spend amounts, or absolute home paths into tracked files. Use placeholders (`<acct>`, `ABCDEF12`, `~/`).
- Never log tokens / auth headers / response bodies at any level; `Log.redact` and `UUID.short` only (logging design, 2026-09-23).
- Mistake found in the old code (2026-09-23): Claude and Grok OAuth refresh 400/401/403 lines printed the response body. Removed; only `http=` stays. Keep response bodies out of every log line.

## Credential storage (2026-07-19)

- Real path: `~/Library/Application Support/DashIsland/{accounts.json,accounts/<uuid>/}` — outside the `.app` bundle; rebuild never wipes it.
- Never launch user-facing smoke tests with `DASHISLAND_DEMO=1` — it replaces UI with fake widgets while leaving disk alone (looks like "accounts wiped").
- Hardening: refuse empty `accounts.json` overwrite unless last account explicitly removed; corrupt file → `accounts.corrupt.<ts>.json` backup, no clobber; orphan folders with valid vendor creds rehydrate into the list on live load only.
- On launch log: Application Support path + account count.

## Keychain and Claude CLI facts

- Claude CLI 2.1.229 on macOS writes login to scoped Keychain only — **no** `.credentials.json`. Pure file capture made Reauth fail (`credentialsMissing`) (2026-08-13).
- Never touch unsuffixed `Claude Code-credentials` (user's real Claude Code) (2026-08-30).
- Ad-hoc codesign still resets ACL on every rebuild — that's why Always Allow dies in dev. Don't re-read Keychain after the file exists (2026-08-30).
- `claude -p ok --model haiku` with `CLAUDE_CONFIG_DIR` **does** rotate tokens. Darwin CLI writes scoped Keychain and **deletes** `.credentials.json` (2026-09-02; recovery pattern in patterns.md).

## Usage attribution (2026-09-12)

- Source TokenEvent/CostStore (codex-island) are provider-wide, not account-aware. Never attribute global local logs to the clicked account; label machine/provider scope unless ownership is proven. Grok `usedTokens` may contain monetary counters, not token counts.
- Orca Codex account homes hardlink other accounts' history for resume (`codex-account-session-bridge.ts`). A log's folder is NOT proof of ownership. Claude Orca uses `claude-accounts/<id>/auth` as CLAUDE_CONFIG_DIR even when it initially contains no settings/projects. Root `orca-data.json` can be stale; active profile data lives under profiles/local-default.
- See also mistakes.md "Claude needles identical across accounts": never assign a machine-wide signal to an account without an identity match.

## Claude telemetry identity can lag an account switch (2026-09-14)

- User observed using Dev while Developer API estimate rose. Server `/api/oauth/profile` verified Dash Dev/Developer credential identities match their labels. Orca active selection and global ~/.claude.json were Dev, yet all new telemetry was Developer. Between live reads Dev five-hour quota increased 18→19%, Developer stayed 13%; collector Developer calls kept rising while Dev still had only Sep 12 smoke calls. Do NOT claim the collector's account ID proves actual billed account.
- Request IDs in Developer-attributed records matched the active work-session transcript and its subagent transcript. The main Claude process started Sep 14 12:54 and used the default config.
- Correction to Sep 12 memory: on macOS Orca materializes selected managed Claude credentials/profile into the SHARED runtime (normally ~/.claude / ~/.claude.json); `runtime-auth-preparation.ts` returns paths.configDir/paths.envPatch for host. Dedicated auth directory launch applies to WSL; auth folders on Mac are account snapshots, not each host process's config home.
- Installed Claude code builds telemetry identity from PN() (credentialSlots.authenticatedAccount, stamped from bootstrap account_uuid) before the profile fallback. Credential store change handling vEe/jG/Pw clears credential caches but does not clear that stamped identity via AX(null). Thus an external account switch can leave reported identity stale. Receiver cannot reconstruct actual historical request bearer from these events. Preserve records; never relabel all Developer history as Dev based on current selection.
- Current mitigation: restart the affected Claude process after selecting the desired account, or use the existing account-cli launcher with a dedicated managed home to isolate it from Orca global switches. Working user sessions were not restarted. A fresh post-restart call still needs verification before claiming end-to-end correctness.

## Vendor CLI homes (2026-09-23)

- `agy` has no home variable other than `$HOME` (checked the binary strings), so account-cli must replace HOME. It sets `GIT_CONFIG_GLOBAL` to the user's git config; other `~` configs are not available inside that session (README documents this).
- account-cli takes no refresh lock: vendor CLIs cannot honor it. The app yields to a newer file (README) (2026-09-24).

## Live machine etiquette

- Launch smoke tests with clean env (`env -i …` or unset DASHISLAND_DEMO). Never leave DEMO=1 processes running for the user (2026-07-19).
- Existing Orca/CLI processes must be reopened once to inherit collector config; never restart the user's working Orca automatically (2026-09-12).
- The installed collector on a real Mac stays stale until someone reruns the connector. Never rerun it from an agent session without explicit user approval (2026-09-23).
- Computer-use bundle lookup omits this accessory app; PID selection works. Prefer AX widget actions when the user is moving the cursor. Raw mouse checks during concurrent user input are inconclusive; stop repeating pointer manipulation. Source-picker semantic action alone did not prove selection; the subsequent fresh UI state did (2026-09-15).
- E2E (2026-09-24): the user works on the same Mac: wait for an idle pointer, then restore its position. Never leave `DASHISLAND_DEMO=1` running.

## Build and test limits

- Build and tests must run sequentially: build.sh removes build/, including the test linker output directory. Never run these concurrently (2026-09-12).
- File sink is opt-in (`Log.startFile` in `AppDelegate` only) so the test binary never writes the real log (2026-09-23).
- Tests must never call real `launchctl` or use the real HOME/env: `install(home, environ, run)` and `disconnect(...)` take a fake `run`, and `environ={}` (CODEX_HOME is often set in agent shells) (2026-09-23).
- Phase 1 integration (2026-09-23): no test may drive the Claude oauth/token refresh to a 429/5xx. That path starts a real `claude -p` and a `security` Keychain read in the background. Inject a spawner first if such a test is needed. (Phase 3 added that seam; see next bullet.)
- Claude tests never call `fetchUsage` (it deletes a Keychain item). Drive `refreshThenProbe` / `refreshManagedCredentialsDetailed` inside a sandbox that swaps the gate (throwaway defaults) and `backgroundPing` (counter). A token-host 429/5xx test is now safe that way (2026-09-24).
- A test may call `refreshThenProbe` only with a ping registered for its temp folder (then no `claude` can spawn) (2026-09-23).
- FileManager enumeration resolves /var to /private/var on macOS; normalize symlinks when asserting temporary URL equality (2026-09-14).
- `check-widget-render.sh` and `check-detail-toggle.sh` are not executable in git; run them with `bash` (2026-09-23).

## Platform coverage

- macOS 13/14 runtime is not verified anywhere. The dated verification bullets in mistakes.md and patterns.md state the exact gaps.
- Known limits: `.help` tooltips and the pointing-hand cursor may not show while the app is inactive (2026-09-23).

## Limit resets (2026-09-25)

- A reset call spends a credit and cannot be undone. Tests never send one; live checks read counts only.
- Codex: `GET wham/rate-limit-reset-credits` (count), `POST …/consume {"redeem_request_id"}`. Answers are HTTP 200 codes: `reset`, `already_redeemed`, `nothing_to_reset`, `no_credit`.
- Claude: `GET /api/oauth/usage?cedar_ember=1&skip_spend=1` (grants), `POST /api/organizations/{org}/reset_rate_limits {"program":"cedar_ember","grant_id","request_id"}`. The org id is `oauthAccount.organizationUuid` in the folder's `.claude.json`.
- Claude gates resets on the client surface, read from the User-Agent. `claude-code/<ver>` answers `ineligible_reason: surface`; `claude-cli/<ver> (external, cli)` works. Only the reset calls send the CLI form.
- The request id is the idempotency key. Keep it after a timeout, 5xx or unknown answer, and reuse it on the retry.
- Claude grants seen so far have `use_requires_limit=false`: early use spends the credit, so the confirmation names the highest limit percent.
