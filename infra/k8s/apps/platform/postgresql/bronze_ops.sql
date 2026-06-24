-- =====================================================================
-- Bronze 운영 메타데이터 (parquet이 아니라 DB에 둠 — 작고 자주 갱신, 모니터링이 쿼리)
-- 대상 DB: audit  (※ audit DB 용도가 다르면 \connect 대상을 바꿀 것)
-- 적용(라이브 PG는 이미 초기화돼 있어 수동 적용):
--   kubectl -n platform cp infra/k8s/apps/platform/postgresql/bronze_ops.sql platform/postgresql-0:/tmp/bronze_ops.sql
--   kubectl -n platform exec -it postgresql-0 -- psql -U admin -d audit -f /tmp/bronze_ops.sql
-- =====================================================================
\connect audit

CREATE SCHEMA IF NOT EXISTS bronze;

-- 수집 로그: 성공/실패/부분실패 — freshness·fallback 판단 근거
CREATE TABLE IF NOT EXISTS bronze.ingestion_log (
  id            bigserial PRIMARY KEY,
  source        text NOT NULL,            -- price / macro / sec_8k / news / reddit
  dag_run_id    text,
  as_of_date    date,                     -- 수집 대상 파티션 dt
  started_at    timestamptz,
  finished_at   timestamptz,
  status        text,                     -- success / failed / partial
  rows_written  integer,
  lake_path     text,                     -- 기록된 parquet 파티션 경로
  error_msg     text
);

-- (선택) 소스별 최신 신선도 뷰용 — freshness 모니터링이 참조
CREATE TABLE IF NOT EXISTS bronze.source_freshness (
  source        text PRIMARY KEY,
  last_as_of    date,
  last_success  timestamptz,
  is_stale      boolean DEFAULT false,
  updated_at    timestamptz DEFAULT now()
);
