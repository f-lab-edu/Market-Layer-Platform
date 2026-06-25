# Kubernetes Bootstrap

애플리케이션 배포 전에 네임스페이스, StorageClass, ingress controller를 준비한다.

## 0. 네임스페이스

생명주기 계층(platform/pipeline/serving) 네임스페이스를 먼저 생성한다(lifecycle 라벨 포함).
앱들도 `CreateNamespace=true`를 갖지만 그건 라벨 없는 ns를 만들 뿐이므로, 이 정의를 먼저 적용한다.

```sh
kubectl apply -f infra/k8s/namespaces.yaml
kubectl get ns platform pipeline serving --show-labels
```

## 1. Local Path Provisioner

노드 로컬 디스크를 사용하는 기본 StorageClass를 설치한다.

```sh
kubectl apply -f infra/k8s/bootstrap/storageclass/local-path.yaml
kubectl get storageclass
kubectl -n local-path-storage rollout status deployment/local-path-provisioner
```

`local-path`가 default StorageClass이고 reclaim policy가 `Retain`인지 확인한다.

## 2. ingress-nginx

Helm chart 4.15.1을 NodePort 방식으로 설치한다.

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.15.1 \
  --namespace ingress-nginx \
  --create-namespace \
  -f infra/k8s/bootstrap/ingress-nginx/values.yaml
```

```sh
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller
kubectl -n ingress-nginx get service ingress-nginx-controller
```

HTTP는 `<node-ip>:30080`, HTTPS는 `<node-ip>:30443`으로 접근한다.

## 3. 애플리케이션 배포

각 애플리케이션 README에 따라 Secret을 먼저 생성한다. 배포 방식은 하나를 선택한다.

- Argo CD: `infra/k8s/argocd/root-app.yaml`을 적용하고 sync wave 순서로 배포
- 직접 배포: PostgreSQL/data lake를 먼저 적용하고 MLflow/Airflow를 배포

## 운영 제약

- local-path 데이터는 노드 장애 시 자동 복제되지 않는다.
- Secret은 Git 외부에서 관리한다.
- stateful PV는 `Retain` 정책을 사용한다.
