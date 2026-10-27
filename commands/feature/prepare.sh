#!/usr/bin/env bash
#
# feature 준비 — add · claim · preflight. commands/feature.sh 가 source 한다.
#

cmd_add() {
  local id desc acceptance design decisions figma baseline deps problem file
  id="$(flag_value --id "$@")"
  desc="$(flag_value --desc "$@")"
  acceptance="$(flag_value --acceptance "$@")"
  design="$(flag_value --design "$@")"
  decisions="$(flag_value --decisions-json "$@")"
  figma="$(flag_value --figma "$@")"
  baseline="$(flag_value --baseline-json "$@")"
  deps="$(depends_on_json "$(flag_value --depends-on "$@")")"
  [[ -n "$id" && -n "$desc" && -n "$acceptance" ]] || die "$EXIT_USAGE" "사용: feature add --id ID --desc 설명 --acceptance 명령 [--design 문서] [--decisions-json JSON] [--figma 링크] [--baseline-json JSON] [--depends-on a,b]"
  jq -e 'type == "array"' <<<"${decisions:-[]}" >/dev/null 2>&1 || die "$EXIT_USAGE" "--decisions-json 은 [{question, answer}] 배열"
  jq -e 'type == "array"' <<<"${baseline:-[]}" >/dev/null 2>&1 || die "$EXIT_USAGE" "--baseline-json 은 [{id, title, how}] 배열"
  file="$(features_file)"
  [[ -f "$file" ]] || { mkdir -p "$(dirname "$file")"; echo '{"features":[]}' > "$file"; }
  [[ -z "$(feature_json "$id")" ]] || die "$EXIT_USAGE" "이미 있는 기능이다: $id"
  problem="$(dependency_problem "$id" "$deps")"
  [[ -z "$problem" ]] || die "$EXIT_USAGE" "$problem"
  json_update "$file" '.features += [{id: $id, description: $desc, acceptance: $acc,
                                       status: "pending", attempts: 0, repeats: 0}
                                      + (if $design == "" then {} else {designDoc: $design} end)
                                      + (if ($decisions | length) == 0 then {} else {decisions: $decisions} end)
                                      + (if $figma == "" then {} else {figma: $figma} end)
                                      + (if ($baseline | length) == 0 then {} else {baseline: $baseline} end)
                                      + (if ($deps | length) == 0 then {} else {dependsOn: $deps} end)]' \
    --arg id "$id" --arg desc "$desc" --arg acc "$acceptance" --arg design "$design" --arg figma "$figma" \
    --argjson decisions "${decisions:-[]}" --argjson baseline "${baseline:-[]}" --argjson deps "$deps"
  echo "➕ 기능 추가: $id"
}

# 같은 작업 트리에서 여러 기능을 동시에 구현할 때, 기능이 맡은 파일을 적는다.
# 게이트·검증·기록·보관이 이 범위만 본다.
# 한 파일은 한 기능의 범위에만 있다. 이미 다른 기능의 범위인 파일이면 맡지 않는다 —
# 같은 파일에 섞인 두 기능의 변경은 가를 수 없다. 그 기능은 앞 기능이 기록된 뒤 다시 구현한다.
# 다시 claim 하면 범위에 더한다. 앞 시도의 변경도 트리에 남아 있기 때문이다.
# verified · reviewed 에서도 claim 할 수 있다(범위 없이 판정을 받았는데 다른 기능 때문에 기록이 막혔을 때).
# 범위가 바뀌면 게이트가 본 변경이 아니므로 pending 으로 돌려 게이트부터 다시 한다.
# 커밋으로 운용할 때는 쓰지 않는다. 커밋과 보관(브랜치)이 트리 전체를 담아서 범위를 지킬 수 없다 —
# 그 운용은 깨끗한 트리에서 한 기능씩, 병렬은 워크트리(adopt)로 한다. (adopt 가 커밋 없는 운용에서 거부되는 것과 짝)
claimed_by_others() {  # claimed_by_others <id> <파일 JSON 배열> → "경로(기능)" 쉼표로
  jq -r --arg id "$1" --argjson files "$2" '
    [.features[] | select(.id != $id and .scope != null) as $f
     | $f.scope[] | select(. as $p | $files | index($p)) | "\(.)(\($f.id))"] | join(", ")' "$(features_file)"
}

cmd_claim() {
  local id="${1:-}"; shift || true
  local files files_json taken json_mode scope_json status
  files="$(flag_value --files "$@")"
  [[ -n "$id" && -n "$files" ]] || die "$EXIT_USAGE" "사용: feature claim ID --files 경로,경로"
  auto_commit_enabled && die "$EXIT_USAGE" "커밋으로 운용할 때는 claim 을 쓰지 않는다 — 커밋과 보관이 트리 전체를 담는다. 한 기능씩 기록하고, 막고 있는 기능이 끊긴 것이면 feature reset 한다"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING" "$STATUS_VERIFIED" "$STATUS_REVIEWED"
  json_mode="$(json_mode_of "$@")"
  files_json="$(split_commas "$files" | lines_to_json)"
  taken="$(claimed_by_others "$id" "$files_json")"
  if [[ -n "$taken" ]]; then
    trace_add claim "$(jq -cn --arg id "$id" --arg t "$taken" '{feature: $id, result: "overlap", files: $t}')"
    emit "$json_mode" "$(result_json "$id" overlap "다른 기능의 범위와 겹친다: $taken" "앞 기능이 기록된 뒤 다시 구현한다")" \
      "⛔ claim $id: 다른 기능의 범위와 겹친다 — $taken (같은 파일을 고치는 기능은 순차로)"
    return "$EXIT_GATE_FAILED"
  fi
  scope_json="$(jq -c --arg id "$id" --argjson files "$files_json" \
    '.features[] | select(.id == $id) | (.scope // []) + $files | unique' "$(features_file)")"
  status="$(feature_field "$id" status)"
  if [[ "$status" != "$STATUS_PENDING" && "$scope_json" != "$(feature_scope "$id" | lines_to_json | jq -c 'unique')" ]]; then
    set_feature_fields "$id" "$(jq -cn --argjson s "$scope_json" --arg was "$status" \
      '{scope: $s, status: "pending", lastFailure: ("범위 지정 — " + $was + " 때 본 변경과 범위가 달라 게이트부터 다시"), lastFailureDetail: ""}')"
  else
    set_feature_fields "$id" "$(jq -cn --argjson s "$scope_json" '{scope: $s}')"
  fi
  emit "$json_mode" "$(result_json "$id" claimed "범위 $(jq length <<<"$scope_json")개 파일")" "📌 claim $id: $(jq -r 'join(",")' <<<"$scope_json") → $(feature_field "$id" status)"
}

# ── 루프 사전 점검 ───────────────────────────────────────────────────
PREFLIGHT_PROBLEMS=()
PREFLIGHT_NOTES=()

check_ledger_ready() {
  if [[ ! -f "$(features_file)" ]]; then PREFLIGHT_PROBLEMS+=("기능 원장이 없다: $(features_file)"); return; fi
  jq -e '.features | type == "array"' "$(features_file)" >/dev/null 2>&1 || PREFLIGHT_PROBLEMS+=("원장 형식이 틀렸다")
  local missing
  missing="$(jq -r '[.features[] | select(.status == "pending" and ((.acceptance // "") == "")) | .id] | join(", ")' "$(features_file)")"
  [[ -n "$missing" ]] && PREFLIGHT_PROBLEMS+=("acceptance 명령이 없는 기능: $missing")
  return 0
}

# 커밋으로 운용하면 남의 변경을 커밋하지 않도록 깨끗한 트리와 기준 커밋이 필요하다.
#   원장은 빼고 본다 — 기록되지 않고 떠난 기능(막힘 · 승인 대기 · 판단 대기)은 원장만 바꿔 두고 커밋하지 않는다.
#   원장까지 보면 그런 기능이 하나라도 생긴 뒤로 다음 루프가 시작하지 못한다. (approve 의 확인과 같은 기준)
# 커밋 없이 운용하면 지금 상태를 기준선으로 삼는다(이미 있으면 그대로).
check_working_tree_ready() {
  if auto_commit_enabled; then
    has_head_commit || PREFLIGHT_PROBLEMS+=("커밋이 하나도 없다 — 기준 커밋이 필요하다 (커밋 없이 쓰려면 loop.autoCommit: false)")
    if has_changes_outside_ledger; then
      PREFLIGHT_PROBLEMS+=("작업 트리가 깨끗하지 않다 — 루프가 남의 변경까지 커밋하지 않도록 먼저 커밋하거나 stash 한다")
    else
      release_stale_in_flight
    fi
    return 0
  fi
  has_baseline && return 0
  baseline_save
  PREFLIGHT_NOTES+=("기준선을 지금 상태로 저장했다 — 이후 변경은 이 기준선과 비교한다")
}

# 커밋 운용에서 트리가 깨끗하면(원장 밖) 이 트리에 진행 중인 변경은 없다. 남은 진행 중 표시는 끊긴 실행의 흔적이다.
#   그대로 두면 그런 기능끼리 소유권 확인에서 서로를 막고, verified · reviewed 는 루프가 고르지 않아 영영 남는다.
#   pending 은 표시만 지우고, verified · reviewed 는 볼 변경이 없으니 pending 으로 되돌린다(다시 구현).
release_stale_in_flight() {
  [[ -f "$(features_file)" ]] || return 0
  local stale
  stale="$(jq -r "$JQ_IN_FLIGHT"' [.features[] | select(in_flight) | .id] | join(", ")' "$(features_file)")"
  [[ -z "$stale" ]] && return 0
  json_update "$(features_file)" "$JQ_IN_FLIGHT"'
    .features |= map(if in_flight then
      .implementedUnder = null
      | if .status == "verified" or .status == "reviewed"
        then .status = "pending" | .lastFailure = "작업 트리에 변경이 없다 — 다시 구현한다 (사전 점검)" | .lastFailureDetail = ""
        else . end
    else . end)'
  trace_add preflight "$(jq -cn --arg ids "$stale" '{result: "released-stale", features: $ids}')"
  PREFLIGHT_NOTES+=("작업 트리가 깨끗한데 진행 중으로 남은 기능을 풀었다(끊긴 실행의 흔적): $stale")
}

# 검증을 통과한 뒤 손으로 고친 기능은 다시 대기열로 — 이번 루프가 다시 검증한다
reopen_drifted_for_loop() {
  [[ -f "$(features_file)" ]] || return 0
  local id files
  while IFS=$'\t' read -r id files; do
    [[ -n "$id" ]] && PREFLIGHT_NOTES+=("검증 후 변경된 기능 $id 를 다시 연다: $files")
  done < <(reopen_drifted_features)
  return 0
}

# 포맷 검사가 루프 전부터 실패하면 모든 기능이 남의 코드 때문에 포맷 게이트에서 막힌다. 시작하기 전에 알린다.
#   포매터를 한 번 돌려 커밋(또는 기준선)하면 그 뒤로는 기능이 바꾼 파일만 검사에 걸린다.
check_format_ready() {
  local check
  check="$(cfg '.build.formatCheckCommand')"
  [[ -z "$check" ]] && return 0
  run_locked_step "$check" && return 0
  PREFLIGHT_PROBLEMS+=("포맷 검사가 루프 전부터 실패한다($check) — 포매터($(cfg '.build.formatCommand'))를 한 번 돌려 반영하거나 build.formatCheckCommand 를 비운다"$'\n'"$STEP_OUTPUT")
}

# 판단 대기 질문이 나온 뒤 커밋이 쌓였으면 알린다 — 사람이 낡은 전제로 답하지 않게(현장 보고 H11)
note_stale_questions() {
  [[ -f "$(features_file)" ]] || return 0
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && PREFLIGHT_NOTES+=("$line")
  done < <(jq -r --argjson stale "$(stale_questions_json)" "$JQ_QUESTION_AGE"'
    .features[] | select(.status == "needs-decision") | question_age($stale) as $age | select($age != "")
    | "판단 대기 \(.id) 의 질문\($age)"' "$(features_file)")
  return 0
}

cmd_preflight() {
  PREFLIGHT_PROBLEMS=()
  PREFLIGHT_NOTES=()
  check_ledger_ready
  reopen_drifted_for_loop
  check_working_tree_ready
  check_format_ready
  note_stale_questions
  local figma_notice
  figma_notice="$(figma_mcp_notice)"
  [[ -n "$figma_notice" ]] && PREFLIGHT_NOTES+=("$figma_notice")
  local ok=true problems_json='[]' notes_json='[]' mcp_json
  [[ ${#PREFLIGHT_PROBLEMS[@]} -gt 0 ]] && { ok=false; problems_json="$(printf '%s\n' "${PREFLIGHT_PROBLEMS[@]}" | lines_to_json)"; }
  [[ ${#PREFLIGHT_NOTES[@]} -gt 0 ]] && notes_json="$(printf '%s\n' "${PREFLIGHT_NOTES[@]}" | lines_to_json)"
  # MCP 는 막지 않는다. 연결 상태만 싣는다 (루프가 검증자 지시를 고른다).
  mcp_json="$(mcp_status_json)"
  emit "$(json_mode_of "$@")" \
    "$(jq -cn --argjson ok "$ok" --argjson problems "$problems_json" --argjson notes "$notes_json" --argjson mcp "$mcp_json" \
       --argjson parallel "$(cfg '.loop.parallel')" --argjson autoCommit "$(auto_commit_enabled && echo true || echo false)" \
       --argjson agents "$(plugin_agents_json)" \
       '{ok: $ok, problems: $problems, notes: $notes, mcp: $mcp, parallel: $parallel, autoCommit: $autoCommit, agents: $agents}')" \
    "$([[ "$ok" == true ]] && echo "✅ preflight 통과" || { echo "⛔ preflight 실패"; printf '   - %s\n' "${PREFLIGHT_PROBLEMS[@]}"; })
$([[ ${#PREFLIGHT_NOTES[@]} -gt 0 ]] && printf 'ℹ️ %s\n' "${PREFLIGHT_NOTES[@]}")
$(mcp_status_text "$mcp_json")"
  [[ "$ok" == true ]]
}
