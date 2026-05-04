# test-all.sh 가 service 디렉토리로 cd 하지 않아 pytest collection 이 실패한 사례

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (사용자가 1차 검증 명령에서 즉시 차단됨) |
| **Affected** | `scripts/test-all.sh` 첫 도입 직후 |
| **Tags** | `pytest`, `cwd`, `rootdir`, `pythonpath`, `bash`, `verification-gap` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

EPIC 1 의 단위 테스트 일괄 실행을 위한 `scripts/test-all.sh` 가 **service 디렉토리로 cd 하지 않은 채 venv 의 pytest 만 절대경로로 호출**해서, pytest 가 project root 를 rootdir 로 잡고 5개 service 의 test 파일을 한꺼번에 collect 하다 모두 ImportError(`from main import app`) 로 실패했다. 원인은 코드 결함이지만, 그보다 더 중요한 **프로세스 결함**은 스크립트를 commit 전에 실제로 실행해보지 않은 것이다. 본 사건을 계기로 CLAUDE.md A-5 (실행 가능 산출물 검증 규칙) 을 신설했다.

---

## Symptom

```bash
$ ./scripts/test-all.sh
=== _template ===
  creating venv...
ERROR services/loan/tests/test_main.py
ERROR services/notification/tests/test_main.py
ERROR services/transfer/tests/test_main.py
!!!!!!!!!!!!!!!!!!! Interrupted: 5 errors during collection !!!!!!!!!!!!!!!!!!!!
5 errors in 0.57s
  FAIL

=== account ===
ERROR services/loan/tests/test_main.py
... (동일 5건 error)
  FAIL

... (5개 service 모두 동일 패턴 반복)

========================================
Result: 0 pass, 5 fail _template account transfer loan notification
```

`_template` 이 collect 하고 있는 게 자기 tests 가 아니라 `services/loan/...` 등 다른 service 의 tests 라는 점이 결정적 단서.

---

## Investigation & Root cause

### 1차 가설 (오답): pytest 의존성 미설치 또는 venv 손상

각 service 마다 `creating venv...` 가 찍히고 있어 venv 자체는 새로 만들어진다.
설치도 정상으로 돌고 있다. 의존성 문제는 아님.

### 진단 — 실제 어떤 디렉토리에서 collect 가 일어나는가

스크립트의 pytest 호출 부분을 확인:

```bash
"$dir/.venv/bin/pytest" --tb=short -q
```

`$dir = services/<svc>` 이지만 **cd 가 없음**. 즉 cwd 는 사용자가 스크립트를 실행한 곳(project root) 그대로다.

### 확정 원인

pytest 의 rootdir/pythonpath 결정 로직:

1. **rootdir**: cwd 에서 시작해 위로 올라가며 첫 번째 `pytest.ini` / `pyproject.toml[tool.pytest.ini_options]` / `tox.ini` 를 찾는 디렉토리.
2. project root 에는 어느 것도 없으므로 cwd (= project root) 자체가 rootdir 가 됨.
3. **collection**: rootdir 부터 재귀적으로 `test_*.py` / `*_test.py` 수집.
4. → 5개 service 의 test 파일을 모두 발견.
5. 각 test 파일 첫 줄: `from main import app`.
6. project root 의 sys.path 에는 어느 service 의 디렉토리도 없음 → ImportError.

```
잘못된 호출 흐름:
project root  ──  pytest 절대경로 호출  ──  cwd=project root
                                                │
                                                ▼
                                  rootdir=project root, pythonpath 미적용
                                                │
                                                ▼
                                  services/*/tests/* 5개 모두 collect
                                                │
                                                ▼
                                  from main import app 모두 실패
```

**핵심 오해**: "절대 경로로 venv 의 pytest 를 호출하면 pytest 가 알아서 그 venv 위치 기준으로 동작할 것"이라고 추론. 사실 binary 위치와 cwd 는 완전히 독립이며, pytest 의 rootdir 는 cwd 에 의해 결정된다.

---

## Fix

### 즉시 복구 — 서브셸로 cd 후 호출

```bash
if (cd "$dir" && ./.venv/bin/pytest --tb=short -q) 2>&1 | tail -5; then
    ...
```

서브셸 `(cd ...; ...)` 로 감싸 cwd 변경이 다음 iteration 에 누출되지 않게 한다.

### 장기 방어 — 프로세스 변경

코드 결함의 단발 수정보다 더 중요한 건, **commit 전에 실제로 실행하지 않은 것**이 본 사건의 진짜 원인이라는 인정.
이를 막기 위해 `CLAUDE.md` 에 **A-5: 실행 가능 산출물 검증 규칙** 신설.

> `bash -n` 같은 syntax 검사는 동작 검증이 아니다. 실행 가능한 산출물을 작성·수정한 후에는
> 실제로 실행해서 의도대로 동작함을 확인한 다음에야 commit 한다.
> 검증 불가 사유가 있으면 commit 메시지에 명시한다.

검증 후 sandbox 에서 5/5 PASS 확인.

---

## Lessons learned

1. **pytest 는 invocation 의 cwd 에 강하게 의존한다.** 절대 경로로 binary 를 호출하더라도 rootdir/pythonpath 는 cwd 기준. "어떤 디렉토리에서 어떤 명령을 호출하느냐" 는 모든 pytest 자동화의 첫 번째 점검 항목.
2. **"기존에 통과한 형태와 동일한 패턴"을 임의로 바꾸지 않는다.** 직전 검증에서 `(cd X && pytest)` 가 통과했다면 그 형태를 유지. "절대경로 호출이 더 깔끔하다" 같은 미적 개선은 **반드시 재검증** 필수.
3. **`bash -n` 은 동작 검증이 아니다.** syntax 만 본다. 함수 호출 순서, 환경 변수, 외부 도구 호출, exit code 처리 등은 syntax 검사로 잡히지 않는다.
4. **CLAUDE.md A-5 신설**: 모든 실행 가능 산출물(`*.sh`, Dockerfile, K8s manifest, GHA workflow, Helm chart, Python script) 은 commit 전 실제 실행으로 검증. 검증 불가 시 그 사유를 commit 메시지에 명시.
5. **추론 vs 검증의 혼동이 본 프로젝트의 가장 흔한 회귀 원인**임을 인지. "X 는 Y 와 동치일 것" 같은 추론은 모두 검증 대상. 시간 절약 차원의 추론 무검증은 결과적으로 더 많은 시간을 잡아먹는다.
