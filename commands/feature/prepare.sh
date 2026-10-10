#!/usr/bin/env bash
#
# feature 준비 — add · claim · preflight. commands/feature.sh 가 source 한다.
#

cmd_add() {
  local id desc acceptance design decisions figma file
  id="$(flag_value --id "$@")"
  desc="$(flag_value --desc "$@")"
  acceptance="$(flag_value --acceptance "$@")"
  design="$(flag_value --design "$@")"
  decisions="$(flag_value --decisions-json "$@")"
  figma="$(flag_value --figma "$@")"
  [[ -n "$id" && -n "$desc" && -n "$acceptance" ]] || die "$EXIT_USAGE" "사용: feature add --id ID --desc 설명 --acceptance 명령 [--design 문서] [--decisions-json JSON] [--figma 링크]"
  jq -e 'type == "array"' <<<"${decisions:-[]}" >/dev/null 2>&1 || die "$EXIT_USAGE" "--decisions-json 은 [{question, answer}] 배열"
  file="$(features_file)"
  [[ -f "$file" ]] || { mkdir -p "$(dirname "$file")"; echo '{"features":[]}' > "$file"; }
  [[ -z "$(feature_json "$id")" ]] || die "$EXIT_USAGE" "이미 있는 기능이다: $id"
  json_update "$file" '.features += [{id: $id, description: $desc, acceptance: $acc,
                                       status: "pending", attempts: 0, repeats: 0}
                                      + (if $design == "" then {} else {designDoc: $design} end)
                                      + (if ($decisions | length) == 0 then {} else {decisions: $decisions} end)
                                      + (if $figma == "" then {} else {figma: $figma} end)]' \
    --arg id "$id" --arg desc "$desc" --arg acc "$acceptance" --arg design "$design" --arg figma "$figma" \
    --argjson decisions "${decisions:-[]}"
  echo "➕ 기능 추가: $id"
}

# 같은 작업 트리에서 여러 기능을 동시에 구현할 때, 기능이 맡은 파일을 적는다.
# 게이트·검증·기록·보관이 이 범위만 본다.
# 한 파일은 한 기능의 범위에만 있다. 이미 다른 기능의 범위인 파일이면 맡지 않는다 —
# 같은 파일에 섞인 두 기능의 변경은 가를 수 없다. 그 기능은 앞 기능이 기록된 뒤 다시 구현한다.
claimed_by_others() {  # claimed_by_others <id> <파일 JSON 배열> → "경로(기능)" 쉼표로
  jq -r --arg id "$1" --argjson files "$2" '
    [.features[] | select(.id != $id and .scope != null) as $f
     | $f.scope[] | select(. as $p | $files | index($p)) | "\(.)(\($f.id))"] | join(", ")' "$(features_file)"
}

cmd_claim() {
  local id="${1:-}"; shift || true
  local files files_json taken json_mode
  files="$(flag_value --files "$@")"
  [[ -n "$id" && -n "$files" ]] || die "$EXIT_USAGE" "사용: feature claim ID --files 경로,경로"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING"
  json_mode="$(json_mode_of "$@")"
  files_json="$(split_commas "$files" | lines_to_json)"
  taken="$(claimed_by_others "$id" "$files_json")"
  if [[ -n "$taken" ]]; then
    trace_add claim "$(jq -cn --arg id "$id" --arg t "$taken" '{feature: $id, result: "overlap", files: $t}')"
    emit "$json_mode" "$(result_json "$id" overlap "다른 기능의 범위와 겹친다: $taken" "앞 기능이 기록된 뒤 다시 구현한다")" \
      "⛔ claim $id: 다른 기능의 범위와 겹친다 — $taken (같은 파일을 고치는 기능은 순차로)"
    return "$EXIT_GATE_FAILED"
  fi
  set_feature_fields "$id" "$(jq -c '{scope: .}' <<<"$files_json")"
  emit "$json_mode" "$(result_json "$id" claimed "범위 $(jq length <<<"$files_json")개 파일")" "📌 claim $id: $files"
}

# ── 루프 사전 점검 ───────────────────────────────────────────────────
worktree_is_clean() { [[ -z "$(git status --porcelain --untracked-files=normal)" ]]; }

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
# 커밋 없이 운용하면 지금 상태를 기준선으로 삼는다(이미 있으면 그대로).
check_working_tree_ready() {
  if auto_commit_enabled; then
    has_head_commit || PREFLIGHT_PROBLEMS+=("커밋이 하나도 없다 — 기준 커밋이 필요하다 (커밋 없이 쓰려면 loop.autoCommit: false)")
    worktree_is_clean || PREFLIGHT_PROBLEMS+=("작업 트리가 깨끗하지 않다 — 루프가 남의 변경까지 커밋하지 않도록 먼저 커밋하거나 stash 한다")
    return 0
  fi
  has_baseline && return 0
  baseline_save
  PREFLIGHT_NOTES+=("기준선을 지금 상태로 저장했다 — 이후 변경은 이 기준선과 비교한다")
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

cmd_preflight() {
  PREFLIGHT_PROBLEMS=()
  PREFLIGHT_NOTES=()
  check_ledger_ready
  reopen_drifted_for_loop
  check_working_tree_ready
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
