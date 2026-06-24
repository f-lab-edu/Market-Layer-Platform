# PostgreSQL with pgvector

> ⚠️ **범위: 신규(빈) 클러스터 부트스트랩 기준.** Secret 생성·`init_db.sql` 실행은 빈 데이터 볼륨 전용이다.
> 이미 운영 중인 클러스터를 GitOps로 넘기려면 **`docs/gitops-adoption-runbook.md`**를 따른다(기존 `postgres-secret`·PVC 재사용, StatefulSet 인수는 롤링 1회).

Airflow·MLflow metadata, Feast online store, 애플리케이션 데이터와 벡터 데이터를 저장한다.

- namespace: `platform`
- image: `pgvector/pgvector:pg16`
- service: `postgresql:5432`
- StorageClass: `local-path`
- PVC template: `postgres-data`, 10Gi
- 실제 PVC: `postgres-data-postgresql-0`
- node selector: `node-role=data`

Bronze/Silver 원본은 PostgreSQL이 아니라 parquet data lake에 저장한다.

## 사전 조건

data node에 label을 추가하고 PostgreSQL Secret을 생성한다.

```sh
kubectl label node <data-node> node-role=data
kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic postgres-secret -n platform \
  --from-literal=POSTGRES_USER=admin \
  --from-literal=POSTGRES_PASSWORD='<password>' \
  --from-literal=POSTGRES_DB=postgres
```

## 배포

```sh
kubectl apply -k infra/k8s/apps/platform/postgresql
kubectl -n platform rollout status statefulset/postgresql
```

### PVC 보호 (Git이 아니라 PVC에 직접 부여)

`volumeClaimTemplates`는 immutable이라 prune/delete 보호 annotation을 매니페스트에 넣으면 기존
StatefulSet 인수 시 sync가 거부된다. 따라서 보호는 **기존 PVC에 직접** 부여한다.

```sh
kubectl -n platform annotate pvc postgres-data-postgresql-0 \
  argocd.argoproj.io/sync-options=Prune=false,Delete=false --overwrite
```

빈 데이터 볼륨에서 최초 실행할 때 `init_db.sql`이 서비스별 DB와 vector extension을 생성한다.
Bronze 수집 상태 테이블은 다음과 같이 적용한다.

```sh
kubectl -n platform cp \
  infra/k8s/apps/platform/postgresql/bronze_ops.sql \
  postgresql-0:/tmp/bronze_ops.sql
kubectl -n platform exec postgresql-0 -- \
  psql -U admin -d audit -f /tmp/bronze_ops.sql
```

## 검증

```sh
kubectl -n platform get pod,svc -l app=postgresql
kubectl -n platform get pvc postgres-data-postgresql-0
kubectl -n platform exec postgresql-0 -- psql -U admin -d postgres -c '\l'
kubectl -n platform exec postgresql-0 -- psql -U admin -d vector -c '\dx'
```

## 운영 제약

- init SQL은 빈 데이터 볼륨의 최초 부팅에서만 실행된다.
- PVC retention policy와 Argo CD prune/delete 보호를 적용한다.
- local-path는 단일 노드 로컬 스토리지이므로 별도 백업이 필요하다.
