#!/usr/bin/env bash
#
# harness lock run -- <명령...> — 빌드 잠금을 잡고 명령을 실행한다.
#   같은 작업 트리에서 여러 에이전트가 빌드·테스트할 때 쓴다. 하네스의 게이트도 같은 잠금을 쓴다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/lock.sh"
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

[[ "${1:-}" == "run" && "${2:-}" == "--" && $# -gt 2 ]] || die "$EXIT_USAGE" "사용: harness lock run -- <명령...>"
shift 2
with_build_lock "$(printf '%q ' "$@")"
