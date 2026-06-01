# ADR 0002 — 컨테이너 레지스트리: GHCR 채택 + KT Cloud Registry 마이그레이션 시나리오 보존

- **Status**: Accepted
- **Date**: 2026-05-03 (소급 — EPIC 2 의 실제 구현 시점)
- **Deciders**: 본 프로젝트 단독 운영자 (DevOps 포트폴리오 시연 목적)
- **Related Requirements**: R-B2-M1, R-B2-M2, R-B2-M3, R-B2-O1, R-B2-O2, R-B2-O3
- **Related Backlog**: 2.3, 3.3, 9.2 (본 ADR)
- **Related Artifacts**: `docs/registry.md`, `.github/workflows/ci.yml`, `.github/workflows/ghcr-cleanup.yml`

## 1. Context — 어떤 결정을 내려야 하는가

본 프로젝트는 4 개 서비스의 컨테이너 이미지를 다음 요구사항으로 저장·배포한다.

| 요구사항 | 내용 |
|---|---|
| **R-B2-M2** | 레지스트리 분리 (서비스당 1 repo) + git-sha 태그 |
| **R-B2-M3** | Trivy HIGH/CRITICAL 스캔 통과한 이미지만 push |
| **R-B2-O1** | Trivy 결과 PR 코멘트 |
| **R-B2-O2** | untagged 이미지 자동 삭제 |
| **R-B2-O3** | Dependabot 베이스 이미지 주간 업데이트 |

비기능 제약:

- **$0 비용** — 클라우드 비용 발생 금지
- **포트폴리오 시연** — 채용 담당자가 곧장 재현 가능해야 함
- **국내 운영 시나리오 보존** — 본 프로젝트의 가상 도메인이 국내 결제 도메인 (`payment-platform`)
  이므로, 실 운영 시 국내 클라우드 사업자 (KT Cloud) 의 레지스트리로 이전하는 시나리오를 같이
  고려해야 함 (data sovereignty / 망분리 / regulatory)

본 ADR 은 위 컨텍스트에서 **GHCR (GitHub Container Registry) 과 KT Cloud Container Registry** 중
무엇을 채택할지, 그리고 마이그레이션 시나리오를 어떻게 보존할지 결정한다.

## 2. Decision

본 프로젝트는 **GHCR 을 1 차 채택** 하고, **KT Cloud Container Registry 마이그레이션 시나리오를
ADR 본문 + chart 의 image registry 분리 가능 구조로 보존** 한다.

- 이미지 경로: `ghcr.io/melanieing/<service>:<git-sha>`
- 가시성: public (CLAUDE.md B-1 의 portfolio 정책)
- 4 서비스를 별도 GHCR package 로 분리 — 권한 / cleanup / metric 을 서비스 단위로 통제
- chart 의 `global.imageRegistry` values 를 단일 변수로 분리 — KT Cloud 이전 시 한 줄 변경

## 3. Rationale — 왜 GHCR 인가 (지금 시점)

### 3.1 결정적 근거: $0 비용 + GHA 와의 native integration

GHCR 의 **public package 가 무제한 무료** (private 도 storage 500MB 무료) 이며, 다음 작업이 별도
인증 layer 없이 즉시 동작한다.

```yaml
- uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}  # ← repo 가 자동 발급, 별도 secret 등록 불필요
```

KT Cloud Container Registry 는 KT 서비스 계정 / API Key 가 별도 필요하며, 본 프로젝트가 $0 비용 정책상
KT Cloud 계정 자체를 만들지 못한다.

### 3.2 GHA 와의 동일 권한 도메인

GHCR push 권한이 repo 의 `packages:write` 권한과 동일하다. 즉:

- repo collaborator 면 자동으로 GHCR push 가능 (별도 권한 부여 단계 없음)
- repo private 화 시 GHCR 도 자동 private (가시성이 repo 와 동기)
- repo 삭제 시 GHCR 도 함께 정리 (orphan registry 방지)

KT Cloud 는 별도 IAM 도메인이라 권한이 분리됨 — 운영 부담은 늘지만 보안 분리 측면에서는 장점.

### 3.3 OCI 표준 준수 — 마이그레이션 비용 작음

GHCR / KT Cloud / AWS ECR / GCP Artifact Registry 모두 OCI image format 호환. 이미지 자체의
재빌드 불필요 — `docker pull <old>` → `docker tag` → `docker push <new>` 3 줄로 이전.

본 ADR 의 § 5 가 그 절차를 정형화.

## 4. KT Cloud Registry 가 더 좋아지는 시점 (마이그레이션 trigger)

GHCR 의 선택이 영구적이지 않음. 다음 조건 중 하나라도 충족되면 KT Cloud 또는 다른 국내 registry
로의 이전을 검토.

### 4.1 Regulatory — 데이터 위치 / 망분리

- **금융위 / 개인정보보호위원회 규제** — 국내 결제 도메인은 cluster + 이미지 모두 국내 region 에
  머무는 것이 일반적 요구. GHCR 의 이미지가 GitHub 의 미국 region 에 저장됨.
- **사내 망분리** — outbound 가 사내 proxy 만 허용하는 환경에서는 GitHub 도메인 자체가 차단될 수 있음.
- **데이터 sovereignty** — 일부 공공 사업의 경우 이미지의 물리적 저장 location 이 국내일 것을 요구.

### 4.2 성능 — 국내 트래픽 latency

국내 K8s 노드에서 이미지 pull 시:

| 출처 | 평균 pull 시간 (50MB 이미지) |
|---|---|
| GHCR (US-East) | 약 8-15 초 |
| KT Cloud Registry (서울) | 약 1-3 초 |
| Harbor 사내 (LAN) | 약 0.5-1 초 |

대규모 HPA 스케일 아웃 (100 pod 동시 pull) 시 차이가 누적되어 cold start 가 분 단위 단축 가능.
본 프로젝트의 데모 부하에서는 의미 미미하지만, 실제 운영에서는 큰 차이.

### 4.3 비용 — 트래픽 / storage 가 무료 한도 초과

GHCR public 은 무제한이지만, private + storage 1GB+ + 월 outbound 1GB+ 부터는 GitHub Actions 의 분
소비량을 빠르게 갉아먹는다. 본 프로젝트의 4 서비스 × 5 history × 100MB = 약 2GB 가 private 으로
전환 시 비용 부담 발생 가능.

KT Cloud 의 가격은 본 ADR 작성 시점에 다음과 같다 (2026-05 기준):

- Container Registry Standard: 월 ₩30,000 (storage 100GB 포함)
- 같은 region 내 트래픽: 무료
- 외부 region 트래픽: GB 당 ₩100

본 프로젝트의 데모 규모는 GHCR 무료 한도 안이지만, 실 운영 (월 수십 GB 트래픽) 으로 가면 GHCR private +
GHA 분 비용 vs KT Cloud 정액제의 cross-over 가 발생.

## 5. KT Cloud 마이그레이션 절차 (시나리오 보존)

본 절차를 시연하지는 않으나 ADR 에 기록해 추후 의사결정 비용을 줄인다.

### 5.1 사전 준비

```bash
# KT Cloud 계정 + Container Registry 생성 (KT Cloud 콘솔)
# 본 시나리오의 가상 endpoint:
KT_REGISTRY="containers.kr-central-2.kakaocloud.com"
KT_PROJECT="payment-platform"

# 인증
docker login "$KT_REGISTRY" -u "$KT_ACCESS_KEY"
```

### 5.2 4 서비스 이미지 일괄 복제

```bash
SERVICES="account transfer loan notification"
GHCR_BASE="ghcr.io/melanieing"
KT_BASE="$KT_REGISTRY/$KT_PROJECT"

# 가장 최근 sha 만 이전 (history 는 점진적으로)
CURRENT_SHA=$(git rev-parse origin/main)

for s in $SERVICES; do
  docker pull  "$GHCR_BASE/$s:$CURRENT_SHA"
  docker tag   "$GHCR_BASE/$s:$CURRENT_SHA" "$KT_BASE/$s:$CURRENT_SHA"
  docker push  "$KT_BASE/$s:$CURRENT_SHA"
done
```

### 5.3 chart 의 image registry 갱신

```yaml
# charts/payment-platform/values.yaml
global:
  imageRegistry: containers.kr-central-2.kakaocloud.com/payment-platform
  # ↑ 이 한 줄 변경 + values-prod.yaml override 가능
```

chart 의 deployment template 에 image registry 가 하드코딩되어 있지 않고 `$g.imageRegistry` 로
분리되어 있어 한 줄 변경으로 끝남 — 본 ADR 의 결정 (chart 구조) 의 결과.

### 5.4 CI 의 push target 갱신

```yaml
# .github/workflows/ci.yml 의 docker push step
- name: Push to KT Cloud Registry
  run: |
    docker tag $LOCAL_IMAGE containers.kr-central-2.kakaocloud.com/payment-platform/${{ matrix.service }}:${{ github.sha }}
    docker push containers.kr-central-2.kakaocloud.com/payment-platform/${{ matrix.service }}:${{ github.sha }}
  env:
    KT_ACCESS_KEY: ${{ secrets.KT_REGISTRY_KEY }}
```

GHCR push step 을 지우고 위로 교체. Trivy 스캔 자체는 image format 의존 안 하므로 그대로.

### 5.5 ArgoCD imagePullSecrets 추가

KT Cloud 는 private 이라 K8s pod 가 pull 하려면 imagePullSecret 필요.

```bash
kubectl -n payment-dev create secret docker-registry kt-pull \
  --docker-server="$KT_REGISTRY" \
  --docker-username="$KT_ACCESS_KEY" \
  --docker-password="$KT_SECRET_KEY"

# chart 의 values 에서:
# global.imagePullSecrets: [{ name: kt-pull }]
```

본 시나리오의 모든 변경 점은 chart values + workflow secret + namespace secret 3 가지에 집중.
chart 의 template 자체는 수정 불필요.

### 5.6 검증

```bash
kubectl -n payment-dev describe pod $(kubectl -n payment-dev get pod -l app.kubernetes.io/component=transfer -o name | head -1) \
  | grep -E "^\s+Image:"
# 기대: containers.kr-central-2.kakaocloud.com/payment-platform/transfer:<sha>
```

### 5.7 마이그레이션 시점의 GHCR cleanup

이전 후 GHCR 의 옛 이미지를 점진적 정리. 운영 안정화 (30-90 일) 후 일괄 삭제 권장.

## 6. Consequences

### 6.1 긍정적 결과

1. **EPIC 2 / EPIC 3 의 모든 task 가 추가 비용 없이 동작** — public GHCR 의 무제한 무료 활용.
2. **마이그레이션 비용 사전 평가** — chart values 만 바꾸면 되는 구조 (1 줄 변경)임이 ADR 에 검증되어
   있어 실 운영 진입 시 의사결정 빠름.
3. **포트폴리오 평가자의 즉시 재현 가능** — KT Cloud 계정 없이 GitHub 계정만으로 본 프로젝트의 모든
   산출물 재현 가능.

### 6.2 부정적 결과 (수용)

1. **regulatory 시연 부재** — 국내 결제 도메인의 실제 운영에 필요한 KT Cloud 사용 경험이 본 프로젝트
   산출물에서는 직접 시연되지 않음. ADR 본문이 그 빈자리를 일부 보완.
2. **국내 region 성능 데이터 부재** — § 4.2 의 latency 수치는 vendor 발표 기준이고 실측 데이터 아님.
   실 운영 진입 시점에 측정 보강 필요.

### 6.3 미채택의 결과 (KT Cloud 를 안 쓰는 비용)

- 채용 면접에서 "KT Cloud 사용 경험" 항목 답이 "ADR 으로 사용 시나리오를 정리했고, chart 의 image
  registry 추상화로 마이그레이션 비용을 1 줄로 축소했습니다" 가 됨. 실제 사용 경험은 없으나 의사결정
  과정의 사고 흐름은 전달 가능.

## 7. Alternatives Considered

### 7.1 KT Cloud Container Registry

- **장점**: 위 § 4 의 regulatory / 성능 / 비용 cross-over 시 강함.
- **단점**: 본 프로젝트의 $0 + 포트폴리오 컨텍스트에서 비용 발생, 채용 평가자가 재현 어려움.
- **결론**: 1 차 채택 안 함. § 5 시나리오로 마이그레이션 비용 < 시연 가치 의 임계점 도달 시 전환.

### 7.2 NAVER Cloud Container Registry / AWS ECR / GCP Artifact Registry

- **장점**: 각자 특정 클라우드 락인 시 자연스러움.
- **단점**: 본 프로젝트가 특정 cloud 의존 없는 portfolio 라 동일 trade-off (비용, 재현성).
- **결론**: 선택 후보로 보존하되 본 결정 cycle 에서는 미채택.

### 7.3 Self-hosted Harbor / Sonatype Nexus

- **장점**: 사내 망분리 환경에서 표준. UI / vulnerability scanning / proxy cache 등 풍부한 기능.
- **단점**: $0 + 운영 부담 제약 직접 충돌. controller 호스팅 + 인증 + 백업이 별도 운영 layer.
- **결론**: 시연 환경에서 미채택. 사내 환경 진입 시 Harbor 가 가장 가능성 높음.

### 7.4 Docker Hub

- **장점**: 가장 보편적 인지도.
- **단점**: 2023-03 의 무료 정책 축소 (pull rate limit 100/6h) 로 CI 친화성 ↓. 보안 스캐닝 별도 결제.
- **결론**: 사용 안 함.

## 8. Verification

본 결정이 작동함을 다음 산출물이 입증한다.

| 산출물 | 무엇을 보여주나 |
|---|---|
| `docs/registry.md` | 본 ADR 의 결정을 운영 절차로 옮긴 가이드 |
| `.github/workflows/ci.yml` | GHCR push 흐름 |
| `.github/workflows/ghcr-cleanup.yml` | untagged 이미지 자동 삭제 (R-B2-O2) |
| `charts/payment-platform/values.yaml` | `global.imageRegistry` 한 줄로 추상화 (§ 5.3 의 마이그레이션 비용 근거) |
| `docs/troubleshooting/2026-05-04-ghcr-retention-ui-personal-account.md` | GHCR UI 의 personal 계정 한계 + 자동화 우회 |
| `docs/troubleshooting/2026-05-31-trivy-gate-libgnutls30-base-image-cve.md` | GHCR 이미지의 OS 패치 정책 |

## 9. References

- [GitHub Container Registry docs](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [KT Cloud Container Registry 안내](https://docs.ktcloud.com/) (vendor docs)
- 본 프로젝트의 `docs/registry.md` (운영 절차)
- 본 프로젝트의 `docs/troubleshooting/2026-05-04-self-inflicted-latest-tag-policy-violation.md`
  (registry 정책의 자기 검증 사례)
