# K8s env 변수 substitution 순서 의존성으로 4 service pod 가 CrashLoopBackOff (uvicorn exit 3)

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (4 service 모두 기동 실패, helm install 자체는 성공) |
| **Affected** | `charts/payment-platform/templates/deployment.yaml` 의 env 배열 순서 |
| **Tags** | `kubernetes`, `env-substitution`, `helm`, `asyncpg`, `uvicorn`, `lifespan-failure` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

helm chart 의 deployment.yaml 에서 `DATABASE_URL` 을 `DB_PASSWORD` **보다 먼저** 정의했더니
K8s 의 env 변수 dependency resolve 가 동작 못 함. 결과적으로 컨테이너 안에서 DATABASE_URL 의 값이
**literal `"$(DB_PASSWORD)"`** 로 남아 asyncpg 가 잘못된 password 로 connect 시도 → 인증 실패 →
uvicorn lifespan startup failure → exit code 3 → K8s CrashLoopBackOff.

수정: env 배열에서 `DB_PASSWORD` 를 먼저 두어 substitution 가능하게 함.

---

## Symptom

```bash
$ kubectl -n payment-dev get pods -w
account-7c449c5c99-zd6kq        0/1     CrashLoopBackOff   3 (8s ago)   2m
loan-d55ff587b-npzcv            0/1     CrashLoopBackOff   3 ...
notification-688c68f69c-gdf6c   0/1     CrashLoopBackOff   3 ...
transfer-cb88c4c97-jkf79        0/1     CrashLoopBackOff   3 ...
postgres-0                      1/1     Running            ...

$ kubectl describe pod account-7c449c5c99-zd6kq -n payment-dev
...
Containers:
  account:
    State:       Waiting
      Reason:    CrashLoopBackOff
    Last State:  Terminated
      Reason:    Error
      Exit Code: 3                       # ← uvicorn lifespan startup failure
    Environment:
      DATABASE_URL: postgresql://payment:$(DB_PASSWORD)@postgres.payment-dev.svc.cluster.local:5432/account_db
                                          ▲ literal text 로 남아있음
      DB_PASSWORD:  <set to ... secret>
Events:
  Warning  Unhealthy  Readiness probe failed: dial tcp 10.244.2.6:8000: connect: connection refused
                                                                          ▲ uvicorn 이 listen 안 함
```

---

## Investigation & Root cause

### 가설 — env 변수 substitution 실패

`kubectl describe` 출력의 `DATABASE_URL` 라인에 `$(DB_PASSWORD)` 가 그대로 보임. K8s 가 그 라인을 표시할 때 source 값을 보여주는 게 일반적이지만, **kubelet 이 dependency resolve 를 못 한 경우** 도 동일하게 보인다.

### 검증 — K8s 공식 docs

> Variables that the kubelet is unable to dependency resolve will be left as `$(VAR_NAME)` verbatim within the container env var value.

`$(VAR_NAME)` 형태의 substitution 은 **같은 container 의 env 목록에서 그 이전에 정의된 변수만 참조 가능**.

### 우리 chart 의 deployment.yaml (수정 전)

```yaml
env:
  - name: DATABASE_URL                    # ← 1번째
    value: "postgresql://...:$(DB_PASSWORD)@..."
  - name: DB_PASSWORD                     # ← 2번째 (너무 늦음)
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: POSTGRES_PASSWORD
```

→ kubelet 이 DATABASE_URL 처리 시점에 DB_PASSWORD 가 아직 정의 안 됨 → resolve 실패 → literal 보존.

### 확정 원인

asyncpg 가 password = literal 문자열 `"$(DB_PASSWORD)"` 로 postgres connect 시도.
이는 실제 비밀번호 `payment-dev-pw` 와 다름 → `InvalidPasswordError` (또는 `password authentication failed`).

uvicorn 의 lifespan 핸들러 (services/_template/main.py 의 `await asyncpg.create_pool(...)`) 가 예외를 raise → uvicorn 이 lifespan startup failure 로 판단 → **exit code 3** 으로 종료.

K8s 는 종료를 보고 restart, 같은 실패 반복 → CrashLoopBackOff.

### 메타 결함

- `helm template` 출력은 K8s 의 runtime 동작을 반영 안 함 (substitution 은 kubelet 단계).
- `helm lint` / `kubeconform` 도 schema 만 본다.
- A-5 의 stateless 검증 도구 6종이 모두 통과해도 **K8s runtime 에서만 발생하는 ordering bug** 는 잡지 못함.
- 이 클래스 (K8s 실제 동작 검증) 도 cluster-state, registry-state, policy-state 처럼 별도 layer.

같은 클래스의 결함이 24시간 안에 4건째 반복:
1. Task 1.4 ownership (cluster-state)
2. ImagePullBackOff (registry-state)
3. self-inflicted :latest 태그 (policy-state)
4. **K8s env substitution ordering (k8s-runtime-state)** ← 이번

---

## Fix

### 즉시 — env 순서 swap

```yaml
env:
  - name: DB_PASSWORD                     # ← 먼저 정의
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: POSTGRES_PASSWORD
  - name: DATABASE_URL                    # ← 그 다음. 이제 $(DB_PASSWORD) 가 resolve 됨
    value: "postgresql://...:$(DB_PASSWORD)@..."
```

inline 주석으로 K8s 의 ordering 규칙과 본 사건 reference 추가.

### Sandbox 검증 (helm template)

```bash
$ helm template payment charts/payment-platform/ \
    -n payment-dev -f values-dev.yaml --set global.imageTag=abc1234 \
    | sed -n '/kind: Deployment/,/^---/p' | grep -A 10 "env:" | head -10

env:
  - name: DB_PASSWORD                     # ✅ 1번째
    valueFrom: ...
  - name: DATABASE_URL                    # ✅ 2번째
    value: "postgresql://payment:$(DB_PASSWORD)@..."
```

순서 정상. 실제 K8s install 후에는 DATABASE_URL 이 `postgresql://payment:payment-dev-pw@...` 로 resolve 되어 asyncpg connect 성공 → uvicorn lifespan 정상 → :8000 listen → readiness probe pass.

### 사용자 복구 절차

```bash
git pull
helm upgrade payment charts/payment-platform/ -n payment-dev \
  -f charts/payment-platform/values-dev.yaml \
  --set global.imageTag=$(git rev-parse origin/main)
kubectl -n payment-dev rollout restart deploy
kubectl -n payment-dev get pods -w   # 4 service 가 Ready 상태로 전환되어야 함
```

---

## Lessons learned

1. **K8s 의 `$(VAR_NAME)` env substitution 은 ordering 의존적이다.**
   같은 container 의 env 목록 안에서 **참조되는 변수가 참조하는 변수보다 먼저** 정의되어야 한다.
   docs.kubernetes.io > Define Environment Variables for a Container > "Use environment variables to define arguments" 참조.
2. **`helm template` 은 K8s runtime 동작을 시뮬레이션하지 않는다.**
   substitution / volume binding / probe 평가 같은 kubelet 단계 동작은 해당 도구 범위 밖.
   이를 잡으려면 실제 cluster install 만이 유일한 방법.
3. **Secret-backed env 는 항상 먼저 선언.**
   pattern: 모든 `valueFrom: secretKeyRef` 변수를 env 목록 상단에 모으고,
   그것을 참조하는 일반 `value:` 변수를 하단에 두는 것을 chart 의 표준 컨벤션으로.
   향후 chart 작성 시 이 컨벤션 적용 후 helm template grep 으로 1차 점검.
4. **kubectl describe 출력의 env 라인 = source 가 아니라 unresolved 일 수 있다.**
   describe 가 보여주는 값에 `$(VAR)` 가 보이면 의심. resolved 값을 확인하려면
   `kubectl exec <pod> -- env | grep VAR` 가 정답.
5. **본 프로젝트의 검증 layer 분류표 (지금까지 확인된 카테고리) — CLAUDE.md 차후 정리 후보:**
   - syntax (lint/parse)
   - schema (jsonschema/kubeconform)
   - rendered-yaml (yamllint key-duplicates 등)
   - cluster-state (기존 리소스 ownership)
   - registry-state (외부 image registry 가시성·태그)
   - policy-state (자기 결정 docs 와 정합성)
   - **k8s-runtime-state** (env substitution / probe 평가 / volume binding 등 kubelet 동작) ← 본 사건으로 추가
   - external-action-state (3rd-party action 의 실재 태그 등)
