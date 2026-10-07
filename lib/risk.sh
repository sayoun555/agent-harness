#!/usr/bin/env bash
#
# risk.sh — 사람 승인이 필요한 위험 파일 판정. source 전용.
#   approval.riskGlobs 에 걸리는 변경 파일을 한 줄에 하나씩 출력한다. lib/changes.sh 가 필요하다.
#

risky_changed_files() {  # risky_changed_files [paths...]
  local globs=() glob file
  while IFS= read -r glob; do [[ -n "$glob" ]] && globs+=("$glob"); done < <(cfg_lines '.approval.riskGlobs')
  [[ ${#globs[@]} -eq 0 ]] && return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] && path_matches_any "$file" "${globs[@]}" && printf '%s\n' "$file"
  done < <(changed_files "$@")
  return 0
}
