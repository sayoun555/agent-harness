#!/usr/bin/env bash
#
# harness trace — 루프 실행 기록 조회.
#   harness trace show        전체
#   harness trace tail [N]    마지막 N줄 (기본 20)
#   harness trace summary     이벤트·결과별 개수
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/trace.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

FILE="$(trace_file)"
[[ -s "$FILE" ]] || { info "trace: 기록 없음 ($FILE)"; exit 0; }

case "${1:-show}" in
  show)    cat "$FILE" ;;
  tail)    tail -n "${2:-20}" "$FILE" ;;
  summary) jq -rs 'group_by(.event + "/" + (.result // "-"))
                   | map("\(.[0].event)\t\(.[0].result // "-")\t\(length)") | .[]' "$FILE" ;;
  *)       die "$EXIT_USAGE" "사용: harness trace [show | tail N | summary]" ;;
esac
