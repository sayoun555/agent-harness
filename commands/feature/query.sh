#!/usr/bin/env bash
#
# feature 조회 — list · next · status · brief. commands/feature.sh 가 source 한다.
#

cmd_list() {
  if has_flag --json "$@"; then jq -c '.features' "$(features_file)"; return; fi
  jq -r '.features[] | "\(.status)\t\(.id)\t\(.description)"' "$(features_file)" | column -t -s $'\t'
}

cmd_next() {
  local id limit
  limit="$(flag_value --limit "$@")"
  if [[ -n "$limit" ]]; then
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" "--limit 은 1 이상의 정수"
    jq -c --argjson n "$limit" --arg s "$STATUS_PENDING" '[.features[] | select(.status == $s)][:$n]' "$(features_file)"
    return
  fi
  id="$(next_pending_id)"
  if has_flag --json "$@"; then
    [[ -n "$id" ]] && feature_json "$id" || echo '{}'
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
