#!/usr/bin/env bash
#
# mcp.sh — 프리셋이 권하는 MCP 가 연결돼 있는지 확인한다. source 전용.
#
# 확인만 하고 설치하지 않는다. MCP 는 외부 코드를 실행하고 자격 증명이 필요할 때가 많아서,
# 설치는 사람이 결정한다. 연결돼 있으면 루프의 검증자에게 그 MCP 로 확인하라는 지시가 붙는다.
#
# `claude mcp list` 는 서버마다 상태를 점검해서 수 초 걸린다. 그래서 훅이 아니라
# init 과 루프 사전 점검에서만 부른다. 권하는 MCP 가 없으면 부르지 않는다.
#
# 출력 형식 (Claude Code 2.1.x):
#   playwright: npx -y @playwright/mcp@latest - ✔ Connected
#   plugin:vercel:vercel: https://mcp.vercel.com (HTTP) - ! Needs authentication
#

readonly MCP_CONNECTED="connected"
readonly MCP_NEEDS_AUTH="needs-auth"
readonly MCP_FAILED="failed"
readonly MCP_ABSENT="absent"
readonly MCP_UNKNOWN="unknown"   # claude CLI 가 없어 확인할 수 없음

has_mcp_recommendations() {
  load_config
  [[ "$(jq '(.mcp.recommended // []) | length' <<<"$RESOLVED_CONFIG")" -gt 0 ]]
}

# "이름<TAB>상태" 한 줄씩. claude CLI 가 없으면 아무것도 출력하지 않는다.
mcp_server_states() {
  command -v claude >/dev/null 2>&1 || return 0
  claude mcp list 2>/dev/null | awk '
    / - / && /: / {
      name = substr($0, 1, index($0, ": ") - 1)
      state = "failed"
      if ($0 ~ /Connected/) state = "connected"
      else if ($0 ~ /Needs authentication/) state = "needs-auth"
      printf "%s\t%s\n", name, state
    }'
}

# state_for <detect-regex> <states> → 가장 좋은 상태 하나
state_for() {
  local detect="$1" states="$2" best="$MCP_ABSENT" name state
  while IFS=$'\t' read -r name state; do
    [[ -z "$name" ]] && continue
    [[ "$name" =~ $detect ]] || continue
    case "$state" in
      "$MCP_CONNECTED") printf '%s\n' "$MCP_CONNECTED"; return ;;
      "$MCP_NEEDS_AUTH") best="$MCP_NEEDS_AUTH" ;;
      *) [[ "$best" == "$MCP_ABSENT" ]] && best="$MCP_FAILED" ;;
    esac
  done <<<"$states"
  printf '%s\n' "$best"
}

# 권하는 MCP 마다 상태를 붙인 JSON 배열. reviewHint 의 {startCommand} 를 채운다.
mcp_status_json() {
  has_mcp_recommendations || { echo '[]'; return; }
  local states cli_available=1 start_command
  command -v claude >/dev/null 2>&1 || cli_available=0
  states="$(mcp_server_states)"
  start_command="$(cfg '.app.startCommand')"

  local result='[]' item detect state
  while IFS= read -r item; do
    detect="$(jq -r '.detect' <<<"$item")"
    if [[ "$cli_available" -eq 1 ]]; then state="$(state_for "$detect" "$states")"; else state="$MCP_UNKNOWN"; fi
    result="$(jq -c --argjson item "$item" --arg state "$state" --arg start "${start_command:-앱 실행 명령}" \
      '. + [($item | del(.detect) | .state = $state
             | .reviewHint = ((.reviewHint // "") | gsub("\\{startCommand\\}"; $start)))]' <<<"$result")"
  done < <(load_config; jq -c '(.mcp.recommended // [])[]' <<<"$RESOLVED_CONFIG")
  printf '%s\n' "$result"
}

# 사람이 읽는 한 단락 (권하는 MCP 가 없으면 빈 출력)
mcp_status_text() {
  local status_json="$1"
  jq -r '
    def icon: if . == "connected" then "✅" elif . == "needs-auth" then "🔑" elif . == "unknown" then "❔" else "➕" end;
    .[] |
    if .state == "connected" then "\(.state | icon) MCP \(.name): 연결됨 — 루프 검증자가 \(.purpose)"
    elif .state == "needs-auth" then "\(.state | icon) MCP \(.name): 인증 필요 — Claude Code 에서 /mcp 로 인증하면 \(.purpose)"
    elif .state == "unknown" then "\(.state | icon) MCP \(.name): claude CLI 가 없어 확인 못 함"
    else "\(.state | icon) MCP \(.name): 없음 — 있으면 \(.purpose)\n     설치(선택): \(.install)"
    end' <<<"$status_json"
}
