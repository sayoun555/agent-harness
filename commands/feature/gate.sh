#!/usr/bin/env bash
#
# feature 판정 — verify(결정론 게이트) · review(독립 검증 기록) · reject · audit. commands/feature.sh 가 source 한다.
#

# 실패한 단계 이름과 요약을 FAILED_STEP / FAILED_DETAIL 에 남긴다.
FAILED_STEP=""
FAILED_DETAIL=""

fail_gate() {  # fail_gate <단계> → 1
  FAILED_STEP="$1"
  FAILED_DETAIL="$STEP_OUTPUT"
  return 1
}

# rules.sizePolicy 가 block-growth 면, 이번 변경으로 한도를 넘은 파일이 게이트를 막는다 (기본 warn: 검증 컨텍스트에만).
size_blocks_gate() {
  local grown
  [[ "$(cfg '.rules.sizePolicy')" == "block-growth" ]] || return 1
  grown="$(grown_oversized_files ${SCOPE[@]+"${SCOPE[@]}"})"
  [[ -z "$grown" ]] && return 1
  STEP_OUTPUT="$(describe_grown_oversized <<<"$grown")"
}

# 빌드·테스트는 빌드 잠금 안에서 돈다. 같은 트리의 다른 에이전트와 빌드 도구가 충돌하지 않게.
run_locked_step() { run_step "bash \"$HARNESS_HOME/commands/lock.sh\" run -- bash -c $(printf '%q' "$1")"; }

run_gates() {  # run_gates <id> → 0 이면 모두 통과
  local id="$1" compile acceptance guard
  compile="$(cfg '.build.compileCommand')"
  acceptance="$(feature_field "$id" acceptance)"
  scope_of "$id"
  guard="bash \"$HARNESS_HOME/commands/test-guard.sh\""
  [[ ${#SCOPE[@]} -gt 0 ]] && guard="$guard -- $(printf '%q ' "${SCOPE[@]}")"

  if size_blocks_gate; then fail_gate "크기 초과"; return; fi
  if [[ -n "$compile" ]] && ! run_locked_step "$compile"; then fail_gate "컴파일"; return; fi
  run_step "$guard" || { fail_gate "테스트 약화"; return; }
  run_locked_step "$acceptance" || { fail_gate "acceptance"; return; }
  return 0
}

cmd_verify() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature verify ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING" "$STATUS_VERIFIED"
  local json_mode status reason
  json_mode="$(json_mode_of "$@")"

  if run_gates "$id"; then
    set_feature_fields "$id" '{"status":"verified","repeats":0,"lastFailure":"","lastFailureDetail":"","lastFailureFingerprint":""}'
    trace_add verify "$(jq -cn --arg id "$id" '{feature: $id, result: "pass"}')"
    emit "$json_mode" "$(result_json "$id" pass "모든 게이트 통과")" "✅ verify $id: 통과 → verified (다음: 독립 검증)"
    return 0
  fi

  reason="$FAILED_STEP 실패"
  status="$(record_failure "$id" "$reason" "$FAILED_DETAIL")"
  set_aside_if_blocked "$id" "$status"
  trace_add verify "$(jq -cn --arg id "$id" --arg step "$FAILED_STEP" --arg status "$status" \
    '{feature: $id, result: "fail", step: $step, status: $status}')"
  emit "$json_mode" "$(result_json "$id" fail "$reason" "$FAILED_DETAIL")" \
    "⛔ verify $id: $reason → $status"$'\n'"$FAILED_DETAIL"
  return "$EXIT_GATE_FAILED"
}

# ── 독립 검증 기록 ───────────────────────────────────────────────────
# 검증자(구현하지 않은 에이전트)의 판정을 원장에 남긴다. 기록(record)은 reviewed 에서만 할 수 있다.
#   에이전트는 대조표(--verdict-json · --verdict-file)를 낸다. 승인·반려는 하네스가 대조표로 정한다(lib/verdict.sh).
#   --approve · --reject 는 사람이 직접 판정할 때 쓴다.
approve_review() {  # approve_review <id> <json-mode> <reason>
  local id="$1" reason="${3:-승인}"
  set_feature_fields "$id" "$(jq -cn --arg r "$reason" '{status: "reviewed", reviewNote: $r}')"
  trace_add review "$(jq -cn --arg id "$id" --arg r "$reason" '{feature: $id, result: "approve", reason: $r}')"
  emit "$2" "$(result_json "$id" approve "$reason")" "✅ review $id: 승인 → reviewed (다음: record)"
}

reject_review() {  # reject_review <id> <json-mode> <reason>
  local id="$1" reason="$3" status
  status="$(record_failure "$id" "리뷰 반려: $reason" "")"
  set_aside_if_blocked "$id" "$status"
  trace_add review "$(jq -cn --arg id "$id" --arg status "$status" --arg reason "$reason" \
    '{feature: $id, result: "reject", status: $status, reason: $reason}')"
  emit "$2" "$(result_json "$id" reject "리뷰 반려: $reason")" "↩️ review $id: 반려 → $status"
}

verdict_from_args() {  # verdict_from_args <args...> → 대조표 JSON (없으면 빈 출력)
  local file
  file="$(flag_value --verdict-file "$@")"
  if [[ -n "$file" ]]; then cat "$file"; return; fi
  flag_value --verdict-json "$@"
}

review_by_checklist() {  # review_by_checklist <id> <json-mode> <대조표>
  local id="$1" json_mode="$2" verdict="$3"
  evaluate_verdict "$verdict"
  set_feature_fields "$id" "$(jq -cn --arg v "$verdict" '{lastReview: (try ($v | fromjson) catch $v)}')"
  if [[ "$VERDICT_DECISION" == approve ]]; then approve_review "$id" "$json_mode" "$VERDICT_REASON"
  else reject_review "$id" "$json_mode" "$VERDICT_REASON"; fi
}

cmd_review() {
  local id="${1:-}"; shift || true
  local reason json_mode verdict
  reason="$(flag_value --reason "$@")"
  json_mode="$(json_mode_of "$@")"
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature review ID (--verdict-json JSON | --verdict-file 파일 | --approve [--reason 근거] | --reject --reason 이유)"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_VERIFIED"
  verdict="$(verdict_from_args "$@")"
  if [[ -n "$verdict" ]]; then review_by_checklist "$id" "$json_mode" "$verdict"; return; fi
  if has_flag --approve "$@"; then approve_review "$id" "$json_mode" "$reason"; return; fi
  has_flag --reject "$@" || die "$EXIT_USAGE" "--verdict-json · --verdict-file · --approve · --reject 중 하나가 필요하다"
  [[ -n "$reason" ]] || die "$EXIT_USAGE" "반려에는 --reason 이 필요하다"
  reject_review "$id" "$json_mode" "$reason"
}

cmd_reject() { local id="${1:-}"; shift || true; cmd_review "$id" --reject "$@"; }

# ── 감사: passing 이 여전히 참인가 ────────────────────────────────────
cmd_audit() {
  require_features_file
  local id regressed=()
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    run_locked_step "$(feature_field "$id" acceptance)" && continue
    set_feature_fields "$id" "$(jq -cn --arg d "$STEP_OUTPUT" '{status: "pending", lastFailure: "audit 회귀", lastFailureDetail: $d}')"
    trace_add audit "$(jq -cn --arg id "$id" '{feature: $id, result: "regressed"}')"
    regressed+=("$id")
  done < <(jq -r '.features[] | select(.status == "passing") | .id' "$(features_file)")

  local regressed_json='[]'
  [[ ${#regressed[@]} -gt 0 ]] && regressed_json="$(printf '%s\n' "${regressed[@]}" | lines_to_json)"
  emit "$(json_mode_of "$@")" "$(jq -cn --argjson r "$regressed_json" '{regressed: $r}')" \
    "$([[ ${#regressed[@]} -eq 0 ]] && echo "✅ audit: 회귀 없음" || echo "⛔ audit: 회귀 → pending 으로 되돌림: ${regressed[*]}")"
  [[ ${#regressed[@]} -eq 0 ]]
}
