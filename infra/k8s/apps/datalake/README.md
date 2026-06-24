# 데이터 레이크 PVC — Bronze/Silver parquet 저장소

- 네임스페이스: `platform` (PVC는 마운트하는 Pod와 같은 ns여야 함)
- 스토리지: `local-path` (RWO) → **worker1 로컬 디스크**에 저장, 비복제
- 마운트 위치: **Airflow worker** `/opt/airflow/data` (CeleryExecutor → 태스크가 worker에서 실행)
- 레이크 루트: `/opt/airflow/data/lake` (env `DATA_LAKE_ROOT`)

## 경로/파티션 규약

```
/opt/airflow/data/lake/
├── bronze/
│   ├── price/dt=YYYY-MM-DD/data.parquet       # ticker는 컬럼
│   ├── macro/dt=YYYY-MM-DD/data.parquet
│   ├── sec_8k/dt=YYYY-MM-DD/data.parquet      # raw_text는 컬럼으로 포함
│   ├── news/dt=YYYY-MM-DD/data.parquet
│   └── reddit/dt=YYYY-MM-DD/data.parquet
└── silver/{dataset}/dt=YYYY-MM-DD/data.parquet
```

- 파티션은 **`source/dt`까지만**. ticker는 컬럼(디렉터리로 쪼개면 small-file 문제).
- 멱등 재실행 = 해당 `dt=` 파티션 **덮어쓰기**(overwrite).

## 제약 (의도된 선택)

- RWO + 노드 로컬 → worker(태스크 실행)가 디스크 있는 노드(worker1)에 자동 핀. 같은 노드의 다른 Pod만 접근.
- **worker.replicas = 1 전제.** 2개 이상이면 RWO 충돌 → RWX(NFS)/MinIO 필요.
- 단일 디스크·비복제 → 디스크 장애 시 데이터 손실. **단일 장애점으로 남겨두기로 결정**(홈랩 자원 제약).
- PVC에는 ArgoCD prune/delete 방지 annotation을 적용하고 StorageClass는 `Retain`으로 설정한다.
