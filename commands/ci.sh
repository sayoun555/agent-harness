#!/usr/bin/env bash
#
# harness ci — CI 백스톱 한 번에: 전체 check → compile → test.
#   로컬 훅을 --no-verify 로 건너뛰어도 여기서 다시 잡힌다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
require_commands git jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

run_configured() {  # run_configured <label> <jq-path>
  local command
  command="$(cfg "$2")"
  [[ -z "$command" ]] && { echo "⏭️  $1: 설정 없음 ($2)"; return 0; }
  echo "▶ $1: $command"
  bash -c "$command"
}

bash "$HARNESS_HOME/commands/check.sh" --all
run_configured compile '.build.compileCommand'
run_configured test '.build.testCommand'
echo "✅ harness ci 통과"
