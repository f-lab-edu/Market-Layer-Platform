# ArgoCD 인수 절차

현재 child Application은 기존 Helm/수동 배포 리소스를 안전하게 인수하기 위해 automated sync가
비활성화되어 있다.

## 최초 sync 순서

1. `storageclass`
2. `postgresql`, `datalake`, `ingress-nginx`
3. `mlflow`
4. `airflow`

각 단계에서 `argocd app diff <app>` 결과를 확인하고 수동 sync한다. PostgreSQL sync 전후
`postgres-data-postgresql-0` PVC/PV UID가 동일해야 한다. Airflow sync 전후 아래 Secret의 UID와
data checksum이 동일해야 한다.

- `airflow-fernet-key`
- `airflow-api-secret-key`
- `airflow-jwt-secret`
- `airflow-broker-url`
- `airflow-redis-password`
- `airflow-metadata`

## 검증 후 automated sync 활성화

```sh
for app in storageclass postgresql datalake ingress-nginx mlflow airflow; do
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done
```

Git 선언에도 automated sync를 영구 반영하려면 동일한 설정을 각 Application manifest에 추가한다.

## MetalLB 잔여 RBAC

라이브에는 `metallb-system` namespace가 없지만 MetalLB ClusterRole/ClusterRoleBinding이 남아 있다.
NodePort 전환 검증 후 해당 cluster-scoped 잔여 리소스를 별도 삭제한다. 애플리케이션 인수와 함께
자동 삭제하지 않는다.
