# Helm install 후 4 service pod 가 ImagePullBackOff — `:latest` 태그 부재 + GHCR 가시성 미확인

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (helm install 자체는 성공, pod 만 실패) |
| **Affected** | `payment-dev` 의 4 service Deployment pods |
| **Tags** | `helm`, `ghcr`, `image-tag`, `imagePullBackOff`, `cluster-state`, `verification-scope` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

`scripts/migrate-to-helm.sh` 가 정상 종료되어 `helm install payment ...` 가 성공했지만,
4 service pod 모두 `ImagePullBackOff` 로 떨어짐. 두 가지 미검증 가정이 동시에 노출:
1. `values-dev.yaml` 의 `imageTag: latest` — **CI 는 `:latest` 를 push 하지 않음** (sha 2종만)
2. GHCR 패키지가 public 인지 미확인 — private 이면 secret 없이는 pull 불가

수정: CI 워크플로에 `:latest` 태그 push 추가 (main 한정), Helm chart 에 `imagePullSecrets` 옵션 추가, 그리고 chart README/troubleshooting 에 "GHCR 가시성 확인" 단계 명시.

---

## Symptom

```bash
$ ./scripts/migrate-to-helm.sh
... cleanup OK ...
$ helm install payment ... # 성공
$ kubectl get pods -n payment-dev
NAME                            READY   STATUS             RESTARTS   AGE
account-7f79c7897-w6phl         0/1     ImagePullBackOff   0          4m
loan-7475bb6b74-kvjcx           0/1     ImagePullBackOff   0          4m
notification-84ffdf666c-mqkgs   0/1     ImagePullBackOff   0          4m
postgres-0                      1/1     Running            1 (3m31s ago) 4m
transfer-7c84f5bf59-8fxcc       0/1     ImagePullBackOff   0          4m
```

---

## Investigation & Root cause

### 두 가능성

`kubectl describe pod <name>` 의 Events 로 정확한 카테고리를 가린다.

| 메시지 | 의미 | 카테고리 |
|---|---|---|
| `manifest unknown` / `not found` | 그 태그가 GHCR 에 없음 | (a) tag mismatch |
| `unauthorized` / `denied` | 인증 실패 | (b) private + no secret |

### (a) `:latest` 태그 부재

`.github/workflows/ci.yml` 의 push step:
```yaml
tags: |
  ${{ steps.refs.outputs.tag_full }}    # ghcr.io/.../<svc>:<40-hex-sha>
  ${{ steps.refs.outputs.tag_short }}   # ghcr.io/.../<svc>:sha-<7-hex>
```

`:latest` 가 없음. 그러나 `values-dev.yaml` 은 `imageTag: latest` 로 박아둠.

→ helm 이 만든 Deployment 의 image 가 `ghcr.io/melanieing/account:latest`. 그런 태그가 없으니 manifest unknown.

작성 당시 내가 확인하지 않은 가정:
- "CI 가 `latest` 를 push 한다" → 실제로는 sha 2종만 push.

### (b) GHCR 가시성

GHCR 패키지의 default 가시성은 **private**. 사용자가 public 으로 명시 전환하지 않으면:
- Public 인 GHA runner / 외부 클라이언트는 pull 못 함
- K8s 도 `unauthorized`

작성 당시 내가 chart 도입을 위해 사용자에게 안내했어야 할 것 — "GHCR 패키지를 public 으로 전환하거나 imagePullSecret 등록" — 을 chart README 에 명시 안 했음.

### 메타 결함 — A-5 의 stateful 검증 한계 재발

EPIC 4 chart 검증 시 `helm lint` / `helm template` / `kubeconform` / `yamllint` 모두 통과.
하지만 **"이 chart 가 실제 cluster 에 install 된 후 image pull 까지 성공하는가"** 는 검증 안 됨.

이 단계에서 catch 하려면:
- sandbox 에 cluster + GHCR 인증 (둘 다 sandbox 한계로 어려움), 또는
- 사용자에게 **사전 점검 단계** 를 chart README 의 Quickstart 0번 항목에 명시

후자만 가능했지만 안 했음. 동일 카테고리 (cluster-state / external-state 검증 누락) 가
2026-05-04 의 helm-install-blocked-by-task1-4-resources 에 이어 두 번째.

---

## Fix

### 즉시 (사용자 측)

#### 옵션 A — sha 태그로 override

```bash
# 최신 main commit sha 로 override (CI 가 그걸로 image push 했다고 가정)
LATEST_SHA=$(git rev-parse origin/main)
helm upgrade payment charts/payment-platform/ -n payment-dev \
  -f charts/payment-platform/values-dev.yaml \
  --set global.imageTag="$LATEST_SHA"
kubectl -n payment-dev rollout restart deploy
```

#### 옵션 B — GHCR 패키지 public 화 (private 시) + 새 CI 푸시 후 재시도

1. https://github.com/users/melanieing/packages/container/account/settings → Danger Zone → Change visibility → Public (4 패키지 모두)
2. 본 PR 머지 → main push 트리거 → CI 가 이번엔 `:latest` 까지 push
3. helm upgrade 로 재시도 (또는 그냥 둬도 K8s 가 ImagePullBackOff 에서 자동 재시도)

#### 옵션 C — private 유지 + imagePullSecret

```bash
# GHCR PAT 발급 (https://github.com/settings/tokens) - 권한: read:packages
kubectl -n payment-dev create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=melanieing \
  --docker-password=<GHCR_PAT> \
  --docker-email=<email>

# values 에 추가하여 helm upgrade
helm upgrade payment charts/payment-platform/ -n payment-dev \
  -f charts/payment-platform/values-dev.yaml \
  --set 'global.imagePullSecrets[0].name=ghcr-pull'
```

### 장기 (코드 측)

1. **`.github/workflows/ci.yml`** — main push 시 `:latest` 태그도 함께 push.
   ```yaml
   tags: |
     ${{ steps.refs.outputs.tag_full }}
     ${{ steps.refs.outputs.tag_short }}
     ${{ steps.refs.outputs.image }}:latest   # 추가
   ```
   향후 `helm install` default 가 동작.
2. **`values.yaml`** — `global.imagePullSecrets: []` 옵션 추가 + 주석으로 사용법 명시.
3. **`templates/deployment.yaml`** — `{{- with $g.imagePullSecrets }} imagePullSecrets: ... {{- end }}` 블록.
4. **`charts/payment-platform/README.md`** — Quickstart 0번 항목에 "GHCR 패키지가 public 인지 확인 + 처음 install 전 main 에 한 번 push 가 있어야 :latest 태그 존재" 명시 (별도 커밋에서 할 수 있음).

### 검증 (sandbox)

- `actionlint` (ci.yml): clean (exit 0)
- `helm lint` (chart): clean
- `helm template ... -f values-dev.yaml`: 17 docs, kubeconform 17/17 valid
- `helm template ... --set global.imagePullSecrets[0].name=ghcr-pull`:
  4 Deployment 의 spec.template.spec 에 `imagePullSecrets:\n  - name: ghcr-pull` 정상 렌더링 확인

---

## Lessons learned

1. **CI 가 어떤 태그를 만드는지 확인 후 chart 의 imageTag default 결정.**
   `:latest` 가 default 면 CI 도 그걸 push 해야 일관됨. 본 사건은 default 와 CI 출력이 미스매치.
2. **GHCR (또는 어떤 레지스트리든) 의 default 가시성은 항상 확인.**
   GHCR 의 default 가 private 이라는 사실은 chart 도입 시 README 의 첫 점검 항목으로.
3. **A-5 의 stateful 검증 한계 — 외부 시스템 상태 (registry 가시성, 태그 존재) 까지 포함.**
   이전 사건(2026-05-04 Task1.4 resources)이 cluster-state 였다면 본 사건은 **registry-state**.
   둘 다 stateless 도구로는 못 잡고, sandbox 환경에서 끝까지 시뮬하기도 어려움.
   대안: chart README 의 "필수 사전 점검" 섹션 (registry 가시성, 첫 push 완료 여부, secret 존재 여부 등) 을
   배포자가 따라가도록 명시.
4. **`imagePullSecrets` 는 default values 에 빈 리스트로 노출.**
   public 운영이라도 `imagePullSecrets: []` 가 있으면 사용자가 private 전환 시 옵션 한 줄만 추가하면 됨.
   chart 의 운영 유연성 측면에서 권장.
5. **이 사건의 카테고리는 새롭지 않다.**
   2026-05-04 Task1.4 resources 사건과 메타 결함이 동일 (stateful/external 검증 누락).
   재발 빈도가 높으므로 chart-introducing 작업 시 **외부 상태 점검 체크리스트** 를 chart README
   상단에 의무 포함하도록 패턴 잡기.
