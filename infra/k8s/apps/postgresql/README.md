# PostgreSQL (pgvector) — platform 네임스페이스

MLflow/Airflow 메타DB + Feast online + RAG 벡터 저장. 단일 PostgreSQL 인스턴스 안에서 DB를 분리한다
(라이브: `airflow` / `mlflow` / `feast` / `app` / `vector` / `audit` / `mlops`).
**Bronze/Silver는 PostgreSQL이 아니라 parquet 데이터 레이크에 저장**(`apps/datalake/`). PG엔 Bronze 운영 메타데이터(`audit.bronze.*`)만.

- 이미지: `pgvector/pgvector:pg16`
- Service FQDN: `postgresql.platform.svc.cluster.local:5432` (ClusterIP)
- 노드: `node-role=data`인 worker1
- 스토리지: `local-path` StorageClass, 10Gi PVC
- superuser: `admin` (라이브 클러스터 기준)

## ⚠️ 현재 클러스터에 PostgreSQL이 이미 떠 있음

`postgresql-0`이 이미 Running이고, **그 데이터 디렉터리는 이미 초기화**되어 있다. 따라서
`init_db.sql`의 `/docker-entrypoint-initdb.d` 자동 실행은 **다시 일어나지 않는다**(initdb는 빈
디렉터리에서만 실행). 즉 이 매니페스트를 GitOps로 적용해도 기존 데이터/DB는 그대로 보존된다.

→ **Bronze raw는 PostgreSQL에 안 들어간다**(parquet 데이터 레이크 사용 — `apps/datalake/` 참조).
PostgreSQL엔 Bronze **운영 메타데이터(ingestion_log/freshness)**만 `audit` DB에 둔다.

```sh
# 1) 기존 DB 목록 확인 (라이브: airflow/mlflow/feast/app/vector/audit/mlops)
kubectl -n platform exec -it postgresql-0 -- psql -U admin -d postgres -c "\l"

# 2) Bronze 운영 메타데이터를 audit DB에 적용
kubectl -n platform cp infra/k8s/apps/postgresql/bronze_ops.sql platform/postgresql-0:/tmp/bronze_ops.sql
kubectl -n platform exec -it postgresql-0 -- psql -U admin -d audit -f /tmp/bronze_ops.sql
```

## 기존 클러스터 ArgoCD 인수

- 기존 Secret `postgres-secret`과 PVC `postgres-data-postgresql-0`을 그대로 재사용한다.
- PVC template 이름은 StatefulSet immutable field이므로 `postgres-data`를 변경하지 않는다.
- 기존 데이터는 PVC 루트에 있으므로 `PGDATA`를 별도 하위 디렉터리로 지정하지 않는다.
- 최초 sync 전후 PVC/PV UID가 동일한지 확인한다.

## 신규 클러스터일 때만 — Secret 주입 + DB 부트스트랩 (Git 밖)

빈 클러스터에 처음 띄울 때만 해당. `init_db.sql`이 7개 DB를 생성(라이브엔 이미 존재).

```sh
kubectl create secret generic postgres-secret -n platform \
  --from-literal=POSTGRES_USER=admin \
  --from-literal=POSTGRES_PASSWORD='<비밀번호>' \
  --from-literal=POSTGRES_DB=postgres
```

## 알아둘 것

- `init_db.sql`은 **부트스트랩 참조**(라이브 PG는 이미 초기화됨 → 자동 실행 안 일어남).
- StatefulSet의 PVC template에는 ArgoCD prune/delete 방지 annotation을 적용하고 StorageClass는 `Retain`으로 설정한다.
- Bronze/Silver = parquet 레이크, Gold = Feast(offline parquet + online `feast` DB). PG엔 bronze raw 테이블 없음.
- `bronze_ops.sql`의 대상 DB는 `audit` 가정 — 용도가 다르면 `\connect` 대상을 바꿀 것.
- v1은 **DB 단위 분리**까지만(소유자는 superuser `admin` 공용). 서비스별 전용 role 분리는 후속.
