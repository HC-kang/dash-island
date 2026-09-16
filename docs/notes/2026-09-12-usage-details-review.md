# 클릭 상세와 codex-island 선별 도입 검토

2026-09-12. Dash Island `3e635eb`, 로컬 codex-island `1a0634d`(0.2.5, 9월 10일) 기준. 원격 최신 여부는 확인하지 않았다. 앱 코드는 변경하지 않았다.

## 판단

클릭 상세는 유용하다. 계정별 잔량을 빠르게 보는 현재 링은 유지하고, 클릭으로 여는 작은 패널에 사용량의 원인을 설명한다. 우선순위는 **얼마나 남았나 → 언제 다시 쓸 수 있나 → 어떤 모델을 얼마나 썼나**다.

비용은 로컬 토큰 기록에 단가를 적용한 **API 환산 추정액**이다. 구독 청구액이나 계정의 전체 사용량으로 표현하지 않는다. 모델별 토큰 비율을 구독 한도 소모 비율로 해석하지 않는다.

## 최근 변경에서 선별할 것

| 변경 | 가져올 가치 | Dash Island 적용 판단 |
| --- | --- | --- |
| `b5bbd84` 9/10: usage ledger와 Claude 기록 복구 | 로그가 사라져도 사용량 이력이 유지됨 | 비용 기능과 함께 저장·중복 방지 핵심 도입. 외부 기록 복구 UI는 보류 |
| `ceadf27` 9/8: Grok·Antigravity 로컬 비용 reader | JSONL/SQLite에서 모델별 사용량 추출 | Claude/Codex 이후 실제 기록 범위 검증해서 확장 |
| `d577547` 9/8: 기간별 사용 이력 | 오늘/최근 7일/최근 30일 비교 | 짧은 추이만 도입. 연간 달력은 초기 상세에서 제외 |
| `3b6121f`, `b58e970` 9/8: 콘텐츠 크기·렌더링 개선 | 패널 여백과 스크롤 성능 | 원칙만 재사용. 현재 고정 캔버스/드래그 구조에 전체 carousel 이식은 부적합 |
| `718ddda` 9/8: Grok/Agy quota 정정 | 실제 backend·월간 fallback 정확성 | Agy daily host, Grok 헤더·월간 fallback은 현재 앱에도 있음. 통째 이식 불필요 |
| `8ce6dcb`, `dfa8ec9` 9/10: 공유 카드·30일 범위 | 사용량 공유 | 현재 목적과 거리가 있어 보류 |
| `201a45f` 및 8월 quota window 수정 | 데이터 없음과 실제 0 구분 | 상세의 정확성에 직접 필요. 아래 현재 앱의 빈 값 처리부터 보완 |

모델별 집계는 최신 신규 기능에만 있는 것이 아니다. 기존 `Sources/Cost/{TokenEvent,ClaudeLogReader,CodexLogReader,CostSummary,CostUsage,Pricing,PricingCatalog}.swift`와 `Sources/Views/ProviderBreakdown.swift`가 핵심 참고다. `CostStore`는 공급자 단위이고 `TokenEvent`에 계정 ID가 없으므로 그대로 계정 상세에 연결할 수 없다.

## 실제 가능한 데이터

- Claude: `message.model`, `message.usage`의 입력·출력·캐시 쓰기·읽기. 안정적인 message/request ID로 streaming 중복 제거 가능.
- Codex: `turn_context.payload.model`, `event_msg.token_count` 사용량. 현재 로그의 캐시 쓰기와 반복된 누적 스냅샷까지 처리해야 함.
- Grok: 원본 reader는 `updates.jsonl`의 완료된 `_meta.modelUsage`를 읽는다. 파일 존재만으로 모든 호출의 비용을 얻는다고 보장할 수 없음.
- Antigravity: 원본 reader는 대화 SQLite의 `gen_metadata`를 읽고 protobuf 필드를 해석한다. 하나의 호출이 여러 step에 나타나므로 step 합산 금지.
- 계정별 quota는 현재 API 데이터로 가능. 계정별 비용은 로그의 소유 계정이 확인되는 범위만 가능. 전역 로그는 **이 Mac의 Codex 사용량** 같은 별도 범위로 보여준다. 현재 로그인 계정으로 과거 기록을 소급 귀속하지 않는다.
- 다른 기기·웹 사용·누락된 로컬 기록은 이 합계에 포함된다고 보장할 수 없다.

로컬 기본 경로에서 Codex JSONL 628개, Claude JSONL 206개, Grok JSONL 1,749개, Agy DB 14개 존재 확인. Codex/Claude 각각 최근 파일 3개의 최대 4MB 꼬리 부분에서 사용량 이벤트 38/433개 확인. 이는 전체 사용량 계산이 아닌 형식 표본 검증이다. 대화 본문·인증 정보는 출력하지 않았다. Grok/Agy는 파일 존재까지만 검증했다.

## 그대로 가져오면 틀리는 부분

1. **Codex 중복 이벤트:** 실제 표본에 연속된 동일 누적 사용량이 있었다. 합성 fixture로 원본 `CodexLogReader`를 실행하니 같은 누적/직전 사용량을 두 시각에 기록한 경우 이벤트 2개로 합산했다. ledger의 재스캔 중복 방지는 이 파일 내부 중복을 해결하지 않는다. 모델 전환·누적 초기화·fork까지 고려한 이벤트 식별이 필요하다.
2. **캐시 쓰기 누락:** 실제 Codex 로그에 `cache_write_input_tokens`가 있으나 원본 reader는 `cacheCreationTokens: 0`을 고정한다. 20토큰을 넣은 fixture에서도 0으로 나왔다. 현재 스키마의 입력 포함 관계를 확인해 서로 겹치지 않는 항목으로 정규화해야 한다.
3. **알 수 없는 모델:** 원본은 모델이 없으면 `gpt-5.4`로 가정하고, 가격이 없으면 계산 함수에서 0을 반환한다. Dash Island에서는 모델 미상/가격 미등록을 별도 상태로 유지하고 부분 합계임을 알린다.
4. **요금 조건:** `TokenEvent`는 service tier, speed, 캐시 TTL 등 모든 가격 조건을 보존하지 않는다. 실제 Claude 표본에는 이 중 일부 필드가 존재한다. 단가표만 복사해 청구액 수준 정확성을 약속할 수 없다. 가격 출처·기준일과 추정 범위를 남긴다.
5. **계정/단위 혼동:** 현재 `ClaudeActivity`의 전역 로그 fallback은 바늘의 활동 신호다. 계정별 비용 근거로 재사용하지 않는다. 현재 Grok 월간 금액성 값도 `usedTokens/limitTokens`에 저장하므로 상세 토큰 합계에 합산하면 안 된다.

표준 계산은 서로 겹치지 않는 입력·출력·캐시 항목별 토큰 × 해당 단가의 합이다. 공급자별 포함 관계, 모델·가격 조건이 확인된 부분만 계산한다.

공식 가격 구조 참고: [OpenAI token categories](https://help.openai.com/en/articles/4936856), [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing). 이 검토에서는 특정 모델의 현재 단가 정확성을 인증하지 않았다.

## 추천 정보 구조와 표현

1. **평소:** 현재 계정 링과 활동 바늘.
2. **호버:** 잔량 + 리셋까지 시간. 아래에 작게 ‘클릭하여 상세’. 모노스페이스 진단 문구가 주인공이 되지 않게 한다.
3. **클릭:** 선택 계정에 연결된 380–420pt 폭의 작은 상세 패널. 포인터가 벗어나도 유지하며 Escape·닫기·바깥 클릭으로 닫는다. 패널 높이는 화면 안으로 제한하고 필요한 경우 내부 스크롤.

패널 위에서 아래로:

- 공급자·계정 이름, 플랜, 조용한 갱신 상태.
- **이 계정의 한도:** Weekly 잔량을 큰 숫자와 얇은 막대로 표시. 오른쪽 리셋 시간. 보고된 Session·Spark 창은 아래에 짧은 행. 링을 다시 크게 복제하지 않는다.
- **사용 기록 범위:** 계정에 귀속되면 계정 기록, 불명확하면 ‘이 Mac의 Codex 사용량’처럼 범위를 분명히 구분. 오늘 / 7일 / 30일 선택.
- 선택 기간의 토큰 합계와 API 환산 추정액. 캐시 포함 여부를 작은 설명으로 표시.
- 짧은 시간별/일별 사용량 막대. 날짜·값을 확인할 수 있게 하되 그래프 없이도 핵심 숫자를 읽을 수 있게 한다.
- 모델별 상위 3행: 이름 / 토큰 / 환산액. 공통 척도의 가로 막대로 기여도 비교. 나머지는 ‘모두 보기’, 모델 행 클릭은 입력·출력·캐시 구성 disclosure.
- 하단 작은 출처·가격 기준일·부분 수집 상태. 사용량이 없으면 빈 상태, 가격이 없으면 ‘미산정’.

시각적으로 현재 검정 island의 배경·브랜드 색을 이어가고 모델마다 무지개색을 추가하지 않는다. 숫자는 자릿수 정렬, 텍스트는 읽기 좋은 일반 서체. 강조는 잔량과 선택 기간의 핵심 수치에 제한한다. 기존 `CostSparkline`은 누적액이라 항상 상승한다. ‘언제 많이 썼나’를 설명하려면 시간 버킷의 증분 막대가 적합하다. 원본 모델별 막대도 모델마다 자기 주간량으로 정규화되므로 기여도 비교용으로 그대로 가져오지 않는다.

## 참고 이미지에서 선택

- 채택: Weekly 중심 위계, 가까운 리셋 정보, 짧은 추이, 보조 한도의 점진적 공개.
- 현재 앱에서 보완: `CodexAdapter.parseAdditionalRateLimits`는 각 모델의 `primary_window`만 읽는다. Spark Weekly를 표시하려면 `secondary_window`도 보존하고 모델+기간으로 식별해야 한다.
- 빈 값 보완: Codex primary 누락 시 현재 0%를 만들고, window 내부 퍼센트 누락도 0으로 처리한다. ‘수집 안 됨’을 ‘100% 남음’으로 표시하지 않게 한다.
- 후순위: `~52% left at reset`. quota 시계열이 충분히 쌓이고 reset/오래된 샘플을 처리한 후 제한적으로 제공. 현재 바늘의 로컬 활동 heuristic을 잔량 예측에 사용하지 않는다.
- 리셋 크레딧: 참고 레포에 `CodexResetCredits`가 있으므로 실제 응답 지원 시 만료 시간을 고려해 한도 부족 시에만 작은 보조 행으로 노출. 첫 화면 상시 정보로는 우선순위 낮음.
- 생략: Today/Yesterday/30일 합계를 한 화면에 모두 나열, 큰 Status/Dashboard 버튼, 초기 연간 heatmap·공유 카드·스타일 선택.

## 구현 시 최소 범위와 검증

먼저 단일 클릭 패널 + 정확한 quota/빈 값 처리, 이어서 Claude/Codex 로컬 사용량·모델별 집계·오늘/7일/30일을 넣는 범위를 추천한다. 사용 이력 보존은 비용 기능과 함께 제공한다.

현재 `GaugeClusterView`는 6pt부터 드래그하며 tooltip은 `allowsHitTesting(false)`다. tooltip에 클릭 핸들러만 넣는 방식은 작동하지 않는다. 계정 셀에 클릭 동작을 추가하고 drag·오른쪽 메뉴와 공존시켜야 한다. `IslandRootView`의 280ms 자동 접힘과 고정 캔버스는 상세 패널의 포커스/수명과 연결해야 한다. 네이티브 popover/panel이 첫 검토 대상이며 전체 island 레이아웃 확대는 피한다.

성능: 클릭 직후 기존 quota·캐시를 먼저 표시하고 로컬 집계는 백그라운드. hover마다 전체 로그 재스캔 금지. 이력에는 사용량 메타데이터만 저장하며 공급자/소스/계정 귀속을 보존한다.

이번 관측 검증:

- 원본 `bash scripts/test-usage-ledger.sh`: **47 checks 통과**. 로그 삭제 후 유지, streaming 중복, 재시도, 오래된 작업, 저장 실패·rollback 등을 포함.
- 임시 Swift fixture로 원본 Codex reader 직접 실행: 동일 누적 스냅샷 2개 → 2개 이벤트; 캐시 쓰기 20 → 0. fixture와 바이너리는 임시 디렉터리 정리됨.
- 실제 앱 클릭/패널 시각 검증은 아직 수행하지 않았다. 이 문서는 도입 판단이며 구현 완료 보고가 아니다.

실제 이식 시 원본 MIT 저작권·라이선스 고지를 보존한다. 인증 코드와 원본 레포는 이 작업 범위에서 수정하지 않는다.

## 구현 후 확인 (2026-09-12)

- 클릭 상세에 오늘/7일/30일, 추이, 모델별 토큰·캐시 구성과 API 환산액을 구현했다. 로컬 이력은 메타데이터만 보존한다. Claude/Codex뿐 아니라 Grok과 Antigravity도 지원한다.
- 실제 Grok 로그는 원본 reader의 형식과 달리 `params.update.sessionUpdate=turn_completed`, `usage.modelUsage`, `cachedReadTokens`를 사용했다. 이 형식을 추가하고 `costUsdTicks / 10^10`의 기록된 API 비용을 우선한다. Agy는 SQLite/WAL의 generation 메타데이터를 읽으며 thinking 중복 합산을 피한다.
- 사용자 피드백: 같은 벤더 계정에 동일 합계를 보여주는 기본값은 혼동을 만든다. 기본은 해당 계정의 관리 폴더만 읽고, 공용 로그는 “All … on this Mac” 선택으로 분리했다. 계정 식별자가 없는 공용 로그는 임의로 귀속시키지 않는다. quota는 기존처럼 계정별 API 응답이다.
- 사용자 요청으로 Codex 리셋권 횟수를 툴팁·상세에 추가했다. `/wham/rate-limit-reset-credits`에 기존 계정 토큰과 `ChatGPT-Account-Id`를 사용한 실제 GET에서 두 계정 각각 1개/3개를 확인했다. 실패·미지원은 0개가 아닌 미확인이다. 리셋권 사용 동작은 추가하지 않았다.
- 툴팁을 viewport 안으로 이동시킨 첫 수정은 사용자 요구와 달랐다. 위젯 중심을 유지하고 중복된 root mask를 제거했다. 이미 별도로 존재하는 gauge 행의 clip은 유지하며, 툴팁 overlay는 기존 투명 canvas에 그린다. 표시 공간과 hover 유지 영역을 분리하여 아래쪽 유지 범위는 20pt다.

## 계정별 실수집 연결 (후속 요청)

사용자가 Orca와 일반 CLI 양쪽에서 계정별 수집을 요청했다. 폴더 기반 귀속을 추가 조사한 결과 Orca Codex는 다른 계정의 로그를 hardlink로 공유하므로, 계정 폴더 전체를 해당 계정의 소비로 취급하면 안 된다. Claude의 비슷한 합계는 별도 인증 갱신용 호출들이었으며 작업 사용량과 분리했다.

Codex/Claude는 공식 완료 이벤트를 로컬 OTLP/JSON 수집기에 연결했다. [Codex의 OTel 이벤트](https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry), [Claude의 계정 식별자·API 요청 이벤트](https://code.claude.com/docs/en/monitoring-usage#api-request-event)를 참고했다. 실행 시점의 로그인 파일을 추측하는 대신 각 호출이 보고한 계정 ID로 연결한다. 설치 도구 `scripts/connect-usage.py`, 수집기 `scripts/usage-collector.py`, 앱 조회 `AccountUsageReader`가 이 경로를 담당한다. 일반 CLI 홈, Orca 전용 홈, Dash 전용 홈 12곳을 실제 연결했다. 기존 프로세스는 시작 설정을 다시 읽도록 재실행해야 한다.

Grok/Agy는 명시적으로 선택한 계정 홈에서 실행하는 `account-cli` 경로를 제공한다. 일반 터미널과 Orca 터미널 모두 동일한 명령을 사용할 수 있다. 이 명령을 거치지 않은 공용 로그까지 자동 계정 귀속한다고 주장하지 않는다.

검증: Swift 170개 통과, Python 수집·중복·계정분리·설정 보존·실행 환경 검증 통과. 실제 Codex CLI의 null body/0 timeUnixNano 형식을 재현하고 event.timestamp로 처리했다. 실제 호출 수집 후 앱에서 Codex personal 30.6K/$0.31, Claude Dev 8.8K/$0.02 표시를 확인했고 다른 계정에는 합산되지 않았다. 숫자는 검증 시점이며 이후 호출에 따라 변한다. Claude의 정확한 원본 합계 8,779 tokens/$0.016881와 수집값이 일치했다.
