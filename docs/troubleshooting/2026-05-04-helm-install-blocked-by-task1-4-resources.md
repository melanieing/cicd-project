# helm install 이 Task 1.4 의 plain-manifest 리소스 충돌로 차단된 사례

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (사용자가 EPIC 4 의 helm install 첫 시도에서 막힘) |
| **Affected** | `payment-dev` 의 postgres-* 리소스, helm chart `payment` release |
| **Tags** | `helm`, `migration`, `ownership-label`, `cluster-state`, `verification-scope` |
| **Related commits** | (이 사건을 수정하는 커밋), 51ce296, 5a0d921 |

---

## Summary

EPIC 4 의 Helm chart 를 사용자의 kind 클러스터에 `helm install` 했더니 즉시 fail.
원인은 단순 — Task 1.4 단계에서 `kubectl apply -f` 로 직접 띄운 postgres 리소스 5종이 17시간째 살아있는데
그것들에 Helm 의 ownership label/annotation 이 없어, Helm 이 같은 이름의 리소스를 새로 만들지 못함.

3 단계 메타 결함:
1. EPIC 4 가이드에 "Task 1.4 리소스 정리" 단계가 없었음 (`|| true` 로 얼버무림).
2. 정리 명령으로 제시한 `kubectl delete -f charts/.../postgres.yaml` 도 실패함 — Helm 화 후의 파일은 `{{ }}` 가 들어가 kubectl 이 파싱 못 함.
3. Sandbox 에 cluster 가 없어 helm install 을 실제로 돌리지 못한 채 commit. A-5 의 검증 범위가 stateless tools (lint/template/kubeconform) 에 한정된 사각지대.

해결: 마이그레이션 전용 스크립트 신설, chart README 에 Task 1.4 → Helm 절차 명시, A-5 에 cluster-state 검증의 한계 추가.

---

## Symptom

사용자 화면:

```bash
$ kubectl -n payment-dev delete -f charts/payment-platform/templates/postgres.yaml --ignore-not-found
error: error parsing charts/payment-platform/templates/postgres.yaml:
  json: offset 2: invalid character '{' looking for beginning of object key string

$ helm install payment charts/payment-platform/ -n payment-dev -f charts/payment-platform/values-dev.yaml
Error: INSTALLATION FAILED: Unable to continue with install:
  Secret "postgres-secret" in namespace "payment-dev" exists
  and cannot be imported into the current release:
  invalid ownership metadata;
  label validation error: missing key "app.kubernetes.io/managed-by":
    must be set to "Helm";
  annotation validation error: missing key "meta.helm.sh/release-name":
    must be set to "payment";
  annotation validation error: missing key "meta.helm.sh/release-namespace":
    must be set to "payment-dev"
```

결과: postgres 만 살아있고 4 service Deployment/Service/HPA 는 한 개도 설치 안 됨.

---

## Investigation & Root cause

### 1차 가설 (오답): chart 자체 결함

helm lint / helm template / kubeconform 모두 통과한 chart 라 chart 자체가 깨졌다고 보긴 어려움.
실제로 helm install 의 에러 메시지가 친절히 알려줌 — "exists and cannot be imported".
Helm 이 자기가 만들지 않은 리소스를 덮어쓰지 않는 안전 장치 발동.

### 확정 원인 — Task 1.4 의 잔존 리소스

`kubectl get` 으로 현재 상태 확인:

```
NAME                        STATUS    AGE
pod/postgres-0              Running   17h
service/postgres            ClusterIP 17h
service/postgres-headless   ClusterIP 17h
statefulset.apps/postgres   1/1       17h
```

Task 1.4 의 plain manifest `kubectl apply -f charts/payment-platform/templates/postgres.yaml`
이 만든 secret/postgres-secret, configmap/postgres-init, statefulset/postgres, 2 service, PVC 가 그대로 살아있음.

이 리소스들의 metadata:
```yaml
metadata:
  name: postgres-secret
  # ❌ helm install 이 요구하는 다음 키들이 없음
  # labels.app.kubernetes.io/managed-by: Helm
  # annotations.meta.helm.sh/release-name: payment
  # annotations.meta.helm.sh/release-namespace: payment-dev
```

→ Helm 이 같은 이름의 Secret 을 만들려다 ownership 부재로 거부.

### 메타 결함 — A-5 의 검증 범위

EPIC 4 의 chart 작성 시 다음 검증을 수행했음:
- helm lint        ✓
- helm template    ✓
- kubeconform      ✓
- yamllint key-duplicates on rendered  ✓ (이전 IDE 결함 사건 후 추가)

**모두 stateless** — chart 자체와 렌더링 결과만 봄.
**stateful** 검증 (실제 cluster 에 install 했을 때의 충돌 여부) 은 안 함.

이를 잡으려면:
1. 실제 cluster (kind / minikube / 원격) 에 helm install 까지 시도, 또는
2. `kubectl apply --dry-run=server -f <rendered>` 로 server-side dry-run, 또는
3. 마이그레이션 절차를 별도 산출물로 작성하고 사용자가 따르도록 명시

본 프로젝트 sandbox 에서 1번을 시도했으나 nested container 환경에서 kind 노드가 즉시 종료되어 실패.
2번도 sandbox 에 cluster 가 없으면 불가.
3번은 작성하지 않았음 — 이게 실수의 핵심.

---

## Fix

### 즉시 복구 — `scripts/migrate-to-helm.sh`

두 가지 모드:

**MODE=clean (기본·권장)**
```bash
./scripts/migrate-to-helm.sh
```
- Task 1.4 리소스 5 개 + PVC 삭제 → Pod 종료 대기 → fresh `helm install`
- dev 환경의 mock 데이터라 손실 부담 없음

**MODE=adopt** (Helm 3.13+ 의 `--take-ownership`)
```bash
MODE=adopt ./scripts/migrate-to-helm.sh
```
- 기존 postgres-secret 등을 Helm 이 흡수 → 4 DB 데이터 보존
- 이후 helm upgrade/uninstall 을 통해 정상 관리

### 장기 방어 — 절차 문서화

- `charts/payment-platform/README.md` 신설: Task 1.4 → Helm 마이그레이션 절차 명시
- `CLAUDE.md A-5` 보강: cluster-state 검증의 한계 + chart 도입 시 마이그레이션 스크립트 동반 의무화 (아래 §Lessons learned 참조)

---

## Lessons learned

1. **Stateless 검증 (lint/template/kubeconform) ≠ stateful 검증 (실제 install).**
   chart 자체가 깨끗해도 사용자 cluster 의 기존 상태와 충돌할 수 있다.
   가능하면 sandbox 에 cluster 를 띄워 실제 helm install 을 돌리고,
   그게 어려우면 **마이그레이션 절차를 별도 산출물 (script + README)** 로 분리해 사용자가 따라가게 한다.
2. **kubectl 과 helm 의 동거가 불가능함을 인지.**
   `kubectl apply -f` 와 `helm install` 이 같은 이름의 리소스를 만들면 두 번째 시도가 실패한다.
   Plain manifest 단계에서 Helm 으로 옮길 때는 항상 ownership 전이가 필요.
3. **`kubectl delete -f <helm template>` 는 작동하지 않는다.**
   Helm template 파일은 raw YAML 이 아니라 `{{ }}` 가 포함된 텍스트.
   삭제 명령은 리소스 종류·이름을 직접 지정해야 한다 (`kubectl delete statefulset/postgres`).
4. **마이그레이션 스크립트는 chart 의 일부다.**
   chart 를 도입할 때마다 "기존 사용자가 어떤 상태에서 출발하는가" 를 점검하고
   필요하면 cleanup/adopt 스크립트를 동반 출시. 이걸 빼먹으면 사용자가 막힌다.
5. **A-5 검증 범위 명문화 필요.**
   "실행으로 검증" 의 도구 추천 항목에 "가능하면 cluster install" 을 추가하고,
   cluster 접근 불가 시 "마이그레이션 절차를 별도 산출물로 작성" 을 의무화한다 (CLAUDE.md 갱신 예정).
