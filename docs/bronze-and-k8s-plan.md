# Bronze + K8s 작업 계획

> 작성일 2026-06-22 · 확정 전제: **데이터 소스 5개 전부 / 유니버스 S&P 500 / Bronze 적재처 = 클러스터 내 PostgreSQL(`postgresql.data.svc.cluster.local:5432`) / 이번 세션 k8s 범위 = 계획 + 매니페스트 작성**

이 문서는 두 갈래로 구성됩니다.

1. **Part A — Bronze 데이터 소스 확정** (요청하신 "데이터 소스 한번 확실히 정리"). 소스별 스펙, 적재 스키마, 수집 DAG 설계.
2. **Part B — K8s 매니페스트 작성 계획.** 빈 매니페스트를 어떤 순서로 채울지 + 첨부 인프라 정보 반영.

---

## 인프라 좌표 (첨부 정보 정리)

| 레이어 | 항목 | 값 |
|---|---|---|
| 가상화 | Proxmox VE | `https://100.85.18.13:8006` |
| K8s | control-plane | `192.168.50.101` / Tailscale `100.92.70.32` |
| K8s | worker1 | `192.168.50.102` |
| K8s | worker2 | `192.168.50.99` |
| LB | Ingress VIP | `192.168.50.241` |
| 서비스 | MLflow | `mlflow.mlops.svc.cluster.local:5000` |
| 서비스 | PostgreSQL | `postgresql.data.svc.cluster.local:5432` |
| 서비스 | Airflow API Server | `airflow-api-server.airflow.svc.cluster.local:8080` |
| 포트포워드 | ArgoCD / MLflow / Airflow | `localhost:8080` / `5000` / `8082` |

**노드 역할 매핑(제안).** 계획서의 control/data/public 3역할을 현재 3노드에 매핑:

- `control-plane`(101) → control plane + ArgoCD
- `worker1`(102) → **data** 노드 (PostgreSQL, Airflow worker, Bronze 수집 Job)
- `worker2`(99) → **public** 노드 (Ingress, MLflow, 추론 API 등 외부 노출)

→ 각 노드에 label 부여 후 `nodeSelector`로 워크로드 분리. (Part B에서 매니페스트화)

---

# Part A — Bronze 데이터 소스 확정

## A-0. 설계 원칙

- **Bronze = 원본 보존.** 변환/정규화 금지. 외부에서 받은 그대로 + 수집 메타데이터(언제·어디서·해시)만 덧붙여 적재. 정제는 Silver의 책임.
- **멱등(idempotent) 수집.** 같은 (source, 자연키, as_of) 재수집 시 중복 행 생성 X — `content_hash` + upsert.
- **수집 실패는 데이터다.** 성공/실패/부분실패 모두 `bronze.ingestion_log`에 기록 → freshness 모니터링·fallback 판단 근거.
- **as-of 시각 보존.** 모든 행에 `as_of`(데이터 기준 시점)와 `ingested_at`(수집 시각) 분리 기록 → point-in-time 재현·audit log 연결.

## A-1. 소스 5개 명세표

| # | 소스 | Bronze 산출 | 주요 용도(다운스트림) | 페르소나 가치 |
|---|---|---|---|---|
| 1 | **yfinance** (Yahoo Finance) | S&P500 OHLCV 일봉 | 이벤트 수익률 라벨(`event_returns`), 거시 feature 일부, 변동성 | 종목 반응·시장 상태의 정량 근거 |
| 2 | **FRED** (St. Louis Fed) | 거시 시계열 | 거시 국면 분류 feature | "지금 시장이 어느 국면인가" |
| 3 | **SEC EDGAR** | 8-K 공시 메타 + 원문 | **이벤트 분류 모델 핵심 입력**, RAG evidence | "어젯밤 주목할 이벤트" |
| 4 | **Reddit** | 종목별 언급량 | attention spike(참고용, sentiment X) | "관심도 (참고용)" |
| 5 | **News** | 종목·시장 뉴스 메타 | 8-K 밖 이벤트 보강(Legal/Product), RAG 보조 evidence | 이벤트 맥락 보강 |

## A-2. 소스별 상세 스펙

### 1) yfinance — 가격
- **접근:** `yfinance` 파이썬 라이브러리(비공식 Yahoo 엔드포인트). API key 불필요.
- **대상:** S&P 500 구성종목 OHLCV(+adjusted close) 일봉. backfill로 과거 2~3년 확보(`scripts/backfill_historical.py`).
- **갱신 주기:** 일 1회, 미국장 마감 후(KST 익일 오전). DAG 스케줄과 정합.
- **rate limit:** 공식 명세 없음 → 배치(종목 묶음) + 짧은 sleep + 재시도. 과도 호출 시 일시 차단 위험.
- **raw 형태:** ticker, date, open/high/low/close/adj_close, volume.
- **fallback:** 재시도 후 실패 시 → Stooq 또는 Alpha Vantage 백업 소스(설계만, 1차는 재시도+로그). 직전일 데이터 carry-forward 금지(Silver에서 결측 처리).
- **주의:** **생존편향(survivorship bias).** S&P 500 구성종목은 시점마다 다름 → 유니버스 스냅샷을 날짜와 함께 보존(A-3 `sp500_constituents`).

### 2) FRED — 매크로
- **접근:** FRED REST API. **무료 API key 필요**(fred.stlouisfed.org → My Account). `fredapi` 라이브러리 사용.
- **대상 시리즈(국면 분류 feature 후보):**
  - `VIXCLS` (변동성), `DGS10`/`DGS2` (10년·2년 국채금리), `T10Y2Y` (장단기 스프레드)
  - `BAMLH0A0HYM2` (HY 신용 스프레드 OAS), `FEDFUNDS` (정책금리)
  - `UNRATE` (실업률), `CPIAUCSL` (CPI), `T10YIE` (기대인플레)
  - PMI: FRED 무료 제공 제한적 → ISM 직접 또는 대체 프록시는 Week 2에 확정
- **갱신 주기:** 시리즈별 상이(일별 금리/VIX vs 월별 CPI/실업률). DAG에서 시리즈별 스케줄 분리 또는 일 1회 폴링 후 신규 관측만 upsert.
- **rate limit:** 120 req/min. 시리즈 수가 적어 여유.
- **raw 형태:** series_id, date(관측일), value, realtime_start/end(개정 추적).
- **fallback:** key 누락/장애 시 로그 후 skip, 직전 적재분 유지(Silver가 stale 표기).

### 3) SEC EDGAR — 8-K (이벤트 핵심)
- **접근:** SEC 공식 API. key 불필요하나 **`User-Agent` 헤더 필수**(이름+이메일, 미설정 시 403). rate limit 준수 의무.
- **엔드포인트:**
  - ticker→CIK 매핑: `https://www.sec.gov/files/company_tickers.json` (일 1회 갱신)
  - 회사별 제출목록: `https://data.sec.gov/submissions/CIK##########.json`
  - 8-K 원문/첨부(Exhibit 99.1 등): 제출목록의 accession에서 문서 URL 구성
- **대상:** S&P 500 종목의 **8-K** 필링. Item 번호(2.02/5.02/1.01/1.05/3.02 등)가 약한 라벨(Layer 1)이므로 **반드시 Item 메타 보존**.
- **갱신 주기:** 8-K는 수시 제출 → 일별(야간) 폴링, 필요 시 시간별. "지난 N시간 신규 8-K" 윈도우 수집.
- **rate limit:** **10 req/sec 이하.** 토큰버킷/슬립으로 강제. CIK 루프 시 특히 주의.
- **raw 형태:** ticker, cik, accession_no, form_type(8-K), filed_at, items(배열), primary_doc_url, **원문 텍스트/HTML**(text), 첨부 메타.
- **fallback:** 문서 fetch 실패 시 메타만 우선 적재 + 본문 재수집 큐. accession 단위 멱등.
- **주의:** 원문 HTML 용량 큼 → PG `text`/`jsonb`(TOAST 자동 압축)에 저장. S&P 500 일 8-K 수십 건 규모면 PG로 충분.

### 4) Reddit — attention proxy (sentiment 아님)
- **접근:** Reddit OAuth 앱(client_id/secret) + `PRAW`. 무료.
- **대상:** r/stocks, r/wallstreetbets, r/investing 등에서 **종목 ticker 언급 카운트**(시간/일 단위). 본문 sentiment 분류 안 함.
- **갱신 주기:** 시간별 또는 일별 집계.
- **rate limit:** OAuth 60 req/min.
- **raw 형태:** ticker, subreddit, window_start/end, mention_count, (옵션)post_ids.
- **현 상태:** 계획서상 **현재 mock**. → 1차엔 실데이터 수집 경로 구축 + 키 미발급 시 mock fallback 유지. Brief에는 "관심도(참고용)", 평소 대비 spike만 신호화.
- **주의:** manipulation 가능 소스 → 단정적 해석 금지, spike만 참고.

### 5) News — 이벤트 보강
- **접근: GDELT 확정.** 무료·키 불필요·커버리지 넓음 → 자격증명 의존 없이 가장 덜 막힘. (대안 Finnhub company-news/NewsAPI는 키·쿼터 제약으로 1차 제외, Phase 5+ 보조 후보로만 남김.)
- **대상:** S&P 500 종목 + 시장 전반. 8-K가 안 잡는 이벤트(소송 진행, 제품 리콜, 거시 뉴스) 보강 + RAG 보조 evidence.
- **갱신 주기:** 일별(야간). GDELT는 15분 단위 업데이트지만 1차는 일별 윈도우 수집.
- **raw 형태:** ticker(또는 market), headline, source, url, published_at, summary/snippet.
- **fallback:** 소스 장애 시 skip + 로그. Brief는 뉴스 없이도 8-K만으로 성립.
- **구현:** `src/bronze/news.py` — GDELT DOC 2.0 API 쿼리(종목명/티커 필터).

## A-3. Bronze PostgreSQL 스키마

`postgresql.data.svc.cluster.local:5432` 안에 **별도 DB `bronze_db`** 를 만들고 그 안에 `bronze` 스키마 생성(아래 B-3에서 MLflow backend와 DB 분리). 공통 컬럼 규약 + 소스별 테이블.

**공통 컬럼 규약(모든 bronze 테이블에 실제 포함 — DDL과 정합):**

- `source` text — 소스 식별
- `ingested_at` timestamptz — 수집 시각
- `dag_run_id` text — Airflow run 추적
- `content_hash` text — 멱등키(본문/행 SHA-256)
- `payload` jsonb — 원본 원형 보존(정형 테이블은 원응답 일부, 비정형은 전체)

`as_of`(데이터 기준 시점)는 **테이블별 타입 컬럼이 그 역할을 겸한다**: `prices_raw.trade_date`, `macro_raw.obs_date`, `sec_filings_raw.filed_at`, `reddit_mentions_raw.window_end`, `news_raw.published_at`. (별도 `as_of` 컬럼 중복 생성 안 함 — 각 DDL 주석에 명시.)

```sql
CREATE SCHEMA IF NOT EXISTS bronze;

-- 0) 유니버스 스냅샷 (생존편향 방지: 날짜별 구성종목 보존)
CREATE TABLE bronze.sp500_constituents (
  snapshot_date date NOT NULL,
  ticker        text NOT NULL,
  company_name  text,
  sector        text,
  cik           text,
  ingested_at   timestamptz DEFAULT now(),
  PRIMARY KEY (snapshot_date, ticker)
);

-- 1) 가격 (정형)
CREATE TABLE bronze.prices_raw (
  ticker      text NOT NULL,
  trade_date  date NOT NULL,
  open numeric, high numeric, low numeric, close numeric,
  adj_close numeric, volume bigint,
  source      text DEFAULT 'yfinance',
  ingested_at timestamptz DEFAULT now(),
  content_hash text,
  PRIMARY KEY (ticker, trade_date)
);

-- 2) 매크로 (정형, long format)
CREATE TABLE bronze.macro_raw (
  series_id   text NOT NULL,
  obs_date    date NOT NULL,
  value       numeric,
  source      text DEFAULT 'fred',
  realtime_start date, realtime_end date,
  ingested_at timestamptz DEFAULT now(),
  PRIMARY KEY (series_id, obs_date, realtime_start)
);

-- 3) SEC 8-K (메타 정형 + 원문 비정형)
CREATE TABLE bronze.sec_filings_raw (
  accession_no text PRIMARY KEY,
  cik         text NOT NULL,
  ticker      text,
  form_type   text DEFAULT '8-K',
  filed_at    timestamptz NOT NULL,         -- as_of
  items       text[],                        -- Item 2.02 등 (약한 라벨)
  primary_doc_url text,
  raw_text    text,                          -- 원문 (TOAST 압축)
  payload     jsonb,                         -- 제출 메타 원형
  source      text DEFAULT 'sec_edgar',
  ingested_at timestamptz DEFAULT now(),
  content_hash text
);

-- 4) Reddit 언급량 (집계)
CREATE TABLE bronze.reddit_mentions_raw (
  ticker      text NOT NULL,
  subreddit   text NOT NULL,
  window_start timestamptz NOT NULL,
  window_end   timestamptz NOT NULL,
  mention_count integer,
  source      text DEFAULT 'reddit',
  is_mock     boolean DEFAULT false,
  ingested_at timestamptz DEFAULT now(),
  PRIMARY KEY (ticker, subreddit, window_start)
);

-- 5) 뉴스 (메타)
CREATE TABLE bronze.news_raw (
  id          text PRIMARY KEY,             -- url 해시 등
  ticker      text,
  headline    text,
  news_source text,
  url         text,
  published_at timestamptz,                  -- as_of
  summary     text,
  payload     jsonb,
  source      text,                          -- gdelt/finnhub
  ingested_at timestamptz DEFAULT now()
);

-- 수집 로그 (성공/실패/부분실패 — freshness·fallback 근거)
CREATE TABLE bronze.ingestion_log (
  id          bigserial PRIMARY KEY,
  source      text NOT NULL,
  dag_run_id  text,
  started_at  timestamptz, finished_at timestamptz,
  status      text,                          -- success / failed / partial
  rows_written integer,
  error_msg   text
);
```

→ `scripts/init_db.sql`에 위 DDL 작성. (현재 빈 파일)

## A-4. 수집 DAG 설계 (`dag_bronze_ingestion.py`)

```
dag_bronze_ingestion  (schedule: 야간 1회, KST 새벽)
├─ refresh_universe        : company_tickers.json + S&P500 구성 → sp500_constituents
├─ [TaskGroup] ingest
│   ├─ prices    (yfinance)   ──┐
│   ├─ macro     (fred)         │ 병렬
│   ├─ sec_8k    (edgar)        │ (rate limit별 동시성 제한)
│   ├─ reddit    (praw/mock)    │
│   └─ news      (gdelt)      ──┘
└─ finalize: ingestion_log 집계 → freshness 신호 emit
```

- 각 태스크: `retries=3`, exponential backoff, 성공/실패를 `ingestion_log`에 기록.
- 동시성: EDGAR(10 req/s)·yfinance는 태스크 내부에서 토큰버킷/슬립으로 자체 제한.
- 8-K는 별도 시간별 DAG로 분리 가능(설계 옵션) — 1차는 야간 단일 DAG.
- backfill: `scripts/backfill_historical.py`로 가격·매크로 과거분 1회 적재 후 일별 증분.

## A-5. 멘토 산출물 매핑 (계획서 Week 1 요구사항 충족 체크)

- [x] 데이터 소스 선정 문서 → **이 문서 Part A**
- [ ] Bronze raw 샘플 + EDA 노트 → 수집 후 작성
- [ ] 페르소나 ↔ 데이터 매핑 표 → A-1 표가 초안, 확장
- [ ] 갱신 주기 표 ↔ 재학습 주기 정합 → A-2 갱신주기 + Week2/3 재학습 연결
- [ ] 수집 실패 fallback → A-0 원칙 + ingestion_log + 소스별 fallback

---

# Part B — K8s 매니페스트 작성 계획

> 컴포넌트(이미지/차트)는 이미 다운로드 완료. 이번 세션은 **빈 매니페스트 파일을 채우는 작업**. 현재 `infra/k8s/**` 전부 0바이트 스텁.

## B-1. 작성 대상 파일 (현재 전부 빈 상태)

```
infra/k8s/
├── bootstrap/metallb/ip-pool.yaml          # MetalLB IP 풀 (VIP 포함)
├── apps/postgresql/postgresql.yaml          # data ns
├── apps/mlflow/mlflow.yaml                   # mlops ns
├── apps/airflow/values.yaml                  # airflow ns (Helm values)
├── argocd/root-app.yaml                      # app-of-apps 루트
└── argocd/applications/{postgresql,mlflow,airflow}.yaml
```

## B-2. 작성 순서 (의존성 순)

1. **네임스페이스 + 노드 label** — `data`/`mlops`/`airflow` ns, 노드에 `role=data|public` label. control-plane=control, worker1=data, worker2=public.
2. **MetalLB `ip-pool.yaml`** — L2 풀에 Ingress VIP `192.168.50.241` 포함하는 대역 지정(예: `192.168.50.240-192.168.50.250`).
3. **Ingress 컨트롤러** — ingress-nginx를 LoadBalancer로, VIP 할당. public 노드 `nodeSelector`.
4. **PostgreSQL `postgresql.yaml`** — `data` ns, Service명 `postgresql`(→ FQDN `postgresql.data.svc.cluster.local:5432`), PVC(영속), Secret(자격증명), pgvector 확장. data 노드 배치.
5. **MLflow `mlflow.yaml`** — `mlops` ns, Service `mlflow:5000`, backend store=PostgreSQL, artifact store(PVC 또는 추후 S3 호환). public 노드.
6. **Airflow `values.yaml`** — `airflow` ns, API server Service `airflow-api-server:8080`, executor(Kubernetes/Celery), Git-sync로 `src/pipelines` DAG 연결, PG 메타DB. data 노드에 worker.
7. **ArgoCD `applications/*.yaml` + `root-app.yaml`** — 각 앱을 ArgoCD Application으로 선언, root-app이 app-of-apps로 묶음. sync policy.

## B-3. 매니페스트별 확정 필요 값

| 파일 | 채울 핵심 값 | 비고 |
|---|---|---|
| `ip-pool.yaml` | IPAddressPool 대역 + L2Advertisement | VIP 240~250 대역 |
| `postgresql.yaml` | ns=data, svc=postgresql, PVC 크기, Secret, pgvector | Bronze 적재처 |
| `mlflow.yaml` | ns=mlops, backend=PG, artifact 경로 | DB는 postgresql 재사용 or 별 DB |
| `airflow/values.yaml` | executor, gitSync repo/branch/path, PG 연결 | DAG = src/pipelines |
| `argocd/applications/*` | repoURL, path(infra/k8s/apps/*), destination ns | self-managed GitOps |
| `root-app.yaml` | applications 디렉터리 가리키는 app-of-apps | sync wave |

## B-4. 검증 체크리스트 (작성 후)

- `kubectl get nodes` → 3개 Ready, label 확인
- `kubectl -n metallb-system` → VIP 풀 광고
- PostgreSQL Pod Running + `psql`로 `bronze` 스키마 생성 가능
- ArgoCD UI(`localhost:8080`)에서 3개 앱 Synced/Healthy
- MLflow(`localhost:5000`) / Airflow(`localhost:8082`) 포트포워드 접속
- Airflow에 `dag_bronze_ingestion` 로드 확인

---

## 권장 진행 순서 (다음 액션)

1. **이 계획 확정 / 수정** — 특히 News 1차 소스(GDELT 권장)·FRED API key·Reddit OAuth·SEC User-Agent 이메일 4개 자격증명 확보 여부.
2. **k8s 매니페스트 작성** — B-2 순서대로. PostgreSQL부터 띄워야 Bronze 적재처 + Airflow 메타DB가 준비됨.
3. **`scripts/init_db.sql` 작성** — A-3 DDL.
4. **Bronze 수집 코드** — `src/bronze/*.py` + `src/common/{config,db,logging}.py` + `dag_bronze_ingestion.py`.
5. **샘플 수집 + EDA 노트** — 멘토 산출물.
