# Dash Island

**[English](#english)** · **[한국어](#한국어)**

macOS notch / menu-bar island for **multi-vendor, multi-account** AI usage limits.

macOS 노치·메뉴바 아일랜드 — **여러 벤더·여러 계정** AI 사용량 한도를 한눈에.

| | |
|--|--|
| Vendors / 벤더 | **Claude** · **Codex** · **Grok** |
| Accounts / 계정 | Up to **5** (center-aligned gauges) |
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

Click an account for a persistent detail panel: quota/reset times, Today / 7 days / 30 days, and model-level tokens with expandable input/output/cache totals. Claude, Codex, Grok, and Antigravity read local records. Details show only the clicked account, with no source selector. Codex/Claude totals use completed-call telemetry filtered by provider account ID. Shared historical logs are never assigned to the currently logged-in account. Grok/Antigravity use a dedicated account CLI home. Codex also shows available rate limit resets per account. Cost figures are API equivalents, not subscription charges; Grok uses recorded API values where available, and missing prices remain unpriced. Usage metadata is retained under `usage-history/` in the app's Application Support folder even if source logs disappear. Click the same account again to close its detail panel; click another account to switch. Escape and clicks outside the app also close it. The island's hover margin extends only 20pt below its visible body.

To connect account tracking for both ordinary CLI sessions and Orca sessions, run `python3 scripts/connect-usage.py` (Python 3.11+). It preserves settings, backs up changed files, configures local OTLP/JSON export for Codex/Claude, and installs a login-time collector on `127.0.0.1:43190`. Reopen existing CLI/Orca agent sessions once; already-running processes cannot inherit new startup settings. The collector keeps only account identity hashes, model/token/cost metadata and event IDs in `tracking/account-usage.sqlite`. It does not save prompts, tool outputs or credentials. The app need not remain open. Run the connector again after adding a new custom CLI home. If a running Claude process has its login changed externally, its reported account identity can stay stale. Reopen it after selecting the account, or launch it with the dedicated `account-cli` command below; historical records cannot prove which account was billed.

For an explicitly selected account in either a normal terminal or an Orca terminal, run `"$HOME/Library/Application Support/DashIsland/tracking/account-cli" <account-id-prefix> [CLI arguments]`. Running it without arguments lists accounts; Grok/Antigravity empty states also provide “Copy command for this account”. This selects the account's CLI home and removes competing API-key environment variables. Plain Grok/Antigravity launches outside that home are not attributed to the selected account.

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

### Tests

```bash
./scripts/run-tests.sh
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

TBD — set before a public release tag (MIT is a common choice).

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

TBD — 공개 릴리스 태그 전에 정하세요 (이런 도구는 MIT가 흔합니다).
