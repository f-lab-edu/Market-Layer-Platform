# pipeline (배치 워크로드 계층)

> 생명주기 기준 분할의 **pipeline** 계층 — "주기적으로 돌고 끝나는 배치 작업"이 들어간다.
> 네임스페이스: `pipeline`. **Week 1 현재 비어 있는 게 정상**(아직 워크로드 미구현).

## 무엇이 들어가나 (Week 2~)

- Bronze/Silver/Gold 변환 Job
- 모델 학습 Job (거시 국면 K-Means+RF, 이벤트 분류 FinBERT fine-tune)
- Feast materialize Job

## 동작 방식

Airflow **본체**는 `platform`에 있다. Bronze v1은 `platform` namespace의 Airflow Celery worker에서
실행한다. 이 방식은 `datalake-pvc`가 같은 namespace에 있고 RWO/local-path 제약이 있기 때문에
현재 단계에서 가장 단순하다.

`pipeline` namespace는 이후 KubernetesPodOperator 또는 별도 Job으로 배치 작업을 분리할 때 사용한다.
그 시점에는 오케스트레이터(platform)와 작업물(pipeline)이 분리된다.

## 선행 작업 (Week 2 착수 시)

- Airflow worker의 ServiceAccount가 `pipeline` ns에 Pod/Job 생성 가능하도록 RBAC(Role/RoleBinding) 추가.
- 데이터 레이크 접근이 필요한 Job은 namespace-scoped PVC와 같은 노드 RWO 제약을 고려해
  RWX(NFS), MinIO/S3, 또는 실행 위치/namespace 재설계를 확정.
