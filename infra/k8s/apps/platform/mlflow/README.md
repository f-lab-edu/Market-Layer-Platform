# MLflow Tracking Server

> ⚠️ **범위: 신규(빈) 클러스터 부트스트랩 기준.** Secret 생성 단계는 빈 클러스터 전용이다.
> 이미 운영 중인 클러스터를 GitOps로 넘기려면 **`docs/gitops-adoption-runbook.md`**를 따른다(기존 `mlflow-secret`·PVC 재사용).

실험 메타데이터는 PostgreSQL에, artifact는 local-path PVC에 저장한다.

- namespace: `platform`
- image: `ghcr.io/mlflow/mlflow:v3.10.0-full`
- service: `mlflow:5000`
- backend DB: `postgresql.platform.svc.cluster.local:5432/mlflow`
- artifact PVC: `mlflow-artifacts-pvc` 20Gi

## 사전 조건

PostgreSQL의 `mlflow` DB와 backend URI Secret을 준비한다.

```sh
kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic mlflow-secret -n platform \
  --from-literal=MLFLOW_BACKEND_STORE_URI='postgresql://admin:<password>@postgresql.platform.svc.cluster.local:5432/mlflow'
```

## 배포 및 검증

```sh
kubectl apply -f infra/k8s/apps/platform/mlflow/mlflow.yaml
kubectl -n platform rollout status deployment/mlflow
kubectl -n platform get pod,svc -l app=mlflow
kubectl -n platform get pvc mlflow-artifacts-pvc
kubectl -n platform port-forward svc/mlflow 5000:5000
```

MLflow UI는 `http://localhost:5000`에서 확인한다. Argo CD 사용 시 `mlflow` Application을 sync한다.

## 운영 제약

- Deployment는 RWO PVC의 중복 마운트를 방지하기 위해 `Recreate` 전략을 사용한다.
- `/health` 기반 startup/readiness/liveness probe를 사용한다.
- artifact PVC에는 Argo CD prune/delete 보호가 적용된다.
