#!/usr/bin/env bash
#
# harness config [-r] [jq-경로] — defaults → preset → project.json 을 병합한 최종 설정.
#   예: harness config .build      harness config -r .build.compileCommand
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"

JQ_FLAGS=()
[[ "${1:-}" == "-r" ]] && { JQ_FLAGS+=(-r); shift; }
load_config
jq ${JQ_FLAGS[@]+"${JQ_FLAGS[@]}"} "${1:-.}" <<<"$RESOLVED_CONFIG"
