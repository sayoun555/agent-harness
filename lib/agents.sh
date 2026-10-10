#!/usr/bin/env bash
#
# agents.sh — 플러그인이 주는 하네스 전용 서브에이전트 정의. source 전용. lib/mcp.sh · lib/features.sh 가 필요하다.
#
# 플러그인의 agents/ 에 명령 실행·구현·검증용 정의가 있다. 도구를 필요한 것만 줘서
# 켜진 플러그인·MCP 의 스킬과 도구 목록이 실리지 않는다 (시작 컨텍스트가 기본 에이전트의 약 1/5).
# 정의는 플러그인이 켜져 있을 때만 있다. 이 프로젝트 설정에서 켜져 있으면 이름을 알려 주고,
# 아니면 빈 객체를 준다. 루프는 이름이 없으면 기본 에이전트를 쓴다.
#

readonly HARNESS_PLUGIN_ID="agent-harness@agent-harness"
readonly HARNESS_AGENT_NAMESPACE="${HARNESS_PLUGIN_ID%%@*}"

# Figma 전용 정의(agents/harness-figma-*.md)가 도구로 가진 Figma MCP 서버 이름.
# 정의의 tools 에 적힌 mcp__figma · mcp__plugin_figma_figma 와 짝이다. 한쪽을 바꾸면 다른 쪽도 바꾼다.
readonly FIGMA_MCP_SERVERS="figma|plugin:figma:figma"

plugin_enabled_for_project() {
  local settings
  for settings in "$PROJECT_ROOT/.claude/settings.json" "$PROJECT_ROOT/.claude/settings.local.json"; do
    jq -e --arg p "$HARNESS_PLUGIN_ID" '.enabledPlugins[$p] == true' "$settings" >/dev/null 2>&1 && return 0
  done
  return 1
}

# ── Figma 화면이 붙은 기능 ───────────────────────────────────────────
pending_figma_features() {  # → Figma 링크가 있는 pending 기능 (쉼표로)
  [[ -f "$(features_file)" ]] || return 0
  jq -r '[.features[] | select(.status == "pending" and ((.figma // "") != "")) | .id] | join(", ")' "$(features_file)"
}

# 정의가 아는 이름의 Figma MCP 가 연결돼 있는가. claude mcp list 는 느려서 Figma 기능이 있을 때만 부른다.
figma_mcp_connected() {
  [[ "$(state_for "^($FIGMA_MCP_SERVERS)\$" "$(mcp_server_states)")" == "$MCP_CONNECTED" ]]
}

# Figma 전용 정의를 쓸 조건: 플러그인이 켜져 있고, Figma 링크가 있는 pending 기능이 있고, 아는 이름의 Figma MCP 가 연결됨.
# 하나라도 빠지면 이름을 주지 않는다. 루프는 Figma 기능을 기본 에이전트로 띄운다(다른 이름으로 연결된 MCP 도 쓸 수 있게).
plugin_agents_json() {  # → {runner, implementer, reviewer[, figmaImplementer, figmaReviewer]} 또는 {}
  plugin_enabled_for_project || { echo '{}'; return 0; }
  local figma=false
  [[ -n "$(pending_figma_features)" ]] && figma_mcp_connected && figma=true
  jq -cn --arg ns "$HARNESS_AGENT_NAMESPACE" --argjson figma "$figma" \
    '{runner: ($ns + ":harness-runner"), implementer: ($ns + ":harness-implementer"), reviewer: ($ns + ":harness-reviewer")}
     + (if $figma then {figmaImplementer: ($ns + ":harness-figma-implementer"), figmaReviewer: ($ns + ":harness-figma-reviewer")} else {} end)'
}

# Figma 기능이 있는데 아는 이름의 Figma MCP 가 연결돼 있지 않으면 한 줄 (아니면 빈 출력)
figma_mcp_notice() {
  local features
  features="$(pending_figma_features)"
  [[ -z "$features" ]] && return 0
  figma_mcp_connected && return 0
  echo "Figma 링크가 있는 기능($features): Figma MCP(${FIGMA_MCP_SERVERS//|/ · })가 연결돼 있지 않다 — 기본 에이전트로 띄운다. 그 에이전트도 Figma 를 열 수 없으면 구현자는 추측하지 않고 판단을 요청한다"
}
