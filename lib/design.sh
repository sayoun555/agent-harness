#!/usr/bin/env bash
#
# design.sh — 설계 문서. source 전용. lib/criteria.sh 가 필요하다.
#
# 설계 문서는 design/templates/design.md 양식을 따른다. 이 파일은 그 양식의
# 절 제목과 표를 읽는다. HTML 주석(<!-- -->)은 안내문이라 내용으로 치지 않는다.
#

readonly DESIGN_TEMPLATE="$HARNESS_HOME/design/templates/design.md"
readonly REQUIRED_SECTIONS="요구 원천|완성 정의|UX·레퍼런스|범위 밖|현재 상태|설계 결정|구성 요소|검증 계획|기능 분해|요구 추적"
readonly OUT_OF_SCOPE="범위 밖"
readonly TEXT_SECTIONS="완성 정의|UX·레퍼런스|범위 밖|현재 상태"
readonly DECISION_PENDING="사람 결정 필요"
readonly BASELINE_SECTION="기본 동작 점검"
readonly BASELINE_APPLIED="반영"
readonly BASELINE_NOT_APPLICABLE="해당 없음"

# ── 기준 ── lib/criteria.sh 에 있다 (design_criteria_files · print_design_criteria)

design_docs_dir() { project_path "$(cfg '.design.docsDir')"; }

# ── 문서 읽기 ───────────────────────────────────────────────────────
# section_body <doc> <제목> → 주석을 뺀 절 본문
#   제목 비교에 awk 의 == 를 쓰지 않는다. == 는 로케일 정렬 규칙을 따라서, 한글 정렬이
#   없는 로케일(CI 의 macOS 등)에서는 서로 다른 한글 제목이 모두 "같다" 로 나온다.
#   index·length 는 바이트로 비교한다.
section_body() {
  awk -v want="## $2" '
    /^## / { inside = (index($0, want) == 1 && length($0) == length(want)); next }
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

# table_cells <doc> <제목> → table_rows 와 같지만 칸 구분이 CELL(0x1F). while read 로 읽을 때 쓴다.
#   탭은 IFS 공백 문자라 read 가 연속된 탭을 하나로 합친다 — 가운데 칸이 비면 뒤 칸이 앞으로 밀린다.
#   cut · jq 는 빈 칸을 지키므로 table_rows 를 그대로 쓴다.
readonly CELL=$'\037'
table_cells() { table_rows "$1" "$2" | tr '\t' "$CELL"; }

# 설계 결정 표에서 사람이 내린 결정("사람 결정: <답>")만 [{question, answer}] 로
human_decisions_json() {  # human_decisions_json <doc>
  table_rows "$1" "설계 결정" | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t"))
    | map(select((.[4] // "") | startswith("사람 결정: "))
          | {question: "\(.[0]) \(.[1])", answer: (.[4] | ltrimstr("사람 결정: "))})'
}

# ── 검사 ────────────────────────────────────────────────────────────
DESIGN_PROBLEMS=()
DESIGN_UNRESOLVED=()
DESIGN_WARNINGS=()

problem() { DESIGN_PROBLEMS+=("$1"); }
warning() { DESIGN_WARNINGS+=("$1"); }

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
  while IFS="$CELL" read -r id decision choice basis status; do
    [[ -z "$id" ]] && continue
    case "$status" in
      "결정됨") ;;
      "$DECISION_PENDING") DESIGN_UNRESOLVED+=("$(printf '%s\t%s\t%s' "$id" "$decision" "$choice")") ;;
      "사람 결정: "*) ;;
      *) problem "결정 $id 의 상태가 올바르지 않다: '$status' (결정됨 · $DECISION_PENDING · 사람 결정: <답>)" ;;
    esac
    [[ -z "$basis" ]] && problem "결정 $id 에 근거 기준이 없다"
  done < <(table_cells "$doc" "설계 결정")
  return 0
}

check_components_are_verifiable() {
  local doc="$1" component verified_names
  verified_names="$(table_rows "$doc" "검증 계획" | cut -f1)"
  [[ -z "$(table_rows "$doc" "구성 요소")" ]] && problem "구성 요소가 하나도 없다"
  [[ -z "$verified_names" ]] && problem "검증 계획이 하나도 없다 (C4)"
  while IFS="$CELL" read -r component _; do
    [[ -z "$component" ]] && continue
    grep -qxF -- "$component" <<<"$verified_names" || problem "구성 요소 '$component' 의 검증 방법이 없다 (C4)"
  done < <(table_cells "$doc" "구성 요소")
  return 0
}

check_feature_breakdown() {
  local doc="$1" id desc acceptance screen count=0
  while IFS="$CELL" read -r id desc acceptance screen; do
    [[ -z "$id$desc$acceptance" ]] && continue
    count=$((count + 1))
    [[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || problem "기능 id 는 영문 소문자 kebab-case: '$id'"
    [[ -z "$acceptance" ]] && problem "기능 $id 에 acceptance 가 없다"
    [[ -z "$screen" || "$screen" == "-" || "$screen" =~ ^https?:// ]] || problem "기능 $id 의 화면은 Figma 링크(https://…) 또는 - : '$screen'"
  done < <(table_cells "$doc" "기능 분해")
  [[ "$count" -eq 0 ]] && problem "기능 분해가 비어 있다"
  return 0
}

# 1차 요구 문서가 있어야 한다. 파생 문서만으로 설계하면 원본 요구를 빠뜨린다.
check_requirement_sources() {
  local doc="$1" source edition kind scope primary=0 count=0
  while IFS="$CELL" read -r source edition kind scope; do
    [[ -z "$source$edition$kind" ]] && continue
    count=$((count + 1))
    case "$kind" in
      1차) primary=$((primary + 1)) ;;
      파생) ;;
      *) problem "요구 원천 '$source' 의 종류가 올바르지 않다: '$kind' (1차 · 파생)" ;;
    esac
    [[ -z "$edition" ]] && problem "요구 원천 '$source' 에 판·날짜가 없다"
  done < <(table_cells "$doc" "요구 원천")
  [[ "$count" -eq 0 ]] && { problem "요구 원천이 비어 있다 — 1차 요구 문서를 적는다"; return 0; }
  [[ "$primary" -eq 0 ]] && problem "1차 요구 문서가 없다 — 파생 문서만으로 설계하지 않는다"
  return 0
}

# 요구 ID 마다 기능(또는 범위 밖)·구성 요소·검증이 이어져야 한다.
check_requirement_trace() {
  local doc="$1" features components req source component feature verify count=0 seen=""
  features="$(table_rows "$doc" "기능 분해" | cut -f1)"
  components="$(table_rows "$doc" "구성 요소" | cut -f1)"
  while IFS="$CELL" read -r req source component feature verify; do
    [[ -z "$req" ]] && continue
    count=$((count + 1))
    grep -qxF -- "$req" <<<"$seen" && problem "요구 추적에 같은 요구 ID 가 두 번 있다: $req"
    seen="$seen"$'\n'"$req"
    if [[ "$feature" == "$OUT_OF_SCOPE" ]]; then continue; fi
    [[ -z "$feature" ]] && { problem "요구 $req 가 어느 기능에도 이어지지 않는다 (기능 id 또는 \"$OUT_OF_SCOPE\")"; continue; }
    grep -qxF -- "$feature" <<<"$features" || problem "요구 $req 의 기능 '$feature' 가 기능 분해에 없다"
    grep -qxF -- "$component" <<<"$components" || problem "요구 $req 의 구성 요소 '$component' 가 구성 요소 표에 없다"
    [[ -z "$verify" ]] && problem "요구 $req 의 검증 방법이 없다"
  done < <(table_cells "$doc" "요구 추적")
  [[ "$count" -eq 0 ]] && problem "요구 추적이 비어 있다 — 1차 문서의 요구 ID 마다 한 줄"
  return 0
}

# 기능 하나가 너무 많은 요구를 맡거나, 요구 없이 생긴 기능은 경고만 한다 (막지는 않는다).
check_feature_load() {
  local doc="$1" limit feature count
  limit="$(cfg '.design.maxRequirementsPerFeature')"
  while IFS=$'\t' read -r count feature; do
    [[ -n "$limit" && "$count" -gt "$limit" ]] && warning "기능 $feature 가 요구 ${count}개를 맡는다 (> $limit) — 나눠서 한 에이전트에 몰리지 않게 한다"
  done < <(table_rows "$doc" "요구 추적" | cut -f4 | grep -vxF "$OUT_OF_SCOPE" | awk 'NF' | sort | uniq -c | awk '{ printf "%s\t%s\n", $1, $2 }')
  while IFS= read -r feature; do
    [[ -z "$feature" ]] && continue
    table_rows "$doc" "요구 추적" | cut -f4 | grep -qxF -- "$feature" \
      || warning "기능 $feature 는 어느 요구에도 이어지지 않는다 — 기반 작업(테스트 환경 등)이 아니면 요구 추적에 적는다"
  done < <(table_rows "$doc" "기능 분해" | cut -f1)
  return 0
}

# ── 기본 동작 점검 ──────────────────────────────────────────────────
# 프리셋(design.baselineChecks)이 정한 항목마다 설계가 판단을 남긴다. 빠뜨림을 막는 질문이지 의무가 아니다.
#   표: | ID | 항목 | 판단 | 기능 | 방법·이유 |
#   반영            기능 = 맡을 기능 id(쉼표로), 방법·이유 = 어떻게 (원장에 들어가 구현자·검증자에게 간다)
#   해당 없음        방법·이유 = 왜 이 설계에 필요 없는가
#   사람 결정 필요   방법·이유 = 선택지. 다른 사람 결정과 함께 묻는다. 답을 받으면 반영 · 해당 없음으로 바꾼다
baseline_checks_json() { load_config; jq -c '.design.baselineChecks // []' <<<"$RESOLVED_CONFIG"; }

has_baseline_checks() { [[ "$(baseline_checks_json | jq length)" -gt 0 ]]; }

baseline_row() {  # baseline_row <doc> <ID> → 그 항목의 표 행, 칸 구분 CELL (없으면 빈 출력)
  table_cells "$1" "$BASELINE_SECTION" | grep -m 1 "^$2$CELL" || true
}

check_baseline_item() {  # check_baseline_item <doc> <ID> <항목> <기능 분해 id 목록>
  local doc="$1" id="$2" title="$3" features="$4" row judgment owners how owner
  row="$(baseline_row "$doc" "$id")"
  [[ -z "$row" ]] && { problem "기본 동작 점검이 빠졌다: $id $title"; return 0; }
  IFS="$CELL" read -r _ _ judgment owners how <<<"$row"
  case "$judgment" in
    "$BASELINE_APPLIED")
      [[ -z "$owners" || "$owners" == "-" ]] && problem "기본 동작 $id 를 반영한다면 맡을 기능 id 를 적는다"
      [[ -z "$how" ]] && problem "기본 동작 $id 를 어떻게 반영하는지 적는다"
      for owner in $(tr ',' ' ' <<<"$owners"); do
        [[ "$owner" == "-" ]] && continue
        grep -qxF -- "$owner" <<<"$features" || problem "기본 동작 $id 의 기능 '$owner' 가 기능 분해에 없다"
      done ;;
    "$BASELINE_NOT_APPLICABLE")
      [[ -z "$how" ]] && problem "기본 동작 $id 를 해당 없음으로 둔 이유를 적는다" ;;
    "$DECISION_PENDING")
      DESIGN_UNRESOLVED+=("$(printf '%s\t%s\t%s' "$id" "$title" "$how")") ;;
    *)
      problem "기본 동작 $id 의 판단이 올바르지 않다: '$judgment' ($BASELINE_APPLIED · $BASELINE_NOT_APPLICABLE · $DECISION_PENDING)" ;;
  esac
  return 0
}

check_baseline() {
  local doc="$1" features id title
  has_baseline_checks || return 0
  has_section "$doc" "$BASELINE_SECTION" || { problem "절이 없다: ## $BASELINE_SECTION (이 프리셋에는 점검 항목이 있다 — harness design criteria)"; return 0; }
  features="$(table_rows "$doc" "기능 분해" | cut -f1)"
  while IFS=$'\t' read -r id title; do
    [[ -n "$id" ]] && check_baseline_item "$doc" "$id" "$title" "$features"
  done < <(baseline_checks_json | jq -r '.[] | "\(.id)\t\(.title)"')
  return 0
}

# 반영한 기본 동작을 기능별로: {"기능 id": [{id, title, how}]}  (import 가 원장에 붙인다)
baseline_by_feature_json() {  # baseline_by_feature_json <doc>
  table_rows "$1" "$BASELINE_SECTION" | jq -Rsc --arg applied "$BASELINE_APPLIED" '
    split("\n") | map(select(length > 0) | split("\t") | select(.[2] == $applied))
    | map(. as $r | ($r[3] | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "" and . != "-")))[]
          | {feature: ., item: {id: $r[0], title: $r[1], how: ($r[4] // "")}})
    | group_by(.feature) | map({(.[0].feature): map(.item)}) | add // {}'
}

# 새 설계 문서의 점검 표에 넣을 빈 행 (판단은 쓰는 사람이 채운다)
baseline_template_rows() {
  baseline_checks_json | jq -r '.[] | "| \(.id) | \(.title) |  |  |  |"'
}

# 설계하는 사람이 읽을 항목과 질문
print_baseline_checks() {
  has_baseline_checks || return 0
  echo "# 기본 동작 점검 항목 (설계 문서의 '$BASELINE_SECTION' 표에 항목마다 판단을 남긴다)"
  echo
  baseline_checks_json | jq -r '.[] | "- \(.id) \(.title): \(.ask)"'
  echo
}

check_design_doc() {  # check_design_doc <doc> → DESIGN_PROBLEMS · DESIGN_UNRESOLVED · DESIGN_WARNINGS
  local doc="$1"
  DESIGN_PROBLEMS=()
  DESIGN_UNRESOLVED=()
  DESIGN_WARNINGS=()
  check_required_sections "$doc"
  check_requirement_sources "$doc"
  check_decisions "$doc"
  check_components_are_verifiable "$doc"
  check_feature_breakdown "$doc"
  check_requirement_trace "$doc"
  check_feature_load "$doc"
  check_baseline "$doc"
}
