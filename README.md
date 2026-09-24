# Dash Island

**[English](#english)** · **[한국어](#한국어)**

macOS notch / menu-bar island for **multi-vendor, multi-account** AI usage limits.

macOS 노치·메뉴바 아일랜드 — **여러 벤더·여러 계정** AI 사용량 한도를 한눈에.

| | |
|--|--|
| Vendors / 벤더 | **Claude** · **Codex** · **Grok** · **Antigravity** |
| Accounts / 계정 | Up to **20** stored, **5** visible at once (scroll for more) |
| Store / 스토어 | **Not** on the Mac App Store — build from source (GitHub) |
| Sign / 서명 | Ad-hoc (`codesign -s -`) |

**Principles / 원칙:** simplicity → practicality → elegance.

---

<a id="english"></a>

## English

### Requirements

| | |
|--|--|
| Mac | **Apple Silicon** (arm64) |
| OS | macOS **13** Ventura or later |
| Tools | Xcode Command Line Tools (`swiftc`, `codesign`) |

```bash
xcode-select --install   # if swiftc is missing
```

Optional CLIs (only needed when **adding** accounts from the app):

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [OpenAI Codex](https://github.com/openai/codex) (`codex`)
- [Grok](https://grok.com) CLI (`grok`)

### Build from source

```bash
git clone https://github.com/HC-kang/dash-island.git
cd dash-island
./build.sh
open build/DashIsland.app
```

Produces `build/DashIsland.app`:

- Bundle id: `dev.dashisland.DashIsland`
- Menu-bar agent (`LSUIElement` — no Dock icon)
- Ad-hoc signature for local / GitHub use

#### First open on another Mac

Gatekeeper may block ad-hoc apps:

1. **System Settings → Privacy & Security** → Open Anyway, or  
2. Right-click → **Open**, or  

```bash
xattr -dr com.apple.quarantine build/DashIsland.app
open build/DashIsland.app
```

#### Install (optional)

```bash
cp -R build/DashIsland.app /Applications/
# or ~/Applications/
```

**Launch at Login** is in Preferences (gear in the notch ears when expanded).

### How to use

1. Hover the island (or the top-center bar on non-notch displays) to expand.
2. **+** / chevron → add Claude, Codex, or Grok.  
   Credentials are stored under a **managed** folder (not your default CLI home):

   ```text
   ~/Library/Application Support/DashIsland/
     accounts.json
     accounts/<uuid>/     # per-account tokens (files only)
   ```

3. **Rings** = quota used or remaining (prefs). **Red needle** = burn pace vs even “cruise”.
4. Gear in the notch ear → display mode, rim accent, target display, launch at login.

Click an account for a persistent detail panel: quota/reset times, Today / 7 days / 30 days, and model-level tokens with expandable input/output/cache totals. Claude, Codex, Grok, and Antigravity read local records. Details show only the clicked account, with no source selector. Codex/Claude totals use completed-call telemetry filtered by provider account ID. Shared historical logs are never assigned to the currently logged-in account. Grok/Antigravity use a dedicated account CLI home. Codex also shows available rate limit resets per account. Cost figures are API equivalents, not subscription charges; Grok uses recorded API values where available, and missing prices remain unpriced. Usage metadata is retained under `usage-history/` in the app's Application Support folder for 400 days, even if source logs disappear; the collector database uses the same 400-day window. Click the same account again to close its detail panel; click another account to switch. Escape and clicks outside the app also close it. The island's hover margin extends only 20pt below its visible body.

To connect account tracking for both ordinary CLI sessions and Orca sessions, run `python3 scripts/connect-usage.py` (Python 3.11+). It preserves settings, backs up changed files, configures local OTLP/JSON export for Codex/Claude, and installs a login-time collector on `127.0.0.1:43190`. Reopen existing CLI/Orca agent sessions once; already-running processes cannot inherit new startup settings. The collector keeps only account identity hashes, model/token/cost metadata and event IDs in `tracking/account-usage.sqlite`. It does not save prompts, tool outputs or credentials. The app need not remain open. Run the connector again after adding a new custom CLI home, and after updating Dash Island: it replaces an older installed collector (`tracking/collector-status.json` shows the running version). The LaunchAgent runs the collector with the Python that ran the connector; run the connector again if that Python is removed. Rows older than 400 days are deleted. If a running Claude process has its login changed externally, its reported account identity can stay stale. Reopen it after selecting the account, or launch it with the dedicated `account-cli` command below; historical records cannot prove which account was billed.

For an explicitly selected account in either a normal terminal or an Orca terminal, run `"$HOME/Library/Application Support/DashIsland/tracking/account-cli" <account-id-prefix> [CLI arguments]`. Running it without arguments lists accounts; Grok/Antigravity empty states also provide “Copy command for this account”. This selects the account's CLI home and removes competing API-key and provider-routing variables (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`/`VERTEX`/`FOUNDRY`). Other variables, proxies, and files outside that home stay shared. Antigravity reads its login only from `$HOME`, so the whole `agy` session runs with the account folder as `HOME`: git keeps your global config through `GIT_CONFIG_GLOBAL`, but other tools the agent runs do not find their `~` settings. Plain Grok/Antigravity launches outside that home are not attributed to the selected account.

To undo the connection, run `python3 scripts/connect-usage.py --disconnect`. It removes only the settings it added: a value that existed before connecting comes back, and later edits stay. It also stops and removes the LaunchAgent and deletes the collector token. Captured usage and config backups stay in `tracking/`.

The connector writes the local collector token into each CLI config file (`config.toml`, `settings.json`) and sets those files to mode 0600. The token only allows writes to the loopback collector, but do not commit these files to a dotfiles repository. A symlinked config file is written through its link.

Codex/Claude account figures include captured calls only: a process started before telemetry was configured also omits its **new** calls until reopened. Previously collected shared transcript archives remain on disk, but are not shown in account details. This does not retroactively prove which account paid for a shared call.

Collector checks: `python3 scripts/test-usage-collector.py`. Config backups are stored under `tracking/config-backups/`.


#### Claude authentication (important)

| Method | Works for usage meter? |
|--------|------------------------|
| Browser OAuth: `claude auth login --claudeai` (with managed `CLAUDE_CONFIG_DIR`) | **Yes** — needs `user:profile` for `/api/oauth/usage` |
| `claude setup-token` (long-lived, model-only) | **No** — Anthropic returns 403 missing scope |

If access expires, the app prefers a long **token quiet** period (last-good rings stay) over hammering OAuth refresh (which often returns **429**). Use **Reauthenticate** (browser login) for that account — not setup-token. Each Claude account stores credentials in its own managed folder. Claude CLI on macOS writes login tokens to Keychain only; Dash copies that item into the folder once after Add/Reauth, then polls the file.

Codex and Grok use their own managed OAuth/session refresh where supported.

### Demo mode (no real accounts)

```bash
DASHISLAND_DEMO=1 open build/DashIsland.app
DASHISLAND_DEMO=1 DASHISLAND_DEMO_COUNT=5 open build/DashIsland.app
```

`DASHISLAND_DEMO_COUNT` ∈ `1` | `3` | `5` (default `3`).

### Privacy and network

Dash Island has no telemetry and no server of its own. It talks only to:

| What | Hosts |
|--|--|
| Usage readings (your own accounts) | `api.anthropic.com`, `chatgpt.com`, `cli-chat-proxy.grok.com`, `cloudcode-pa.googleapis.com` |
| Token refresh for managed accounts | `console.anthropic.com`, `platform.claude.com`, `auth.openai.com`, `auth.x.ai`, `oauth2.googleapis.com` |
| Vendor status pages | `status.claude.com`, `status.openai.com`, `status.x.ai` |
| Model price catalog (API-equivalent cost), cached daily | `ericjypark.github.io` (codex-island's public catalog; the bundled copy is used offline) |
| Local usage collector (optional) | `127.0.0.1:43190` only |

Credentials stay in `~/Library/Application Support/DashIsland/accounts/` (folders 0700, files 0600). Logs and `status.json` never contain tokens or response bodies.

### Logs

- File: `~/Library/Application Support/DashIsland/logs/dashisland.log` (2 MB × 3 rotation). Also mirrored to the unified log (`log show --predicate 'subsystem == "dev.dashisland.DashIsland"'`).
- Level: `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug` (or `DASHISLAND_LOG=debug` in the env). Values: `debug info warn error`. Default `info`. Restart the app to apply.
- Tail: `scripts/logs.sh`, follow: `scripts/logs.sh -f`, filter: `scripts/logs.sh -f fetch`.
- The log never contains tokens or response bodies.

### Status file

`~/Library/Application Support/DashIsland/status.json` mirrors what the island shows, for scripts (sketchybar, tmux, Raycast). It is rewritten after each update, owner-only (0600), and holds only account id (8 chars), label, vendor, health, window percents, reset times, and freshness. No tokens.

### Tests

```bash
./scripts/run-tests.sh
# Native rendering + drag regression (briefly opens an isolated fake-widget window).
bash scripts/check-widget-render.sh
```

### Version

Single line in [`VERSION`](VERSION) (`X.Y.Z`). Injected into `Info.plist` by `build.sh`.

### What this repo is *not* (yet)

| | |
|--|--|
| Mac App Store | No |
| Developer ID / notarization | No (ad-hoc only) |
| Sparkle auto-update | Plan only: `docs/notes/SPARKLE-HOMEBREW-PLAN.md` |
| Homebrew cask | Not public yet |

**v0 distribution:** clone → `./build.sh` → `open`.

Optional later: GitHub Release zips → notarized Developer ID → Sparkle → Homebrew.

### Design

- Spec: [`docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`](docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md)
- Polling: ~15m background; lazy refresh on expand; long quiet after vendor **429**

### License

MIT — see [LICENSE](LICENSE). Third-party code and marks: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

<a id="한국어"></a>

## 한국어

### 요구 사항

| | |
|--|--|
| Mac | **Apple Silicon** (arm64) |
| OS | macOS **13** Ventura 이상 |
| 도구 | Xcode Command Line Tools (`swiftc`, `codesign`) |

```bash
xcode-select --install   # swiftc 없을 때
```

계정 **추가** 시에만 선택적으로 필요:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [OpenAI Codex](https://github.com/openai/codex) (`codex`)
- [Grok](https://grok.com) CLI (`grok`)

### 소스에서 빌드

```bash
git clone https://github.com/HC-kang/dash-island.git
cd dash-island
./build.sh
open build/DashIsland.app
```

결과물: `build/DashIsland.app`

- 번들 ID: `dev.dashisland.DashIsland`
- 메뉴바 에이전트 (`LSUIElement` — Dock 아이콘 없음)
- 로컬/GitHub용 **ad-hoc** 서명

#### 다른 Mac에서 처음 열 때

Gatekeeper가 ad-hoc 앱을 막을 수 있습니다.

1. **시스템 설정 → 개인정보 보호 및 보안** → 확인 후 열기, 또는  
2. 우클릭 → **열기**, 또는  

```bash
xattr -dr com.apple.quarantine build/DashIsland.app
open build/DashIsland.app
```

#### 설치 (선택)

```bash
cp -R build/DashIsland.app /Applications/
# 또는 ~/Applications/
```

**로그인 시 실행**은 환경설정(확장 시 노치 귀 쪽 톱니)에서 켤 수 있습니다.

### 사용 방법

1. 아일랜드(또는 노치 없는 디스플레이의 상단 중앙 바)에 호버하면 확장됩니다.
2. **+** / chevron으로 Claude · Codex · Grok 계정을 추가합니다.  
   자격 증명은 **앱 전용 managed 폴더**에 저장됩니다 (기본 CLI 홈이 아님).

   ```text
   ~/Library/Application Support/DashIsland/
     accounts.json
     accounts/<uuid>/     # 계정별 토큰 파일만
   ```

3. **링** = 할당량 사용/잔여(설정). **빨간 바늘** = 고른 소진(cruise) 대비 소진 속도.

계정을 클릭하면 잔량·리셋, 오늘/7일/30일 사용량, 모델별 토큰·비용 상세가 열립니다. 모델 행을 누르면 입력·출력·캐시 구성이 펼쳐집니다. Claude·Codex·Grok·Antigravity의 로컬 기록을 지원합니다. Codex·Claude 계정별 수치는 호출 당시 계정 ID가 포함된 완료 이벤트로 집계합니다. 상세 화면은 선택 상자 없이 클릭한 계정의 사용량만 보여줍니다. 과거 공용 기록은 계정별 수치에 포함하지 않으며, 기존 로그 이력 파일은 보존합니다. Grok·Antigravity는 계정 전용 CLI 홈을 사용합니다. Codex 리셋권 잔여 횟수도 계정별로 표시합니다. 비용은 구독 청구액이 아닌 API 환산액이고, Grok은 기록된 API 비용을 우선 사용합니다. 가격 미상은 미산정으로 남깁니다. 원본 로그가 지워져도 수집한 이력은 보존됩니다. Escape 또는 바깥 클릭으로 상세를 닫습니다. 호버 유지 범위는 아일랜드 아래 20pt입니다.
4. 노치 귀 톱니 → 표시 모드, 림 색, 디스플레이, 로그인 시 실행.

일반 CLI와 Orca 세션의 계정별 수집을 연결하려면 `python3 scripts/connect-usage.py`를 실행합니다(Python 3.11 이상). 이 스크립트는 기존 설정을 보존하고 바꾸는 파일을 백업합니다. 그리고 Codex/Claude의 로컬 OTLP/JSON 전송과 `127.0.0.1:43190` 수집기(LaunchAgent)를 설치합니다. 이미 실행 중인 CLI/Orca 세션은 한 번 다시 열어야 합니다. 새 CLI 홈을 추가한 뒤와 Dash Island를 업데이트한 뒤에도 다시 실행하세요. 설치된 수집기가 더 오래된 버전이면 교체합니다(`tracking/collector-status.json`에 실행 중인 버전이 있습니다). 수집기는 커넥터를 실행한 Python으로 동작합니다. 그 Python을 지웠다면 커넥터를 다시 실행하세요. 400일보다 오래된 기록은 삭제합니다.

연결을 해제하려면 `python3 scripts/connect-usage.py --disconnect`를 실행합니다. 커넥터가 추가한 설정만 지웁니다. 연결 전에 있던 값은 되돌리고, 이후에 바꾼 값은 유지합니다. LaunchAgent와 수집기 토큰도 제거합니다. 수집한 사용량과 설정 백업은 `tracking/`에 남습니다.

CLI 설정 파일(`config.toml`, `settings.json`)에는 로컬 수집기 토큰이 기록되고, 파일 권한은 0600이 됩니다. 이 토큰은 루프백 수집기에 쓰는 권한만 있습니다. 그래도 이 파일들을 dotfiles 저장소에 커밋하지 마세요. 심볼릭 링크인 설정 파일은 링크 대상에 씁니다.

특정 계정으로 CLI를 실행하려면 `"$HOME/Library/Application Support/DashIsland/tracking/account-cli" <계정-ID-접두어> [CLI 인수]`를 실행합니다. 이 명령은 계정의 CLI 홈을 선택하고, API 키와 라우팅 변수(`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`/`VERTEX`/`FOUNDRY`)를 제거합니다. 그 밖의 환경 변수, 프록시, 홈 밖의 파일은 공유됩니다. Antigravity는 `$HOME`에서만 로그인을 찾습니다. 그래서 `agy` 세션 전체가 계정 폴더를 `HOME`으로 봅니다. git은 `GIT_CONFIG_GLOBAL`로 사용자 전역 설정을 유지하지만, 에이전트가 실행하는 다른 도구는 `~` 설정을 찾지 못합니다.

#### Claude 인증 (중요)

| 방식 | 사용량 미터에 사용 가능? |
|------|--------------------------|
| 브라우저 OAuth: managed `CLAUDE_CONFIG_DIR`에서 `claude auth login --claudeai` | **가능** — `/api/oauth/usage`에 `user:profile` 필요 |
| `claude setup-token` (장기, 모델 전용) | **불가** — Anthropic이 403 (스코프 부족) |

access가 만료되면 앱은 OAuth refresh를 무리하게 두드리지 않고 (**429** 흔함) **token quiet** + 마지막 정상 링을 유지하는 쪽을 택합니다.  
해당 계정으로 Claude Code를 한 번 열거나, **Reauthenticate → 브라우저 로그인**을 쓰세요. setup-token은 쓰지 마세요.

Codex / Grok는 지원되는 범위에서 managed OAuth·세션 refresh를 사용합니다.

### 데모 모드 (실제 계정 없음)

```bash
DASHISLAND_DEMO=1 open build/DashIsland.app
DASHISLAND_DEMO=1 DASHISLAND_DEMO_COUNT=5 open build/DashIsland.app
```

`DASHISLAND_DEMO_COUNT` ∈ `1` | `3` | `5` (기본 `3`).

### 개인정보와 네트워크

Dash Island는 텔레메트리를 보내지 않고, 자체 서버도 없습니다. 앱은 다음 주소와만 통신합니다.

| 용도 | 호스트 |
|--|--|
| 사용량 조회(사용자 본인 계정) | `api.anthropic.com`, `chatgpt.com`, `cli-chat-proxy.grok.com`, `cloudcode-pa.googleapis.com` |
| 관리 계정의 토큰 갱신 | `console.anthropic.com`, `platform.claude.com`, `auth.openai.com`, `auth.x.ai`, `oauth2.googleapis.com` |
| 벤더 상태 페이지 | `status.claude.com`, `status.openai.com`, `status.x.ai` |
| 모델 가격표(API 환산 비용), 하루 한 번 캐시 | `ericjypark.github.io` (codex-island의 공개 가격표; 오프라인에서는 동봉 사본 사용) |
| 로컬 사용량 수집기(선택) | `127.0.0.1:43190`만 사용 |

자격 증명은 `~/Library/Application Support/DashIsland/accounts/`에 저장됩니다(폴더 0700, 파일 0600). 로그와 `status.json`에는 토큰과 응답 본문이 기록되지 않습니다.

### 로그

- 파일: `~/Library/Application Support/DashIsland/logs/dashisland.log` (2 MB × 3 회전). 통합 로그에도 같은 내용이 기록됩니다 (`log show --predicate 'subsystem == "dev.dashisland.DashIsland"'`).
- 레벨: `defaults write dev.dashisland.DashIsland DashIsland.logLevel debug` 또는 환경 변수 `DASHISLAND_LOG=debug`. 값은 `debug info warn error`이고 기본값은 `info`입니다. 앱을 다시 시작해야 적용됩니다.
- 보기: `scripts/logs.sh`, 따라가기: `scripts/logs.sh -f`, 필터: `scripts/logs.sh -f fetch`.
- 로그에는 토큰과 응답 본문이 기록되지 않습니다.

### 상태 파일

`~/Library/Application Support/DashIsland/status.json`에는 island가 보여 주는 값이 기록됩니다. sketchybar, tmux, Raycast 같은 스크립트가 이 파일을 읽을 수 있습니다. 갱신할 때마다 다시 쓰고, 권한은 소유자 전용(0600)입니다. 계정 ID(8자), 라벨, 벤더, 상태, 창별 사용률, 리셋 시각, 갱신 여부만 담고, 토큰은 담지 않습니다.

### 테스트

```bash
./scripts/run-tests.sh
```

### 버전

[`VERSION`](VERSION) 한 줄 (`X.Y.Z`). `build.sh`가 `Info.plist`에 넣습니다.

### 아직 없는 것

| | |
|--|--|
| Mac App Store | 없음 |
| Developer ID / 공증 | 없음 (ad-hoc만) |
| Sparkle 자동 업데이트 | 계획만: `docs/notes/SPARKLE-HOMEBREW-PLAN.md` |
| Homebrew cask | 공개 탭 미연결 |

**v0 배포 모델:** clone → `./build.sh` → `open`.

이후 선택: GitHub Release zip → 공증 Developer ID → Sparkle → Homebrew.

### 설계

- 스펙: [`docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md`](docs/superpowers/specs/2026-07-19-multi-vendor-usage-island-design.md)
- 폴링: 백그라운드 약 15분, 확장 시 lazy refresh, 벤더 **429** 후 긴 quiet

### 라이선스

MIT — [LICENSE](LICENSE)를 보세요. 외부 코드와 상표는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있습니다.
