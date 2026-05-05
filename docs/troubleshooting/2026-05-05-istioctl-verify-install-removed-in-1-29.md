# istioctl verify-install 명령이 1.29 에서 제거됨 — 가이드에 stale 명령 인용

## Summary

`docs/setup/istio-install.md` 가이드의 § 2-3-3 에 `istioctl verify-install` 을 검증 단계로 적었으나, 이 명령은 Istio 1.23 부터 deprecated 되어 1.29 에서는 완전히 제거된 상태였다. 사용자가 가이드를 따라 실행하다 `Error: unknown command "verify-install"` 을 만나 보고함. 가이드를 작성하면서 명령의 1.29 호환성을 검증하지 않은 것이 직접 원인 (CLAUDE.md A-2 위반). § 2-3-3 을 삭제하고 § 2-3-4 (`istioctl proxy-status`) 를 § 2-3-3 으로 번호 재조정 + 1.29 의 install 검증 전략을 한 줄 메모로 명시해 후속 독자가 같은 혼동을 안 겪도록 보강.

## Symptom

```
melan@LAPTOP-4A5QH4PB:~$ istioctl verify-install
Error: unknown command "verify-install" for "istioctl"
Run 'istioctl --help' for usage.
```

`istioctl version --remote=false` 는 `client version: 1.29.2` 로 정상.
`istioctl install` 도 정상 종료 (Istio core / Istiod / Ingress gateways 모두 installed).
`kubectl -n istio-system get pods` 도 모두 `1/1 Running`.

즉 설치 자체는 정상이고 단지 가이드가 안내한 검증 명령만 무효.

## Investigation & Root cause

WebSearch 로 Istio 공식 GitHub issue [#51666](https://github.com/istio/istio/issues/51666) 확인:

> `verify-install` is recognized as not providing meaningful information, and there are plans to consider deprecating it. Additionally, the command is currently broken due to issues with IstioOperator removal.

내용 정리:

- `istioctl verify-install` 은 Istio 1.x 초창기에 IstioOperator (분리된 CRD) 가 cluster 에 적용된 Istio 매니페스트 vs 공식 manifest 를 비교하는 용도로 도입.
- 1.23 부터 IstioOperator 자체가 제거 (`istioctl install` 이 in-line 방식으로 통합) 되면서 `verify-install` 이 비교할 reference 가 사라짐 → 명령이 broken 상태로 일부 기간 유지.
- 1.29 에서는 cobra 명령 등록에서 완전히 제거 → `unknown command` 에러.

본 가이드를 작성할 때 공식 문서의 옛 install 페이지 (1.20 이하 버전 기준) 의 검증 절차를 그대로 인용했고, 그 명령이 1.29 에서도 유효한지 검증하지 않은 것이 가이드 결함의 직접 원인. **CLAUDE.md A-2 의 "추천하는 모든 도구·라이브러리·명령은 2026년 stable 인지 검색으로 확인" 규칙의 명백한 위반**. 도구 메이저 버전 (Istio 1.29) 만 검증하고 sub-command 의 호환성은 검증 안 한 부분 검증의 함정.

`verify-install` 이 하던 역할은 1.29 에서 다음으로 분산 흡수:

| 옛 verify-install 의 검증 항목 | 1.29 에서의 대체 |
|---|---|
| 컴포넌트 pod 가 떠있는가 | `kubectl -n istio-system get pods` (가이드 § 2-3-1) |
| CRD 가 등록됐는가 | `kubectl get crd \| grep istio.io \| wc -l` (가이드 § 2-3-2) |
| istiod ↔ 사이드카 통신 | `istioctl proxy-status` (가이드 § 2-3-4 → 번호 재조정 후 § 2-3-3) |
| 매니페스트 일관성 | `istioctl analyze` (cluster 설정 분석용 후속 도구) |

즉 가이드의 다른 단계들이 이미 verify-install 의 기능을 모두 커버하고 있었고, § 2-3-3 만 잉여였던 것.

## Fix

- `docs/setup/istio-install.md` § 2-3-3 (`istioctl verify-install` 단계) 전체 삭제.
- 옛 § 2-3-4 (`istioctl proxy-status`) 를 § 2-3-3 으로 번호 재조정.
- 새 § 2-3-3 도입부에 1.29 의 install 검증 전략 (옛 verify-install 의 역할이 다른 단계들로 분산됐다는 사실) 을 한 줄 메모로 명시.
- § 2-3 의 헤더 "(4 단계)" 를 "(3 단계)" 로 정정.
- 관련 commit: 본 troubleshooting 파일과 동시에 push 되는 커밋.

## Lessons learned

1. **도구의 메이저 버전만 검증하고 sub-command 의 호환성은 검증 안 하는 함정.** 본 가이드는 Istio 1.29.2 가 2026년 stable 임을 WebSearch 로 확인했고, kind 와의 K8s 버전 호환성도 확인했지만, `verify-install` 같은 sub-command 가 그 메이저 버전에서도 유효한지는 별도로 검증 안 했다. 도구의 메이저 결정 ≠ 그 도구의 모든 sub-command 가 stable. **앞으로 가이드에 명령을 적기 전, 그 명령이 인용 시점의 stable 메이저에서 실제로 존재하는지 `<tool> --help` 출력 확인** 또는 공식 docs 의 해당 버전 페이지 확인을 1 단계 추가해야 함.

2. **가이드의 검증 절차는 "검증할 명령의 검증" 부터.** 가이드의 검증 단계 (§ 2-3 같은) 는 사용자가 가장 처음 실행해보는 단계라, 거기에 stale 명령이 들어가면 사용자의 신뢰를 가장 빨리 잃는 위치다. 검증 명령 자체를 가이드 작성 시점에 한 번 sandbox 또는 docker 안에서 실행해보고 출력을 그대로 가이드에 옮기는 것이 가장 안전 (CLAUDE.md A-5 의 "Trust but Verify" 의 가장 명확한 적용 지점).

3. **옛 명령 → 새 명령 매핑을 가이드에 명시하면 후속 독자에게 친절.** Istio 의 1.x 초기 가이드를 본 적 있는 독자가 본 프로젝트의 가이드를 보면 "왜 verify-install 이 없지?" 하고 의문이 들 수 있다. 단순히 명령을 빼는 것이 아니라 "1.23 부터 제거됐고 그 역할은 X / Y / Z 로 분산" 이라는 한 줄 메모를 남기면, 다음 독자가 같은 길에서 헤매지 않는다. 본 가이드의 § 2-3-3 도입부에 그 메모를 추가했음.
