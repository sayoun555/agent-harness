#!/usr/bin/env bash
#
# harness criteria — 검증 기준(공통 · 스택 · 프로젝트).
#
#   list                      검증에 쓰는 기준 ID 와 제목, 어느 파일인지
#   show                      검증에 쓰는 기준 전체 (review --criteria 와 같다)
#   add --title 제목 --rule 규칙 [--why 이유] [--when 적용 조건] [--check 확인 방법] [--file 이름.md]
#                             프로젝트 기준(.harness/criteria/)에 새 항목을 P<번호> 로 붙인다.
#                             반려가 반복된 항목을 여기 쌓으면 다음 구현·검증에 자동으로 들어간다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/criteria.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

readonly PROJECT_CRITERION_PREFIX="P"
readonly DEFAULT_PROJECT_CRITERIA_FILE="project.md"

cmd_list() {
  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    printf '%s\n' "${file#"$HARNESS_HOME"/}" | sed "s#^$PROJECT_ROOT/##"
    criterion_index <<<"$file" | awk -F'\t' '{ printf "  %-5s %s\n", $1, $2 }'
  done < <(review_criteria_files)
}

next_project_criterion_id() {
  local last
  last="$(project_criteria_files | criterion_index | cut -f1 \
    | sed -n "s/^$PROJECT_CRITERION_PREFIX\([0-9][0-9]*\)$/\1/p" | sort -n | tail -1)"
  printf '%s%s\n' "$PROJECT_CRITERION_PREFIX" "$(( ${last:-0} + 1 ))"
}

ensure_project_criteria_file() {  # ensure_project_criteria_file <파일>
  [[ -f "$1" ]] && return 0
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'HEADER'
# 코드 기준 — 이 프로젝트

> 이 프로젝트에서 반려와 지적으로 쌓은 기준이다. 공통(Q)·스택 기준 다음에 읽는다.
> `harness criteria add` 로 붙인다. 검증 대조표에 자동으로 들어간다.
HEADER
}

cmd_add() {
  local title rule why when check name file id
  title="$(flag_value --title "$@")"
  rule="$(flag_value --rule "$@")"
  why="$(flag_value --why "$@")"
  when="$(flag_value --when "$@")"
  check="$(flag_value --check "$@")"
  name="$(flag_value --file "$@")"
  [[ -n "$title" && -n "$rule" ]] || die "$EXIT_USAGE" "사용: criteria add --title 제목 --rule 규칙 [--why 이유] [--when 적용 조건] [--check 확인 방법] [--file 이름.md]"
  [[ "${name:-$DEFAULT_PROJECT_CRITERIA_FILE}" =~ ^[a-z0-9-]+\.md$ ]] || die "$EXIT_USAGE" "--file 은 영문 소문자 kebab-case.md"
  file="$(project_criteria_dir)/${name:-$DEFAULT_PROJECT_CRITERIA_FILE}"
  ensure_project_criteria_file "$file"
  id="$(next_project_criterion_id)"
  cat >> "$file" <<ITEM

## $id. $title

- **규칙:** $rule
- **이유:** ${why:-이 프로젝트에서 반려가 반복됐다.}
- **적용 조건:** ${when:-이 규칙이 다루는 코드를 새로 쓰거나 바꿀 때.}
- **확인 방법:** ${check:-검증자가 바뀐 코드에서 위반을 찾으면 파일:줄과 함께 지적한다.}
ITEM
  echo "➕ 기준 추가: $id $title → ${file#"$PROJECT_ROOT"/}"
}

case "${1:-}" in
  list) cmd_list ;;
  show) print_review_criteria ;;
  add)  shift; cmd_add "$@" ;;
  *)    die "$EXIT_USAGE" "사용: harness criteria <list | show | add --title 제목 --rule 규칙 …>" ;;
esac
