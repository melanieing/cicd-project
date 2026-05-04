# Helm chart 의 IDE-가시 결함 (중복 키 / 잘못된 sequence 항목) — runtime 검증으로 잡히지 않는 클래스의 문제

| | |
|---|---|
| **Date** | 2026-05-04 |
| **Severity** | 중간 (helm/runtime 은 정상이지만 IDE 와 정적 yaml 도구 시선에서 결함) |
| **Affected** | `charts/payment-platform/templates/configmap.yaml`, `charts/payment-platform/templates/postgres.yaml` |
| **Tags** | `helm`, `yaml`, `ide-linter`, `verification-scope`, `claude-md-a5` |
| **Related commits** | (이 사건을 수정하는 커밋) |

---

## Summary

EPIC 4 의 Helm chart 가 `helm lint` / `helm template` / `kubeconform` 의 runtime 검증은 모두 통과했지만,
사용자 IDE(VSCode YAML extension 등) 가 다음 두 결함을 빨간 줄로 표시:
1. **configmap.yaml** — `NOTIFICATION_URL` 키 중복: `{{- if/else }}` 양쪽 분기에 같은 키가 있어 일반 YAML 파서 시선으로는 중복.
2. **postgres.yaml** — `command: ["pg_isready", "-U", {{ .Values.postgres.user | quote }}, ...]` 의 inline flow sequence 안에 `{{ }}` 가 들어가 정적 파서가 시퀀스 항목으로 인식 못 함.

근본 원인은 **runtime 검증과 author-time IDE 검증의 scope 차이**.
A-5 가 "실행으로 검증" 을 강조했지만 그 "실행" 의 범위를 runtime 도구로만 한정해 IDE/static YAML 시선을 누락.
수정: 두 템플릿을 IDE-친화 형태로 재구성하고, 검증 스위트에 **rendered output 의 yamllint(key-duplicates) 패스를 추가**.

---

## Symptom

사용자 IDE 표시:
```
charts/payment-platform/templates/configmap.yaml
  NOTIFICATION_URL 키는 중복입니다  (line 25, line 27)

charts/payment-platform/templates/postgres.yaml
  {{ .Values.postgres.user | quote }} 시퀀스 항목이 필요합니다
```

이때 sandbox 의 검증 결과:
```
helm lint        ✅ 1 chart linted, 0 failed (only icon-recommended INFO)
helm template    ✅ 17 / 21 resources rendered
kubeconform      ✅ 17/17, 21/21 valid
```

→ runtime 도구가 모두 통과한 상태에서 IDE 만 빨간색.

---

## Investigation & Root cause

### 1차 가설 (오답): IDE 의 false positive 라 무시해도 됨

부분적으로 맞지만, **IDE 가 빨간 줄을 띄우는 코드는 다음 작업자도 똑같이 보게 된다**.
포트폴리오 / 협업 관점에서 "동작은 하지만 코드가 빨갛다" 는 받아들이기 어려운 상태.
또한 IDE 경고 자체가 진짜 결함을 가릴 수 있다 — 다음 진짜 오류가 들어와도 "원래 빨갰는데" 로 흘려보낼 위험.

### 확정 원인 (두 가지 결함, 같은 카테고리)

#### (a) configmap.yaml — 분기 양쪽에 같은 키

원본:
```yaml
{{- if eq $svc.notificationUrl "from-template" }}
NOTIFICATION_URL: {{ printf "..." | quote }}
{{- else }}
NOTIFICATION_URL: {{ $svc.notificationUrl | quote }}
{{- end }}
```

Helm 은 if/else 중 한 쪽만 렌더링하므로 runtime 결과는 단일 키.
하지만 일반 YAML 파서 / IDE 는 `{{- if }}` 를 텍스트로 보고 두 `NOTIFICATION_URL:` 라인을 sibling 키로 인식 → **중복 키 경고**.

#### (b) postgres.yaml — inline flow sequence 안의 template 토큰

원본:
```yaml
command: ["pg_isready", "-U", {{ .Values.postgres.user | quote }}, "-h", "127.0.0.1"]
```

Helm 은 `{{ ... }}` 를 `"payment"` 로 치환 후 정상 sequence 가 됨.
일반 YAML 파서는 `{{` 로 시작하는 토큰을 sequence item 으로 받지 못해 **"시퀀스 항목이 필요합니다"** 경고.

### 메타 결함 — A-5 적용 범위의 누락

A-5 ("실행 가능 산출물 검증 규칙") 를 적용해 helm lint + helm template + kubeconform 을 돌렸지만,
이 도구들은 모두 **runtime layer** 만 본다:
- helm lint: chart 구조 + Helm template syntax (Helm 자체 파서)
- helm template: 렌더링 동작 (Go template + Helm sprig)
- kubeconform: 렌더링 후 K8s schema

**author-time IDE 가 보는 layer** (template 파일 자체를 raw YAML 로 본 결과) 는 검증되지 않았음.
A-5 의 정신은 "사용자가 마주하는 시점의 문제" 를 잡자는 것이고, IDE 빨간 줄은 그 시점에 사용자가 매일 마주함.

---

## Fix

### (a) configmap.yaml — 변수 할당으로 단일 키화

```yaml
{{- $notifUrl := $svc.notificationUrl -}}
{{- if eq $svc.notificationUrl "from-template" -}}
  {{- $notifUrl = printf "http://notification.%s.svc.cluster.local:8000" $.Release.Namespace -}}
{{- end }}
NOTIFICATION_URL: {{ $notifUrl | quote }}
```

핵심: 분기는 변수 갱신만 하고, YAML 출력 라인은 단 하나. IDE 가 봐도 키 1개.

### (b) postgres.yaml — block sequence 로 변경

```yaml
command:
  - pg_isready
  - "-U"
  - {{ .Values.postgres.user | quote }}
  - "-h"
  - "127.0.0.1"
```

block sequence 의 `- ITEM` 은 IDE 가 한 줄을 한 항목으로 인식. 안에 `{{ }}` 가 있어도 dash 가
명시적 구분자라 시퀀스 파싱 깨지지 않음.

### 부수 — 같은 함정 재발 방지를 위한 추가 검증

검증 스위트에 한 단계 추가:
```bash
helm template ... | yamllint -d "{rules: {key-duplicates: enable, ...}}"
```

이 단계가 catch 하는 것:
- 렌더링된 매니페스트의 **실제 중복 키** (template 의 if 가 잘못 짜여 둘 다 출력되는 사고)
- 어떤 이유로든 출력에 중복 발생 시 즉시 fail

(IDE 가 보는 결함은 source 에서 catch 못 하지만 적어도 runtime 출력에 중복이 있으면 잡음)

### 부수 — postgres.yaml 의 또 다른 함정 (오늘 같은 패턴 두 번째)

수정 도중 **YAML 주석 안의 `{{ }}`** 를 Helm 이 빈 directive 로 읽어 또 parse error.
2026-05-03 의 postgres SQL 주석 안 `{{- range }}` 사건과 동일 카테고리.
해결: 주석에 literal `{{` `}}` 토큰을 쓰지 않고 문장으로 풀어쓰기.

---

## Lessons learned

1. **runtime 검증과 author-time 검증은 다른 layer 다.**
   `helm lint` / `helm template` / `kubeconform` 은 runtime 만 본다.
   사용자 IDE 가 매일 보는 화면 (template 파일을 raw YAML 로 파싱한 결과) 도 검증 대상.
   향후 helm chart 작업 시 검증 스위트에 다음을 추가:
     - `yamllint --rules key-duplicates` on rendered output (런타임 중복 catch)
     - 가능하면 `helm template` 결과에 `kubectl apply --dry-run=client -f -` 시도 (server-side 추가 검증)
2. **template 안의 YAML 주석에 `{{` `}}` 를 쓰면 안 된다.**
   YAML 의 `#` 은 Helm 의 template processor 에 대해 escape 효과가 없다.
   "block sequence — `{{ }}` 를 항목으로 인식 못 함" 같은 친절한 주석이 그 자체로 parse error 를 일으킨다.
   주석에서 template 토큰을 언급해야 할 때는 "Helm template 토큰" 같이 풀어쓰기.
3. **inline flow sequence 안에 template 토큰을 넣지 말기.**
   `["a", "b", {{ }}, "d"]` 형태는 IDE 가 항목으로 인식 못 한다.
   block sequence (`- ITEM`) 가 명시적 구분자라 IDE-친화 + helm-친화 양쪽 모두 안전.
4. **분기문 양쪽에 같은 YAML 키를 두지 말기.**
   `{{ if }} key: A {{ else }} key: B {{ end }}` 패턴은 IDE 에 중복 키로 보인다.
   변수에 결과를 모은 뒤 단일 라인으로 출력하는 패턴이 IDE-친화.
5. **CLAUDE.md A-5 의 검증 범위를 확장 인지.**
   "실행 가능 산출물" 의 검증 도구 추천 항목에 "static YAML 검사 (rendered + source)" 추가 필요.
   본 사건을 계기로 향후 helm chart 작업 시 yamllint 단계를 표준 스위트에 포함.
