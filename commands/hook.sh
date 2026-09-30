#!/usr/bin/env bash
#
# harness hook — 에디터 훅 어댑터 (Claude Code 플러그인 훅, Codex 어댑터가 부른다).
#   stdin 으로 훅 JSON 을 받고, stdout 으로 훅 응답 JSON 을 낸다.
#   하네스가 끼워지지 않은 프로젝트에서는 아무것도 하지 않는다.
#   어떤 경우에도 턴을 멈추게 하지 않는다. 막는 것은 원장 직접 편집 하나뿐이다.
#
#   harness hook session     SessionStart — 진행 상태 + 기능 원장 요약 주입
#   harness hook pre-edit    PreToolUse(Edit|Write) — 기능 원장 직접 편집 거부
#   harness hook post-edit   PostToolUse(Edit|Write) — 방금 바뀐 파일에 check
#   harness hook stop        Stop — 전체 check, 문제가 있으면 경고만
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/shim.sh"

EVENT="${1:-}"
HOOK_INPUT="$(cat 2>/dev/null || true)"

pass_silently() { exit 0; }
project_is_plugged_in || pass_silently
command -v jq >/dev/null 2>&1 || pass_silently

edited_file() { jq -r '.tool_input.file_path // empty' <<<"$HOOK_INPUT" 2>/dev/null || true; }

relative_to_project() {
  local path root
  path="$(canonical_path "$1")"
  root="$(canonical_path "$PROJECT_ROOT/.")"; root="${root%/.}"
  [[ "$path" == "$root"/* ]] && path="${path#"$root"/}"
  printf '%s\n' "$path"
}

# ── SessionStart ────────────────────────────────────────────────────
progress_block() {
  local file
  file="$(project_path "$(cfg '.state.progressFile')")"
  [[ -s "$file" ]] || return 0
  printf '진행 상태 (%s, 이전 세션 핸드오프):\n' "$(cfg '.state.progressFile')"
  head -n 40 "$file" | sed 's/^/  /'
}

on_session() {
  local context
  ensure_shim || true   # 새로 clone 한 저장소에도 스킬이 쓸 shim 을 둔다 (토큰 0, 셸에서 처리)
  context="$(printf '🧭 하네스\n%s\n%s\n' "$(features_summary)" "$(progress_block)")"
  context="$context
기능 원장은 직접 편집하지 않는다. 추가는 .harness/bin/harness feature add, 통과 판정은 harness 가 한다."
  jq -cn --arg ctx "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

# ── PreToolUse ──────────────────────────────────────────────────────
on_pre_edit() {
  local target ledger
  target="$(edited_file)"
  [[ -z "$target" ]] && pass_silently
  ledger="$(canonical_path "$(features_file)")"
  [[ "$(canonical_path "$target")" == "$ledger" ]] || pass_silently
  jq -cn --arg reason "기능 원장($(cfg '.state.featuresFile'))은 직접 편집할 수 없다. 기능 추가는 '.harness/bin/harness feature add --id ID --desc 설명 --acceptance 명령', 통과 판정은 'harness feature verify ID' 가 한다." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# ── PostToolUse ─────────────────────────────────────────────────────
on_post_edit() {
  local target output
  target="$(edited_file)"
  [[ -z "$target" || ! -f "$target" ]] && pass_silently
  if output="$(cd "$PROJECT_ROOT" && bash "$HARNESS_HOME/commands/check.sh" "$(relative_to_project "$target")" 2>&1)"; then
    grep -q '⚠️' <<<"$output" || pass_silently
    jq -cn --arg ctx "$output" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
    return
  fi
  jq -cn --arg reason "하네스 결정론 게이트 실패 — 지금 고친다:
$output" '{decision: "block", reason: $reason}'
}

# ── Stop ────────────────────────────────────────────────────────────
on_stop() {
  local output
  output="$(cd "$PROJECT_ROOT" && bash "$HARNESS_HOME/commands/check.sh" --all 2>&1)" && pass_silently
  jq -cn --arg msg "⚠️ 하네스 check 경고 (커밋 전에 고칠 것):
$output" '{systemMessage: $msg}'
}

case "$EVENT" in
  session)   on_session ;;
  pre-edit)  on_pre_edit ;;
  post-edit) on_post_edit ;;
  stop)      on_stop ;;
  *)         die "$EXIT_USAGE" "사용: harness hook <session|pre-edit|post-edit|stop>" ;;
esac
