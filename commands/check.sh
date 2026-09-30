#!/usr/bin/env bash
#
# harness check — 결정론 게이트. git 훅·CI·에디터 훅이 같이 쓴다.
#   강한 stub 마커·하드코딩 시크릿 = 차단(exit 1). 약한 마커(임시·추후·일단)·파일 크기 = 경고.
#   의미 위반(설계·footgun)은 review 가 본다.
#
#   harness check            staged 파일 (pre-commit)
#   harness check --all      추적 중인 전체 소스 (pre-push·CI)
#   harness check 파일...     지정 파일 (에디터 훅)
#   HARNESS_STRICT=1         경고도 차단
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
require_commands git jq
project_is_plugged_in || { info "harness check: 이 프로젝트에 하네스가 없다 — 건너뜀"; exit 0; }
cd "$PROJECT_ROOT"

EXTENSIONS_RE="$(cfg_lines '.source.extensions' | paste -sd '|' -)"
TEST_PATH_RE="$(cfg '.source.testPathPattern')"
SOURCE_ROOT="$(cfg '.source.root')"
STUB_RE="$(cfg '.rules.stubMarkerPattern')"
SOFT_MARKER_RE="$(cfg '.rules.softMarkerPattern')"
SECRET_RE="$(cfg '.rules.secretPattern')"
SECRET_EXCLUDE_RE="$(cfg '.rules.secretExcludePattern')"
MAX_FILE_LINES="$(cfg '.rules.maxFileLines')"

has_checked_extension() { [[ "${1##*.}" =~ ^($EXTENSIONS_RE)$ ]]; }
is_test_path() { [[ -n "$TEST_PATH_RE" && "$1" =~ $TEST_PATH_RE ]]; }
is_under_source_root() { [[ -z "$SOURCE_ROOT" || "$1" == "$SOURCE_ROOT"/* ]]; }

matches_main_globs() {
  local globs=()
  while IFS= read -r glob; do [[ -n "$glob" ]] && globs+=("$glob"); done < <(cfg_lines '.source.mainGlobs')
  [[ ${#globs[@]} -eq 0 ]] && return 0
  path_matches_any "$1" "${globs[@]}"
}

is_checked_source() {
  [[ -f "$1" ]] && has_checked_extension "$1" && ! is_test_path "$1" \
    && is_under_source_root "$1" && matches_main_globs "$1"
}

candidate_files() {
  case "${1:-}" in
    --all) git ls-files ;;
    "")    git diff --cached --name-only --diff-filter=ACM ;;
    *)     printf '%s\n' "$@" ;;
  esac
}

# ── 개별 검사: 위반이면 메시지를 출력하고 0 을 반환 ──────────────────
find_stub_markers() {
  [[ -n "$STUB_RE" ]] && grep -nIE "$STUB_RE" "$1" 2>/dev/null | head -3
}

find_soft_markers() {
  [[ -n "$SOFT_MARKER_RE" ]] && grep -nIE "$SOFT_MARKER_RE" "$1" 2>/dev/null | head -3
}

find_hardcoded_secrets() {
  [[ -z "$SECRET_RE" ]] && return 0
  local hits
  hits="$(grep -nIiE "$SECRET_RE" "$1" 2>/dev/null || true)"
  [[ -n "$hits" && -n "$SECRET_EXCLUDE_RE" ]] && hits="$(grep -viE "$SECRET_EXCLUDE_RE" <<<"$hits" || true)"
  printf '%s' "$hits" | head -3
}

line_count() { wc -l < "$1" | tr -d ' '; }

# ── 실행 ────────────────────────────────────────────────────────────
blocked=0
warned=0
checked=0

report_block() {  # report_block <kind> <file> <evidence>
  printf '⛔ [%s] %s\n' "$1" "$2"
  [[ -n "$3" ]] && sed 's/^/      /' <<<"$3"
  blocked=1
}

check_file() {
  local file="$1" evidence lines
  evidence="$(find_stub_markers "$file" || true)"
  [[ -n "$evidence" ]] && report_block "stub" "$file" "$evidence"
  evidence="$(find_soft_markers "$file" || true)"
  if [[ -n "$evidence" ]]; then
    printf '⚠️ [marker] %s — 미완성인지 설명인지 확인\n' "$file"
    sed 's/^/      /' <<<"$evidence"
    warned=1
  fi
  evidence="$(find_hardcoded_secrets "$file")"
  [[ -n "$evidence" ]] && report_block "secret" "$file" "하드코딩 의심 — 환경 변수로 옮긴다."
  lines="$(line_count "$file")"
  if [[ -n "$MAX_FILE_LINES" && "$lines" -gt "$MAX_FILE_LINES" ]]; then
    printf '⚠️ [size] %s (%s줄 > %s) — 분리 고려\n' "$file" "$lines" "$MAX_FILE_LINES"
    warned=1
  fi
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  is_checked_source "$file" || continue
  checked=$((checked + 1))
  check_file "$file"
done < <(candidate_files "$@")

[[ "$checked" -eq 0 ]] && { echo "✅ check: 검사할 소스 없음"; exit 0; }
[[ "$warned" -eq 1 && "${HARNESS_STRICT:-0}" == "1" ]] && blocked=1
[[ "$blocked" -eq 1 ]] && { echo "❌ check 실패 — 차단 항목을 고친다. 우회하지 않는다."; exit "$EXIT_GATE_FAILED"; }
[[ "$warned" -eq 1 ]] && echo "✅ check 통과 (경고 있음)" || echo "✅ check 통과 (${checked}개 파일)"
