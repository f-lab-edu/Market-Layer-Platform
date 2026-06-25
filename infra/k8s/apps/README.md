# apps — 생명주기 기준 분할

워크로드를 **생명주기(lifecycle)** 기준으로 3개 네임스페이스로 나눈다.

| 계층 | 네임스페이스 | 성격 | 들어가는 것 | 시점 |
|---|---|---|---|---|
| `platform/` | `platform` | 항상 떠있는 stateful 공용 서비스 | PostgreSQL(pgvector), MLflow, Airflow 본체, datalake PVC | Week 1 |
| `pipeline/` | `pipeline` | 주기적으로 돌고 끝나는 배치 작업 | bronze/silver/gold 변환·모델 학습·Feast materialize Job | Week 2 |
| `serving/` | `serving` | 사용자에게 결과를 전달하는 계층 | 추론 API, brief 생성, 텔레그램 봇 | Week 3 |

## 왜 이렇게 나누나

- **Airflow 본체 = platform** : 파이프라인을 "도는 작업"이 아니라 "돌릴 수 있게 해주는 오케스트레이터 본체"라서 항상 켜져 있어야 함.
- **현재 Bronze v1 = platform worker 실행** : `datalake-pvc`가 `platform`에 있고 RWO/local-path 제약이 있어 Airflow Celery worker에서 실행한다.
- **향후 Airflow 작업물 = pipeline** : KubernetesPodOperator 또는 별도 Job 전환 시 `pipeline` ns에 Pod/Job을 생성한다. 오케스트레이터와 그 작업물은 그때 분리된다.
- pipeline/serving이 **Week 1에 비어 있는 것은 정상** — 아직 그 계층 워크로드를 만들지 않았을 뿐, 설계 의도대로의 빈 자리.

## 노드 배치 원칙

- **PostgreSQL만 `nodeSelector: node-role: data`** 를 명시(라이브 구성). 나머지(mlflow/airflow/ingress)는 nodeSelector 미사용.
- nodeSelector 없는 stateful Pod(mlflow/airflow worker)도 `local-path` PVC의 node-affinity로 볼륨이 있는 노드(worker1)에 자동 핀된다.
- `datalake-pvc`가 RWO·노드로컬이라 **Airflow worker.replicas=1 전제**. 스케일하려면 RWX(NFS)/MinIO 필요(ADR 018/019).
