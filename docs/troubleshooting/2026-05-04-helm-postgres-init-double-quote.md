# Helm 의 `quote` 가 SQL 의 single quote 가 아니라 double quote 라 init.sql 이 빈 결과 — 4 DB 누락

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (4 service 모두 lifespan 단계에서 InvalidCatalogNameError) |
| **Affected** | `charts/payment-platform/templates/postgres.yaml` ConfigMap 의 init.sql 렌더 |
| **Tags** | `helm`, `sprig`, `quote-vs-squote`, `postgres`, `psql`, `gexec` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

Helm chart 의 postgres init.sql 이 `{{ $db | quote }}` 로 DB 이름을 감쌌는데, Helm/sprig 의 `quote` 함수는 **Go 언어의 double-quote string** (`"foo"`) 을 만든다. 그러나 PostgreSQL 의 `VALUES` 절에서 string literal 은 **single quote (`'foo'`)** 여야 하고, double quote 는 **identifier** (column/table 이름) 으로 해석됨.

결과: SELECT 가 `"account_db"` 라는 column 을 찾으려다 0행 반환 → `\gexec` 가 받을 게 없어 CREATE DATABASE 0번 실행 → 4 service DB (account_db / transfer_db / loan_db / notification_db) 가 하나도 안 만들어짐 → 4 service 의 asyncpg lifespan 이 `InvalidCatalogNameError: database "<name>" does not exist` 로 죽음 → uvicorn exit 3 → CrashLoopBackOff.

수정: `{{ $db | quote }}` → `{{ $db | squote }}` (sprig 의 single-quote 함수).

---

## Symptom

```bash
$ kubectl logs transfer-cd657b6c7-6psgn -n payment-dev --previous | tail -10
asyncpg.exceptions.InvalidCatalogNameError: database "transfer_db" does not exist
ERROR:    Application startup failed. Exiting.

$ kubectl -n payment-dev exec postgres-0 -- psql -U payment -c "\l"
  datname
-----------
 payment       ← postgres 가 만든 default DB
 postgres      ← maintenance DB
 template0
 template1
(4 rows)        ← 우리가 기대한 4 service DB 가 0 개!
```

확정 단서: psql-check 으로 같은 자격증명 connect 시도하면 동일 에러 (database 없음, 인증은 성공).

---

## Investigation & Root cause

### 진단 — 렌더된 init.sql 직접 확인

```bash
$ helm template payment charts/payment-platform/ ... | sed -n '/postgres-init/,/^---/p'
data:
  init.sql: |
    SELECT format('CREATE DATABASE %I', d)
    FROM (VALUES
        ("account_db"),         ← 이 줄
        ("transfer_db"),
        ("loan_db"),
        ("notification_db")
    ) AS t(d)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_database WHERE datname = d
    )
    \gexec
```

`"account_db"` — **double quote**. PostgreSQL 에서:
- single quote `'foo'` → string literal
- double quote `"foo"` → identifier (column/table 이름)

`VALUES ("account_db")` 는 "account_db 라는 column 의 값을 select 한다" 로 해석. 그런 column 이 없으니 SELECT 가 빈 결과 반환. `\gexec` 가 SELECT 결과의 각 행을 SQL command 로 실행하는데, 0 행이라 0 번 실행. CREATE DATABASE 가 1 번도 안 일어남.

### 코드 결함

원본 chart template:
```yaml
data:
  init.sql: |
    SELECT format('CREATE DATABASE %I', d)
    FROM (VALUES
      {{- range $i, $db := .Values.postgres.databases }}
        ({{ $db | quote }})...   ← Helm 의 quote 함수
      {{- end }}
```

Helm/sprig 의 `quote` 는 Go fmt.Sprintf 의 `%q` 와 같은 double-quote string. `account_db` → `"account_db"`. **SQL 문맥에서는 의미가 다른 quote**.

올바른 함수: `squote` — sprig 의 single-quote string. `account_db` → `'account_db'`.

### 메타 결함 — 렌더 출력 검증 누락

이전 helm template 검증에서 `kubeconform` 으로 schema 만 봤지, **init.sql 의 SQL semantic 은 검증 안 함**. ConfigMap 의 data 필드는 K8s 입장에선 그냥 string 이라 schema pass. SQL parser 가 봐야 잡힘.

이 클래스(SQL embedded in YAML embedded in Helm template) 는 stateless 도구로 잡기 거의 불가. 직접 cluster 에서 init 까지 돌려봐야 하는데 sandbox 한계로 못 돌렸음. 같은 stateful 검증 누락 패턴.

---

## Fix

### chart 수정

`charts/payment-platform/templates/postgres.yaml` 의 init.sql 렌더:
```yaml
({{ $db | quote }})  →  ({{ $db | squote }})
```

검증 (helm template):
```sql
('account_db'),     ← single quote, SQL 문법 정상
('transfer_db'),
('loan_db'),
('notification_db')
```

### 사용자 즉시 복구 — 두 경로

**경로 A (빠름) — 수동으로 4 DB 생성**

기존 postgres-0 의 PGDATA 는 살려두고 누락된 DB 만 추가. init.sql 은 PGDATA 가 비어있을 때만 자동 실행되므로, 한 번 실행 후에는 수동 실행이 답:

```bash
kubectl -n payment-dev exec postgres-0 -- psql -U payment -d postgres -c "
CREATE DATABASE account_db;
CREATE DATABASE transfer_db;
CREATE DATABASE loan_db;
CREATE DATABASE notification_db;
"
kubectl -n payment-dev rollout restart deploy
```

**경로 B (clean) — migrate-to-helm.sh MODE=clean 으로 재설치**

PVC 까지 날리고 fresh init.sql (이번엔 single quote) 가 자동 실행:

```bash
git pull
./scripts/migrate-to-helm.sh   # MODE=clean default
```

스크립트가 imageTag prompt 안 받으니 `helm install` 시점에 `--set global.imageTag=3b46c95b762d048e007c78669e5dd9b4b9e67e44` 추가 필요할 수 있음 — TODO 로 남겨둠.

---

## Lessons learned

1. **Helm/sprig 의 `quote` 와 `squote` 는 다른 함수다.**
   - `quote` = double quote (Go string 컨벤션)
   - `squote` = single quote
   YAML/JSON 출력에는 `quote` 가 맞지만, **SQL 문자열 리터럴**, **bash 안의 single-quoted argument** 등은 `squote` 가 정답.
   인용 문맥을 항상 의식해서 함수 선택.
2. **embedded language 의 semantic 은 helm template 으로 안 잡힌다.**
   ConfigMap 의 data 가 SQL/Python/bash 라도 K8s 는 string 으로만 보고 schema pass. 이 클래스는 **실제 cluster 에서 그 언어 파서까지 돌려봐야** 잡힘. 본 사건처럼 sandbox 한계로 못 돌리는 경우 init script 자체를 단위 테스트하는 별도 방법 (e.g. docker run postgres + 마운트 후 psql 실행) 을 고려.
3. **postgres init.sql 은 PGDATA 가 비어있을 때만 1회 실행.**
   chart 수정 후에도 기존 PGDATA 가 살아있으면 수정된 init.sql 이 적용 안 됨. PVC 삭제 + 재설치 또는 수동 실행 필요. Helm chart 의 init 패턴은 늘 이 idempotency 가정을 명시해야 함.
4. **A-5-pre 적용 — 더 큰 그림.**
   "포트폴리오용 단일 chart 가 init script 까지 직접 관리" 자체가 단순화 한계. 운영 환경의 답:
   - **CloudNative-PG / Zalando postgres-operator**: declarative DB 관리. CREATE DATABASE / role 까지 매니페스트로.
   - **bitnami/postgresql Helm chart**: battle-tested init scripts.
   본 프로젝트는 데모용이라 직접 작성 유지하되, 운영 시 위 도구로 옮긴다는 메모를 README 에 추가 검토.
