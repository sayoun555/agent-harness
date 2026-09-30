#!/usr/bin/env bash
#
# trace.sh — 루프 실행 기록(JSONL). 노드마다 한 줄.
#   반복 감지·비용 추적·부품 빼 보기 실험의 원천 데이터다. source 전용.
#

trace_file() { project_path "$(cfg '.state.traceFile')"; }

# trace_add <event> <json-object> — ts·event 를 붙여 한 줄 추가한다.
trace_add() {
  local event="$1" payload="${2:-}" file
  [[ -z "$payload" ]] && payload='{}'
  file="$(trace_file)"
  mkdir -p "$(dirname "$file")"
  jq -cn --arg ts "$(utc_now)" --arg event "$event" --argjson payload "$payload" \
    '{ts: $ts, event: $event} + $payload' >> "$file"
}
