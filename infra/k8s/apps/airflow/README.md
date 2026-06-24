# Apache Airflow — platform 네임스페이스 (공식 차트 1.22.0 / Airflow 3.2.2)

- executor: **CeleryExecutor** (라이브와 동일 — redis broker + worker)
- 메타DB: 외부 PostgreSQL `airflow` DB (host `postgresql.platform.svc.cluster.local`, user `admin`)
- DAG: **gitSync → `src/pipelines`** (라이브엔 없던 추가)
- 데이터 레이크: **worker**에 `datalake-pvc` 마운트 → `/opt/airflow/data` (CeleryExecutor라 태스크가 worker에서 실행)
- nodeSelector 없음 (PVC node-affinity로 worker1에 자연 핀)
- API server FQDN: `airflow-api-server.platform.svc.cluster.local:8080`
- 접근: `kubectl -n platform port-forward svc/airflow-api-server 8082:8080` → http://localhost:8082

## 기존 Helm release를 ArgoCD로 인수

인수 과정에서 차트가 Secret을 재생성하지 않도록 다음 기존 Secret 이름을 values에 고정한다.

| 용도 | Secret | 필수 key |
|---|---|---|
| Fernet | `airflow-fernet-key` | `fernet-key` |
| API session | `airflow-api-secret-key` | `api-secret-key` |
| API JWT | `airflow-jwt-secret` | `jwt-secret` |
| Celery broker URL | `airflow-broker-url` | `connection` |
| Redis password | `airflow-redis-password` | `password` |
| Metadata DB | `airflow-metadata` | `connection` |

인수 전후 Secret UID와 checksum을 비교하고, 기존 Connection/Variable 복호화 및 worker의 broker
연결을 확인하기 전에는 Airflow Application의 automated sync를 활성화하지 않는다.

```sh
kubectl -n platform get secret \
  airflow-fernet-key airflow-api-secret-key airflow-jwt-secret \
  airflow-broker-url airflow-redis-password airflow-metadata \
  -o json > airflow-secrets-before-argocd.json
```

## 신규 클러스터 — Secret 주입 (Git 밖)

라이브는 메타DB 접속을 values에 **인라인 평문**으로 두고 있음. GitOps로 옮기려면 Secret으로 외부화한다.

```sh
# 메타DB 접속 문자열 (기존: user=admin / db=airflow / host=platform)
kubectl create secret generic airflow-metadata -n platform \
  --from-literal=connection='postgresql://admin:<pw>@postgresql.platform.svc.cluster.local:5432/airflow'

# 외부 API 자격증명 (Bronze 수집용 — DAG task에서 사용)
kubectl create secret generic market-layer-api-secret -n platform \
  --from-literal=FRED_API_KEY=<...> \
  --from-literal=SEC_USER_AGENT='이름 email@example.com' \
  --from-literal=REDDIT_CLIENT_ID=<...> \
  --from-literal=REDDIT_CLIENT_SECRET=<...>
```

> 기존 클러스터의 Fernet/JWT/API/Broker/Redis Secret은 재생성하거나 덮어쓰면 안 된다.

## 알아둘 것

- 이 values는 라이브(`helm -n platform get values airflow -a`)를 기반으로 기존 Secret 고정, gitSync, API server 리소스 제한을 보완한다.
- worker/triggerer 로그 PVC는 라이브와 동일하게 각각 100Gi, Redis PVC는 1Gi다.
- Airflow 3의 UI/API를 담당하는 `apiServer`에 명시적 request/limit을 설정한다.
- `workers.replicas=1` 전제로 데이터 레이크 PVC(RWO)를 worker에 마운트. 스케일하면 RWX/MinIO 필요.
- 외부 API secret을 task env로 노출하는 방식은 Bronze DAG 구현 단계에서 확정(`extraEnvFrom` 등).
