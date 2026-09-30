#!/usr/bin/env bash
#
# harness mcp [--json] — 프리셋이 권하는 MCP 의 연결 상태. 확인만 하고 설치하지 않는다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/mcp.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

STATUS="$(mcp_status_json)"
if [[ "${1:-}" == "--json" ]]; then
  printf '%s\n' "$STATUS"
elif [[ "$STATUS" == "[]" ]]; then
  echo "ℹ️ 이 프리셋이 권하는 MCP 는 없다"
else
  mcp_status_text "$STATUS"
fi
