#!/usr/bin/env bash
#
# harness criteria — 검증 기준(공통 · 스택 · 프로젝트).
#
#   list                      검증에 쓰는 기준 ID 와 제목, 어느 파일인지
#   show [ID...]              검증에 쓰는 기준 전체 (review --criteria 와 같다). ID 를 주면 그 항목만
#   add --title 제목 --rule 규칙 [--why 이유] [--when 적용 조건] [--check 확인 방법] [--file 이름.md] [--from 기준ID]
#                             프로젝트 기준(.harness/criteria/)에 새 항목을 P<번호> 로 붙인다.
#                             반려가 반복된 항목을 여기 쌓으면 다음 구현·검증에 자동으로 들어간다.
#                             --from 은 반복된 반려 기준(trace report 의 제안)에서 왔다는 표시다. 보고서는 그 뒤에
#                             같은 기준 반려가 다시 반복될 때만 다시 제안한다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/criteria.sh"
source "$HARNESS_HOME/lib/trace.sh"
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
  local title rule why when check name from file id
  title="$(flag_value --title "$@")"
  rule="$(flag_value --rule "$@")"
  why="$(flag_value --why "$@")"
  when="$(flag_value --when "$@")"
  check="$(flag_value --check "$@")"
  name="$(flag_value --file "$@")"
  from="$(flag_value --from "$@")"
  [[ -n "$title" && -n "$rule" ]] || die "$EXIT_USAGE" "사용: criteria add --title 제목 --rule 규칙 [--why 이유] [--when 적용 조건] [--check 확인 방법] [--file 이름.md] [--from 기준ID]"
  [[ -z "$from" ]] || review_criterion_index | cut -f1 | grep -qxF "$from" \
    || die "$EXIT_USAGE" "--from 은 이 프로젝트의 검증 기준 ID 여야 한다: $from (harness criteria list)"
  [[ "${name:-$DEFAULT_PROJECT_CRITERIA_FILE}" =~ ^[a-z0-9-]+\.md$ ]] || die "$EXIT_USAGE" "--file 은 영문 소문자 kebab-case.md"
  file="$(project_criteria_dir)/${name:-$DEFAULT_PROJECT_CRITERIA_FILE}"
  ensure_project_criteria_file "$file"
  id="$(next_project_criterion_id)"
  cat >> "$file" <<ITEM

## $id. $title

- **규칙:** $rule
- **이유:** ${why:-이 프로젝트에서 ${from:+$from }반려가 반복됐다.}
- **적용 조건:** ${when:-이 규칙이 다루는 코드를 새로 쓰거나 바꿀 때.}
- **확인 방법:** ${check:-검증자가 바뀐 코드에서 위반을 찾으면 파일:줄과 함께 지적한다.}
ITEM
  [[ -z "$from" ]] || trace_add criteria-add "$(jq -cn --arg id "$id" --arg from "$from" '{id: $id, from: $from}')"
  echo "➕ 기준 추가: $id $title → ${file#"$PROJECT_ROOT"/}"
}

# 기준 항목 하나 = "## <ID>. 제목" 부터 다음 제목 전까지
cmd_show() {
  [[ $# -eq 0 ]] && { print_review_criteria; return; }
  local id missing=()
  for id in "$@"; do
    [[ "$id" =~ ^[A-Z][0-9]+$ ]] || die "$EXIT_USAGE" "기준 ID 형식이 아니다: $id (예: B4)"
    review_criterion_index | cut -f1 | grep -qxF "$id" || missing+=("$id")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "$EXIT_USAGE" "이 프로젝트의 검증 기준에 없다: ${missing[*]} (harness criteria list)"
  review_criteria_files | while IFS= read -r file; do [[ -n "$file" ]] && cat "$file"; done \
    | awk -v ids=" $* " '
        /^#{1,2} / { on = 0 }
        /^## [A-Z][0-9]+\. / { id = $2; sub(/\.$/, "", id); on = index(ids, " " id " ") > 0 }
        on'
}

case "${1:-}" in
  list) cmd_list ;;
  show) shift; cmd_show "$@" ;;
  add)  shift; cmd_add "$@" ;;
  *)    die "$EXIT_USAGE" "사용: harness criteria <list | show [ID...] | add --title 제목 --rule 규칙 …>" ;;
esac
