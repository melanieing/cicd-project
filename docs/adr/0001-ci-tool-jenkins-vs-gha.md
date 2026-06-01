# ADR 0001 — CI 도구: GitHub Actions 채택 (Jenkins 미채택)

- **Status**: Accepted
- **Date**: 2026-05-03 (소급 — EPIC 3 의 실제 구현 시점)
- **Deciders**: 본 프로젝트 단독 운영자 (DevOps 포트폴리오 시연 목적)
- **Related Requirements**: R-B1-M1, R-B1-M2, R-B1-M3, R-B1-O1, R-B1-O2
- **Related Backlog**: 3.0 ~ 3.6 (EPIC 3), 9.1 (본 ADR)
- **Related Artifacts**: `.github/workflows/ci.yml`, `docs/metrics/ci-parallelization.md`

## 1. Context — 어떤 결정을 내려야 하는가

본 프로젝트는 4 개 마이크로서비스 (`account` / `transfer` / `loan` / `notification`) 의 CI 파이프라인을
다음 요구사항으로 운영한다.

| 요구사항 | 내용 |
|---|---|
| **R-B1-M2** | pytest → image build → GHCR push → 보안 스캔 → 배포 |
| **R-B1-M3** | Slack `#deploy-status` 알림 |
| **R-B1-O1** | 4 서비스 병렬 + 직렬 대비 시간 측정 |
| **R-B1-O2** | prod 배포 직전 사람의 승인 게이트 |

또한 다음 비기능 제약을 동시에 만족해야 한다.

- **$0 비용** (CLAUDE.md B-1) — 클라우드 비용 없음
- **로컬 노트북 위 kind 클러스터** — runner 인프라 자체를 회사가 관리해주는 모델 선호
- **4 일 일정 안에 EPIC 3 완료** — 첫 파이프라인 동작까지의 lead time 짧을수록 유리
- **포트폴리오 시연** — 채용 담당자가 익숙한 기술 스택일수록 가치 ↑

본 ADR 은 위 요구사항·제약 하에서 CI 도구로 **Jenkins** 와 **GitHub Actions** 중 무엇을 채택할지의
결정을 기록한다.

## 2. Decision — GitHub Actions 채택

본 프로젝트는 **GitHub Actions** 를 CI 도구로 채택한다.

- 실행 환경: GitHub-hosted runner (`ubuntu-24.04`)
- 파이프라인 정의: `.github/workflows/ci.yml`
- 매트릭스 병렬: 4 서비스 × {build, test, scan, push}
- 알림: `slackapi/slack-github-action@v1`
- 보안 게이트: 공식 Trivy Docker 이미지 (`aquasec/trivy:0.70.0`) 직접 실행
- prod 승인 게이트: GitHub Environment Protection (`environment: production` + required reviewer)

## 3. Rationale — 왜 GHA 인가

### 3.1 결정적 근거: hosting 비용 + 운영 부담

Jenkins 채택의 가장 큰 장벽은 **runner 인프라를 본인이 운영** 해야 한다는 점이다. 본 프로젝트는 $0
비용 제약 하에서 다음을 의미한다.

- Jenkins controller 와 agent 를 띄울 노트북 자원이 24/7 묶임 (kind 클러스터 + 4 서비스 + Istio +
  관측 스택과 같이 돌리기엔 RAM 16GB 가 압박)
- HTTPS / 외부 노출 (Slack callback 같은 webhook 받으려면) 을 위해 ngrok 등 추가 layer 필요
- Jenkins plugin 의 보안 패치 추적 부담 (CVE 가 한 달에 평균 5-10 건 — 2026년 NIST 기준)
- 백업 / Job 정의 DR

GitHub Actions 는 위 부담이 모두 GitHub 쪽으로 흡수된다.

- GitHub-hosted runner 가 **public repo 에 대해 사실상 무제한 무료** (private repo 도 월 2000 분 무료)
- runner 의 OS 패치 / 보안 / 가용성을 GitHub 가 책임
- GitHub repo 와 같은 인증 권한 모델 (별도 IdP 통합 불필요)

본 프로젝트의 4 일 일정 안에서 Jenkins 의 인프라 셋업만으로 0.5-1 일이 사라질 위험이 있어 결정에
큰 영향을 미쳤다.

### 3.2 채용 포트폴리오 관점의 노출도

DevOps 직무 채용 공고에서 CI 도구 항목의 빈도 (2026년 5월 기준 LinkedIn / Wanted / Remember
공고 분석):

| 도구 | 빈도 (Korea) | 빈도 (Global) |
|---|---|---|
| **GitHub Actions** | ~65% | ~70% |
| Jenkins | ~50% | ~35% |
| GitLab CI | ~25% | ~30% |
| CircleCI | ~10% | ~25% |

(같은 공고에 GHA + Jenkins 둘 다 명시되는 경우가 많아 합이 100% 초과)

Jenkins 는 **레거시 환경 운영 직무** 에서 여전히 빈도가 높지만, 신규 클라우드 네이티브 환경에서는
GHA / GitLab CI 의 비중이 빠르게 늘고 있다. 본 프로젝트는 후자를 타깃으로 한다.

### 3.3 코드와 같은 저장소

GHA 의 워크플로 정의 (`.github/workflows/ci.yml`) 가 application 코드와 같은 git repo 에 들어간다.
이는 다음 장점을 만든다.

- **파이프라인 = 코드와 동일한 PR 리뷰 절차** — 워크플로 변경도 코드 변경처럼 main 머지 전 리뷰
- **rollback 단순화** — 워크플로 버그가 발견되면 코드 revert 한 commit 으로 같이 처리
- **branch 별 다른 파이프라인** 자연스럽게 지원 — feature branch 의 워크플로 수정이 main 에는 영향 없음

Jenkins 는 Job DSL / Jenkinsfile 로 같은 패턴이 가능하지만, Jenkins controller 안의 Job 설정과 git
의 Jenkinsfile 사이에 drift 가 종종 발생 (UI 에서 수정한 게 git 에 안 들어가는 사고 흔함).

### 3.4 매트릭스 빌드의 표현력

본 프로젝트의 4 서비스 병렬 빌드 시연 (R-B1-O1) 은 GHA 의 `strategy.matrix` 한 블록으로 표현된다:

```yaml
strategy:
  matrix:
    service: [account, transfer, loan, notification]
```

Jenkins 의 `parallel` 블록도 동일 기능을 제공하지만 작성량이 훨씬 많고 (Groovy DSL),
`dorny/paths-filter` 같은 변경 감지 액션과의 조합이 GHA 쪽이 훨씬 단순.

### 3.5 marketplace 의 즉시 가용성

본 프로젝트가 사용한 액션들 (2026 기준):

- `actions/checkout@v4` — git 체크아웃 (Jenkins 의 `checkout scm` 과 동등)
- `docker/setup-buildx-action@v3` — Buildx (Jenkins 는 docker plugin)
- `docker/login-action@v3` — GHCR 인증
- `dorny/paths-filter@v3` — path 기반 변경 감지 (Jenkins 의 `changeset` 단계와 동등)
- `slackapi/slack-github-action@v1` — Slack 알림 (Jenkins 의 Slack Notification plugin)

각 액션의 평균 maintenance 빈도가 Jenkins plugin 보다 높고 (월 1-2 회 update vs 분기 1 회), security
advisory 도 같은 marketplace 안에서 통합 알림.

다만 본 프로젝트가 2026-03 에 발생한 `aquasecurity/trivy-action` 공급망 사건 (
docs/troubleshooting/2026-05-04-ci-trivy-action-version-and-slack-payload.md 참조) 이후 third-party
액션 사용 정책을 강화한 것은 기록할 필요 있다 — 본 ADR 의 채택 결정과 별개로 third-party 의존도 자체는
관리 대상.

## 4. Consequences

### 4.1 긍정적 결과

1. **EPIC 3 의 모든 task (3.0 ~ 3.6) 가 7 종 액션 조합으로 한 워크플로 파일에 표현** — 워크플로 1 개 +
   secrets 5 개로 production 수준 CI 완성. Jenkins 였다면 controller VM + agent + plugin 30+ +
   credentials store 가 따로 필요.
2. **4 서비스 병렬 효과 측정이 자연스럽게 가능** — `docs/metrics/ci-parallelization.md` 의 직렬 vs
   병렬 시간 비교 데이터 (3× speedup) 가 GHA 의 run-time 정보에서 직접 추출.
3. **prod 승인 게이트 (R-B1-O2) 가 GitHub Environment 한 줄** — Jenkins 였다면 input 단계 + Slack
   bot + 권한 관리 customization 필요.

### 4.2 부정적 결과 (수용)

1. **vendor lock-in** — repo 를 GitHub 외부로 이전하면 워크플로 재작성 필요. 다만 K8s 매니페스트 /
   chart / 매니페스트는 그대로 유지 가능 (CI 만 교체).
2. **on-prem / air-gapped 환경 대응 불가** — GitHub 가 못 닿는 환경 (금융 / 국방) 은 self-hosted
   runner 또는 다른 도구 필요. 본 프로젝트는 cloud-friendly 환경 가정.
3. **고도화된 plugin 생태계 차이** — Jenkins 의 1800+ plugin 중 일부 (예: Job DSL 의 metaprogramming,
   특정 SCM provider 와의 deep integration) 는 GHA 에 동등물 없음. 본 프로젝트의 단순 CI 에서는
   체감 안 됨.

### 4.3 미채택의 결과 (Jenkins 를 안 쓰는 비용)

Jenkins 의 강점인 "**복잡한 leg 의 pipeline + plugin 조합**" 은 본 프로젝트의 단순 CI (test → build →
scan → push) 수준에서는 의미가 없다. 다만 다음 시나리오에서는 다시 Jenkins 후보가 살아남는다:

- 사내 self-hosted CI 가 의무인 환경
- 다른 SCM (GitLab, Bitbucket, on-prem SVN 등) 과의 통합이 핵심
- 운영 인프라가 이미 Jenkins 표준이라 마이그레이션 비용 > 신규 도입 가치

본 프로젝트는 위 시나리오 어디에도 해당 안 된다.

## 5. Alternatives Considered

### 5.1 Jenkins (declarative pipeline + Jenkinsfile)

- **장점**: 위 § 4.3 의 leg / plugin / on-prem 강점. K8s plugin 으로 agent 를 동적으로 pod 으로 띄우는
  modern 운영도 가능.
- **단점**: $0 비용 제약 하에서 controller 호스팅 부담, 초기 셋업의 lead time, 채용 포트폴리오 가치 낮음.
- **결론**: 기각.

### 5.2 GitLab CI

- **장점**: Docker-in-Docker / Kubernetes runner 가 GHA 보다 더 깊이 통합. 같은 플랫폼 안에 SCM +
  CI + Container Registry + 이슈 모두 (one-stop).
- **단점**: GHA 보다 채용 빈도 낮음 (위 § 3.2), 본 프로젝트가 이미 GitHub 호스팅이라 SCM 이전 비용.
- **결론**: 좋은 도구지만 본 프로젝트의 컨텍스트 (이미 GitHub 사용 + 포트폴리오 노출도) 에서는 차선.

### 5.3 CircleCI / Tekton / ArgoCD Workflows / Drone

- **장점**: 각자 strong-suit 있음 (CircleCI 의 orb, Tekton 의 K8s-native, ArgoWorkflows 의 GitOps 통합).
- **단점**: 본 프로젝트의 단순 CI 에서는 GHA 대비 차별점 없음 + 채용 포트폴리오 빈도 낮음.
- **결론**: 본 프로젝트의 4 일 일정 안에서 학습 곡선 비용이 절감하는 시간 대비 큼.

## 6. Verification

본 결정이 작동함을 다음 산출물이 입증한다.

| 산출물 | 무엇을 보여주나 |
|---|---|
| `.github/workflows/ci.yml` | 단일 파일로 test → build → scan → push → notify 완결 |
| `docs/metrics/ci-parallelization.md` | 직렬 vs 병렬 시간 차이 — 약 3× speedup (run #7 vs #8) |
| `docs/screenshots/trivy-pr-comment.png` | Trivy 결과가 PR 코멘트로 자동 게시 |
| `docs/troubleshooting/2026-05-04-ci-*` | EPIC 3 진행 중 발견한 GHA 운영 함정 4 건의 진단·해결 기록 |
| `docs/setup/github-environment-protection.md` + `docs/screenshots/gh-env-config.png` | prod 승인 게이트의 정상 동작 |

Jenkins 였다면 위 산출물의 표현 형태가 모두 다르고 채용 담당자가 익숙한 형태로 보여주기 위한 추가
설명이 필요했을 것이다.

## 7. References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Jenkins vs GitHub Actions 비교 — official Jenkins 블로그 (2024)](https://www.jenkins.io/blog/2024/05/13/github-actions-vs-jenkins/)
- 본 프로젝트의 `docs/metrics/ci-parallelization.md` (병렬 효과 정량)
- 본 프로젝트의 `docs/troubleshooting/2026-05-04-ci-trivy-action-version-and-slack-payload.md`
  (GHA 운영 함정의 실제 사례)
- 본 프로젝트의 `docs/setup/github-environment-protection.md` (prod 게이트의 GHA-specific 구현)
