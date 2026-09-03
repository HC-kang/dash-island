# Antigravity (`agy`) auth state graph

Gemini CLI was retired in favor of Antigravity CLI (`agy`).
Codex is unrelated and stays in the vendor registry.

Usage API (oh-my-pi):
`POST https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
after `loadCodeAssist` with `ideType: ANTIGRAVITY`.

## Storage

| Store | Path | When |
| --- | --- | --- |
| Managed creds | `accounts/<uuid>/.gemini/oauth_creds.json` | `HOME` is the managed folder |
| Last-good | `accounts/<uuid>/.dash-island-usage.json` | wiped on clear |
| Default CLI | `~/.gemini`, OS keyring | **never** read/written |

## Leftover guards

Same as Claude: snapshot access+refresh, reject leftover, smoke 401/403,
wipe last-good, roll back failed add/reauth. Cancel/remove wipes Agy files.

## Known gaps

- CLI tokens live in Keychain `service=gemini` / `account=antigravity`
  (`go-keyring-base64:{token:{access_token,refresh_token,expiry}}`). Piped
  `agy` never opens a browser — login is harvest-that-item, else Terminal.app.
- Global keyring is one Google session; leftover access/refresh inequality
  would deadlock reauth, so Agy accepts the same tokens after smoke.
- This machine may not have `agy` on PATH until
  `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
