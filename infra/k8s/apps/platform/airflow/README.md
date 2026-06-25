# Apache Airflow

> ⚠️ **범위: 신규(빈) 클러스터 부트스트랩 기준.** 아래 Secret 생성 단계는 빈 클러스터 전용이다.
> 이미 운영 중인 클러스터를 GitOps로 넘기려면 이 문서를 따르지 말고 **`docs/gitops-adoption-runbook.md`**를 따른다(기존 Secret 재사용, 새로 생성 금지, `helm uninstall` 금지).

Airflow 3.2.2를 공식 Helm chart 1.22.0과 `CeleryExecutor`로 배포한다.

- namespace: `platform`
- metadata DB: `postgresql.platform.svc.cluster.local:5432/airflow`
- broker: chart 내 Redis
- image: `ghcr.io/f-lab-edu/market-layer-platform-airflow:develop`
- DAG: gitSync의 `src/market_layer/pipelines`
- data lake: worker의 `/opt/airflow/data`
- API service: `airflow-api-server:8080`
- image pull policy: `develop` 태그는 `Always`

## 사전 조건

PostgreSQL과 `datalake-pvc`가 먼저 준비되어야 한다. Airflow sync 전에
`ghcr.io/f-lab-edu/market-layer-platform-airflow:develop` 이미지도 CI로 build/push되어 있어야 한다.

다음 Secret도 `platform` namespace에 생성한다.

| Secret | key | 용도 |
|---|---|---|
| `airflow-fernet-key` | `fernet-key` | Connection/Variable 암호화 |
| `airflow-api-secret-key` | `api-secret-key` | API session |
| `airflow-jwt-secret` | `jwt-secret` | API JWT |
| `airflow-broker-url` | `connection` | Celery broker URL |
| `airflow-redis-password` | `password` | Redis 인증 |
| `airflow-metadata` | `connection` | metadata DB 접속 |

```sh
kubectl create secret generic airflow-fernet-key -n platform \
  --from-literal=fernet-key='<fernet-key>'
kubectl create secret generic airflow-api-secret-key -n platform \
  --from-literal=api-secret-key='<random-secret>'
kubectl create secret generic airflow-jwt-secret -n platform \
  --from-literal=jwt-secret='<random-secret>'
kubectl create secret generic airflow-redis-password -n platform \
  --from-literal=password='<redis-password>'
kubectl create secret generic airflow-broker-url -n platform \
  --from-literal=connection='redis://:<redis-password>@airflow-redis:6379/0'
kubectl create secret generic airflow-metadata -n platform \
  --from-literal=connection='postgresql://admin:<password>@postgresql.platform.svc.cluster.local:5432/airflow'
```

외부 데이터 수집 자격증명은 별도 Secret으로 관리한다.
`values.yaml`이 이 Secret을 `extraEnvFrom`으로 참조하므로, Secret이 없으면 Airflow Pod가
`CreateContainerConfigError`로 뜨지 않는다.

```sh
kubectl create secret generic market-layer-api-secret -n platform \
  --from-literal=FRED_API_KEY='<key>' \
  --from-literal=SEC_USER_AGENT='name email@example.com' \
  --from-literal=REDDIT_CLIENT_ID='<id>' \
  --from-literal=REDDIT_CLIENT_SECRET='<secret>'
```

Secret 값은 Git에 저장하지 않는다.

GHCR package를 private로 운영하는 경우에는 이미지 pull Secret도 필요하다. Public package면 생략한다.

```sh
kubectl create secret docker-registry ghcr-market-layer-pull -n platform \
  --docker-server=ghcr.io \
  --docker-username='<github-user>' \
  --docker-password='<github-token-with-read-packages>'
```

private package를 쓸 때는 `values.yaml`의 `imagePullSecrets` 주석도 해제한다.

개발 단계에서는 mutable `develop` 태그를 쓰므로 `pullPolicy: Always`를 유지한다. 운영 릴리스에서는
CI가 만든 `develop-<sha>` 같은 immutable tag로 고정하고 `pullPolicy: IfNotPresent`로 전환한다.

## 배포

Argo CD app-of-apps를 사용하는 경우 `airflow` Application을 sync한다. Helm으로 직접 확인하려면:

```sh
helm repo add apache-airflow https://airflow.apache.org
helm repo update
helm template airflow apache-airflow/airflow \
  --version 1.22.0 \
  --namespace platform \
  -f infra/k8s/apps/platform/airflow/values.yaml >/tmp/airflow-rendered.yaml
helm upgrade --install airflow apache-airflow/airflow \
  --version 1.22.0 \
  --namespace platform \
  --create-namespace \
  -f infra/k8s/apps/platform/airflow/values.yaml
```

## 검증

```sh
kubectl -n platform get pods,svc,pvc
kubectl -n platform get pvc \
  logs-airflow-worker-0 logs-airflow-triggerer-0 redis-db-airflow-redis-0
kubectl -n platform exec airflow-worker-0 -- python -c 'import market_layer'
kubectl -n platform port-forward svc/airflow-api-server 8082:8080
```

Airflow UI/API는 `http://localhost:8082`에서 확인한다. worker Pod에서
`/opt/airflow/data/lake`가 마운트되고 DAG가 로드되는지도 확인한다.

## 운영 제약

- `datalake-pvc`가 RWO이므로 worker replica는 1개를 전제로 한다.
- worker와 triggerer 로그 PVC는 각각 100Gi, Redis PVC는 1Gi다.
- worker를 확장하려면 RWX 스토리지 또는 MinIO/S3로 전환해야 한다.
