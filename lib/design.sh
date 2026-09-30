#!/usr/bin/env bash
#
# design.sh — 설계 기준과 설계 문서. source 전용.
#
# 설계 문서는 design/templates/design.md 양식을 따른다. 이 파일은 그 양식의
# 절 제목과 표를 읽는다. HTML 주석(<!-- -->)은 안내문이라 내용으로 치지 않는다.
#

readonly DESIGN_TEMPLATE="$HARNESS_HOME/design/templates/design.md"
readonly REQUIRED_SECTIONS="완성 정의|범위 밖|현재 상태|설계 결정|구성 요소|검증 계획|기능 분해"
readonly TEXT_SECTIONS="완성 정의|범위 밖|현재 상태"
readonly DECISION_PENDING="사람 결정 필요"

# ── 기준 ────────────────────────────────────────────────────────────
# 이름만 있으면 하네스의 design/criteria/, 경로(/ 포함)면 프로젝트 기준
criteria_file_for() {
  case "$1" in
    */*) project_path "$1" ;;
    *)   printf '%s/design/criteria/%s\n' "$HARNESS_HOME" "$1" ;;
  esac
}

print_design_criteria() {
  local entry file
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    file="$(criteria_file_for "$entry")"
    if [[ -f "$file" ]]; then cat "$file"; echo; else info "⚠️ 설계 기준 파일이 없다: $file"; fi
  done < <(cfg_lines '.design.criteria')
}

design_docs_dir() { project_path "$(cfg '.design.docsDir')"; }

# ── 문서 읽기 ───────────────────────────────────────────────────────
# section_body <doc> <제목> → 주석을 뺀 절 본문
section_body() {
  awk -v want="## $2" '
    /^## / { inside = ($0 == want); next }
    !inside { next }
    /<!--/ { in_comment = 1 }
    in_comment { if (/-->/) in_comment = 0; next }
    { print }
  ' "$1"
}

has_section() { grep -qx "## $2" "$1"; }

# section_text <doc> <제목> → 빈 줄과 표를 뺀 글
section_text() { section_body "$1" "$2" | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*|' || true; }

# table_rows <doc> <제목> → 머리줄과 구분줄을 뺀 표의 행, 칸은 탭으로
#   칸 안의 파이프는 GitHub 마크다운처럼 \| 로 쓴다 (acceptance 명령에 흔하다).
#   칸 전체를 감싼 백틱은 벗긴다.
table_rows() {
  section_body "$1" "$2" | awk '
    /^[[:space:]]*\|/ {
      rows++
      if (rows <= 2) next          # 머리줄, |---|
      line = $0
      gsub(/\\\|/, "\001", line)   # \| 를 잠시 다른 글자로
      sub(/^[[:space:]]*\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      n = split(line, cells, "|")
      out = ""
      for (i = 1; i <= n; i++) {
        c = cells[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
        gsub(/\001/, "|", c)
        if (c ~ /^`.*`$/) c = substr(c, 2, length(c) - 2)
        out = out (i > 1 ? "\t" : "") c
      }
      print out
    }'
}

# ── 검사 ────────────────────────────────────────────────────────────
DESIGN_PROBLEMS=()
DESIGN_UNRESOLVED=()

problem() { DESIGN_PROBLEMS+=("$1"); }

check_required_sections() {
  local doc="$1" section
  local IFS='|'
  for section in $REQUIRED_SECTIONS; do
    has_section "$doc" "$section" || problem "절이 없다: ## $section"
  done
  for section in $TEXT_SECTIONS; do
    has_section "$doc" "$section" && [[ -z "$(section_text "$doc" "$section")" ]] && problem "절이 비어 있다: ## $section"
  done
  return 0
}

check_decisions() {
  local doc="$1" id decision choice basis status
  while IFS=$'\t' read -r id decision choice basis status; do
    [[ -z "$id" ]] && continue
    case "$status" in
      "결정됨") ;;
      "$DECISION_PENDING") DESIGN_UNRESOLVED+=("$(printf '%s\t%s\t%s' "$id" "$decision" "$choice")") ;;
      "사람 결정: "*) ;;
      *) problem "결정 $id 의 상태가 올바르지 않다: '$status' (결정됨 · $DECISION_PENDING · 사람 결정: <답>)" ;;
    esac
    [[ -z "$basis" ]] && problem "결정 $id 에 근거 기준이 없다"
  done < <(table_rows "$doc" "설계 결정")
  return 0
}

check_components_are_verifiable() {
  local doc="$1" component verified_names
  verified_names="$(table_rows "$doc" "검증 계획" | cut -f1)"
  [[ -z "$(table_rows "$doc" "구성 요소")" ]] && problem "구성 요소가 하나도 없다"
  [[ -z "$verified_names" ]] && problem "검증 계획이 하나도 없다 (C4)"
  while IFS=$'\t' read -r component _; do
    [[ -z "$component" ]] && continue
    grep -qxF -- "$component" <<<"$verified_names" || problem "구성 요소 '$component' 의 검증 방법이 없다 (C4)"
  done < <(table_rows "$doc" "구성 요소")
  return 0
}

check_feature_breakdown() {
  local doc="$1" id desc acceptance count=0
  while IFS=$'\t' read -r id desc acceptance; do
    [[ -z "$id$desc$acceptance" ]] && continue
    count=$((count + 1))
    [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || problem "기능 id 는 영문 소문자 kebab-case: '$id'"
    [[ -z "$acceptance" ]] && problem "기능 $id 에 acceptance 가 없다"
  done < <(table_rows "$doc" "기능 분해")
  [[ "$count" -eq 0 ]] && problem "기능 분해가 비어 있다"
  return 0
}

check_design_doc() {  # check_design_doc <doc> → DESIGN_PROBLEMS, DESIGN_UNRESOLVED 를 채운다
  local doc="$1"
  DESIGN_PROBLEMS=()
  DESIGN_UNRESOLVED=()
  check_required_sections "$doc"
  check_decisions "$doc"
  check_components_are_verifiable "$doc"
  check_feature_breakdown "$doc"
}
