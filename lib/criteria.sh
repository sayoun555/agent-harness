#!/usr/bin/env bash
#
# criteria.sh — 기준 파일 찾기·읽기. source 전용.
#
#   설계 기준   design.criteria                                     (설계 단계)
#   검증 기준   review.commonCriteria → review.criteria → .harness/criteria/*.md   (구현·검증)
#
# 이름만 적으면 하네스의 design/criteria/, 경로(/ 포함)면 프로젝트 파일.
# 프로젝트가 직접 쌓은 기준은 .harness/criteria/ 에 두면 설정 없이 자동으로 들어간다.
#

readonly PROJECT_CRITERIA_DIR_NAME="criteria"
readonly CRITERION_HEADING_RE='^## ([A-Z][0-9]+)\. (.*)$'

project_criteria_dir() { printf '%s\n' "$PROJECT_HARNESS_DIR/$PROJECT_CRITERIA_DIR_NAME"; }

criteria_file_for() {  # criteria_file_for <이름|경로>
  case "$1" in
    */*) project_path "$1" ;;
    *)   printf '%s/design/criteria/%s\n' "$HARNESS_HOME" "$1" ;;
  esac
}

# 설정에 적힌 이름들을 파일 경로로 (없는 파일은 경고하고 뺀다)
resolve_criteria_files() {  # resolve_criteria_files < 이름 목록
  local entry file
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    file="$(criteria_file_for "$entry")"
    if [[ -f "$file" ]]; then printf '%s\n' "$file"; else info "⚠️ 기준 파일이 없다: $file"; fi
  done
}

design_criteria_files() { cfg_lines '.design.criteria' | resolve_criteria_files; }

project_criteria_files() {
  local dir
  dir="$(project_criteria_dir)"
  [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -name '*.md' -type f | sort
  return 0
}

review_criteria_files() {
  { cfg_lines '.review.commonCriteria'; cfg_lines '.review.criteria'; } | resolve_criteria_files
  project_criteria_files
}

print_files() {  # print_files < 파일 목록 — 이어 붙여 출력
  local file
  while IFS= read -r file; do [[ -n "$file" ]] && { cat "$file"; echo; }; done
  return 0
}

print_design_criteria() { design_criteria_files | print_files; }
print_review_criteria() { review_criteria_files | print_files; }

# 기준 ID 와 제목: "ID<TAB>제목" 한 줄씩 (검증 대조표의 항목)
criterion_index() {  # criterion_index < 파일 목록
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] && sed -nE "s/$CRITERION_HEADING_RE/\1	\2/p" "$file"
  done
  return 0
}

review_criterion_index() { review_criteria_files | criterion_index; }
