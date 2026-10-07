#!/usr/bin/env bash
#
# agents.sh — 플러그인이 주는 하네스 전용 서브에이전트 정의. source 전용.
#
# 플러그인의 agents/ 에 명령 실행·구현·검증용 정의가 있다. 도구를 필요한 것만 줘서
# 켜진 플러그인·MCP 의 스킬과 도구 목록이 실리지 않는다 (시작 컨텍스트가 기본 에이전트의 약 1/5).
# 정의는 플러그인이 켜져 있을 때만 있다. 이 프로젝트 설정에서 켜져 있으면 이름을 알려 주고,
# 아니면 빈 객체를 준다. 루프는 이름이 없으면 기본 에이전트를 쓴다.
#

readonly HARNESS_PLUGIN_ID="agent-harness@agent-harness"
readonly HARNESS_AGENT_NAMESPACE="${HARNESS_PLUGIN_ID%%@*}"

plugin_enabled_for_project() {
  local settings
  for settings in "$PROJECT_ROOT/.claude/settings.json" "$PROJECT_ROOT/.claude/settings.local.json"; do
    jq -e --arg p "$HARNESS_PLUGIN_ID" '.enabledPlugins[$p] == true' "$settings" >/dev/null 2>&1 && return 0
  done
  return 1
}

plugin_agents_json() {  # → {runner, implementer, reviewer} 또는 {}
  plugin_enabled_for_project || { echo '{}'; return 0; }
  jq -cn --arg ns "$HARNESS_AGENT_NAMESPACE" \
    '{runner: ($ns + ":harness-runner"), implementer: ($ns + ":harness-implementer"), reviewer: ($ns + ":harness-reviewer")}'
}
