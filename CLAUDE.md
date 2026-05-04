# 프로젝트 작업 지침 (Claude 응답 전 항상 검토)

본 문서는 사용자가 Claude에게 매 응답 시 준수하도록 요청한 운영 규칙이다.
응답을 작성하기 전에 반드시 이 문서의 모든 항목을 점검하고, 위배되는 부분이 없는지 확인한 뒤 답한다.

---

## A. 응답 작성 규칙

### A-1. "가이드를 줘"라는 요청을 받은 경우
- **그대로 따라하면 끝까지 동작하는 수준**으로 구체적·자세하게 작성한다.
- 누락 없이 다음 요소를 포함한다.
  - 실행 환경/사전 조건 (OS, 설치된 도구 버전 등)
  - **복붙 가능한 명령어** (쉘에 그대로 입력 가능한 형태)
  - 명령어 실행 시 **예상 출력**과 **성공 판정 기준**
  - 자주 발생하는 오류와 해결 방법
  - 다음 단계로 넘어가기 전 검증 절차
- "이렇게 하면 됩니다" 수준의 추상적 안내는 금지. 단계 번호, 명령, 결과 캡처 포인트까지 명시한다.

### A-2. 기술/스택 추천 규칙 (매우 중요)
- 추천하는 모든 기술·도구·라이브러리·이미지 태그·차트 버전은 **2026년 현재 다수 기업이 실사용 중인 안정 버전**이어야 한다.
- 다음은 절대 추천 금지:
  - deprecated 되었거나 보안 패치가 끊긴 버전
  - 커뮤니티에서 사실상 사용되지 않는 레거시 방식
  - 너무 최신이라 베타/RC 단계인 버전 (포트폴리오 신뢰도 저하)
- **기술 스택 추천 전에는 반드시 최신 정보를 검색**하여 검증한다.
  - WebSearch / WebFetch / 공식 릴리스 노트 확인 필수
  - 검색 없이 학습 데이터만으로 버전을 단정하지 않는다
  - 버전을 명시할 때는 "2026년 X월 기준 최신 stable: vX.Y.Z" 형식으로 근거를 함께 제시한다

### A-3. 코드/파일 주석 작성 규칙 (학습용)
- 사용자는 **Python에 익숙하지 않다**. 따라서 모든 새 파일·소스코드에 **학습용 설명 주석**을 충분히 단다.
- 단계별 적용:
  - **파일 상단**: 파일 목적·역할·이 파일이 시스템에서 차지하는 위치 (Python은 docstring `"""..."""`, YAML/Shell은 `#` 블록)
  - **함수/클래스**: 무엇을 하는지, 왜 필요한지, 인자·반환값 의미. 비자명한 부작용 명시
  - **언어 특유 문법이 등장하는 줄**: 그 문법이 무엇을 의미하는지 한 줄 주석
    - Python: `async`/`await`, `@데코레이터`, `with`/`async with`, type hint, f-string, list/dict comprehension, `*args`/`**kwargs`, generator/`yield`, dataclass/Pydantic BaseModel 상속, `__future__` import 등
    - YAML: 비자명한 필드(예: Istio `injectionTemplate`, K8s `securityContext.fsGroup`, Helm template 함수 `{{ include ... }}` 등)
    - Bash: `set -euo pipefail`, `${VAR:-default}`, heredoc, trap 등
  - **환경변수·매직 넘버**: 의미·기본값·왜 그 값인지
  - **자명한 줄**(`import os`, 단순 변수 할당 등): 주석 불필요
- YAML/JSON 매니페스트는 각 주요 필드 앞에 한두 줄로 "이 필드는 무엇을 의미하고 왜 이 값인지" 명시
- 주석은 **한국어**로 작성 (사용자 모국어). 단, 코드 식별자·기술 용어는 영문 그대로
- 주석이 코드보다 길어도 OK. 가독성·이해도 우선
- 기존 파일 수정 시에도 새로 추가한 부분은 동일 규칙 적용. 기존 무주석 영역도 가능하면 보강

### A-4. 트러블슈팅 기록 작성 규칙
- 프로젝트 진행 중 운영성 이슈(매니페스트 적용 실패, 도구 출력 함정, 빌드 깨짐, 타임아웃, 권한 거부, 알 수 없는 누락 등)에 부딪히면 단순 해결로 끝내지 않고 `docs/troubleshooting/` 에 **한 사건당 한 파일**로 기록한다.
- 파일명: `YYYY-MM-DD-<short-english-slug>.md` (영문 lowercase + 하이픈, 검색·정렬 친화적)
- 본문은 **한국어**로 작성. 명령어·로그·식별자는 영문 그대로.
- 다음 **5섹션을 반드시 포함**:
  1. **Summary** — 한 문단 TL;DR (무엇이 발생했고 무엇이 원인이었는지)
  2. **Symptom** — 운영자/사용자가 본 화면·로그·에러 메시지 (재현 명령 포함)
  3. **Investigation & Root cause** — 1차 가설(틀렸다면 그것도 명시), 진단 명령, 검증, 확정 원인
  4. **Fix** — 즉시 복구 절차 + 장기 방어 (관련 커밋 SHA 명시)
  5. **Lessons learned** — 일반화된 교훈. 같은 형태의 사건을 앞으로 피하거나 빠르게 감지하기 위한 메모
- 새 엔트리 추가 시 `docs/troubleshooting/README.md` 의 인덱스 표에도 한 줄 추가한다 (날짜, 파일명, 한 줄 요약, 심각도).
- 가벼운 사건이면 각 섹션을 1~2 문단으로 짧게 끝내도 OK. 단, **5섹션 자체는 생략하지 않는다.**
- 사건 유발 코드/매니페스트를 고치는 커밋 메시지 본문에 해당 troubleshooting 파일을 참조한다 (`See: docs/troubleshooting/...`).

### A-5. 실행 가능 산출물 검증 규칙 (Trust but Verify)
**`bash -n` 같은 syntax 검사는 동작 검증이 아니다.** 실행 가능한 산출물(`*.sh`, `Dockerfile`, K8s manifest, GHA workflow, Helm chart, Python script 등) 을 작성·수정한 후에는 **실제로 실행해서 의도대로 동작함을 확인한 다음에야 commit** 한다.

- **`*.sh`**: sandbox 가 허용하는 한 `bash <script>` 로 dry-run. 외부 의존(docker, kubectl) 이 없는 범위만이라도 실행. 가능하면 mock env 를 만들어 끝까지 실행.
- **`Dockerfile`**: `docker build .` (sandbox 에 docker 없으면 `hadolint` 또는 최소한 `--check` 옵션) 으로 검증.
- **K8s manifest**: `kubectl apply --dry-run=client -f <file>` 또는 `kubeval` / `kubeconform` 으로 schema 검증. 가능하면 실제 클러스터에 apply 한 후 `kubectl wait` 로 ready 대기까지 확인.
- **Helm chart**: `helm lint` + `helm template` 로 렌더 결과 검증.
- **GHA workflow**: `act` 또는 최소한 yamllint + 자체 schema 검증.
- **Python**: import + `python -m compileall` 이상으로, 가능하면 `pytest` 까지.

**검증 불가 사유가 있으면 commit 메시지에 명시한다** ("sandbox 에 docker 없어 build 미실행, 사용자가 로컬에서 검증 예정" 같이). 이 메모가 있으면 사용자가 다음 검증 단계를 의식하고, 없으면 통과로 가정한다.

**가정과 검증을 구분한다.** "절대 경로로 호출하면 cwd 무관할 것" 같은 추론은 **반드시 실행으로 검증**해야 한다. 추론 vs 검증의 혼동이 본 프로젝트의 가장 흔한 회귀 원인이다 (참조: `docs/troubleshooting/2026-05-04-test-all-script-pytest-collection-without-cd.md`).

---

## B. 프로젝트 컨텍스트

### B-1. 프로젝트 성격
- 본 리포지토리는 **DevOps 엔지니어 취업용 포트폴리오**다.
- 작업 우선순위:
  1. **DevOps 직무 역량의 함양과 시연** (CI/CD, IaC, K8s, 서비스 메시, 관측, 보안, 카오스, 런북, ADR 등)
  2. 위 산출물의 가독성·재현성·문서화 (README, 다이어그램, 스크린샷, 수치 비교)
  3. 애플리케이션 코드 (※ 의도적으로 최소화. 데모용 mock 수준)
- 따라서 모든 결정·제안은 **"채용 담당자/면접관에게 DevOps 역량을 잘 보여주는가?"**를 기준으로 한다.
- 애플리케이션 비즈니스 로직 고도화에는 시간을 쓰지 않는다.

### B-2. 로컬 작업 환경
- **호스트 OS**: Windows 11 Home, 25H2
- **CPU**: 11th Gen Intel Core i7-1165G7 @ 2.80GHz
- **RAM**: 16.0GB (사용 가능 15.7GB)
- **아키텍처**: 64-bit, x64
- **실제 작업 환경**: 호스트에 설치된 **Ubuntu 24.04 (WSL2 또는 듀얼부팅)** 위에서 진행
- 모든 셸 명령·경로·패키지 설치 가이드는 **Ubuntu 24.04 기준**으로 작성한다.
- 리소스 제약 인식: Istio + 4 services + Prometheus/Grafana/Kiali/Jaeger 동시 구동 시 메모리 압박이 있을 수 있으므로, 무거운 컴포넌트를 동시에 띄우는 가이드는 **메모리 사용량 추정치와 함께 단계적 기동 순서**를 제시한다.

---

## C. 자가 점검 체크리스트 (응답 직전 확인)

- [ ] "가이드"성 요청이라면 복붙 가능한 명령어와 검증 절차가 모두 포함되었는가?
- [ ] 추천한 모든 버전이 2026년 기준 stable한지 검색으로 확인했는가?
- [ ] DevOps 역량 시연이라는 본 프로젝트 목적에 부합하는가?
- [ ] 명령어가 Ubuntu 24.04에서 그대로 동작하는 형태인가?
- [ ] 16GB RAM 환경에서 실행 가능한 리소스 수준인가?
- [ ] `docs/requirements.md` 의 모든 항목(B/A 시리즈 33개, 본 프로젝트는 [선] 포함 전부 필수)이 현재 작업/계획에 매핑되어 있는가? `docs/BACKLOG.md` 와 `docs/traceability-matrix.md` 에서 R-ID 역참조를 점검했는가?
- [ ] 새로 작성·수정한 모든 파일·소스코드에 학습용 설명 주석이 충분히 들어갔는가? (특히 Python의 async/decorator/type hint, YAML 비자명 필드, Bash 특수 문법)
- [ ] 운영 이슈(증상-원인-해결의 사이클이 발생했는가)를 만났다면 `docs/troubleshooting/` 에 5섹션 포맷으로 기록하고 인덱스 README 도 갱신했는가?
- [ ] 새로 작성·수정한 실행 가능 산출물(`*.sh`/Dockerfile/manifest/workflow/Python script)을 **실제로 실행해서** 의도대로 동작함을 확인했는가? (`bash -n` 만으로는 부족)
