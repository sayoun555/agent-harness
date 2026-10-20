#!/usr/bin/env bash
#
# harness trace — 루프 실행 기록 조회.
#   harness trace show        전체
#   harness trace tail [N]    마지막 N줄 (기본 20)
#   harness trace summary     이벤트·결과별 개수
#   harness trace report [--stop-reason R] [--reason 글] [--json]
#                             사람이 읽는 보고서(state.reportFile)를 다시 만든다 — 기능별 문제와 해결, 시간 · 시도,
#                             반복된 반려 기준, 하네스 이상 신호, 사람이 할 일. 모델을 부르지 않는다.
#                             --stop-reason 은 루프가 끝날 때 그 이유를 trace 에 먼저 남긴다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/trace.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/report.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

FILE="$(trace_file)"

cmd_report() {
  local stop_reason="" reason="" json_mode=0 out ledger
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stop-reason) stop_reason="${2:?--stop-reason 에 값}"; shift 2 ;;
      --reason)      reason="${2:-}"; shift 2 ;;
      --json)        json_mode=1; shift ;;
      *) die "$EXIT_USAGE" "사용: harness trace report [--stop-reason R] [--reason 글] [--json]" ;;
    esac
  done
  [[ -n "$stop_reason" ]] && trace_add loop-end "$(jq -cn --arg r "$stop_reason" --arg why "$reason" '{result: $r, reason: $why}')"
  out="$(report_file)"
  mkdir -p "$(dirname "$out")"
  ledger="$(features_file)"
  [[ -f "$ledger" ]] || ledger=/dev/null
  touch "$FILE"
  build_report "$FILE" "$ledger" "$(utc_now)" > "$out"
  if [[ "$json_mode" -eq 1 ]]; then
    jq -cn --arg path "${out#"$PROJECT_ROOT"/}" '{result: "ok", path: $path}'
  else
    info "📝 보고서: ${out#"$PROJECT_ROOT"/}"
  fi
}

[[ "${1:-}" == "report" ]] && { shift; cmd_report "$@"; exit 0; }
[[ -s "$FILE" ]] || { info "trace: 기록 없음 ($FILE)"; exit 0; }

case "${1:-show}" in
  show)    cat "$FILE" ;;
  tail)    tail -n "${2:-20}" "$FILE" ;;
  summary) jq -rs 'group_by(.event + "/" + (.result // "-"))
                   | map("\(.[0].event)\t\(.[0].result // "-")\t\(length)") | .[]' "$FILE" ;;
  *)       die "$EXIT_USAGE" "사용: harness trace [show | tail N | summary | report]" ;;
esac
