#!/usr/bin/env bash
#
# common.sh — 모든 harness 명령이 공유하는 경로·설정·출력 헬퍼.
#   이 파일은 source 전용이다. 직접 실행하지 않는다.
#   bash 3.2(macOS 기본) 호환: 연관 배열·mapfile·${var,,} 를 쓰지 않는다.
#

readonly EXIT_OK=0
readonly EXIT_GATE_FAILED=1
readonly EXIT_USAGE=2
readonly EXIT_CONFIG=3

HARNESS_HOME="${HARNESS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly HARNESS_HOME
export HARNESS_HOME

# ── 출력 ───────────────────────────────────────────────────────────
# 사람이 읽는 메시지는 stderr, 기계가 읽는 결과(JSON)는 stdout.
info() { printf '%s\n' "$*" >&2; }

die() {  # die <exit-code> <message>
  local code="$1"; shift
  printf 'harness: %s\n' "$*" >&2
  exit "$code"
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$EXIT_CONFIG" "필요한 명령이 없다: $cmd"
  done
}

# ── 프로젝트 위치 ───────────────────────────────────────────────────
# 프로젝트 = git 최상위. Claude 훅에서는 CLAUDE_PROJECT_DIR 를 우선한다.
resolve_project_root() {
  local start="${CLAUDE_PROJECT_DIR:-$PWD}"
  git -C "$start" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$start"
}

PROJECT_ROOT="$(resolve_project_root)"
PROJECT_HARNESS_DIR="$PROJECT_ROOT/.harness"
PROJECT_CONFIG="$PROJECT_HARNESS_DIR/project.json"

# 이 프로젝트에 하네스가 끼워져 있나. 없으면 훅은 조용히 통과한다.
project_is_plugged_in() { [[ -f "$PROJECT_CONFIG" ]]; }

# ── 설정 해석 ───────────────────────────────────────────────────────
# 해석 순서(뒤가 앞을 덮는다): defaults → preset → project.json
#   객체는 깊게 병합, 배열은 통째로 교체(jq `*` 의미).
DEFAULTS_FILE="$HARNESS_HOME/presets/_defaults.json"
RESOLVED_CONFIG=""

preset_file_for() {
  local name="$1"
  [[ -z "$name" ]] && { printf '%s\n' "$HARNESS_HOME/presets/generic.json"; return; }
  printf '%s\n' "$HARNESS_HOME/presets/$name.json"
}

load_config() {
  [[ -n "$RESOLVED_CONFIG" ]] && return 0
  local preset_name preset_file
  preset_name="$(jq -r '.preset // empty' "$PROJECT_CONFIG" 2>/dev/null || true)"
  preset_file="$(preset_file_for "$preset_name")"
  [[ -f "$preset_file" ]] || die "$EXIT_CONFIG" "프리셋이 없다: $preset_name ($preset_file)"
  RESOLVED_CONFIG="$(jq -s '.[0] * .[1] * (.[2] | del(.preset))' \
    "$DEFAULTS_FILE" "$preset_file" "$PROJECT_CONFIG")" \
    || die "$EXIT_CONFIG" "설정 병합 실패 — JSON 문법을 확인하라: $PROJECT_CONFIG"
}

# cfg <jq-path>  → 문자열 값(없으면 빈 문자열)
cfg() { load_config; jq -r "$1 // empty" <<<"$RESOLVED_CONFIG"; }

# cfg_lines <jq-path-to-array> → 배열 원소를 한 줄에 하나씩
cfg_lines() { load_config; jq -r "($1 // [])[]" <<<"$RESOLVED_CONFIG"; }

# canonical_path <path> → 심볼릭 링크를 푼 물리 경로 (macOS 의 /var → /private/var 등)
#   디렉터리가 없으면 입력을 그대로 돌려준다.
canonical_path() {
  local path="$1" dir
  dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || { printf '%s\n' "$path"; return; }
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# project_path <relative> → 프로젝트 루트 기준 절대 경로
project_path() { printf '%s/%s\n' "$PROJECT_ROOT" "$1"; }

# ── 경로 매칭 ───────────────────────────────────────────────────────
# path_matches_any <path> <glob...> — [[ == ]] 의 * 는 / 도 매칭한다.
path_matches_any() {
  local path="$1" glob; shift
  for glob in "$@"; do
    # shellcheck disable=SC2053  # glob 매칭이 의도다
    [[ "$path" == $glob ]] && return 0
  done
  return 1
}

# ── 작업 트리 ───────────────────────────────────────────────────────
# 커밋 기준(HEAD) 대비 바뀐 파일: 수정·추가·신규(untracked). 삭제는 제외.
changed_files() {
  {
    git -C "$PROJECT_ROOT" diff --name-only --diff-filter=ACMR HEAD 2>/dev/null
    git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}

# ── JSON 파일 원자적 갱신 ────────────────────────────────────────────
# json_update <file> <jq-filter> [jq args...] — 임시 파일에 쓰고 mv 한다.
json_update() {
  local file="$1" filter="$2"; shift 2
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  if jq "$@" "$filter" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "$EXIT_CONFIG" "JSON 갱신 실패: $file"
  fi
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
