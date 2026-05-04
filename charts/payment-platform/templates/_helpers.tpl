{{/*
charts/payment-platform/templates/_helpers.tpl

Helm template helper 함수들. 파일명이 `_` 로 시작하면 helm 이 매니페스트로 렌더링하지 않고
다른 templates 에서 `{{ include "name" . }}` 형태로 호출할 수 있는 라이브러리로 처리한다.

[정의된 헬퍼]
  payment-platform.name             : chart 자체 이름 ("payment-platform")
  payment-platform.fullname         : release name + chart name (충돌 방지용 prefix)
  payment-platform.chart            : "<name>-<version>" (label 용)
  payment-platform.labels           : 모든 리소스에 박는 표준 라벨
  payment-platform.selectorLabels   : Deployment selector / Service selector 용 (좁은 라벨)
  payment-platform.serviceFullname  : 특정 service 의 K8s 리소스 이름 (예: "transfer")
  payment-platform.dbHost           : Postgres Service 의 cluster DNS 이름
*/}}

{{/* chart name (Chart.yaml 의 name 그대로) */}}
{{- define "payment-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* fullname: release-name + chart-name 으로 prefix.
     같은 chart 가 여러 namespace 에 install 될 때 이름 충돌 방지.
     단, release name 과 chart name 이 같으면 한 번만 사용. */}}
{{- define "payment-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* "<chart-name>-<chart-version>" 형태. label 의 value 제약(63자, 알파벳/숫자/. -/_) 위해 + 를 _ 로 치환. */}}
{{- define "payment-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* 모든 리소스에 박을 표준 label 세트.
     app.kubernetes.io/* 는 K8s recommended labels (https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/). */}}
{{- define "payment-platform.labels" -}}
helm.sh/chart: {{ include "payment-platform.chart" . }}
{{ include "payment-platform.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: payment-platform
{{- end -}}

{{/* selector 용 label (Deployment.spec.selector / Service.spec.selector 양쪽에 사용).
     selector 는 변경 불가(immutable) 라 추가/제거가 어려운 라벨만 포함. */}}
{{- define "payment-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "payment-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* 특정 service 의 K8s 리소스 이름.
     templates/ 의 range 안에서 service 이름을 인자로 넘겨 호출.
     본 chart 에서는 단순 service 이름(account/transfer/loan/notification) 그대로 사용. */}}
{{- define "payment-platform.serviceFullname" -}}
{{- .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Postgres Service 의 cluster DNS. 4 service 의 DATABASE_URL host 부분에 들어간다.
     형식: <service-name>.<namespace>.svc.cluster.local */}}
{{- define "payment-platform.dbHost" -}}
{{- printf "postgres.%s.svc.cluster.local" .Release.Namespace -}}
{{- end -}}
