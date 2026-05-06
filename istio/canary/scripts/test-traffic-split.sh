#!/usr/bin/env bash
# istio/canary/scripts/test-traffic-split.sh
#
# Canary 트래픽 분배 검증 — payment-dev namespace 에 임시 curl pod 를 띄워
# transfer:8000/version 을 N 회 호출한 다음 응답의 version 필드 분포를 집계한다.
#
# Usage:
#   ./scripts/test-traffic-split.sh [iterations]
#   기본 iterations = 100
#
# 동작 방식
#   - kubectl run 으로 임시 pod (curlimages/curl) 를 띄움
#   - payment-dev namespace 에 istio-injection=enabled 라벨이 있으므로 임시 pod 도 사이드카가 자동 주입됨
#   - 그 사이드카가 transfer:8000 호출을 가로채 VirtualService 의 weight 에 따라 stable/canary 로 분배
#   - 응답 JSON 의 .version 만 추출해 sort | uniq -c 로 분포 집계
#   - 임시 pod 는 --rm 으로 명령 종료 시 자동 삭제
#
# 기대 출력 (예: 80/20 weight 일 때, iterations=100):
#     80 stable
#     20 canary
#   (정확히 80/20 이 아니어도 됨 — 가중 라우팅은 확률적이라 ±5 정도 편차는 정상)
#
# 본 스크립트의 한계
#   - 트래픽 분배의 통계 정확도는 호출 수가 늘수록 weight 에 수렴. iterations=100 은 시연용 적정선.
#     포트폴리오 캡처에는 100 으로 충분, 정밀 검증이 필요하면 1000 으로.

set -euo pipefail

ITERATIONS="${1:-100}"
NS="payment-dev"

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
  echo "ERROR: iterations 는 양의 정수여야 함 (입력: $ITERATIONS)" >&2
  exit 2
fi

echo "[*] $NS namespace 에 임시 curl pod 으로 transfer:8000/version $ITERATIONS 회 호출"
echo "[*] 사이드카가 자동 주입되므로 응답은 VirtualService 의 weight 에 따라 분배됨"
echo

# kubectl run 의 옵션:
#   --rm         : 명령 종료 시 pod 자동 삭제
#   --restart=Never : 한 번 실행 후 끝 (Job/Deployment 가 아닌 standalone pod)
#   -i / -t      : 컨테이너 stdin / tty 연결
#   --image=...  : curlimages/curl 은 small Alpine 기반 curl 이미지 (~5 MiB)
#   --labels     : 의도적으로 일반 라벨만 부여 — DestinationRule subset 매칭에 영향 X
#
# heredoc 으로 컨테이너 안에서 실행할 sh 스크립트 정의:
#   - jq 가 curl 이미지에 없으므로 grep+awk 으로 .version 만 추출
#   - 한 줄 한 줄 echo 하여 외부 파이프 (sort | uniq -c) 가 읽도록
kubectl -n "$NS" run curl-canary-test \
  --image=curlimages/curl:8.10.1 \
  --rm -i --restart=Never \
  --quiet \
  --labels='app=canary-test,test-pod=true' \
  --overrides='{"spec":{"containers":[{"name":"curl","image":"curlimages/curl:8.10.1","stdin":true,"tty":false,"command":["sh","-c","for i in $(seq 1 '"$ITERATIONS"'); do curl -s --max-time 2 http://transfer.payment-dev.svc.cluster.local:8000/version | sed -n '\''s/.*\"version\":\"\\([^\"]*\\)\".*/\\1/p'\''; done"]}]}}' \
  2>/dev/null | sort | uniq -c | sort -rn

echo
echo "[*] 분포 해석:"
echo "    - 위 출력의 각 행 = '<호출 수> <version 값>'"
echo "    - 합이 $ITERATIONS 이어야 정상. 합이 더 적으면 일부 호출이 timeout 또는 5xx"
echo "    - 비율이 VirtualService 의 weight 와 ±5% 이내면 mesh 가 의도대로 동작 중"
