#!/usr/bin/env bash
#
# harness loop — 사람 없이 루프를 돌리는 트리거.
#
#   run [--max N] [--parallel N] [--plugin-dir 경로] [--dry-run]
#       headless Claude 로 feature-loop 를 실행한다.
#       모델을 부르기 전에 사전 점검과 할 일을 먼저 본다. 실패하거나 할 일이 없으면 토큰을 쓰지 않고 끝난다.
#       이미 실행 중이면(잠금) 두 번째는 시작하지 않는다. 출력은 .harness/runs/ 에 남는다.
#   schedule [cron식]
#       로컬 cron 에 넣을 줄을 출력한다. 시스템 cron 은 건드리지 않는다.
#
#   종료 코드: 0 실행 또는 할 일 없음 · 1 루프 실패 · 2 사용법 · 3 설정 · 4 이미 실행 중
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/shim.sh"
source "$HARNESS_HOME/lib/agents.sh"
require_commands git jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

readonly EXIT_ALREADY_RUNNING=4
readonly LOCK_FILE="$PROJECT_HARNESS_DIR/loop.lock"
readonly RUNS_DIR="$PROJECT_HARNESS_DIR/runs"

# ── 잠금 ────────────────────────────────────────────────────────────
lock_holder_alive() {
  [[ -f "$LOCK_FILE" ]] || return 1
  local pid
  pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

acquire_lock() {
  if lock_holder_alive; then
    info "⏳ loop: 이미 실행 중이다 (pid $(cat "$LOCK_FILE")) — 이번 트리거는 건너뛴다"
    exit "$EXIT_ALREADY_RUNNING"
  fi
  echo "$$" > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# ── 모델을 부르기 전 점검 (토큰 0) ──────────────────────────────────
pending_count() { jq '[.features[] | select(.status == "pending")] | length' "$(features_file)"; }

ready_or_exit() {
  local preflight
  if ! preflight="$(bash "$HARNESS_HOME/commands/feature.sh" preflight 2>&1)"; then
    info "$preflight"
    die "$EXIT_GATE_FAILED" "사전 점검 실패 — 모델을 부르지 않았다"
  fi
  if [[ "$(pending_count)" -eq 0 ]]; then
    info "✅ loop: 할 일이 없다 (pending 0) — 모델을 부르지 않았다"
    exit 0
  fi
}

# ── 실행 ────────────────────────────────────────────────────────────
loop_prompt() {  # loop_prompt <max> <parallel>
  local args
  args="$(jq -cn --argjson m "$1" --argjson p "$2" --argjson a "$(plugin_agents_json)" '{maxIterations: $m, parallel: $p, agents: $a}')"
  cat <<EOF
하네스 루프를 실행한다. 다른 일은 하지 않는다.
Workflow 도구를 다음 인자로 한 번 호출한다: { "scriptPath": "$(workflow_copy_path)", "args": $args }
끝나면 워크플로우가 돌려준 결과 JSON 을 그대로 출력한다. 요약하거나 고치지 않는다.
EOF
}

claude_command() {  # claude_command <plugin-dir> → 배열을 CLAUDE_ARGS 에
  CLAUDE_ARGS=(-p --output-format text)
  local extra
  while IFS= read -r extra; do [[ -n "$extra" ]] && CLAUDE_ARGS+=("$extra"); done < <(cfg_lines '.loop.headless.claudeArgs')
  [[ -n "$1" ]] && CLAUDE_ARGS+=(--plugin-dir "$1")
  return 0
}

cmd_run() {
  local max parallel plugin_dir="" dry_run=0
  max="$(cfg '.loop.maxIterations')"
  parallel="$(cfg '.loop.parallel')"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max)        max="${2:-}"; shift ;;
      --parallel)   parallel="${2:-}"; shift ;;
      --plugin-dir) plugin_dir="${2:-}"; shift ;;
      --dry-run)    dry_run=1 ;;
      *)            die "$EXIT_USAGE" "알 수 없는 옵션: $1" ;;
    esac
    shift
  done
  [[ "$max" =~ ^[1-9][0-9]*$ && "$parallel" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" "--max 와 --parallel 은 1 이상의 정수"

  require_features_file
  ready_or_exit
  ensure_workflow_copy
  claude_command "$plugin_dir"
  if [[ "$dry_run" -eq 1 ]]; then
    printf 'claude'; printf ' %q' "${CLAUDE_ARGS[@]}"; printf ' <프롬프트>\n\n'
    loop_prompt "$max" "$parallel"
    return 0
  fi
  command -v claude >/dev/null 2>&1 || die "$EXIT_CONFIG" "claude CLI 가 없다"

  acquire_lock
  mkdir -p "$RUNS_DIR"
  local log code=0
  log="$RUNS_DIR/$(date -u +%Y%m%dT%H%M%SZ).log"
  info "▶ loop: pending $(pending_count)개, 최대 ${max}바퀴, 병렬 ${parallel} — 기록 ${log#"$PROJECT_ROOT"/}"
  loop_prompt "$max" "$parallel" | claude "${CLAUDE_ARGS[@]}" > "$log" 2>&1 || code=$?
  trace_add loop-run "$(jq -cn --arg log "${log#"$PROJECT_ROOT"/}" --argjson code "$code" '{log: $log, exitCode: $code}')"
  tail -n 40 "$log"
  [[ "$code" -eq 0 ]] || die "$EXIT_GATE_FAILED" "loop: claude 가 $code 로 끝났다 — $log"
}

cmd_schedule() {
  local cron="${1:-0 3 * * *}"
  cat <<EOF
# crontab -e 에 아래 한 줄을 넣는다 (하네스는 시스템 cron 을 바꾸지 않는다)
$cron cd $(printf '%q' "$PROJECT_ROOT") && $(printf '%q' "$PROJECT_HARNESS_DIR/bin/harness") loop run >> $(printf '%q' "$RUNS_DIR/cron.log") 2>&1
EOF
}

source "$HARNESS_HOME/lib/trace.sh"
case "${1:-}" in
  run)      shift; cmd_run "$@" ;;
  schedule) shift; cmd_schedule "$@" ;;
  *)        die "$EXIT_USAGE" "사용: harness loop <run|schedule>" ;;
esac
