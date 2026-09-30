#!/usr/bin/env bash
#
# harness feature — 기능 원장. 루프의 상태와 종료 조건이 여기 있다.
#
#   list [--json]                         전체 기능
#   next [--json]                         다음 pending 기능 (없으면 빈 출력 / {})
#   add --id ID --desc 설명 --acceptance 명령 [--design 설계문서]
#   preflight [--json]                    루프 시작 전 점검 (깨끗한 트리·원장·acceptance)
#   verify ID [--json]                    컴파일 → 테스트 약화 감시 → acceptance. 통과 시 verified
#   reject ID --reason 이유 [--json]       적대자 반려. 실패로 기록
#   commit ID [--json]                    verified → passing + git 커밋 (위험 파일이면 승인 대기)
#   ask ID --question 질문 [--json]        구현자가 판단을 요청: pending → needs-decision
#   decide ID --answer 답                 사람의 결정을 기능에 붙인다: needs-decision → pending
#   approve ID                            사람 승인: 보관 브랜치를 가져와 passing + 커밋
#   reset ID                              blocked·awaiting-approval·needs-decision → pending
#
#   통과하지 못하고 떠나는 기능(blocked·awaiting-approval·needs-decision)의 변경은
#   harness/<ID> 브랜치에 보관하고 작업 트리를 되돌린다. 다음 기능의 커밋에 섞이지 않게 한다.
#   status [--json]                       상태별 개수
#   audit [--json]                        passing 기능의 acceptance 재실행 (회귀·원장 조작 감지)
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/trace.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/risk.sh"
source "$HARNESS_HOME/lib/park.sh"
source "$HARNESS_HOME/lib/mcp.sh"
require_commands git jq shasum
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

# ── 공통 ────────────────────────────────────────────────────────────
has_flag() {  # has_flag <flag> <args...>
  local flag="$1" arg; shift
  for arg in "$@"; do [[ "$arg" == "$flag" ]] && return 0; done
  return 1
}

flag_value() {  # flag_value <flag> <args...> → 다음 인자
  local flag="$1"; shift
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "$flag" ]] && { printf '%s' "${2:-}"; return 0; }
    shift
  done
  return 0
}

# run_step <command> → 출력 끝부분을 STEP_OUTPUT 에 담고 종료 코드를 반환
STEP_OUTPUT=""
run_step() {
  local command="$1" log code=0
  log="$(mktemp)"
  bash -c "$command" > "$log" 2>&1 || code=$?
  STEP_OUTPUT="$(tail -n "$(cfg '.loop.failureTailLines')" "$log")"
  rm -f "$log"
  return "$code"
}

# emit <json-mode> <json-object> <human-line>
emit() {
  if [[ "$1" -eq 1 ]]; then printf '%s\n' "$2"; else printf '%s\n' "$3"; fi
}

result_json() {  # result_json <id> <result> <reason> [detail]
  jq -cn --arg id "$1" --arg result "$2" --arg reason "$3" --arg detail "${4:-}" \
    --arg status "$(feature_field "$1" status)" --argjson attempts "$(feature_field "$1" attempts)" \
    '{id: $id, result: $result, status: $status, attempts: $attempts, reason: $reason, detail: $detail}'
}

# park_feature <id> <kind> — 기능의 변경을 보관하고 원장에 브랜치를 적는다
park_feature() {
  local id="$1" kind="$2" branch
  branch="$(park_changes "$id" "wip($id): $kind — $(feature_field "$id" description)")"
  [[ -z "$branch" ]] && return 0
  set_feature_fields "$id" "$(jq -cn --arg b "$branch" '{parkedBranch: $b}')"
  trace_add park "$(jq -cn --arg id "$id" --arg kind "$kind" --arg b "$branch" '{feature: $id, kind: $kind, branch: $b}')"
}

park_if_blocked() {  # park_if_blocked <id> <status>
  [[ "$2" == "$STATUS_BLOCKED" ]] && park_feature "$1" "blocked"
  return 0
}

# ── 조회 ────────────────────────────────────────────────────────────
cmd_list() {
  if has_flag --json "$@"; then jq -c '.features' "$(features_file)"; return; fi
  jq -r '.features[] | "\(.status)\t\(.id)\t\(.description)"' "$(features_file)" | column -t -s $'\t'
}

cmd_next() {
  local id
  id="$(next_pending_id)"
  if has_flag --json "$@"; then
    [[ -n "$id" ]] && feature_json "$id" || echo '{}'
    return
  fi
  [[ -n "$id" ]] && echo "$id" || true
}

cmd_status() {
  local counts
  counts="$(jq -c '.features | group_by(.status) | map({(.[0].status): length}) | add // {}' "$(features_file)")"
  if has_flag --json "$@"; then echo "$counts"; else jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$counts"; fi
}

# ── 추가 ────────────────────────────────────────────────────────────
cmd_add() {
  local id desc acceptance design file
  id="$(flag_value --id "$@")"
  desc="$(flag_value --desc "$@")"
  acceptance="$(flag_value --acceptance "$@")"
  design="$(flag_value --design "$@")"
  [[ -n "$id" && -n "$desc" && -n "$acceptance" ]] || die "$EXIT_USAGE" "사용: feature add --id ID --desc 설명 --acceptance 명령"
  file="$(features_file)"
  [[ -f "$file" ]] || { mkdir -p "$(dirname "$file")"; echo '{"features":[]}' > "$file"; }
  [[ -z "$(feature_json "$id")" ]] || die "$EXIT_USAGE" "이미 있는 기능이다: $id"
  json_update "$file" '.features += [{id: $id, description: $desc, acceptance: $acc,
                                       status: "pending", attempts: 0, repeats: 0}
                                      + (if $design == "" then {} else {designDoc: $design} end)]' \
    --arg id "$id" --arg desc "$desc" --arg acc "$acceptance" --arg design "$design"
  echo "➕ 기능 추가: $id"
}

# ── 루프 사전 점검 ───────────────────────────────────────────────────
worktree_is_clean() {
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]]
}

cmd_preflight() {
  local problems=()
  git rev-parse --verify --quiet HEAD >/dev/null || problems+=("커밋이 하나도 없다 — 기준 커밋이 필요하다")
  worktree_is_clean || problems+=("작업 트리가 깨끗하지 않다 — 루프가 남의 변경까지 커밋하지 않도록 먼저 커밋하거나 stash 한다")
  if [[ -f "$(features_file)" ]]; then
    jq -e '.features | type == "array"' "$(features_file)" >/dev/null 2>&1 || problems+=("원장 형식이 틀렸다")
    local missing
    missing="$(jq -r '[.features[] | select(.status == "pending" and ((.acceptance // "") == "")) | .id] | join(", ")' "$(features_file)")"
    [[ -n "$missing" ]] && problems+=("acceptance 명령이 없는 기능: $missing")
  else
    problems+=("기능 원장이 없다: $(features_file)")
  fi

  local problems_json='[]'
  [[ ${#problems[@]} -gt 0 ]] && problems_json="$(printf '%s\n' "${problems[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  local ok=true
  [[ ${#problems[@]} -gt 0 ]] && ok=false
  # MCP 는 막지 않는다. 연결 상태만 싣는다 (루프가 검증자 지시를 고른다).
  local mcp_json
  mcp_json="$(mcp_status_json)"
  emit "$(has_flag --json "$@" && echo 1 || echo 0)" \
    "$(jq -cn --argjson ok "$ok" --argjson problems "$problems_json" --argjson mcp "$mcp_json" '{ok: $ok, problems: $problems, mcp: $mcp}')" \
    "$([[ "$ok" == true ]] && echo "✅ preflight 통과" || { echo "⛔ preflight 실패"; printf '   - %s\n' "${problems[@]}"; })
$(mcp_status_text "$mcp_json")"
  [[ "$ok" == true ]]
}

# ── 검증 (결정론 게이트 노드) ─────────────────────────────────────────
# 실패한 단계 이름과 요약을 FAILED_STEP / FAILED_DETAIL 에 남긴다.
FAILED_STEP=""
FAILED_DETAIL=""

run_gates() {  # run_gates <id> → 0 이면 모두 통과
  local id="$1" compile acceptance
  compile="$(cfg '.build.compileCommand')"
  acceptance="$(feature_field "$id" acceptance)"

  if [[ -n "$compile" ]] && ! run_step "$compile"; then
    FAILED_STEP="컴파일"; FAILED_DETAIL="$STEP_OUTPUT"; return 1
  fi
  if ! run_step "bash \"$HARNESS_HOME/commands/test-guard.sh\""; then
    FAILED_STEP="테스트 약화"; FAILED_DETAIL="$STEP_OUTPUT"; return 1
  fi
  if ! run_step "$acceptance"; then
    FAILED_STEP="acceptance"; FAILED_DETAIL="$STEP_OUTPUT"; return 1
  fi
  return 0
}

cmd_verify() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature verify ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING" "$STATUS_VERIFIED"
  local json_mode=0 status reason
  has_flag --json "$@" && json_mode=1

  if run_gates "$id"; then
    set_feature_fields "$id" '{"status":"verified","repeats":0,"lastFailure":"","lastFailureDetail":"","lastFailureFingerprint":""}'
    trace_add verify "$(jq -cn --arg id "$id" '{feature: $id, result: "pass"}')"
    emit "$json_mode" "$(result_json "$id" pass "모든 게이트 통과")" "✅ verify $id: 통과 → verified"
    return 0
  fi

  reason="$FAILED_STEP 실패"
  status="$(record_failure "$id" "$reason" "$FAILED_DETAIL")"
  park_if_blocked "$id" "$status"
  trace_add verify "$(jq -cn --arg id "$id" --arg step "$FAILED_STEP" --arg status "$status" \
    '{feature: $id, result: "fail", step: $step, status: $status}')"
  emit "$json_mode" "$(result_json "$id" fail "$reason" "$FAILED_DETAIL")" \
    "⛔ verify $id: $reason → $status"$'\n'"$FAILED_DETAIL"
  return "$EXIT_GATE_FAILED"
}

# ── 적대자 반려 ──────────────────────────────────────────────────────
cmd_reject() {
  local id="${1:-}"; shift || true
  local reason status json_mode=0
  reason="$(flag_value --reason "$@")"
  [[ -n "$id" && -n "$reason" ]] || die "$EXIT_USAGE" "사용: feature reject ID --reason 이유"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_VERIFIED"
  has_flag --json "$@" && json_mode=1
  status="$(record_failure "$id" "리뷰 반려: $reason" "")"
  park_if_blocked "$id" "$status"
  trace_add review "$(jq -cn --arg id "$id" --arg status "$status" --arg reason "$reason" \
    '{feature: $id, result: "reject", status: $status, reason: $reason}')"
  emit "$json_mode" "$(result_json "$id" reject "리뷰 반려: $reason")" "↩️ reject $id → $status"
}

# ── 커밋 (기록 노드) ─────────────────────────────────────────────────
# commit_feature <id> <message-suffix> <status-on-failure>
#   원장을 passing 으로 바꾼 뒤 커밋한다. git 훅이 커밋을 막으면 원장 상태를 되돌리고 1 을 반환한다
#   (원장은 통과인데 커밋은 없는 어긋난 상태를 남기지 않는다). 변경은 작업 트리에 남는다.
COMMIT_ERROR=""
commit_feature() {
  local id="$1" suffix="$2" rollback_status="$3" desc acceptance log
  desc="$(feature_field "$id" description)"
  acceptance="$(feature_field "$id" acceptance)"
  set_feature_fields "$id" "$(jq -cn --arg at "$(utc_now)" '{status: "passing", passedAt: $at}')"
  git add -A
  log="$(mktemp)"
  if git commit -q -m "feat($id): $desc" -m "harness: acceptance 통과 — $acceptance$suffix" > "$log" 2>&1; then
    rm -f "$log"; return 0
  fi
  COMMIT_ERROR="$(tail -n 20 "$log")"; rm -f "$log"
  git reset -q
  set_feature_fields "$id" "$(jq -cn --arg s "$rollback_status" '{status: $s, passedAt: null}')"
  return 1
}

cmd_commit() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature commit ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_VERIFIED"
  local json_mode=0 risky
  has_flag --json "$@" && json_mode=1

  risky="$(risky_changed_files)"
  if [[ -n "$risky" ]]; then
    set_feature_fields "$id" "$(jq -cn --arg files "$risky" '{status: "awaiting-approval", riskyFiles: ($files | split("\n"))}')"
    park_feature "$id" "awaiting-approval"
    trace_add commit "$(jq -cn --arg id "$id" '{feature: $id, result: "awaiting-approval"}')"
    emit "$json_mode" "$(result_json "$id" awaiting-approval "위험 파일 변경 — 사람 승인 필요" "$risky")" \
      "🔐 commit $id: 위험 파일 변경 → 승인 대기 (harness feature approve $id)"$'\n'"$risky"
    return 0
  fi

  if ! commit_feature "$id" "" "$STATUS_BLOCKED"; then
    set_feature_fields "$id" "$(jq -cn --arg d "$COMMIT_ERROR" '{lastFailure: "git 커밋 실패 (훅 차단 등)", lastFailureDetail: $d}')"
    park_feature "$id" "commit-failed"
    trace_add commit "$(jq -cn --arg id "$id" '{feature: $id, result: "commit-failed"}')"
    emit "$json_mode" "$(result_json "$id" commit-failed "git 커밋 실패 (훅 차단 등)" "$COMMIT_ERROR")" \
      "⛔ commit $id: git 커밋 실패 → blocked (변경은 $(parked_branch "$id") 에 보관)"$'\n'"$COMMIT_ERROR"
    return "$EXIT_GATE_FAILED"
  fi
  trace_add commit "$(jq -cn --arg id "$id" --arg sha "$(git rev-parse --short HEAD)" '{feature: $id, result: "passing", commit: $sha}')"
  emit "$json_mode" "$(result_json "$id" passing "커밋됨 $(git rev-parse --short HEAD)")" "✅ commit $id → passing ($(git rev-parse --short HEAD))"
}

cmd_approve() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature approve ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_AWAITING"
  has_changes_outside_ledger && die "$EXIT_USAGE" "작업 트리가 깨끗하지 않다 — 승인 전에 커밋하거나 stash 한다"
  local branch
  branch="$(feature_field "$id" parkedBranch)"
  if [[ -n "$branch" ]] && ! unpark_changes "$branch"; then
    die "$EXIT_GATE_FAILED" "보관 브랜치 $branch 를 현재 HEAD 에 적용하다 충돌했다. 직접 병합하거나 reset 후 다시 구현한다."$'\n'"$UNPARK_ERROR"
  fi
  if ! commit_feature "$id" " (사람 승인)" "$STATUS_AWAITING"; then
    restore_clean_tree_keeping_ledger
    die "$EXIT_GATE_FAILED" "git 커밋 실패 — awaiting-approval 유지, 변경은 $branch 에 그대로 있다"$'\n'"$COMMIT_ERROR"
  fi
  [[ -n "$branch" ]] && git branch -D -q "$branch"
  trace_add approve "$(jq -cn --arg id "$id" --arg sha "$(git rev-parse --short HEAD)" '{feature: $id, result: "passing", commit: $sha}')"
  echo "✅ approve $id → passing ($(git rev-parse --short HEAD))"
}

cmd_reset() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature reset ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_BLOCKED" "$STATUS_AWAITING" "$STATUS_NEEDS_DECISION"
  local branch
  branch="$(feature_field "$id" parkedBranch)"
  set_feature_fields "$id" '{"status":"pending","attempts":0,"repeats":0,"lastFailure":"","lastFailureDetail":"","lastFailureFingerprint":"","parkedBranch":null}'
  trace_add reset "$(jq -cn --arg id "$id" '{feature: $id}')"
  echo "🔄 reset $id → pending (HEAD 에서 다시 구현한다)"
  [[ -n "$branch" ]] && echo "   이전 시도는 $branch 브랜치에 남아 있다. 필요 없으면: git branch -D $branch"
  return 0
}

# ── 판단 요청 (구현자 → 사람) ─────────────────────────────────────────
cmd_ask() {
  local id="${1:-}"; shift || true
  local question json_mode=0
  question="$(flag_value --question "$@")"
  [[ -n "$id" && -n "$question" ]] || die "$EXIT_USAGE" "사용: feature ask ID --question 질문"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING"
  has_flag --json "$@" && json_mode=1
  set_feature_fields "$id" "$(jq -cn --arg q "$question" '{status: "needs-decision", question: $q}')"
  park_feature "$id" "needs-decision"
  trace_add ask "$(jq -cn --arg id "$id" --arg q "$question" '{feature: $id, result: "needs-decision", question: $q}')"
  emit "$json_mode" "$(result_json "$id" needs-decision "$question")" "❓ ask $id → needs-decision: $question"
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

# ── 감사: passing 이 여전히 참인가 ────────────────────────────────────
cmd_audit() {
  require_features_file
  local id regressed=()
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    run_step "$(feature_field "$id" acceptance)" && continue
    set_feature_fields "$id" "$(jq -cn --arg d "$STEP_OUTPUT" '{status: "pending", lastFailure: "audit 회귀", lastFailureDetail: $d}')"
    trace_add audit "$(jq -cn --arg id "$id" '{feature: $id, result: "regressed"}')"
    regressed+=("$id")
  done < <(jq -r '.features[] | select(.status == "passing") | .id' "$(features_file)")

  local regressed_json='[]'
  [[ ${#regressed[@]} -gt 0 ]] && regressed_json="$(printf '%s\n' "${regressed[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  emit "$(has_flag --json "$@" && echo 1 || echo 0)" "$(jq -cn --argjson r "$regressed_json" '{regressed: $r}')" \
    "$([[ ${#regressed[@]} -eq 0 ]] && echo "✅ audit: 회귀 없음" || echo "⛔ audit: 회귀 → pending 으로 되돌림: ${regressed[*]}")"
  [[ ${#regressed[@]} -eq 0 ]]
}

# ── 진입 ────────────────────────────────────────────────────────────
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)      require_features_file; cmd_list "$@" ;;
    next)      require_features_file; cmd_next "$@" ;;
    status)    require_features_file; cmd_status "$@" ;;
    add)       cmd_add "$@" ;;
    preflight) cmd_preflight "$@" ;;
    verify)    cmd_verify "$@" ;;
    reject)    cmd_reject "$@" ;;
    commit)    cmd_commit "$@" ;;
    ask)       cmd_ask "$@" ;;
    decide)    cmd_decide "$@" ;;
    approve)   cmd_approve "$@" ;;
    reset)     cmd_reset "$@" ;;
    audit)     cmd_audit "$@" ;;
    *)         die "$EXIT_USAGE" "사용: harness feature <list|next|add|preflight|verify|reject|commit|ask|decide|approve|reset|status|audit>" ;;
  esac
}

main "$@"
