#!/usr/bin/env bash
#
# usage.sh — 요금제 사용량(Claude Code 의 /usage)을 읽는다. source 전용.
#
# `claude -p /usage` 는 모델을 부르지 않는다(토큰 0, 약 3초). 세션을 저장하지 않게 부른다.
# 구독이 아니거나(API 키) claude 가 없거나 응답 형식이 바뀌면 "unavailable" — 루프는 멈추지 않고 그대로 돈다.
#
# 응답 형식 (Claude Code 2.1.x, result 필드):
#   Current session: 11% used · resets Oct 21 at 7:20pm (Asia/Seoul)
#   Current week (all models): 15% used · resets Oct 27 at 9pm (Asia/Seoul)
#

readonly USAGE_TIMEOUT_SECONDS=30

# 응답이 없으면 기다리지 않는다. bash 3.2 에는 timeout 이 없어 perl 의 alarm 을 쓴다(없으면 그대로 실행).
with_timeout() {
  local seconds="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
  else
    "$@"
  fi
}

usage_stop_percent() { cfg '.loop.usageStopPercent'; }

# usage_from_text <stop-percent> < /usage 결과 글 → JSON
usage_from_text() {
  jq -Rsc --argjson stop "$1" '
    [ split("\n")[]
      | capture("^(?<name>Current [^:]+): (?<percent>[0-9]+)% used(?: · resets (?<resets>.*))?$")?
      | .percent |= tonumber ] as $limits
    | if ($limits | length) == 0 then {result: "unavailable", reason: "사용량 줄이 없다(구독이 아니거나 형식이 바뀜)"}
      else ($limits | map(.percent) | max) as $highest
        | {result: "ok", limits: $limits, highest: $highest, stopPercent: $stop,
           stop: ($stop > 0 and $highest >= $stop),
           summary: ($limits | map((.name | sub("^Current session$"; "세션") | sub("^Current week \\((?<m>.*)\\)$"; "주간(\(.m | sub("^all models$"; "전체")))")) + " \(.percent)%") | join(" · "))}
      end'
}

usage_json() {
  local stop raw
  stop="$(usage_stop_percent)"
  [[ "$stop" =~ ^[0-9]+$ ]] || stop=0
  if ! command -v claude >/dev/null 2>&1; then
    jq -cn '{result: "unavailable", reason: "claude CLI 가 없다"}'
    return 0
  fi
  if ! raw="$(with_timeout "$USAGE_TIMEOUT_SECONDS" claude -p /usage --output-format json --no-session-persistence 2>/dev/null)" \
     || ! raw="$(jq -r '.result // empty' <<<"$raw" 2>/dev/null)"; then
    jq -cn '{result: "unavailable", reason: "claude /usage 가 응답하지 않았다"}'
    return 0
  fi
  usage_from_text "$stop" <<<"$raw"
}
