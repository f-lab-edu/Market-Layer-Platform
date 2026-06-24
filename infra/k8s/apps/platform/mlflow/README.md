# MLflow Tracking Server — platform 네임스페이스

- Service FQDN: `mlflow.platform.svc.cluster.local:5000`
- backend store: PostgreSQL `mlflow` DB
- artifact store: 로컬 PVC `mlflow-artifacts-pvc` `/mlflow/artifacts` (20Gi, `local-path`)
- 노드: worker1 (PVC 자동 핀)
- 이미지: `ghcr.io/mlflow/mlflow:v3.10.0-full`
- 접근: `kubectl -n platform port-forward svc/mlflow 5000:5000` → http://localhost:5000

## 사전 준비 — Secret 주입 (Git 밖)

backend-store-uri 전체를 secret 값으로 주입(평문 URI를 Git에 두지 않음). 키 이름은 `MLFLOW_BACKEND_STORE_URI`.

```sh
kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic mlflow-secret -n platform \
  --from-literal=MLFLOW_BACKEND_STORE_URI='postgresql://admin:<비밀번호>@postgresql.platform.svc.cluster.local:5432/mlflow'
```

## 알아둘 것

- `-full` 이미지에 PostgreSQL 드라이버가 포함되어 있어 런타임 `pip install`은 하지 않는다.
- `/health` 기반 startup/readiness/liveness probe로 기동 지연과 장애를 구분한다.
- 리소스는 라이브와 동일하게 request `100m/256Mi`, limit `500m/2Gi`로 둔다.
- backend DB(`mlflow`)는 PostgreSQL에 이미 존재해야 한다(현재 클러스터 PG는 별도 init으로 구성됨).
- artifact PVC는 ArgoCD prune/delete 방지 annotation을 사용하고 StorageClass는 `Retain` 정책을 사용한다.
- `strategy`는 RWO PVC 보호를 위해 `Recreate`로 둔다.
