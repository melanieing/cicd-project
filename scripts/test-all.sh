#!/usr/bin/env bash
#
# scripts/test-all.sh
#
# 5개 서비스(_template + account + transfer + loan + notification) 의 venv 를
# 보장하고 pytest 를 일괄 실행한다. 첫 실행 시 venv 와 의존성을 설치하므로
# 시간이 걸리고, 이후에는 캐시되어 빠르게 끝난다.
#
# 결과 형식:
#   === <service> ===
#     <pytest tail output>
#     PASS / FAIL
#   ...
#   ========================================
#   Result: N pass, M fail
#
# 종료 코드: 실패 개수 (0 이면 모두 통과)
#
# 사용:
#   ./scripts/test-all.sh
#   ./scripts/test-all.sh transfer            # 특정 서비스만
#   ./scripts/test-all.sh account transfer    # 여러 개 지정
#
# [bash 특수 문법]
#   - set -uo pipefail : -u 는 미정의 변수 사용 시 오류, -o pipefail 은 파이프
#                        중간 명령 실패도 전체 실패로 잡음. -e 는 의도적 미사용
#                        (한 서비스 실패해도 나머지 계속 진행하기 위함).
#   - "${var:-default}" : var 가 비어있으면 default 사용
#   - $(command)        : command 의 stdout 을 문자열로 캡처

set -uo pipefail

ALL_SERVICES="_template account transfer loan notification"
SERVICES="${*:-$ALL_SERVICES}"  # 인자가 있으면 그 목록만, 없으면 전부

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"

# ANSI color codes (터미널이 컬러 지원 안 하면 시각적으로만 깨짐, 동작은 정상)
C_BLUE="\033[34m"; C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"; C_RESET="\033[0m"

ok=0
fail=0
failed_services=""

for svc in $SERVICES; do
    echo -e "${C_BLUE}=== $svc ===${C_RESET}"
    dir="$SERVICES_DIR/$svc"

    if [ ! -d "$dir" ]; then
        echo -e "  ${C_RED}MISSING directory: $dir${C_RESET}"
        fail=$((fail + 1))
        failed_services="$failed_services $svc(no-dir)"
        continue
    fi

    # venv 가 없으면 생성. python3 가 PATH 에 있어야 함.
    if [ ! -d "$dir/.venv" ]; then
        echo "  creating venv..."
        if ! python3 -m venv "$dir/.venv"; then
            echo -e "  ${C_RED}venv creation failed${C_RESET}"
            fail=$((fail + 1))
            failed_services="$failed_services $svc(venv)"
            continue
        fi
    fi

    # 의존성 설치 (이미 같은 버전이면 pip 가 빠르게 skip).
    # --quiet 로 출력 줄임. --upgrade pip 는 처음 1회만 의미.
    "$dir/.venv/bin/pip" install --quiet --upgrade pip
    if ! "$dir/.venv/bin/pip" install --quiet -r "$dir/requirements.txt"; then
        echo -e "  ${C_RED}dep install failed${C_RESET}"
        fail=$((fail + 1))
        failed_services="$failed_services $svc(deps)"
        continue
    fi

    # pytest 실행. tail 로 마지막 5줄(요약 부분) 만 보여줌.
    #
    # [중요] 반드시 (cd "$dir" && pytest) 형태로 호출해야 한다.
    # pytest 는 cwd 에서 위로 올라가며 pytest.ini 를 찾아 rootdir 를 결정하고,
    # 그 결과로 testpaths 와 pythonpath 가 적용된다. cwd 가 service 디렉토리가
    # 아니면 (예: project root) pytest 가 모든 service 의 test 파일을 한꺼번에
    # collect 하다 'from main import app' 에서 ImportError 로 실패한다.
    # 절대 경로 호출(`$dir/.venv/bin/pytest`) 은 binary 위치만 결정할 뿐
    # cwd 에는 영향이 없다는 점을 잊지 말 것.
    # (서브셸 `(cd ...)` 로 감싸 cwd 변경이 다음 iteration 에 누출되지 않게 한다.)
    if (cd "$dir" && ./.venv/bin/pytest --tb=short -q) 2>&1 | tail -5; then
        echo -e "  ${C_GREEN}PASS${C_RESET}"
        ok=$((ok + 1))
    else
        echo -e "  ${C_RED}FAIL${C_RESET}"
        fail=$((fail + 1))
        failed_services="$failed_services $svc"
    fi
    echo ""
done

# ----- 최종 요약 -----
echo -e "${C_BLUE}========================================${C_RESET}"
if [ "$fail" -eq 0 ]; then
    echo -e "Result: ${C_GREEN}$ok pass${C_RESET}, $fail fail"
    exit 0
else
    echo -e "Result: ${C_GREEN}$ok pass${C_RESET}, ${C_RED}$fail fail${C_RESET}${failed_services}"
    exit "$fail"
fi
