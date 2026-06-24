# Parquet Data Lake

> ⚠️ **범위: 신규(빈) 클러스터 부트스트랩 기준.** 이미 운영 중인 클러스터를 GitOps로 넘기려면 **`docs/gitops-adoption-runbook.md`**를 따른다(PVC는 `Prune=false,Delete=false` 보호).

Bronze/Silver 데이터를 저장하는 `datalake-pvc`를 제공한다.

- namespace: `platform`
- StorageClass: `local-path`
- access mode: `ReadWriteOnce`
- capacity: 20Gi
- Airflow mount: `/opt/airflow/data`
- lake root: `/opt/airflow/data/lake`

## 데이터 경로

```text
/opt/airflow/data/lake/
├── bronze/{dataset}/dt=YYYY-MM-DD/data.parquet
└── silver/{dataset}/dt=YYYY-MM-DD/data.parquet
```

파티션은 dataset과 날짜 단위로 구성하고, ticker는 컬럼으로 저장한다. 재실행 시 해당 날짜
파티션을 덮어써 멱등성을 유지한다.

## 배포 및 검증

```sh
kubectl apply -f infra/k8s/apps/platform/datalake/pvc.yaml
kubectl -n platform get pvc datalake-pvc
kubectl -n platform describe pvc datalake-pvc
```

Argo CD 사용 시 `datalake` Application을 sync한다.

## 운영 제약

- local-path 볼륨은 특정 노드의 로컬 디스크에 종속되고 복제되지 않는다.
- RWO이므로 여러 노드의 Airflow worker가 동시에 사용할 수 없다.
- PVC는 namespace-scoped 리소스이므로 `pipeline` namespace의 Job이 `platform` namespace의
  `datalake-pvc`를 직접 마운트할 수 없다. 독립 Job으로 전환하려면 RWX(NFS), MinIO/S3, 또는
  실행 위치/namespace 재설계가 필요하다.
- PVC에는 Argo CD prune/delete 보호가 적용되고 PV는 `Retain` 정책을 사용한다.
