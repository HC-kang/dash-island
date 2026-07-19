# Grok usage spike (Task 9)

Read-only sources: Orca `src/main/rate-limits/grok-{auth,fetcher}.ts`, live `~/.grok/auth.json` (structure only), Grok CLI help (`GROK_HOME`, `grok login`).

## Auth

| Item | Value |
|------|--------|
| Home | `$GROK_HOME` or `~/.grok` |
| Session file | `$GROK_HOME/auth.json` |
| Login CLI | `grok login` (flags: `--oauth`, `--device-auth`) |

`auth.json` is a map of issuer keys → session objects. Preferred issuer: `https://auth.x.ai` or keys starting with `https://auth.x.ai::`.

Session fields used by Orca / Dash Island:

| Field | Meaning |
|-------|---------|
| `key` | Bearer access token (required) |
| `user_id` | Optional; sent as `x-userid` |
| `email` | Label / provenance |
| `team_id` | Optional |
| `expires_at` | ISO-8601; treat as expired with 5m skew |
| `refresh_token` | Present on disk; **app does not refresh** — Grok CLI refreshes on use |
| `oidc_client_id` | Optional |

Token-less file (logout) = signed out. Malformed JSON = error.

## Usage HTTP

| Item | Value |
|------|--------|
| Base | `https://cli-chat-proxy.grok.com/v1` (override: `GROK_CLI_CHAT_PROXY_BASE_URL`) |
| Credits view | `GET {base}/billing?format=credits` |
| Monthly fallback | `GET {base}/billing` (no format) when credits view lacks weekly % |

### Headers (must match Grok CLI)

```
Authorization: Bearer <key>
X-XAI-Token-Auth: xai-grok-cli
Accept: application/json
x-userid: <user_id>   # when present
```

### Status mapping

| HTTP | Behavior |
|------|----------|
| 401 / 403 | auth required |
| 429 | rate limited |
| other non-2xx | network error |

### Body shape (best-effort)

Response may nest under `config` or be flat:

```json
{
  "config": {
    "creditUsagePercent": 42,
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "…ISO…",
      "end": "…ISO…"
    },
    "billingPeriodStart": "…",
    "billingPeriodEnd": "…",
    "subscriptionTier": "SuperGrok",
    "monthlyLimit": { "val": "150000" },
    "used": { "val": "837" },
    "isUnifiedBillingUser": true
  }
}
```

### Mapping to Dash Island windows

| Window | Source | Notes |
|--------|--------|-------|
| Primary | Weekly credits | `creditUsagePercent` ∈ [0,100] → `usedFraction = %/100`. Reset = `currentPeriod.end` or `billingPeriodEnd`. |
| Secondary | Monthly included | When weekly missing: `(used.val / monthlyLimit.val)` if limit > 0. Reset = period end. |
| Plan | `subscriptionTier` | e.g. SuperGrok |

Protobuf edge case (from Orca): if `creditUsagePercent` is omitted but `currentPeriod.type == USAGE_PERIOD_TYPE_WEEKLY` and period bounds match `billingPeriodStart/End`, treat weekly used as **0%**.

## Polling

No public rate-limit docs for the billing proxy. **Conservative `minPollSeconds = 300`.**

## Multi-account isolation

Dash Island sets `GROK_HOME` to `accounts/<uuid>/` so each account owns its own `auth.json`. Does **not** write the default `~/.grok` keychain/session except as a beginAdd **copy fallback** when the CLI binary is missing and `~/.grok/auth.json` already has a usable session.

## Gaps / concerns

1. App does not implement OIDC refresh; expired access tokens need CLI use or Reauthenticate (`grok login` under managed `GROK_HOME`).
2. Some enterprise/unified accounts only expose monthly budget; others only weekly credits.
3. Endpoint is CLI-proxy internal — may change without notice (same risk Orca accepts).
4. Not verified live HTTP in this spike (auth shape confirmed on disk; request contract from Orca tests).
