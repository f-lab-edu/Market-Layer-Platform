# Kubernetes bootstrap

## 기존 local-path PV 보호

StorageClass의 `reclaimPolicy: Retain`은 새로 프로비저닝되는 PV에 적용된다. 기존 PV는 현재 정책을
확인하고 데이터 PV만 개별적으로 `Retain`으로 변경한다.

라이브 StorageClass가 `Delete`인 상태에서 `Retain`으로 변경되지 않으면 StorageClass를 삭제 후
동일 이름으로 재생성해야 할 수 있다. StorageClass 삭제 자체는 기존 PV/PVC를 삭제하지 않지만,
재생성 전까지 신규 PVC 프로비저닝을 중단한다. 기존 PV가 모두 `Retain`인지 먼저 확인한다.

```sh
kubectl get pv \
  -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name,RECLAIM:.spec.persistentVolumeReclaimPolicy

kubectl patch pv <pv-name> \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

PostgreSQL, MLflow artifact, datalake PVC에 연결된 PV가 모두 `Retain`인지 확인한 뒤 ArgoCD 자동
동기화를 활성화한다.

## ArgoCD 최초 인수

각 child Application은 기존 Helm/수동 배포 리소스를 안전하게 인수하도록 automated sync를
비활성화한 상태다. 다음 순서로 diff와 수동 sync를 수행한다.

1. `storageclass`
2. `postgresql`, `datalake`, `ingress-nginx`
3. `mlflow`
4. `airflow`

Airflow는 기존 Fernet/API/JWT/Broker/Redis/metadata Secret의 UID와 checksum이 유지되는지 반드시
확인한다. PostgreSQL은 `postgres-data-postgresql-0` PVC와 연결 PV의 UID가 유지되어야 한다.
검증 후 각 Application에 `automated.prune=true`, `automated.selfHeal=true`를 활성화한다.
