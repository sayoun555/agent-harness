#!/usr/bin/env bash
#
# harness test-guard — 테스트 약화 감시 (reward hacking 방지).
#   기준 ref(기본 HEAD) 대비 작업 트리에서
#     테스트 케이스 합계가 줄었거나 · assertion 합계가 줄었거나 · skip 합계가 늘면  → 실패(exit 1)
#   파일별 감소는 경고만 한다. 테스트를 다른 파일로 옮기는 정당한 리팩터를 막지 않기 위해서다.
#
#   harness test-guard [기준-ref] [--json]
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
require_commands git jq
project_is_plugged_in || { info "test-guard: 이 프로젝트에 하네스가 없다 — 건너뜀"; exit 0; }
cd "$PROJECT_ROOT"

BASE_REF="HEAD"
OUTPUT_JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT_JSON=1 ;;
    *) BASE_REF="$arg" ;;
  esac
done

TEST_PATH_RE="$(cfg '.source.testPathPattern')"
CASE_RE="$(cfg '.testGuard.testCasePattern')"
ASSERT_RE="$(cfg '.testGuard.assertionPattern')"
SKIP_RE="$(cfg '.testGuard.skipPattern')"

emit_result() {  # emit_result <weakened:true|false> <reason> <warnings-json-array> <totals-json>
  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    jq -cn --argjson weakened "$1" --arg reason "$2" --argjson warnings "$3" --argjson totals "$4" \
      '{weakened: $weakened, reason: $reason, warnings: $warnings, totals: $totals}'
  else
    [[ "$1" == "true" ]] && echo "⛔ test-guard: $2" || echo "✅ test-guard: 테스트 약화 없음"
    jq -r '.[] | "⚠️ " + .' <<<"$3"
  fi
}

[[ -z "$CASE_RE$ASSERT_RE$SKIP_RE" ]] && { emit_result false "패턴 미설정 — 프리셋의 testGuard 를 채운다" '[]' '{}'; exit 0; }
git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || { emit_result false "기준 ref 없음($BASE_REF) — 첫 커밋 전" '[]' '{}'; exit 0; }

# ── 파일 목록 ───────────────────────────────────────────────────────
is_test_path() { [[ "$1" =~ $TEST_PATH_RE ]]; }

test_files_at_base() {
  git ls-tree -r --name-only "$BASE_REF" | while IFS= read -r f; do is_test_path "$f" && echo "$f"; done || true
}

test_files_in_worktree() {
  git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
    [[ -f "$f" ]] && is_test_path "$f" && echo "$f"
  done || true
}

# ── 세기: 줄 수가 아니라 등장 횟수 ───────────────────────────────────
count_matches() {  # count_matches <pattern> < 내용
  [[ -z "$1" ]] && { cat >/dev/null; echo 0; return; }
  { grep -oE "$1" || true; } | wc -l | tr -d ' '
}

count_at_base() { git show "$BASE_REF:$2" 2>/dev/null | count_matches "$1"; }
count_in_worktree() { count_matches "$1" < "$2"; }

sum_over() {  # sum_over <counter-fn> <pattern> <files...>
  local counter="$1" pattern="$2" total=0 file n; shift 2
  for file in "$@"; do n="$($counter "$pattern" "$file")"; total=$((total + n)); done
  echo "$total"
}

BASE_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && BASE_FILES+=("$f"); done < <(test_files_at_base)
NOW_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && NOW_FILES+=("$f"); done < <(test_files_in_worktree)

totals_for() {  # totals_for <counter-fn> <files...>
  local counter="$1"; shift
  jq -cn --argjson cases "$(sum_over "$counter" "$CASE_RE" "$@")" \
         --argjson asserts "$(sum_over "$counter" "$ASSERT_RE" "$@")" \
         --argjson skips "$(sum_over "$counter" "$SKIP_RE" "$@")" \
         '{cases: $cases, asserts: $asserts, skips: $skips}'
}

BASE_TOTALS="$(totals_for count_at_base ${BASE_FILES[@]+"${BASE_FILES[@]}"})"
NOW_TOTALS="$(totals_for count_in_worktree ${NOW_FILES[@]+"${NOW_FILES[@]}"})"

# ── 파일별 경고 (차단하지 않음) ──────────────────────────────────────
per_file_warnings() {
  local file base now
  for file in ${BASE_FILES[@]+"${BASE_FILES[@]}"}; do
    if [[ ! -f "$file" ]]; then
      echo "테스트 파일 삭제: $file"
      continue
    fi
    base="$(count_at_base "$ASSERT_RE" "$file")"
    now="$(count_in_worktree "$ASSERT_RE" "$file")"
    (( now < base )) && echo "assertion 감소: $file ($base → $now)"
  done
  return 0
}
WARNINGS="$(per_file_warnings | jq -Rsc 'split("\n") | map(select(length > 0))')"

# ── 판정 ────────────────────────────────────────────────────────────
REASON="$(jq -rn --argjson b "$BASE_TOTALS" --argjson n "$NOW_TOTALS" '
  [ (if $n.cases   < $b.cases   then "테스트 케이스 \($b.cases) → \($n.cases)"   else empty end),
    (if $n.asserts < $b.asserts then "assertion \($b.asserts) → \($n.asserts)" else empty end),
    (if $n.skips   > $b.skips   then "skip \($b.skips) → \($n.skips)"         else empty end) ]
  | join(", ")')"
TOTALS="$(jq -cn --argjson base "$BASE_TOTALS" --argjson now "$NOW_TOTALS" '{base: $base, now: $now}')"

if [[ -n "$REASON" ]]; then
  emit_result true "테스트가 약해졌다 — $REASON" "$WARNINGS" "$TOTALS"
  exit "$EXIT_GATE_FAILED"
fi
emit_result false "" "$WARNINGS" "$TOTALS"
