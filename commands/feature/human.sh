#!/usr/bin/env bash
#
# feature 사람 개입 — ask · decide · reset. commands/feature.sh 가 source 한다.
#

# 구현자가 스스로 정할 수 없는 설계 결정을 만나면 질문을 남기고 판단 대기로 빠진다.
# 판단 대기로 떠나며 변경을 보관하므로, 다른 보관 경로(verify · review · record)처럼 소유권을 먼저 본다 —
# 범위 없이 보관하면 같은 트리에 있는 다른 기능의 변경까지 이 기능의 보관본으로 치운다.
cmd_ask() {
  local id="${1:-}"; shift || true
  local question
  question="$(flag_value --question "$@")"
  [[ -n "$id" && -n "$question" ]] || die "$EXIT_USAGE" "사용: feature ask ID --question 질문"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING"
  require_sole_owner "$id"
  # 질문은 물을 때의 상황을 전제로 한다. 그 시점을 남겨, 그 뒤 커밋이 쌓였으면 낡았을 수 있다고 알린다(현장 보고 H11)
  set_feature_fields "$id" "$(jq -cn --arg q "$question" --arg at "$(utc_now)" --arg head "$(current_head)" \
    '{status: "needs-decision", question: $q, askedAt: {at: $at, head: $head}}')"
  set_aside_changes "$id" "needs-decision"
  trace_add ask "$(jq -cn --arg id "$id" --arg q "$question" '{feature: $id, result: "needs-decision", question: $q}')"
  emit "$(json_mode_of "$@")" "$(result_json "$id" needs-decision "$question")" "❓ ask $id → needs-decision: $question"
}

cmd_decide() {
  local id="${1:-}"; shift || true
  local answer question prior
  answer="$(flag_value --answer "$@")"
  [[ -n "$id" && -n "$answer" ]] || die "$EXIT_USAGE" "사용: feature decide ID --answer 답"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_NEEDS_DECISION"
  question="$(feature_field "$id" question)"
  prior="$(jq -c --arg id "$id" '.features[] | select(.id == $id) | .decisions // []' "$(features_file)")"
  set_feature_fields "$id" "$(jq -cn --argjson prior "$prior" --arg q "$question" --arg a "$answer" \
    '{status: "pending", question: null, askedAt: null, decisions: ($prior + [{question: $q, answer: $a}])}')"
  trace_add decide "$(jq -cn --arg id "$id" --arg a "$answer" '{feature: $id, answer: $a}')"
  echo "✅ decide $id → pending (결정이 다음 구현에 전달된다)"
}

# 통과하지 않은 기능을 대기열 처음으로: 시도 횟수 · 범위 · 진행 중 표시를 지운다. 작업 트리는 건드리지 않는다.
#   막힘 · 승인 대기 · 판단 대기의 변경은 이미 보관돼 있다(참고용으로 남긴다).
#   pending · verified · reviewed 의 변경은 트리에 그대로 남고, 다음 구현이 이어서 쓴다.
#   진행 중이 아니게 되므로 소유권 판정(lib/record.sh)에서 빠진다 — 다른 기능을 막고 있던 기능을 풀 때 쓴다.
cmd_reset() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature reset ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_BLOCKED" "$STATUS_AWAITING" "$STATUS_NEEDS_DECISION" \
    "$STATUS_PENDING" "$STATUS_VERIFIED" "$STATUS_REVIEWED"
  local ref
  ref="$(parked_ref "$id")"
  set_feature_fields "$id" '{"status":"pending","attempts":0,"repeats":0,"lastFailure":"","lastFailureDetail":"","lastFailureFingerprint":"","scope":null,"implementedUnder":null}'
  trace_add reset "$(jq -cn --arg id "$id" '{feature: $id}')"
  echo "🔄 reset $id → pending ($(base_label) 에서 다시 구현한다)"
  [[ -n "$ref" ]] && echo "   이전 시도는 $ref 에 남아 있다."
  return 0
}
