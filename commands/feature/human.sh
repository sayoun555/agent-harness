#!/usr/bin/env bash
#
# feature 사람 개입 — ask · decide · reset. commands/feature.sh 가 source 한다.
#

# 구현자가 스스로 정할 수 없는 설계 결정을 만나면 질문을 남기고 판단 대기로 빠진다.
cmd_ask() {
  local id="${1:-}"; shift || true
  local question
  question="$(flag_value --question "$@")"
  [[ -n "$id" && -n "$question" ]] || die "$EXIT_USAGE" "사용: feature ask ID --question 질문"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING"
  set_feature_fields "$id" "$(jq -cn --arg q "$question" '{status: "needs-decision", question: $q}')"
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
    '{status: "pending", question: null, decisions: ($prior + [{question: $q, answer: $a}])}')"
  trace_add decide "$(jq -cn --arg id "$id" --arg a "$answer" '{feature: $id, answer: $a}')"
  echo "✅ decide $id → pending (결정이 다음 구현에 전달된다)"
}

# 막힘·승인 대기·판단 대기를 다시 대기열로. 보관한 이전 시도는 참고용으로 남긴다.
cmd_reset() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature reset ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_BLOCKED" "$STATUS_AWAITING" "$STATUS_NEEDS_DECISION"
  local ref
  ref="$(parked_ref "$id")"
  set_feature_fields "$id" '{"status":"pending","attempts":0,"repeats":0,"lastFailure":"","lastFailureDetail":"","lastFailureFingerprint":"","scope":null}'
  trace_add reset "$(jq -cn --arg id "$id" '{feature: $id}')"
  echo "🔄 reset $id → pending ($(base_label) 에서 다시 구현한다)"
  [[ -n "$ref" ]] && echo "   이전 시도는 $ref 에 남아 있다."
  return 0
}
