#!/usr/bin/env bash
#
# harness trace — 루프 실행 기록 조회.
#   harness trace show        전체
#   harness trace tail [N]    마지막 N줄 (기본 20)
#   harness trace summary     이벤트·결과별 개수
#   harness trace report [--stop-reason R] [--reason 글] [--agents-fallback 글] [--json]
#                             사람이 읽는 보고서(state.reportFile)를 다시 만든다 — 기능별 문제와 해결, 시간 · 시도,
#                             반복된 반려 기준, 하네스 이상 신호, 사람이 할 일. 모델을 부르지 않는다.
#                             --stop-reason 은 루프가 끝날 때 그 이유를 trace 에 먼저 남기고,
#                             커밋 운용이면 바뀐 원장만 커밋한다. --agents-fallback 은 전용 에이전트 대신 기본 에이전트로 돈 이유.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/trace.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/criteria.sh"
source "$HARNESS_HOME/lib/report.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

FILE="$(trace_file)"

# 루프가 끝날 때 커밋 운용이면 원장만 커밋한다(현장 보고 H8).
#   통과한 기능은 기록 커밋에 원장이 같이 담기지만, 막힘 · 승인 대기 · 판단 대기로 떠난 기능은 원장만 바뀌고 남는다.
#   커밋하지 않으면 stash · checkout 한 번에 그 상태(실패 사유 · 대조표 · 질문)를 잃는다. 다른 파일은 담지 않는다.
commit_ledger_at_loop_end() {  # commit_ledger_at_loop_end <stop-reason> → 커밋했으면 짧은 해시
  local ledger
  auto_commit_enabled && git -C "$PROJECT_ROOT" rev-parse --verify --quiet HEAD >/dev/null || return 0
  ledger="$(features_file)"
  [[ -f "$ledger" ]] || return 0
  [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain -- "$ledger")" ]] || return 0
  git -C "$PROJECT_ROOT" add -- "$ledger"
  git -C "$PROJECT_ROOT" commit -q -m "chore(harness): 원장 — 루프 종료($1)" --only -- "$ledger" >/dev/null 2>&1 || return 0
  git -C "$PROJECT_ROOT" rev-parse --short HEAD
}

cmd_report() {
  local stop_reason="" reason="" agents_fallback="" json_mode=0 out ledger committed=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stop-reason) stop_reason="${2:?--stop-reason 에 값}"; shift 2 ;;
      --reason)      reason="${2:-}"; shift 2 ;;
      --agents-fallback) agents_fallback="${2:-}"; shift 2 ;;
      --json)        json_mode=1; shift ;;
      *) die "$EXIT_USAGE" "사용: harness trace report [--stop-reason R] [--reason 글] [--agents-fallback 글] [--json]" ;;
    esac
  done
  [[ -n "$agents_fallback" ]] && trace_add agents-fallback "$(jq -cn --arg why "$agents_fallback" '{reason: $why}')"
  [[ -n "$stop_reason" ]] && trace_add loop-end "$(jq -cn --arg r "$stop_reason" --arg why "$reason" '{result: $r, reason: $why}')"
  out="$(report_file)"
  mkdir -p "$(dirname "$out")"
  ledger="$(features_file)"
  [[ -f "$ledger" ]] || ledger=/dev/null
  touch "$FILE"
  build_report "$FILE" "$ledger" "$(utc_now)" "$(stale_questions_json)" "$(criteria_catalog_json)" > "$out"
  [[ -n "$stop_reason" ]] && committed="$(commit_ledger_at_loop_end "$stop_reason")"
  if [[ "$json_mode" -eq 1 ]]; then
    jq -cn --arg path "${out#"$PROJECT_ROOT"/}" --arg c "$committed" '{result: "ok", path: $path, ledgerCommit: (if $c == "" then null else $c end)}'
  else
    info "📝 보고서: ${out#"$PROJECT_ROOT"/}"
    [[ -n "$committed" ]] && info "📌 원장 커밋: $committed"
  fi
  return 0
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
