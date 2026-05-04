# uvicorn 로컬 실행 시 asyncpg 가 localhost:5432 에 접속 못 하는 사례

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 낮음 (사용자 setup 단계의 문서 누락) |
| **Affected** | 4 서비스(account/transfer/loan/notification) 의 로컬 uvicorn 실행 |
| **Tags** | `asyncpg`, `kubectl-port-forward`, `local-dev`, `lifespan`, `timeout` |
| **Related commits** | (이 문서를 첨부하는 docs 보강 커밋) |

---

## Summary

서비스를 host 에서 `uvicorn main:app` 으로 띄우면 asyncpg lifespan 단계에서 `localhost:5432` 접속을 시도하다가 60초 timeout 후 application startup failed 로 종료된다.
원인은 단순 — postgres 가 kind 클러스터 안의 `payment-dev/postgres` Service 로만 떠 있고 host 의 5432 포트에는 아무것도 listen 하지 않기 때문.
해결은 `kubectl port-forward` 한 줄. 다만 이 단계가 서비스 README 의 "로컬 실행" 절차에 빠져 있어 새로 받은 사람은 거의 100% 한 번 막힌다.

---

## Symptom

```bash
$ cd services/account
$ source .venv/bin/activate
$ export $(grep -v '^#' .env.example | xargs)
$ uvicorn main:app --host 0.0.0.0 --port 8001 --reload
INFO:     Will watch for changes in these directories: [...]
INFO:     Uvicorn running on http://0.0.0.0:8001
INFO:     Started reloader process
INFO:     Started server process
INFO:     Waiting for application startup.
2026-05-04 09:13:28,106 INFO account - Initializing DB pool: min=1 max=5
ERROR:    Traceback (most recent call last):
  File ".../asyncpg/connect_utils.py", line 802, in _create_ssl_connection
    tr, pr = await loop.create_connection(...)
  File "uvloop/loop.pyx", line 2033, in create_connection
asyncio.exceptions.CancelledError
...
  File ".../starlette/routing.py", line 638, in lifespan
    async with self.lifespan_context(app) as maybe_state:
...
  File "main.py", line 100, in lifespan
    state["db_pool"] = await asyncpg.create_pool(...)
...
  File "/usr/lib/python3.12/asyncio/timeouts.py", line 115, in __aexit__
    raise TimeoutError from exc_val
TimeoutError
ERROR:    Application startup failed. Exiting.
```

---

## Investigation & Root cause

### 1차 가설 (오답): asyncpg/Postgres 설정 오류

처음에는 라이브러리 설치 / SSL 협상 / 인증 정보 같은 곳을 의심했다.
그러나 에러 흐름을 끝까지 따라가면 `loop.create_connection(...)` 단계에서 멈췄다 — TCP layer 에서 이미 못 가고 있다.

### 진단 명령

```bash
# host 에서 5432 가 열려 있는지
ss -ltnp | grep 5432
# (출력 없음)

# kind 클러스터 안의 postgres Service 는 살아있는가
kubectl -n payment-dev get svc postgres
# postgres   ClusterIP   10.96.x.y   <none>   5432/TCP   ...
```

### 확정 원인

- `.env.example` 의 `DATABASE_URL` 은 `postgresql://payment:payment@localhost:5432/account_db`
- postgres 는 kind 의 cluster network(`10.96.x.y:5432`) 에서만 listen
- host 의 `localhost:5432` 는 비어 있음 → asyncpg 가 60s 동안 connect 시도 후 timeout

요약:

```
host                                   kind cluster
┌──────────────┐                       ┌──────────────────────────────┐
│ uvicorn      │                       │  payment-dev/postgres        │
│  asyncpg     │ -- TCP 5432 ----X     │   ClusterIP 10.96.x.y:5432   │
│              │   (host 에 없음)      │                              │
└──────────────┘                       └──────────────────────────────┘
```

`kubectl port-forward` 가 host 의 5432 ↔ Service 의 5432 를 잇는 임시 터널이 된다.

---

## Fix

### 즉시 복구 (택1)

**(A) 권장 — port-forward**

```bash
# 별도 터미널에서 (실행 중 유지)
kubectl -n payment-dev port-forward svc/postgres 5432:5432
```

다시 uvicorn 실행 → readiness 200.

**(B) 빠르게 /health 만 — DATABASE_URL 비우기**

```bash
unset DATABASE_URL
uvicorn main:app --host 0.0.0.0 --port 8001 --reload
```

lifespan 이 DB 분기를 스킵 (warning 1줄). `/health` 200, `/health/ready` 503.

### 장기 방어

- `services/{_template, account, transfer, loan, notification}/README.md` 의
  "로컬 실행" 절차에 **port-forward 단계를 가장 위에 명시**.
- README 를 두 섹션으로 분리:
  - "단위 테스트 (Task 1.5 검증)" — pytest 만 (DB 불필요)
  - "로컬 실행 (e2e)" — port-forward 필수
  → 새 컨트리뷰터가 어느 단계의 검증인지 헷갈리지 않게.

---

## Variant — pytest 도 같은 셸 오염으로 실패한다

같은 셸에서 e2e 검증을 위해 `export DATABASE_URL=...localhost:5432...` 한 후
별도로 `pytest` 를 돌리면 동일한 TimeoutError 가 재현된다.

원인:

```python
# 5개 test_main.py 가 공통으로 가진 코드 (수정 전):
os.environ.setdefault("DATABASE_URL", "")
                ▲
                "이미 설정된 값이 있으면 그걸 존중" 의미
```

`setdefault` 는 셸 환경의 값을 보존하므로, 셸에 `DATABASE_URL` 이 이미 export 되어 있으면
빈 문자열로 강제하지 못한다. lifespan 은 그 값으로 connect 시도 → 60s timeout → 테스트 실패.

### Fix

5개 테스트 파일에서 `os.environ.setdefault(...)` 를 `os.environ[...] = ...` 로 변경.
**테스트 격리는 결정성이 우선** 이므로 셸에 어떤 값이 떠 있어도 강제로 덮어쓴다.
"외부 주입 값 존중" 이라는 setdefault 의 본래 의도는 일반 라이브러리에는 맞지만
unit test 에서는 오히려 함정이 됐다.

검증: `DATABASE_URL=postgresql://...localhost:5432/...` 가 export 된 상태에서도
11/11 모두 통과 (3 + 2 + 2 + 2 + 2).

---

## Lessons learned

1. **로컬 dev 와 클러스터 dev 가 모두 가능한 환경에서는 README 가 두 모드의 차이를 명시해야 한다.**
   특히 `localhost` 는 host 가 보는 localhost 와 컨테이너가 보는 localhost 가 다르다는 점을
   매번 친절하게 짚어주는 편이 안전하다.
2. **"테스트 통과 = 모든 게 OK" 는 위험한 착각.**
   pytest 는 의도적으로 `DATABASE_URL=""` 로 lifespan 의 DB 분기를 우회해 통과하므로,
   "pytest 통과 → 로컬 uvicorn 도 뜰 것" 이라는 추론이 깨진다.
   e2e 검증은 별도 단계로 README 가 분리해서 안내해야 한다.
3. **TimeoutError 의 traceback 은 항상 끝부터 거꾸로 읽기.**
   asyncpg 내부 `_create_ssl_connection` 까지 traceback 이 떨어지면
   대개 SSL 자체가 문제가 아니라 TCP layer 에서 막힌 것이다 (TLS 협상 전에 timeout).
4. **단위 테스트 환경변수는 `setdefault` 가 아닌 직접 할당** 으로 강제한다.
   `setdefault` 는 셸 환경의 사전 export 를 존중하느라 결정성을 깨뜨린다.
   "어떤 셸에서 돌려도 동일한 결과" 가 unit test 의 기본 계약이다.
