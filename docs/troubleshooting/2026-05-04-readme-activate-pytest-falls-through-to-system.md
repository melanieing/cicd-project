# 서비스 README 의 `source activate + pytest` 흐름이 system pytest 를 잡아 ImportError

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (사용자가 첫 검증 명령에서 막힘, 두 번째 발생) |
| **Affected** | services/{_template, account, transfer, loan, notification}/README.md, root README.md |
| **Tags** | `pytest`, `venv`, `activate`, `path`, `documentation`, `verification-gap` |
| **Related commits** | (이 사건을 수정하는 커밋), CLAUDE.md A-5 신설 직후 발생 |

---

## Summary

서비스 README 의 단위 테스트 절차가 `source .venv/bin/activate` 후 `pytest` 형태였는데,
system 에 동일 이름 pytest 가 있는 환경에서는 PATH 우선순위 또는 activate 누락으로
**system pytest 가 잡혀 ImportError(`No module named 'fastapi'`)** 가 발생.
근본 결함은 코드(README) 가 짧은 이름(`pytest`/`pip`)에 의존한 것.
근본 결함은 프로세스 — A-5 신설 직후인데도 **기존 README 의 명령들을 소급 검증하지 않았음**.
fix 는 venv 의 binary 를 직접 절대 경로로 호출(`./.venv/bin/pytest`)하는 형태로 변경 + sandbox 에서 실제 실행 검증.

---

## Symptom

```bash
$ cd services/account
$ python -m venv .venv && source .venv/bin/activate
$ pip install -r requirements.txt
$ pytest
============================= test session starts ==============================
platform linux -- Python 3.12.3, pytest-7.4.4, pluggy-1.4.0 -- /usr/bin/python3
                                       ▲                          ▲
                              우리가 핀한 8.x 가 아님          system Python (venv 가 아님)
cachedir: .pytest_cache
rootdir: /home/melan/cicd-project/services/account
configfile: pytest.ini
testpaths: tests
collected 0 items / 1 error

ERROR collecting tests/test_main.py
ImportError while importing test module '.../test_main.py'.
tests/test_main.py:15: in <module>
    from fastapi.testclient import TestClient
E   ModuleNotFoundError: No module named 'fastapi'
```

핵심 단서 두 개:
- `pytest-7.4.4` (우리는 `>=8,<9` 핀)
- `/usr/bin/python3` (venv 가 아닌 system Python)

→ 어떤 이유로든 venv 가 활성 상태가 아닌 채로 `pytest` 가 호출됨.

---

## Investigation & Root cause

### 가능한 원인 (어느 하나여도 같은 증상)

1. `&&` 체인 중 하나가 silent 실패해서 activate 가 안 됨 (예: 이전에 같은 이름 venv 가 있어 충돌)
2. 사용자가 새 터미널에서 일부 줄만 복붙
3. system 에 pytest 가 설치되어 있고, activate 후 PATH 가 의도대로 prepend 되지 않은 환경

### 본질

위 셋 다 가능성이 있고, 어떤 게 실제 원인이든 **`source activate` + 짧은 이름 명령** 패턴은 환경 의존이 너무 크다.
이 패턴은 다음을 모두 가정한다:
- activate 가 정상 실행됨
- PATH prepend 가 의도대로 적용됨
- system 에 같은 이름 도구가 우선순위로 없음
- 사용자가 모든 줄을 누락 없이 한 셸에서 실행

가정이 4개나 쌓이면 그중 하나라도 어긋나는 환경에서 깨진다. 포트폴리오 데모용 명령으로는 부적합.

### 메타 결함 — 프로세스

CLAUDE.md A-5 (실행 가능 산출물 검증 규칙) 가 직전에 신설됐음에도, **기존에 작성된 문서의 명령들을 소급 검증하지 않았다.**
A-5 의 정신은 "산출물을 commit 전 실행" 인데, 이미 commit 된 산출물도 다시 의심받는 상황이면 같은 점검을 적용했어야 했다.

---

## Fix

### 즉시 복구 — `./.venv/bin/<binary>` 직접 호출

5개 서비스 README + root README 의 명령을 다음 패턴으로 변경:

```bash
# 변경 전 (취약):
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pytest

# 변경 후 (강건):
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
./.venv/bin/pytest
```

장점:
- activate 와 무관 (PATH 의존 제거)
- system 의 같은 이름 도구가 절대 잡히지 않음
- 일부만 복붙해도 안전 (각 줄이 독립적)
- venv 위치를 절대 경로로 명시하므로 디버깅도 쉬움

### Sandbox 검증

```bash
# 깨끗한 디렉토리로 복사 후 README 의 명령을 그대로 실행
$ rm -rf /tmp/svc-test && cp -r services/account /tmp/svc-test
$ cd /tmp/svc-test
$ python3 -m venv .venv
$ ./.venv/bin/pip install -q -r requirements.txt
$ ./.venv/bin/pytest
============================= test session starts ==============================
platform linux -- Python 3.11.15, pytest-8.4.2, pluggy-1.6.0 -- /tmp/svc-test/.venv/bin/python3
collected 2 items
tests/test_main.py::test_health_returns_ok PASSED                        [ 50%]
tests/test_main.py::test_open_action_echoes_payload PASSED               [100%]
============================== 2 passed in 0.37s ===============================
```

핀한 pytest 8.4.2 + venv 의 python3 가 정확히 사용됨.

### 장기 방어

A-5 의 의도를 강화하기 위한 **추가 운영 원칙**:
- 새 규칙(`CLAUDE.md A-N`) 이 신설되면, 다음 기회에 **기존 산출물 전체 소급 적용** 한다.
  단발성 사건만 처리하면 같은 카테고리 결함이 다른 파일에 잠재한 채로 남는다.

---

## Lessons learned

1. **`source activate` 의존 흐름은 데모/문서에 부적합.**
   activate 는 환경 가정이 많아 깨질 수 있다. 데모나 README 명령은 `./.venv/bin/<binary>` 처럼
   **절대 경로 호출** 로 환경 의존을 제거하는 게 안전하다.
2. **새 규칙 신설 ≠ 기존 산출물에 자동 적용.**
   A-5 신설 직후 같은 카테고리 결함이 다른 파일에서 발견된 사례.
   신설 시 **기존 산출물 전체를 한 번 sweep** 해야 동일 결함이 잠재한 채로 남지 않는다.
3. **에러 첫 줄(`platform linux -- Python ... pytest-X.Y.Z -- /path/to/python`) 을 항상 본다.**
   이 한 줄로 어느 Python 과 어느 pytest 가 실행 중인지 즉시 알 수 있어,
   "venv 가 안 잡혔다" 같은 진단을 1초 안에 끝낼 수 있다.
4. **README 의 명령도 코드다.** Trust but Verify 의 대상은 `*.sh` 만이 아니라 README 의
   복붙 가능한 명령 블록 전부. 새 명령을 적을 때마다 sandbox 에서 그대로 실행해본 결과가 통과해야 한다.
