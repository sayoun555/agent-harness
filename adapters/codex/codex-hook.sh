#!/usr/bin/env bash
#
# codex-hook.sh — Codex CLI 훅 어댑터.
#   Codex 의 apply_patch 는 파일 경로를 주지 않으므로 git 기준으로 바뀐 파일을 검사한다.
#   post: 바뀐 파일에 결정론 게이트.  stop: 전체 게이트 + 의미 적대자(보고만).
#
set -euo pipefail
[[ "${HARNESS_REVIEWING:-0}" == "1" ]] && { echo '{"continue":true}'; exit 0; }   # 재귀 가드

HARNESS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/changes.sh"
cat >/dev/null 2>&1 || true
project_is_plugged_in || { echo '{"continue":true}'; exit 0; }
cd "$PROJECT_ROOT"

emit_block() { jq -nc --arg c "$1" '{decision:"block", reason:"하네스 게이트 실패 — 수정 필요", hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}'; }
emit_note()  { jq -nc --arg c "$1" '{continue:true, hookSpecificOutput:{additionalContext:$c}}'; }

on_post() {
  local files=() output
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(changed_files)
  [[ ${#files[@]} -eq 0 ]] && { echo '{"continue":true}'; return; }
  output="$(bash "$HARNESS_HOME/commands/check.sh" "${files[@]}" 2>&1)" && { echo '{"continue":true}'; return; }
  emit_block "$output"
}

on_stop() {
  local check_output review_output="" files=()
  if ! check_output="$(bash "$HARNESS_HOME/commands/check.sh" --all 2>&1)"; then
    emit_block "$check_output"; return
  fi
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(changed_files)
  [[ ${#files[@]} -gt 0 ]] && review_output="$(bash "$HARNESS_HOME/commands/review.sh" "${files[@]}" 2>&1 || true)"
  if grep -qiE '^\[(high|med)\]' <<<"$review_output"; then emit_note "의미 적대자 보고:
$review_output"; return; fi
  echo '{"continue":true}'
}

case "${1:-post}" in
  post) on_post ;;
  stop) on_stop ;;
  *)    echo '{"continue":true}' ;;
esac
