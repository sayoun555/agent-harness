#!/usr/bin/env bash
#
# harness design — 설계 단계.
#
#   criteria                 이 프로젝트에 적용되는 설계 기준 (공통 + 스택 + 프로젝트)과 기본 동작 점검 항목
#   new 이름                  양식에서 설계 문서를 만든다 (design.docsDir/이름.md). 점검 표에 프리셋 항목을 미리 넣는다
#   check 문서 [--json]       절·결정·검증 가능성·기능 분해 검사. 통과해야 기능 목록으로 넘어간다
#   review-context 문서       독립 검토자에게 줄 컨텍스트 (프로토콜 + 기준 + 문서)
#   features 문서 [--json]    기능 분해 표를 기능 원장 형식으로 (추가는 하지 않음)
#   trace 문서 [--json]       요구 추적표 요약 — 요구가 기능·범위 밖으로 얼마나 이어졌는지
#   import 문서               check 를 통과한 설계의 기능 분해를 원장에 추가한다. 이미 있는 id 는 건너뛴다
#                            설계 결정 표의 "사람 결정: <답>" 은 각 기능의 decisions 로,
#                            기본 동작 점검에서 반영한 항목은 맡은 기능의 baseline 으로 옮긴다
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/criteria.sh"
source "$HARNESS_HOME/lib/design.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

require_doc() {
  [[ -n "${1:-}" ]] || die "$EXIT_USAGE" "설계 문서 경로가 필요하다"
  [[ -f "$1" ]] || die "$EXIT_USAGE" "설계 문서가 없다: $1"
}

cmd_new() {
  local name="${1:-}" path
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "$EXIT_USAGE" "사용: design new 이름 (영문 소문자 kebab-case)"
  path="$(design_docs_dir)/$name.md"
  [[ -e "$path" ]] && die "$EXIT_USAGE" "이미 있다: ${path#"$PROJECT_ROOT"/}"
  mkdir -p "$(dirname "$path")"
  sed "s/{이름}/$name/" "$DESIGN_TEMPLATE" | fill_baseline_table > "$path"
  printf '%s\n' "${path#"$PROJECT_ROOT"/}"
}

# 양식의 점검 표 구분줄 뒤에 프리셋 항목 행을 넣는다 (항목이 없으면 그대로)
fill_baseline_table() {
  local rows_file
  rows_file="$(mktemp)"
  baseline_template_rows > "$rows_file"
  awk -v want="## $BASELINE_SECTION" -v rows="$rows_file" '
    /^## / { inside = (index($0, want) == 1 && length($0) == length(want)) }
    { print }
    inside && /^\|---/ { while ((getline line < rows) > 0) print line; inside = 0 }
  '
  rm -f "$rows_file"
}

cmd_check() {
  local doc="${1:-}"; shift || true
  require_doc "$doc"
  check_design_doc "$doc"
  local problems_json='[]' unresolved_json='[]' warnings_json='[]' ok=true
  [[ ${#DESIGN_PROBLEMS[@]} -gt 0 ]] && problems_json="$(printf '%s\n' "${DESIGN_PROBLEMS[@]}" | lines_to_json)"
  [[ ${#DESIGN_WARNINGS[@]} -gt 0 ]] && warnings_json="$(printf '%s\n' "${DESIGN_WARNINGS[@]}" | lines_to_json)"
  [[ ${#DESIGN_UNRESOLVED[@]} -gt 0 ]] && unresolved_json="$(printf '%s\n' "${DESIGN_UNRESOLVED[@]}" \
    | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], decision: .[1], options: .[2]})')"
  [[ ${#DESIGN_PROBLEMS[@]} -gt 0 || ${#DESIGN_UNRESOLVED[@]} -gt 0 ]] && ok=false

  if [[ "${1:-}" == "--json" ]]; then
    jq -cn --argjson ok "$ok" --argjson p "$problems_json" --argjson u "$unresolved_json" --argjson w "$warnings_json" \
      '{ok: $ok, problems: $p, unresolved: $u, warnings: $w}'
  else
    [[ "$ok" == true ]] && echo "✅ design check 통과 — 기능 목록으로 넘어갈 수 있다"
    [[ ${#DESIGN_PROBLEMS[@]} -gt 0 ]] && { echo "⛔ 문서 문제"; printf '   - %s\n' "${DESIGN_PROBLEMS[@]}"; }
    [[ ${#DESIGN_UNRESOLVED[@]} -gt 0 ]] && { echo "❓ 사람 결정 필요"; jq -r '.[] | "   - \(.id) \(.decision): \(.options)"' <<<"$unresolved_json"; }
    [[ ${#DESIGN_WARNINGS[@]} -gt 0 ]] && { echo "⚠️ 경고 (막지 않음)"; printf '   - %s\n' "${DESIGN_WARNINGS[@]}"; }
  fi
  [[ "$ok" == true ]]
}

# 요구 추적표 요약: 요구가 기능·범위 밖으로 얼마나 이어졌는지, 기능마다 요구 몇 개인지
cmd_trace() {
  local doc="${1:-}"; shift || true
  require_doc "$doc"
  local summary
  summary="$(table_rows "$doc" "요구 추적" | jq -Rsc --arg out "$OUT_OF_SCOPE" '
    split("\n") | map(select(length > 0) | split("\t") | {req: .[0], source: .[1], feature: (.[3] // "")})
    | {total: length,
       mapped: (map(select(.feature != "" and .feature != $out)) | length),
       outOfScope: (map(select(.feature == $out)) | length),
       unmapped: (map(select(.feature == "")) | map(.req)),
       perFeature: (map(select(.feature != "" and .feature != $out)) | group_by(.feature) | map({(.[0].feature): length}) | add // {}),
       perSource: (group_by(.source) | map({(.[0].source): length}) | add // {})}')"
  if [[ "${1:-}" == "--json" ]]; then echo "$summary"; return; fi
  jq -r '"요구 \(.total)개 — 기능에 이어짐 \(.mapped) · 범위 밖 \(.outOfScope) · 이어지지 않음 \(.unmapped | length)"
    + (if (.unmapped | length) > 0 then "\n  이어지지 않은 요구: " + (.unmapped | join(", ")) else "" end)
    + "\n기능별 요구 수:" + ([.perFeature | to_entries[] | "\n  \(.key): \(.value)"] | join(""))
    + "\n출처별 요구 수:" + ([.perSource | to_entries[] | "\n  \(.key): \(.value)"] | join(""))' <<<"$summary"
}

cmd_review_context() {
  local doc="${1:-}"
  require_doc "$doc"
  cat "$HARNESS_HOME/design/review-protocol.md"
  echo
  echo "# 적용되는 설계 기준"
  print_design_criteria
  print_baseline_checks
  echo "# 검토할 설계 문서: $doc"
  echo
  cat "$doc"
}

cmd_features() {
  local doc="${1:-}"; shift || true
  require_doc "$doc"
  local rows
  rows="$(table_rows "$doc" "기능 분해" | jq -Rsc --arg doc "$doc" \
    'split("\n") | map(select(length > 0) | split("\t")
       | {id: .[0], description: .[1], acceptance: .[2], designDoc: $doc}
         + (if ((.[3] // "") | . != "" and . != "-") then {figma: .[3]} else {} end))')"
  if [[ "${1:-}" == "--json" ]]; then printf '%s\n' "$rows"; else jq -r '.[] | "\(.id)\t\(.description)\t\(.acceptance)"' <<<"$rows"; fi
}

cmd_import() {
  local doc="${1:-}"
  require_doc "$doc"
  if ! cmd_check "$doc" >/dev/null; then
    cmd_check "$doc" || true
    die "$EXIT_GATE_FAILED" "설계 검사를 통과하지 못해 원장에 넣지 않았다. 위 문제와 사람 결정을 먼저 해결한다."
  fi
  local ledger added=0 skipped=0 id desc acceptance screen decisions baseline
  ledger="$(project_path "$(cfg '.state.featuresFile')")"
  decisions="$(human_decisions_json "$doc")"   # 사람이 내린 결정은 기능마다 붙어 구현 지시문에 들어간다
  baseline="$(baseline_by_feature_json "$doc")" # 반영한 기본 동작은 맡은 기능에만 붙는다
  while IFS="$CELL" read -r id desc acceptance screen; do
    [[ -z "$id" ]] && continue
    [[ "$screen" == "-" ]] && screen=""
    if [[ -f "$ledger" ]] && jq -e --arg id "$id" '.features[] | select(.id == $id)' "$ledger" >/dev/null; then
      skipped=$((skipped + 1)); continue
    fi
    bash "$HARNESS_HOME/commands/feature.sh" add --id "$id" --desc "$desc" --acceptance "$acceptance" \
      --design "$doc" --decisions-json "$decisions" ${screen:+--figma "$screen"} \
      --baseline-json "$(jq -c --arg id "$id" '.[$id] // []' <<<"$baseline")" >/dev/null
    added=$((added + 1))
  done < <(table_cells "$doc" "기능 분해")
  echo "➕ 설계 $doc → 기능 ${added}개 추가 (이미 있어 건너뜀 ${skipped}개)"
}

case "${1:-}" in
  criteria)       print_design_criteria; print_baseline_checks ;;
  new)            shift; cmd_new "$@" ;;
  check)          shift; cmd_check "$@" ;;
  review-context) shift; cmd_review_context "$@" ;;
  features)       shift; cmd_features "$@" ;;
  import)         shift; cmd_import "$@" ;;
  trace)          shift; cmd_trace "$@" ;;
  *)              die "$EXIT_USAGE" "사용: harness design <criteria|new|check|trace|review-context|features|import>" ;;
esac
