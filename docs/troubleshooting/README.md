# Troubleshooting Log

본 폴더는 본 프로젝트를 진행하면서 마주친 **운영성 이슈와 그 해결 과정**을 한 사건당 한 파일로 기록한다.
SRE 의 "incident postmortem" 을 가벼운 형태로 옮긴 것이며, 포트폴리오 관점에서 다음 두 가지를 보여주기 위함이다.

1. **증상이 아니라 원인을 추적해서 해결**한다는 운영 마인드
2. 같은 사건이 재발하지 않도록 **매니페스트·문서·검증 절차에 방어를 적층**한다는 작업 습관

---

## 파일 명명 규칙

```
YYYY-MM-DD-<short-slug>.md
```

- 날짜: 사건이 인지된 날짜 (UTC 기준)
- slug: 영문 lowercase + 하이픈, 한 줄로 본질을 압축. 예) `postgres-l-truncated-by-tty-pager`

---

## 엔트리 작성 포맷

각 파일은 다음 5개 섹션을 가진다.

| 섹션 | 내용 |
|---|---|
| **Summary** | 한 문단 TL;DR. "무엇이 발생했고 무엇이 원인이었는지" |
| **Symptom** | 운영자/사용자가 본 화면·로그·에러 메시지 (재현 명령 포함) |
| **Investigation & Root cause** | 진단 명령, 가설, 검증, 최종 원인 |
| **Fix** | 즉시 복구 + 장기 방어 (커밋 SHA 명시) |
| **Lessons learned** | 일반화된 교훈. 이 형태의 사건을 **앞으로 피하거나 빨리 감지**하기 위한 메모 |

가벼운 사건이면 각 섹션을 1~2 문단으로 짧게 끝낸다. 복잡한 사건만 장문 작성.

---

## 인덱스

| 날짜 | 파일 | 한 줄 요약 | 심각도 |
|---|---|---|---|
| 2026-05-03 | [postgres-l-truncated-by-tty-pager](2026-05-03-postgres-l-truncated-by-tty-pager.md) | `\l` 의 TTY pager 가 와이드 출력을 잘라 transfer_db 가 누락된 듯 보임 | 낮음 |
| 2026-05-04 | [uvicorn-cannot-reach-localhost-postgres](2026-05-04-uvicorn-cannot-reach-localhost-postgres.md) | host 의 `localhost:5432` 는 비어 있어 uvicorn lifespan 이 timeout. `kubectl port-forward` 로 해결 | 낮음 |
| 2026-05-04 | [test-all-script-pytest-collection-without-cd](2026-05-04-test-all-script-pytest-collection-without-cd.md) | `test-all.sh` 가 service 디렉토리로 cd 안 하고 pytest 절대경로 호출 → rootdir 가 project root 가 되어 ImportError. 더 큰 교훈은 commit 전 미실행 → CLAUDE.md A-5 신설 | 중간 |
