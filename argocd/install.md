# ArgoCD 설치 가이드 (EPIC 5 — Task 5.1)

> 본 문서는 `docs/requirements.md` R-B3-O1 (GitOps 기본 사이클) 의 출발점이다.
> kind 단일 클러스터 + Ubuntu 24.04 호스트 환경에서 **복붙으로 끝까지** 동작하도록 작성했다.
> 이후 5.2 (Application 매니페스트) → 5.3 (App-of-Apps) → 5.4 (sync 정책) → 5.5 (GitHub Environment) 순으로 이어진다.

---

## 1. 사전 조건

| 항목 | 요구 | 확인 명령 | 기대 출력 |
|---|---|---|---|
| kind 클러스터 가동 | `payment-platform` (멀티노드) 떠 있어야 함 | `kubectl get nodes` | 3 nodes Ready |
| kubectl context | kind cluster 를 가리켜야 함 | `kubectl config current-context` | `kind-payment-platform` |
| helm | 3.20.x 설치됨 | `helm version` | `version.BuildInfo{Version:"v3.20...` |
| RAM 여유 | ≥ 2GB | `free -h` 의 available | 2Gi 이상 |

> 클러스터가 없다면 `scripts/bootstrap.sh` 를 먼저 실행 (EPIC 0 산출물).

## 2. ArgoCD Helm repo 등록

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

기대 출력:
```
"argo" has been added to your repositories
...Successfully got an update from the "argo" chart repository
```

확정한 chart 버전 (2026-04 stable, `docs/tech-stack-versions.md` §4):
```bash
helm search repo argo/argo-cd --version 9.5.11
```
기대 출력 1줄:
```
NAME            CHART VERSION   APP VERSION     DESCRIPTION
argo/argo-cd    9.5.11          v3.x.x          A Helm chart for Argo CD ...
```

## 3. 설치 — `argocd` 네임스페이스

본 repo 의 override values 사용:

```bash
helm upgrade --install argocd argo/argo-cd \
  --version 9.5.11 \
  -n argocd --create-namespace \
  -f argocd/values.yaml \
  --wait --timeout 5m
```

`--wait` 는 모든 Deployment/StatefulSet 이 Available 이 될 때까지 블록.

기대 종료 출력:
```
Release "argocd" does not exist. Installing it now.
NAME: argocd
LAST DEPLOYED: ...
NAMESPACE: argocd
STATUS: deployed
REVISION: 1
```

## 4. 설치 검증

### 4.1 모든 pod Running

```bash
kubectl -n argocd get pods
```

기대 (5~7 pod, 모두 1/1 Running):
```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          1m
argocd-applicationset-controller-...                1/1     Running   0          1m
argocd-redis-...                                    1/1     Running   0          1m
argocd-repo-server-...                              1/1     Running   0          1m
argocd-server-...                                   1/1     Running   0          1m
```

dex / notifications 는 values 에서 disabled 했으므로 보이면 안 됨.

### 4.2 CRD 등록 확인

```bash
kubectl get crd | grep argoproj
```

기대 (최소 4 개):
```
applications.argoproj.io
applicationsets.argoproj.io
appprojects.argoproj.io
...
```

### 4.3 admin 초기 비밀번호 추출

ArgoCD 가 자동 생성한 Secret 에서 plain text 비밀번호를 디코드:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

기대: 16자 영숫자 1줄 (예: `aB7xQ2mP9kL3wRvN`)

> 이 secret 은 첫 install 시 1회만 생성된다. **즉시 다른 곳에 백업** 후 UI 에서 비밀번호 변경 + secret 삭제 가 정석.

## 5. UI 접근 — port-forward

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

브라우저:
```
http://localhost:8080
```

로그인:
- Username: `admin`
- Password: §4.3 에서 받은 값

성공 시 빈 Applications 페이지가 보임 (5.2 에서 첫 Application 추가).

## 6. CLI 접근 (선택)

```bash
# argocd CLI 설치 (Ubuntu 24.04)
ARGOCD_VERSION="v3.0.0"   # chart 9.5.11 의 appVersion 과 일치하는 release 사용
curl -sSL -o /tmp/argocd \
  https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
sudo install -m 755 /tmp/argocd /usr/local/bin/argocd
argocd version --client

# port-forward 가 떠 있는 채로 로그인
PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$PASSWORD" --insecure
```

기대:
```
'admin:login' logged in successfully
Context 'localhost:8080' updated
```

> EPIC 5.2 부터는 Application 매니페스트를 `kubectl apply` 또는 `argocd app create` 로 등록.
> 본 프로젝트는 GitOps 일관성 위해 **kubectl apply (declarative)** 만 사용.

## 7. 흔한 오류와 대응

| 증상 | 원인 | 대응 |
|---|---|---|
| `argocd-application-controller-0` Pending | StatefulSet 의 PVC 요구 (없음, 본 chart 는 emptyDir) → 실은 다른 원인일 가능성 | `kubectl -n argocd describe pod argocd-application-controller-0` 로 Events 확인. ImagePullBackOff 이면 quay.io 접근성 점검 |
| `argocd-server` Service 가 안 뜸 | helm install 중 `--timeout` 짧음 | `--wait --timeout 10m` 으로 재시도 |
| port-forward 후 UI 에서 redirect loop | server 가 TLS 모드인데 `--insecure` 누락 | `argocd/values.yaml` 의 `server.extraArgs: [--insecure]` 와 `configs.params.server.insecure: true` 가 모두 들어갔는지 확인 |
| admin 로그인 시 "Invalid credentials" | password 에 줄바꿈 포함 | base64 -d 결과를 `tr -d '\n'` 으로 정리하거나 위 명령처럼 `echo` 로 1줄 출력해서 복사 |
| `kubectl get crd` 에 argoproj 없음 | helm install 실패 (status != deployed) | `helm -n argocd status argocd` 로 확인 후 `helm uninstall argocd -n argocd` 후 재설치 |

## 8. 다음 단계

- [`argocd/applications/`](applications/) — 5.2 에서 dev/prod Application 매니페스트 추가
- [`argocd/root-app.yaml`](root-app.yaml) — 5.3 에서 App-of-Apps 진입점 추가
- 5.4 — Application spec 안에 `syncPolicy.automated` (dev) vs 비활성 (prod, 수동 sync)
- 5.5 — GitHub UI 에서 `prod` Environment 에 reviewer 1명 protection rule 추가

> **참고 (A-5-pre)**: imageTag 수동 지정 (`--set global.imageTag=...`) 의 운영적 부담은 EPIC 5 후속으로 **ArgoCD image updater** 도입 시 소멸한다.
> image updater 가 GHCR 을 watch → 새 sha 를 values 파일에 git commit → ArgoCD 가 그 commit 을 sync.
> 본 task 5.x 단계에서는 `values.global.imageTag` 를 values-{dev,prod}.yaml 에 직접 박는 형태로 진행.
