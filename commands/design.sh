#!/usr/bin/env bash
#
# harness design — 설계 단계.
#
#   criteria                 이 프로젝트에 적용되는 설계 기준 (공통 + 스택 + 프로젝트)
#   new 이름                  양식에서 설계 문서를 만든다 (design.docsDir/이름.md)
#   check 문서 [--json]       절·결정·검증 가능성·기능 분해 검사. 통과해야 기능 목록으로 넘어간다
#   review-context 문서       독립 검토자에게 줄 컨텍스트 (프로토콜 + 기준 + 문서)
#   features 문서 [--json]    기능 분해 표를 기능 원장 형식으로 (추가는 하지 않음)
#   import 문서               check 를 통과한 설계의 기능 분해를 원장에 추가한다. 이미 있는 id 는 건너뛴다
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/design.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

require_doc() {
  [[ -n "${1:-}" ]] || die "$EXIT_USAGE" "설계 문서 경로가 필요하다"
  [[ -f "$1" ]] || die "$EXIT_USAGE" "설계 문서가 없다: $1"
}

lines_to_json() { jq -Rsc 'split("\n") | map(select(length > 0))'; }

cmd_new() {
  local name="${1:-}" path
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "$EXIT_USAGE" "사용: design new 이름 (영문 소문자 kebab-case)"
  path="$(design_docs_dir)/$name.md"
  [[ -e "$path" ]] && die "$EXIT_USAGE" "이미 있다: ${path#"$PROJECT_ROOT"/}"
  mkdir -p "$(dirname "$path")"
  sed "s/{이름}/$name/" "$DESIGN_TEMPLATE" > "$path"
  printf '%s\n' "${path#"$PROJECT_ROOT"/}"
}

cmd_check() {
  local doc="${1:-}"; shift || true
  require_doc "$doc"
  check_design_doc "$doc"
  local problems_json='[]' unresolved_json='[]' ok=true
  [[ ${#DESIGN_PROBLEMS[@]} -gt 0 ]] && problems_json="$(printf '%s\n' "${DESIGN_PROBLEMS[@]}" | lines_to_json)"
  [[ ${#DESIGN_UNRESOLVED[@]} -gt 0 ]] && unresolved_json="$(printf '%s\n' "${DESIGN_UNRESOLVED[@]}" \
    | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], decision: .[1], options: .[2]})')"
  [[ ${#DESIGN_PROBLEMS[@]} -gt 0 || ${#DESIGN_UNRESOLVED[@]} -gt 0 ]] && ok=false

  if [[ "${1:-}" == "--json" ]]; then
    jq -cn --argjson ok "$ok" --argjson p "$problems_json" --argjson u "$unresolved_json" \
      '{ok: $ok, problems: $p, unresolved: $u}'
  else
    [[ "$ok" == true ]] && echo "✅ design check 통과 — 기능 목록으로 넘어갈 수 있다"
    [[ ${#DESIGN_PROBLEMS[@]} -gt 0 ]] && { echo "⛔ 문서 문제"; printf '   - %s\n' "${DESIGN_PROBLEMS[@]}"; }
    [[ ${#DESIGN_UNRESOLVED[@]} -gt 0 ]] && { echo "❓ 사람 결정 필요"; jq -r '.[] | "   - \(.id) \(.decision): \(.options)"' <<<"$unresolved_json"; }
  fi
  [[ "$ok" == true ]]
}

cmd_review_context() {
  local doc="${1:-}"
  require_doc "$doc"
  cat "$HARNESS_HOME/design/review-protocol.md"
  echo
  echo "# 적용되는 설계 기준"
  print_design_criteria
  echo "# 검토할 설계 문서: $doc"
  echo
  cat "$doc"
}

cmd_features() {
  local doc="${1:-}"; shift || true
  require_doc "$doc"
  local rows
  rows="$(table_rows "$doc" "기능 분해" | jq -Rsc --arg doc "$doc" \
    'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], description: .[1], acceptance: .[2], designDoc: $doc})')"
  if [[ "${1:-}" == "--json" ]]; then printf '%s\n' "$rows"; else jq -r '.[] | "\(.id)\t\(.description)\t\(.acceptance)"' <<<"$rows"; fi
}

cmd_import() {
  local doc="${1:-}"
  require_doc "$doc"
  if ! cmd_check "$doc" >/dev/null; then
    cmd_check "$doc" || true
    die "$EXIT_GATE_FAILED" "설계 검사를 통과하지 못해 원장에 넣지 않았다. 위 문제와 사람 결정을 먼저 해결한다."
  fi
  local ledger added=0 skipped=0 id desc acceptance
  ledger="$(project_path "$(cfg '.state.featuresFile')")"
  while IFS=$'\t' read -r id desc acceptance; do
    [[ -z "$id" ]] && continue
    if [[ -f "$ledger" ]] && jq -e --arg id "$id" '.features[] | select(.id == $id)' "$ledger" >/dev/null; then
      skipped=$((skipped + 1)); continue
    fi
    bash "$HARNESS_HOME/commands/feature.sh" add --id "$id" --desc "$desc" --acceptance "$acceptance" --design "$doc" >/dev/null
    added=$((added + 1))
  done < <(table_rows "$doc" "기능 분해")
  echo "➕ 설계 $doc → 기능 ${added}개 추가 (이미 있어 건너뜀 ${skipped}개)"
}

case "${1:-}" in
  criteria)       print_design_criteria ;;
  new)            shift; cmd_new "$@" ;;
  check)          shift; cmd_check "$@" ;;
  review-context) shift; cmd_review_context "$@" ;;
  features)       shift; cmd_features "$@" ;;
  import)         shift; cmd_import "$@" ;;
  *)              die "$EXIT_USAGE" "사용: harness design <criteria|new|check|review-context|features|import>" ;;
esac
