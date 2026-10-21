#!/usr/bin/env bash
#
# harness usage [--json] — 요금제 사용량(세션 · 주간 한도)과 루프를 멈출 기준(loop.usageStopPercent).
#   모델을 부르지 않는다. 루프는 바퀴마다 읽어 진행 줄에 찍고, 기준을 넘으면 다음 기능을 시작하지 않는다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/usage.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

USAGE="$(usage_json)"
if [[ "${1:-}" == "--json" ]]; then
  printf '%s\n' "$USAGE"
elif [[ "$(jq -r .result <<<"$USAGE")" == ok ]]; then
  jq -r '"사용량: \(.summary)" + (if .stopPercent > 0 then " (루프는 \(.stopPercent)% 에서 멈춘다)" else "" end)' <<<"$USAGE"
else
  jq -r '"ℹ️ 사용량을 읽지 못했다: \(.reason)"' <<<"$USAGE"
fi
