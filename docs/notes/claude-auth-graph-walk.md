# Claude auth graph walk (`1d04401` + walk fixes)

Replay of `docs/notes/claude-auth-state-graph.md` against harden-worker code
(`1d04401`) plus the cheap holes found on this walk. No live Anthropic. No
unsuffixed `Claude Code-credentials` writes.

Expected outcomes: **pass** (usable session / live rings), **fail** (error, no
token), **quiet** (keep last-good, no reconnect), **reauth** (hard caption).

Tests: `./scripts/run-tests.sh` passed after the walk fixes.

---

## 1. Add / reauth / harvest

| From | Event | Function | Outcome | Status |
| --- | --- | --- | --- | --- |
| (none) | beginAdd → create folder | `CredentialStore.createDirectory` | — | ok |
| EmptyDir | spawn login (prior usually nil) | `runLogin` | wait | ok; untested live CLI |
| LoginSpawned | harvest non-empty, prior nil | `captureLoginCredentials` + `isAcceptableLogin` + **`verifyUsageAccess` (H2)** | **pass** if smoke 200/soft; **fail** if 401 | graph stale (“no smoke”); helper tested, HTTP not |
| LoginSpawned | harvest access==prior or refresh==prior | `isAcceptableLogin` | stay HarvestPoll → **fail** | tested (H1 + 8148deb) |
| LoginSpawned | 180s / CLI exit / cancel, no acceptable | `runLogin` | **fail** `loginTimeout` / `credentialsMissing` | untested live |
| FilePersisted | name Cancel / add cancel | `EdgeAddChrome.discardManagedFolder` → `clearManagedCredentials` + `removeDirectory` | **fail** | walk fix: scoped KC now wiped (was H4) |
| FilePersisted | smoke 401 after harvest | `verifyUsageAccess` → `usageSmokeDecision` → beginAdd catch `clearManagedCredentials` | **fail** | walk fix: rejected file no longer kept |
| AccountReady | UI Reauthenticate | `EdgeAddChrome.reauthenticate` | wait 3 min | ok |
| PriorSnapshotted | snapshot then wipe | `existingCredentials` + `clearManagedCredentials` | file + last-good + scoped KC gone | file/last-good tested; KC delete untested live |
| Wiped | logout | `runLogout` | best-effort | **H3** still fire-and-forget; untested |
| LoggedOut | leftover same access or same refresh | `isAcceptableLogin` | **fail** | tested |
| LoggedOut | new access **and** new refresh + smoke 200 | `isAcceptableLogin` + `verifyUsageAccess` | **pass** | helper tested; HTTP not |
| LoggedOut | new access+refresh (rotated leftover grant) | `isAcceptableLogin` | **pass** (H1 residual) | helper pins this; needs H3 |
| LoggedOut | cancel / no `claude` after wipe | `reauthenticate` catch | **fail**; last-good **gone** (H6) | graph stale (“rings still show”) |
| TokenlessAccount | `fetchUsage` | `readCredentials` nil → `.authRequired` | **reauth** | untested live; path obvious |
| AccountReady | Remove | `AccountStore.remove` → `clearManagedCredentials` + `removeDirectory` | folder gone; scoped KC delete attempted | walk fix (was H4 folder-only) |
| SetupPaste | paste + smoke | `installSetupToken` + `verifyUsageAccess` | 200/**soft** → **pass**; 401 → **fail** + wipe | decision tested; UI not wired |

---

## 2. Probe / refresh / last-good

| From | Event | Function | Outcome | Status |
| --- | --- | --- | --- | --- |
| ReadFile | no file | `fetchUsage` | **reauth** | ok |
| ReadFile | file has access | `probeUsage` first | — | untested HTTP |
| Probe | usage 200 | `probeUsage` + `encodeLastGood` | **pass** | encode tested |
| Probe | usage 429 | `shouldAttemptRefresh` false | **quiet** | helper tested |
| Probe | usage 401/403 | `shouldAttemptRefresh` | Recover if refresh+not stale | helper tested |
| Probe | network/parse | no refresh | **quiet** | merge tested |
| ConsiderRefresh | long-lived | `isLongLived` → hard unavailable | **reauth** | helper tested |
| ConsiderRefresh | no refresh / >7d stale | `canAttemptRefresh` | **reauth** | helper tested |
| Recover | file access ≠ failed | `shouldAdopt` → re-probe, no POST | 200 **pass** / 401 **reauth** | helper tested; **H8** still no second POST |
| Recover | gate 20m / token 429 | `refreshManagedCredentialsDetailed` | **quiet** | untested live gate |
| Recover | token 400/401/403 | `.rejected` | **reauth** | untested HTTP |
| Recover | token other/network | `.unavailable` | **quiet** | untested HTTP |
| Healthy | error-free snap | `UsageOrchestrator.encodeLastGood` / `apply` | persist last-good | tested |
| Any error + prior last-good | `shouldRetainPreviousRings` | keep rings | soft **quiet** / hard **reauth** caption | tested |
| Wipe / failed reauth | `clearManagedCredentials` | last-good deleted | no previous identity | tested (H6) |
| Launch | `restoreLastGoodSnapshots` | last-good if file exists | **quiet** until probe | untested integration |

---

## 3. Cheap holes fixed on this walk

1. **Smoke-rejected harvest stuck on reauth** — `verifyUsageAccess` threw and left `.credentials.json`. Catch now `clearManagedCredentials`.
2. **H10** — `requireCredentials` no longer re-harvests Keychain / persists a leftover `runLogin` rejected.
3. **H4 (file/KC part)** — add cancel and `AccountStore.remove` call `clearManagedCredentials` before folder delete. Still no logout (H3).

---

## 4. Still wrong or untested

| ID | Severity | Notes |
| --- | --- | --- |
| H1 residual | P1 | Leftover that rotates **both** access and refresh still **pass** `isAcceptableLogin`. Smoke 200 keeps it. Needs real logout (H3) or identity check. |
| H3 | P1 | `runLogout` ignores missing binary / exit / 8s terminate. Untested live. |
| H4 residual | P1 | Logout still skipped on remove/cancel. Scoped KC wipe is best-effort (`NSUserName()` account). |
| H5 | P1 | Wipe-then-login is still not transactional; cancel after wipe = tokenless. Last-good now gone (H6), so no fake signed-in rings. |
| H7 | P2 | CLI may still clone global `Claude Code-credentials`. Do not unit-test that item. |
| H8 | P2 | `.adopted` + 401 never POSTs `oauth/token`. |
| H9 | P2 | Smoke 429/network **soft keep** can save a scope-deficient paste/harvest. UI setup-token still unwired. |
| beginAdd prior=nil | P2 | Any non-empty harvest accepted; global-session clone still **pass** if smoke 200. |
| Live CLI / HTTP / KC | — | `runLogin`, `runLogout`, `probeUsage`, token POST, `deleteScopedKeychainItem` account attribute: not unit-tested (by design). |
