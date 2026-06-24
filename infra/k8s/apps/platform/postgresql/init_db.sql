-- =====================================================================
-- PostgreSQL 부트스트랩 참조 (신규 클러스터에서만 의미 있음)
-- Bronze/Silver는 PostgreSQL이 아니라 parquet 데이터 레이크에 저장됨(이 파일에 bronze 테이블 없음).
-- DB 단위 분리 현황(라이브 기준): airflow / mlflow / feast / app / vector / audit / mlops
-- =====================================================================

CREATE DATABASE airflow;   -- Airflow 메타DB
CREATE DATABASE mlflow;    -- MLflow backend store
CREATE DATABASE feast;     -- Feast (online store / registry)
CREATE DATABASE app;       -- 애플리케이션 데이터
CREATE DATABASE vector;    -- pgvector (RAG 임베딩)
CREATE DATABASE audit;     -- audit log / 운영 메타데이터(수집 로그 등)
CREATE DATABASE mlops;     -- (용도 확인 필요)

-- pgvector 확장 (임베딩 저장 DB)
\connect vector
CREATE EXTENSION IF NOT EXISTS vector;

-- 참고: Bronze 운영 메타데이터(ingestion_log/freshness)는 bronze_ops.sql 참조(audit DB).
