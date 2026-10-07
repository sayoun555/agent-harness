#!/usr/bin/env bash
#
# source.sh — 어떤 파일이 검사 대상 소스인가. source 전용.
#   설정 source.extensions · source.testPathPattern · source.root · source.mainGlobs 로 판단한다.
#   check 게이트와 크기 증가 게이트가 같은 판단을 쓴다.
#

has_checked_extension() {
  local extensions
  extensions="$(cfg_lines '.source.extensions' | paste -sd '|' -)"
  [[ "${1##*.}" =~ ^($extensions)$ ]]
}

is_test_path() {
  local pattern
  pattern="$(cfg '.source.testPathPattern')"
  [[ -n "$pattern" && "$1" =~ $pattern ]]
}

is_under_source_root() {
  local root
  root="$(cfg '.source.root')"
  [[ -z "$root" || "$1" == "$root"/* ]]
}

matches_main_globs() {
  local globs=() glob
  while IFS= read -r glob; do [[ -n "$glob" ]] && globs+=("$glob"); done < <(cfg_lines '.source.mainGlobs')
  [[ ${#globs[@]} -eq 0 ]] && return 0
  path_matches_any "$1" "${globs[@]}"
}

# is_checked_source <상대 경로> — 존재하는 main 소스 파일이면 0
is_checked_source() {
  [[ -f "$1" ]] && has_checked_extension "$1" && ! is_test_path "$1" \
    && is_under_source_root "$1" && matches_main_globs "$1"
}
