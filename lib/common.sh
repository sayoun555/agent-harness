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

source "$HARNESS_HOME/lib/platform.sh"

# ── 출력 ───────────────────────────────────────────────────────────
# 사람이 읽는 메시지는 stderr, 기계가 읽는 결과(JSON)는 stdout.
info() { printf '%s\n' "$*" >&2; }

# --json 으로 부른 명령은 멈출 때도 stdout 에 결과 한 줄을 낸다. 루프는 stdout 의 JSON 만 읽기 때문에,
# 없으면 "응답 없음" 과 "명령이 거부함" 을 가르지 못한다.
#   source 한 명령 스크립트의 인자를 여기서 본다(인자 없이 source 하면 호출한 스크립트의 인자가 보인다).
#   export 하지 않는다 — 그 명령이 안에서 부르는 다른 명령에는 번지지 않는다.
JSON_ERRORS=0
for arg in "$@"; do [[ "$arg" == "--json" ]] && JSON_ERRORS=1; done
unset arg

die() {  # die <exit-code> <message>
  local code="$1"; shift
  printf 'harness: %s\n' "$*" >&2
  if [[ "$JSON_ERRORS" -eq 1 ]]; then
    jq -cn --arg reason "$*" --argjson code "$code" '{result: "error", exitCode: $code, reason: $reason}' 2>/dev/null \
      || printf '{"result":"error","exitCode":%s,"reason":"jq 없음"}\n' "$code"
  fi
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
# 해석 순서(뒤가 앞을 덮는다): defaults → preset → addons(배열은 이어 붙임) → project.json
#   객체는 깊게 병합, 배열은 통째로 교체(jq `*` 의미).
DEFAULTS_FILE="$HARNESS_HOME/presets/_defaults.json"
RESOLVED_CONFIG=""

preset_file_for() {
  local name="$1"
  [[ -z "$name" ]] && { printf '%s\n' "$HARNESS_HOME/presets/generic.json"; return; }
  printf '%s\n' "$HARNESS_HOME/presets/$name.json"
}

# 애드온: 스택(프리셋 하나)과 함께 쓰는 서비스 · 인프라(Supabase · Terraform …). 여러 개를 겹친다.
#   프리셋 위에 얹을 때 객체는 깊게 병합하고 배열은 이어 붙인다(이미 있는 항목은 빼고).
#   그래서 애드온은 프리셋의 점검 항목 · 위험 글롭 · footgun 을 지우지 않고 더한다.
#   project.json 은 지금처럼 맨 마지막에 덮는다(배열은 교체).
addon_file_for() { printf '%s\n' "$HARNESS_HOME/presets/addons/$1.json"; }


load_config() {
  [[ -n "$RESOLVED_CONFIG" ]] && return 0
  local preset_name preset_file addons=()
  preset_name="$(jq -r '.preset // empty' "$PROJECT_CONFIG" 2>/dev/null || true)"
  preset_file="$(preset_file_for "$preset_name")"
  [[ -f "$preset_file" ]] || die "$EXIT_CONFIG" "프리셋이 없다: $preset_name ($preset_file)"
  local name file
  while IFS= read -r name; do   # 없는 애드온이면 여기서(이 셸에서) 멈춘다
    [[ -z "$name" ]] && continue
    file="$(addon_file_for "$name")"
    [[ -f "$file" ]] || die "$EXIT_CONFIG" "애드온이 없다: $name ($file)"
    addons+=("$file")
  done < <(jq -r '(.addons // [])[]' "$PROJECT_CONFIG" 2>/dev/null || true)
  RESOLVED_CONFIG="$(jq -s '
    def stack($base; $add):
      if ($base | type) == "object" and ($add | type) == "object" then
        reduce ($add | keys_unsorted[]) as $k ($base;
          .[$k] = (if has($k) then stack(.[$k]; $add[$k]) else $add[$k] end))
      elif ($base | type) == "array" and ($add | type) == "array" then
        $base + [$add[] | select(. as $item | any($base[]; . == $item) | not)]
      else $add end;
    (reduce .[2:-1][] as $addon (.[0] * .[1]; stack(.; $addon))) * (.[-1] | del(.preset, .addons))' \
    "$DEFAULTS_FILE" "$preset_file" ${addons[@]+"${addons[@]}"} "$PROJECT_CONFIG")" \
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

# ── 운용 방식 ───────────────────────────────────────────────────────
# loop.autoCommit 이 false 면 하네스는 커밋·브랜치를 만들지 않는다(원장만 쓴다).
#   주의: jq 의 `false // empty` 는 비어 버리므로 cfg 로 읽지 않고 직접 비교한다.
auto_commit_enabled() {
  load_config
  ! jq -e '.loop.autoCommit == false' <<<"$RESOLVED_CONFIG" >/dev/null
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
