# Postgres `\l` 출력에서 transfer_db 가 누락된 듯 보였던 사례

| | |
|---|---|
| **Date** | 2026-05-03 |
| **Severity** | 낮음 (데이터 손실 없음, 진단 도구의 출력 가공 문제) |
| **Affected** | `payment-dev` namespace의 `postgres-0` 검증 절차 |
| **Tags** | `postgres`, `psql`, `kubectl-exec`, `tty`, `pager`, `init-script` |
| **Related commits** | [`9707c58`](../../charts/payment-platform/templates/postgres.yaml) (init 멱등화), [`a65d7fb`](../../charts/payment-platform/templates/postgres.yaml) (검증 명령 표준화) |

---

## Summary

Task 1.4 검증 단계에서 `\l | grep transfer_db` 가 0행을 반환해 "transfer_db 가 init 도중 만들어지지 않았다" 고 의심했으나,
실제로는 **psql 의 pager 가 `kubectl exec -it` 의 TTY 환경에서 와이드 출력을 잘라낸 것**이었다.
DB 자체는 처음부터 정상 생성되어 있었고 데이터·매니페스트·init.sql 어느 쪽에도 결함은 없었다.
다만 사건 조사 과정에서 init.sql 의 멱등성 부족(이번 원인은 아니지만 잠재 위험)을 발견해 `\gexec` 패턴으로 보강했다.

---

## Symptom

```bash
# Task 1.4 의 권장 검증 명령
$ kubectl -n payment-dev exec -it postgres-0 -- \
    psql -U payment -c "\l" | grep -E "account_db|transfer_db|loan_db|notification_db"

 account_db      | payment | UTF8     | libc            | en_US.utf8 | en_US.utf8 |        |           |
 loan_db         | payment | UTF8     | libc            | en_US.utf8 | en_US.utf8 |        |           |
 notification_db | payment | UTF8     | libc            | en_US.utf8 | en_US.utf8 |        |           |
# 4개를 기대했는데 transfer_db 1행이 빠져 있다.
```

---

## Investigation & Root cause

### 1차 가설: init.sql 가 transfer_db 만 누락하고 끝났다

postgres 로그를 살폈으나 `CREATE DATABASE` 가 5건(default + 4 from init) 모두 성공으로 찍혀 있었다.

```bash
$ kubectl -n payment-dev logs postgres-0 | grep -iE 'error|fatal|create database'
CREATE DATABASE
CREATE DATABASE
CREATE DATABASE
CREATE DATABASE
CREATE DATABASE      # 5건. 에러 없음.
```

ConfigMap 마운트 본문도 의도한 4 줄 그대로였고, `od -c` 바이트 덤프로 BOM/CRLF 같은 hidden 문자도 없었다.

### 2차 가설: 시스템 카탈로그를 직접 보자

`\l` 이라는 psql 메타 명령을 우회하고 `pg_database` 를 SELECT 로 조회.

```bash
$ kubectl -n payment-dev exec -it postgres-0 -- \
    psql -U payment -c "SELECT datname FROM pg_database ORDER BY datname;"
     datname
-----------------
 account_db
 loan_db
 notification_db
 payment
 postgres
 template0
 template1
 transfer_db        # ← 멀쩡히 존재
(8 rows)
```

DB 는 처음부터 있었다. 차이는 **출력 가공뿐**.

### 실제 원인

`kubectl exec -it` 의 `-t` 가 컨테이너 안에 TTY 를 할당한다. psql 은 TTY 출력을 감지하면 자체 pager 를 호출하는데,
`\l` 의 와이드 테이블 출력이 (TTY 가 보고하는 row 한도와 만나) **알파벳 순으로 마지막인 `transfer_db` 행 직전에 잘려나갔다.**

같은 `kubectl exec -it` 라도 좁은 폭의 일반 SELECT 출력은 pager 임계 이하라 영향을 받지 않았다.
이게 "SELECT 는 보이는데 `\l` 만 누락" 처럼 보였던 이유다.

요약:

```
kubectl exec -it ──► TTY 할당 ──► psql 이 pager 호출 ──► \l 와이드 테이블 잘림
                                                              │
                                                              └─ 알파벳 끝(transfer_db) 부터 사라짐
```

---

## Fix

### 즉시 복구

복구 대상이 없었다. DB 는 있었다. 검증 명령만 바꾸면 된다.

```bash
# (A) pager 끄기
kubectl -n payment-dev exec -it postgres-0 -- \
  psql -U payment -P pager=off -c "\l"

# (B) TTY 미할당 (권장)
kubectl -n payment-dev exec postgres-0 -- \
  psql -U payment -c "\l"

# (C) 시스템 카탈로그 직접 (가장 견고)
kubectl -n payment-dev exec postgres-0 -- \
  psql -U payment -c "SELECT datname FROM pg_database ORDER BY datname;"
```

### 장기 방어

| 변경 | 커밋 | 효과 |
|---|---|---|
| `postgres.yaml` 헤더에 검증 명령 표준화(SELECT 권장 + `\l` + `-it` 함정 메모) | [`a65d7fb`](../..) | 후속 작업자가 같은 함정에 빠지지 않음 |
| `init.sql` 을 `\gexec` 기반 멱등 형태로 변경 | [`9707c58`](../..) | 본 사건 원인은 아니지만, 향후 partial-init 발생 시 idempotent 재적용으로 자가 복구 가능 |

---

## Lessons learned

1. **증거가 도구 출력보다 우선** — `\l` 은 사람을 위한 가공 출력이다. "있다/없다" 판정은 시스템 카탈로그(SELECT)나 `IF EXISTS` SQL 처럼 가공이 적은 경로로 한다.
2. **`kubectl exec -it` 의 TTY 부작용을 인지** — 자동화 스크립트나 CI 의 검증 단계에서는 `-t` 플래그를 의식적으로 빼야 한다 (TTY 동작 차이로 인한 false negative 는 디버깅 비용이 크다).
3. **사건 조사 과정에서 발견한 "이번에는 무관한 잠재 위험"도 같이 막는다** — init.sql 멱등화는 본 사건의 직접 원인이 아니지만, partial-init 시나리오의 안전망으로 별도 가치가 있어 함께 패치했다. 이런 부수 강화가 매니페스트의 운영성을 누적적으로 향상시킨다.
4. **검증 명령은 매니페스트와 함께 배포된다** — README 만의 책임이 아니라 매니페스트 헤더 주석으로도 박아두면 그 파일을 만지는 사람이 자연스럽게 따라간다.
