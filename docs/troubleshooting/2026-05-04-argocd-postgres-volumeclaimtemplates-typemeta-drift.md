# ArgoCD postgres StatefulSet 영구 OutOfSync — volumeClaimTemplates TypeMeta 누락

## Summary

EPIC 5 부트스트랩 후 `kubectl -n argocd get applications.argoproj.io` 가 `payment-dev` / `payment-prod` 둘 다 `OutOfSync / Healthy` 로 떴고, 더 들어가 보니 단 하나의 리소스 — `StatefulSet/postgres` — 가 OutOfSync 였다. 추가로 `root` Application 도 자기 child `payment-dev` 의 `syncPolicy.automated.allowEmpty: false` 차이로 OutOfSync. 두 건 모두 **양성 드리프트** (cluster 상태는 정상). 원인은 (1) K8s API 서버가 `volumeClaimTemplates[].apiVersion/kind` 를 자동 채워넣는 것, (2) ArgoCD controller 가 default 값 (`allowEmpty: false`) 을 normalize 해 떨어뜨리는 것. chart 와 Application 매니페스트에 각각 정식 필드 보강 / default 값 제거로 해결.

## Symptom

```
$ kubectl -n argocd get applications.argoproj.io
NAME           SYNC STATUS    HEALTH STATUS
payment-dev    OutOfSync      Healthy
payment-prod   OutOfSync      Healthy
root           OutOfSync      Healthy
```

UI 의 Application Tree → postgres `sts` 클릭 → DIFF 탭:

```diff
  type: RollingUpdate
  volumeClaimTemplates:
- - apiVersion: v1
-   kind: PersistentVolumeClaim
-   metadata:
+ - metadata:
      name: data
      ...
```

좌측이 **LIVE**, 우측이 **DESIRED (git)**. ArgoCD diff 는 LIVE 에 있고 DESIRED 에 없는 필드를 "지워야 할 것" 으로 표시 (실제로는 K8s 가 알아서 넣은 거라 못 지움) → 영구 OutOfSync.

root → payment-dev Application diff:

```diff
  syncPolicy:
    automated:
+     allowEmpty: false
      prune: true
      selfHeal: true
```

좌측 LIVE 에는 `allowEmpty` 필드가 없고, 우측 git 매니페스트에는 명시되어 있음.

## Investigation & Root cause

### Issue 1 — postgres StatefulSet

`StatefulSet.spec.volumeClaimTemplates[]` 의 각 항목은 임베디드 `PersistentVolumeClaim` 객체다. K8s API 서버는 임베디드 PVC 를 저장할 때 `TypeMeta` (`apiVersion: v1`, `kind: PersistentVolumeClaim`) 를 항상 채워 직렬화한다 (스펙 보존을 위해). chart 의 `templates/postgres.yaml` 은 그 필드를 명시 안 했고:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      ...
```

→ ArgoCD 의 `helm template` 결과에는 그 두 필드가 없음. cluster 의 LIVE 에는 서버가 채운 두 필드가 있음. ArgoCD diff 가 그 차이를 잡는 게 정상 작동.

진단 명령:

```bash
kubectl -n argocd get app payment-dev -o json \
  | jq '.status.resources[] | select(.status != "Synced")'
# {"name":"postgres","kind":"StatefulSet","status":"OutOfSync",...}  ← 단 하나
```

→ 다른 리소스 (Deployment, Service, Secret, ConfigMap) 는 모두 Synced. 범위가 정확히 좁혀짐.

### Issue 2 — root → payment-dev allowEmpty

ArgoCD 의 `Application` CRD 에서 `spec.syncPolicy.automated.allowEmpty` 의 default 는 `false`. controller 는 객체를 ETCD 에 저장하기 전 default 값을 떨어뜨리는 normalization 을 수행. git 에서 `false` 라고 명시해도 cluster 객체는 그 필드를 안 들고 있음. root Application 이 자기가 apply 한 child 매니페스트 (git) 와 cluster 의 child 객체 (LIVE) 를 비교하면 그 한 줄이 영구 diff.

`payment-prod.yaml` 은 애초에 `automated:` 블록이 없으므로 (manual sync 정책) 같은 문제가 없음.

## Fix

### Issue 1 — chart 에 정식 필드 추가

`charts/payment-platform/templates/postgres.yaml` 의 `volumeClaimTemplates` 항목에 `apiVersion: v1` + `kind: PersistentVolumeClaim` 명시. K8s 가 어차피 넣을 값을 git 에서도 미리 선언 → diff 사라짐. `ignoreDifferences` 보다 깔끔: 진짜로 빠진 필드를 채우는 거라 의도 명확하고 회귀 risk 0.

```yaml
volumeClaimTemplates:
  - apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: data
    spec:
      ...
```

### Issue 2 — default 값 제거

`argocd/applications/payment-dev.yaml` + `argocd/root-app.yaml` 의 `syncPolicy.automated.allowEmpty: false` 한 줄 삭제. default 라 동작 동일, drift 만 사라짐.

### 검증 (사용자 작업)

```bash
git pull
# (또는 PR 머지 후 ArgoCD 가 자동 sync)
kubectl -n argocd get applications.argoproj.io
# 기대: 모두 Synced / Healthy
```

## Lessons learned

1. **K8s 임베디드 객체의 TypeMeta 는 git 에 명시한다.** `volumeClaimTemplates`, `Pod` template 안의 emptyDir/Secret 참조 등 server-default 가 채우는 필드는 미리 명시해서 ArgoCD diff 가 잠잠하게.

2. **ArgoCD CRD 의 default 값을 git 에 적지 마라.** `allowEmpty: false`, `prune: false` (default) 같은 default 값은 controller 가 normalize 시 떨어뜨리므로 git 에 적으면 영구 drift. **명시는 default 가 아닌 값에만.**

3. **OutOfSync 가 떴을 때 진단 첫 명령은 `jq '.status.resources[] | select(.status != "Synced")'`** — 어떤 리소스가 범인인지 한 줄에 좁혀준다. UI 의 Application Tree 도 같은 정보 제공 (빨간 점 아이콘).

4. **ArgoCD 의 render mode 를 알면 helm release 가 비어 보여도 당황하지 않는다.** `helm -n payment-dev list` 가 비었던 게 EPIC 5 본 사건의 곁가지였는데, 이는 ArgoCD 가 `helm install` 이 아닌 `helm template + kubectl apply` 로 동작하기 때문. helm release 메타데이터 자체를 안 만든다.

5. **양성 drift 와 진성 drift 의 구분은 Health 상태로 1차 판단.** `Healthy` + `OutOfSync` 조합은 거의 전부 직렬화 normalization 차이. `Degraded` + `OutOfSync` 면 진짜 문제. 본 건은 둘 다 Healthy 였으므로 처음부터 직렬화 의심.
