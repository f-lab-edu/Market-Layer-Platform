# Argo CD Applications

app-of-apps 패턴으로 Kubernetes 인프라와 애플리케이션을 관리한다.

## 구성

| sync wave | Application |
|---|---|
| 0 | `storageclass` |
| 1 | `postgresql`, `datalake`, `ingress-nginx` |
| 2 | `mlflow`, `airflow` |

child Application은 초기 상태에서 수동 sync를 사용한다.

## 부트스트랩

Argo CD를 먼저 설치한 뒤 root Application을 생성한다.

```sh
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f infra/k8s/argocd/root-app.yaml
```

Application 상태와 diff를 확인한 뒤 wave 순서로 sync한다.

```sh
kubectl -n argocd get applications
argocd app diff storageclass
argocd app sync storageclass
```

모든 Application 검증 후 automated sync를 활성화한다.

> ⚠️ **`kubectl patch`로 라이브 Application을 직접 고치지 말 것.** `root-app`이 `selfHeal: true`라
> child Application을 Git 상태로 되돌려, 라이브 patch는 곧 제거된다. 반드시 **Git을 편집**한다.

검증이 끝난 앱부터 `applications/<app>.yaml`의 `syncPolicy`에 `automated` 블록을 추가하고 commit·push한다(root-app이 동기화).

```yaml
# infra/k8s/argocd/applications/<app>.yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```sh
git add infra/k8s/argocd/applications/<app>.yaml
git commit -m "argocd: enable automated sync for <app>"
git push origin develop   # root-app이 child Application을 Git 상태로 동기화 → automated 적용
```

## 검증

```sh
kubectl -n argocd get applications
kubectl get pods,pvc -A
```

모든 Application이 `Synced/Healthy`이고 PVC가 `Bound`인지 확인한다.
