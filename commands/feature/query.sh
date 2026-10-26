#!/usr/bin/env bash
#
# feature 조회 — list · next · status · brief. commands/feature.sh 가 source 한다.
#

# --fields a,b → 기능마다 그 필드만 남기는 jq 필터 (없으면 전체).
#   원장 전체에는 실패 출력 · 대조표 · 결정이 실려 커진다. 루프처럼 몇 필드만 필요한 쪽은 그것만 읽는다
#   — 출력이 크면 에이전트가 옮기는 동안 오래 걸리고, 잘리거나 걸러진다(현장 보고 E9).
fields_filter() {  # fields_filter <args...>
  local fields name
  fields="$(flag_value --fields "$@")"
  [[ -z "$fields" ]] && { echo '.'; return; }
  while IFS= read -r name; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$EXIT_USAGE" "--fields 의 이름이 틀렸다: $name"
  done < <(split_commas "$fields")
  printf '{%s}\n' "$(split_commas "$fields" | paste -sd, -)"
}

cmd_list() {
  local filter
  filter="$(fields_filter "$@")"   # 따로 대입해야 이름이 틀렸을 때 여기서 멈춘다
  if has_flag --json "$@"; then jq -c "[.features[] | $filter]" "$(features_file)"; return; fi
  jq -r '.features[] | "\(.status)\t\(.id)\t\(.description)\(if (.figma // "") != "" then "  [Figma]" else "" end)"' "$(features_file)" | column -t -s $'\t'
}

# 기능 하나만. 상태 하나를 확인하려고 모든 기능을 읽지 않는다.
cmd_show() {
  local id="${1:-}" filter; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature show ID [--fields a,b]"
  require_feature "$id"
  filter="$(fields_filter "$@")"
  feature_json "$id" | jq -c "$filter"
}

cmd_next() {
  local id limit filter
  limit="$(flag_value --limit "$@")"
  filter="$(fields_filter "$@")"
  if [[ -n "$limit" ]]; then
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" "--limit 은 1 이상의 정수"
    jq -c --argjson n "$limit" "$JQ_READY .features as \$all | [.features[] | select(ready(\$all))][:\$n] | map($filter)" "$(features_file)"
    return
  fi
  id="$(next_pending_id)"
  if has_flag --json "$@"; then
    [[ -n "$id" ]] && feature_json "$id" | jq -c "$filter" || echo '{}'
    return
  fi
  [[ -n "$id" ]] && echo "$id" || true
}

cmd_status() {
  local counts
  counts="$(jq -c '.features | group_by(.status) | map({(.[0].status): length}) | add // {}' "$(features_file)")"
  if has_flag --json "$@"; then echo "$counts"; else jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$counts"; fi
}

# brief 는 harness prompt implement 와 같다 (예전 이름). 지시문은 lib/prompts.sh 한 곳에 있다.
cmd_brief() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature brief ID [--mode sequential|isolated|shared] [--json]"
  require_features_file; require_feature "$id"
  emit_implement_prompt "$id" "$@"
}
