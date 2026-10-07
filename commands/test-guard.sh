#!/usr/bin/env bash
#
# harness test-guard — 테스트 약화 감시 (게이트 속이기 방지).
#   기준 트리 대비 작업 트리에서
#     테스트 케이스 합계가 줄었거나 · assertion 합계가 줄었거나 · skip 합계가 늘면  → 실패(exit 1)
#   파일별 감소는 경고만 한다. 테스트를 다른 파일로 옮기는 정당한 리팩터를 막지 않기 위해서다.
#
#   harness test-guard [--json] [--ref 기준-ref] [-- 경로...]
#     기준은 기본으로 lib/changes.sh 의 기준 트리(커밋 운용이면 HEAD, 아니면 기준선).
#     --ref 를 주면 그 커밋(예: CI 의 origin/main). 경로를 주면 그 범위의 테스트만 본다.
#     비교할 기준이 없으면 통과시키되 "감시하지 못했다" 고 분명히 알린다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/changes.sh"
require_commands git jq
project_is_plugged_in || { info "test-guard: 이 프로젝트에 하네스가 없다 — 건너뜀"; exit 0; }
cd "$PROJECT_ROOT"

OUTPUT_JSON=0
REF=""
SCOPE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_JSON=1 ;;
    --ref)  REF="${2:-}"; shift ;;
    --)     shift; SCOPE=("$@"); break ;;
    *)      REF="$1" ;;   # 예전 호출 형식 test-guard <ref>
  esac
  shift
done

TEST_PATH_RE="$(cfg '.source.testPathPattern')"
CASE_RE="$(cfg '.testGuard.testCasePattern')"
ASSERT_RE="$(cfg '.testGuard.assertionPattern')"
SKIP_RE="$(cfg '.testGuard.skipPattern')"

emit_result() {  # emit_result <weakened:true|false> <reason> <warnings-json> <totals-json> [skipped-reason]
  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    jq -cn --argjson weakened "$1" --arg reason "$2" --argjson warnings "$3" --argjson totals "$4" --arg skipped "${5:-}" \
      '{weakened: $weakened, reason: $reason, warnings: $warnings, totals: $totals}
       + (if $skipped == "" then {} else {skipped: $skipped} end)'
    return
  fi
  if [[ -n "${5:-}" ]]; then echo "⚠️ test-guard: 감시하지 못했다 — $5"
  elif [[ "$1" == "true" ]]; then echo "⛔ test-guard: $2"
  else echo "✅ test-guard: 테스트 약화 없음 (기준: $BASE_LABEL)"; fi
  jq -r '.[] | "⚠️ " + .' <<<"$3"
}

# ── 기준 ────────────────────────────────────────────────────────────
resolve_base() {
  if [[ -n "$REF" ]]; then
    BASE_TREE="$(git rev-parse --verify --quiet "$REF^{tree}" || true)"
    BASE_LABEL="$REF"
    return
  fi
  BASE_LABEL="$(base_label)"
  if uses_head_as_base || has_baseline; then BASE_TREE="$(base_tree)"; else BASE_TREE=""; fi
}

[[ -z "$CASE_RE$ASSERT_RE$SKIP_RE" ]] && { emit_result false "" '[]' '{}' "패턴 미설정 — 프리셋의 testGuard 를 채운다"; exit 0; }
resolve_base
[[ -n "$BASE_TREE" ]] || { emit_result false "" '[]' '{}' "비교할 기준이 없다 (커밋 없이 운용하면 harness baseline save)"; exit 0; }
CURRENT_TREE="$(current_tree)"

# ── 파일 목록: 두 트리의 테스트 파일 (범위가 있으면 그 안에서만) ──────────
is_test_path() { [[ "$1" =~ $TEST_PATH_RE ]]; }

test_files_in() {  # test_files_in <tree>
  git ls-tree -r --name-only "$1" ${SCOPE[@]+"${SCOPE[@]}"} | while IFS= read -r f; do
    is_test_path "$f" && echo "$f"
  done || true
}

# ── 세기: 줄 수가 아니라 등장 횟수 ───────────────────────────────────
count_matches() {  # count_matches <pattern> < 내용
  [[ -z "$1" ]] && { cat >/dev/null; echo 0; return; }
  { grep -oE "$1" || true; } | wc -l | tr -d ' '
}

count_in_tree() {  # count_in_tree <tree> <pattern> <path>
  git show "$1:$3" 2>/dev/null | count_matches "$2"
}

totals_for() {  # totals_for <tree> <files...>
  local tree="$1" cases=0 asserts=0 skips=0 file; shift
  for file in "$@"; do
    cases=$((cases + $(count_in_tree "$tree" "$CASE_RE" "$file")))
    asserts=$((asserts + $(count_in_tree "$tree" "$ASSERT_RE" "$file")))
    skips=$((skips + $(count_in_tree "$tree" "$SKIP_RE" "$file")))
  done
  jq -cn --argjson c "$cases" --argjson a "$asserts" --argjson s "$skips" '{cases: $c, asserts: $a, skips: $s}'
}

BASE_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && BASE_FILES+=("$f"); done < <(test_files_in "$BASE_TREE")
NOW_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && NOW_FILES+=("$f"); done < <(test_files_in "$CURRENT_TREE")

BASE_TOTALS="$(totals_for "$BASE_TREE" ${BASE_FILES[@]+"${BASE_FILES[@]}"})"
NOW_TOTALS="$(totals_for "$CURRENT_TREE" ${NOW_FILES[@]+"${NOW_FILES[@]}"})"

# ── 파일별 경고 (차단하지 않음) ──────────────────────────────────────
per_file_warnings() {
  local file base now
  for file in ${BASE_FILES[@]+"${BASE_FILES[@]}"}; do
    if ! git cat-file -e "$CURRENT_TREE:$file" 2>/dev/null; then
      echo "테스트 파일 삭제: $file"
      continue
    fi
    base="$(count_in_tree "$BASE_TREE" "$ASSERT_RE" "$file")"
    now="$(count_in_tree "$CURRENT_TREE" "$ASSERT_RE" "$file")"
    (( now < base )) && echo "assertion 감소: $file ($base → $now)"
  done
  return 0
}
WARNINGS="$(per_file_warnings | lines_to_json)"

# ── 판정 ────────────────────────────────────────────────────────────
REASON="$(jq -rn --argjson b "$BASE_TOTALS" --argjson n "$NOW_TOTALS" '
  [ (if $n.cases   < $b.cases   then "테스트 케이스 \($b.cases) → \($n.cases)"   else empty end),
    (if $n.asserts < $b.asserts then "assertion \($b.asserts) → \($n.asserts)" else empty end),
    (if $n.skips   > $b.skips   then "skip \($b.skips) → \($n.skips)"         else empty end) ]
  | join(", ")')"
TOTALS="$(jq -cn --argjson base "$BASE_TOTALS" --argjson now "$NOW_TOTALS" --arg label "$BASE_LABEL" '{base: $base, now: $now, against: $label}')"

if [[ -n "$REASON" ]]; then
  emit_result true "테스트가 약해졌다 — $REASON" "$WARNINGS" "$TOTALS"
  exit "$EXIT_GATE_FAILED"
fi
emit_result false "" "$WARNINGS" "$TOTALS"
