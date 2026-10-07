#!/usr/bin/env bash
#
# cli.sh — 명령들이 같이 쓰는 인자·출력·실행 헬퍼. source 전용.
#

# has_flag <flag> <args...>
has_flag() {
  local flag="$1" arg; shift
  for arg in "$@"; do [[ "$arg" == "$flag" ]] && return 0; done
  return 1
}

# flag_value <flag> <args...> → 플래그 다음 인자 (없으면 빈 문자열)
flag_value() {
  local flag="$1"; shift
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "$flag" ]] && { printf '%s' "${2:-}"; return 0; }
    shift
  done
  return 0
}

# json_mode_of <args...> → --json 이 있으면 1
json_mode_of() { has_flag --json "$@" && echo 1 || echo 0; }

# emit <json-mode> <json-object> <human-text>
emit() {
  if [[ "$1" -eq 1 ]]; then printf '%s\n' "$2"; else printf '%s\n' "$3"; fi
}

# 한 줄에 하나씩 → JSON 문자열 배열 (빈 줄 제외)
lines_to_json() { jq -Rsc 'split("\n") | map(select(length > 0))'; }

# 쉼표로 나눈 목록 → 한 줄에 하나씩
split_commas() { tr ',' '\n' <<<"$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF'; }

# run_step <command> → 출력 끝부분을 STEP_OUTPUT 에 담고 명령의 종료 코드를 돌려준다
STEP_OUTPUT=""
run_step() {
  local command="$1" log code=0
  log="$(mktemp)"
  bash -c "$command" > "$log" 2>&1 || code=$?
  STEP_OUTPUT="$(tail -n "$(cfg '.loop.failureTailLines')" "$log")"
  rm -f "$log"
  return "$code"
}
