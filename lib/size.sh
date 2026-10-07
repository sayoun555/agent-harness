#!/usr/bin/env bash
#
# size.sh — 이번 변경으로 한도를 넘은 파일. source 전용. lib/changes.sh · lib/source.sh 가 필요하다.
#   새로 만들었거나 이번에 줄 수가 늘어서 rules.maxFileLines 를 넘은 소스만 고른다.
#   손대지 않은 기존 큰 파일은 고르지 않는다 (이번 기능에서 쪼개라고 하지 않기 위해).
#

# grown_oversized_files [paths...] → "경로<TAB>기준 줄 수<TAB>지금 줄 수" 한 줄씩
grown_oversized_files() {
  local max file before now
  max="$(cfg '.rules.maxFileLines')"
  [[ -z "$max" ]] && return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] && is_checked_source "$file" || continue
    now="$(wc -l < "$file" | tr -d ' ')"
    (( now > max )) || continue
    before="$(base_content "$file" | wc -l | tr -d ' ')"
    (( before == 0 || now > before )) && printf '%s\t%s\t%s\n' "$file" "$before" "$now"
  done < <(changed_files "$@")
  return 0
}

describe_grown_oversized() {  # describe_grown_oversized < grown_oversized_files 출력
  awk -F'\t' -v max="$(cfg '.rules.maxFileLines')" \
    '{ printf "%s: %s줄 > %s (%s)\n", $1, $3, max, ($2 == 0 ? "새 파일" : "이번에 " $2 "줄에서 늘어남") }'
}
