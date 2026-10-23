#!/usr/bin/env bash
#
# harness permissions [--json] — 루프가 하네스 · 빌드 명령마다 묻고 멈추지 않도록 Claude Code 허용 규칙을 넣는다.
#   하네스 자신 · build.compileCommand · build.testCommand 만 .claude/settings.local.json 에 넣는다(커밋 안 함).
#   init 이 같은 일을 한다. 빌드 명령을 바꾼 뒤 사람이 실행한다 — 루프는 이 명령을 부르지 않는다(lib/permissions.sh).
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/permissions.sh"
require_commands git jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

RESULT="$(permissions_sync)"
emit "$(json_mode_of "$@")" "$RESULT" "$(jq -r '
  (if .result == "tracked" then "ℹ️ \(.file) 이 커밋돼 있어 건드리지 않는다 — 허용 규칙은 손으로 넣는다"
   elif (.added | length) == 0 then "✅ 허용 규칙이 이미 다 있다"
   else "✅ 허용 규칙 \(.added | length)개 추가 → \(.file)\n" + (.added | map("   + " + .) | join("\n")) end)
  + (if (.skipped | length) > 0 then "\nℹ️ 치환이 들어 있어 규칙으로 넣지 않은 명령:\n" + (.skipped | map("   - " + .) | join("\n")) else "" end)
  + "\nℹ️ 에이전트가 그때그때 치는 명령은 넣지 않는다 — 루프는 자동 모드(Shift+Tab)로 돌리면 덜 멈춘다"' <<<"$RESULT")"
