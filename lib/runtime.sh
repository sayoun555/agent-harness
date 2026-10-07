#!/usr/bin/env bash
#
# runtime.sh — 실행 렌즈. source 전용. lib/features.sh 가 필요하다.
#   앱을 실제로 설치·실행하고 화면을 찍고 로그를 받는다. 코드 리뷰와 단위 테스트로는 못 잡는
#   렌더링 결함(겹친 글자, 안 보이는 아이콘, 엉뚱한 위치)과 릴리스 빌드에서만 깨지는 동작을 보기 위해서다.
#
#   설정 runtime.enabled (기본 false) · runtime.appId · setup[] · screens[] · log · teardown[]
#   명령 안의 {out}(스크린샷 경로) · {appId} · {dir}(이번 실행 폴더)를 채운다.
#   무겁다(에뮬레이터·설치). 편집마다가 아니라 기능 검증 때 한 번만 돈다.
#

runtime_enabled() { load_config; jq -e '.runtime.enabled == true' <<<"$RESOLVED_CONFIG" >/dev/null; }

runtime_runs_root() { printf '%s\n' "$PROJECT_HARNESS_DIR/runs"; }

fill_placeholders() {  # fill_placeholders <명령> <out> <dir>
  local command="$1"
  command="${command//\{out\}/$2}"
  command="${command//\{dir\}/$3}"
  printf '%s\n' "${command//\{appId\}/$(cfg '.runtime.appId')}"
}

RUNTIME_FAILED_STEP=""
RUNTIME_DIR=""

run_runtime_steps() {  # run_runtime_steps <jq-경로> <dir> → 실패하면 1 (RUNTIME_FAILED_STEP)
  local step name command
  while IFS= read -r step; do
    [[ -z "$step" ]] && continue
    name="$(jq -r .name <<<"$step")"
    command="$(fill_placeholders "$(jq -r .command <<<"$step")" "" "$2")"
    if ! bash -c "$command" >> "$2/steps.log" 2>&1; then RUNTIME_FAILED_STEP="$name"; return 1; fi
  done < <(load_config; jq -c "($1 // [])[]" <<<"$RESOLVED_CONFIG")
  return 0
}

capture_screens() {  # capture_screens <dir> → 실패하면 1
  local screen name out index=0 max
  max="$(cfg '.runtime.maxScreens')"
  while IFS= read -r screen; do
    [[ -z "$screen" ]] && continue
    index=$((index + 1))
    (( index > ${max:-6} )) && break
    name="$(jq -r .name <<<"$screen")"
    out="$1/$(printf '%02d' "$index")-${name// /_}.png"
    if ! bash -c "$(fill_placeholders "$(jq -r .command <<<"$screen")" "$out" "$1")" >> "$1/steps.log" 2>&1 || [[ ! -s "$out" ]]; then
      RUNTIME_FAILED_STEP="화면: $name"
      return 1
    fi
  done < <(load_config; jq -c '(.runtime.screens // [])[]' <<<"$RESOLVED_CONFIG")
  return 0
}

collect_runtime_log() {  # collect_runtime_log <dir>
  local command
  command="$(cfg '.runtime.log')"
  [[ -z "$command" ]] && return 0
  bash -c "$(fill_placeholders "$command" "" "$1")" > "$1/runtime.log" 2>&1 || true
}

# run_runtime_lens <id> <stamp> → 성공 0, 실패 1. 결과는 원장의 lastRun 에 남긴다.
run_runtime_lens() {
  local id="$1" ok=true
  RUNTIME_FAILED_STEP=""
  RUNTIME_DIR="$(runtime_runs_root)/$id/$2"
  mkdir -p "$RUNTIME_DIR"
  run_runtime_steps '.runtime.setup' "$RUNTIME_DIR" && capture_screens "$RUNTIME_DIR" || ok=false
  collect_runtime_log "$RUNTIME_DIR"
  run_runtime_steps '.runtime.teardown' "$RUNTIME_DIR" || true
  set_feature_fields "$id" "$(jq -cn --arg dir "${RUNTIME_DIR#"$PROJECT_ROOT"/}" --argjson ok "$ok" --arg failed "$RUNTIME_FAILED_STEP" \
    '{lastRun: {dir: $dir, ok: $ok, failedStep: $failed}}')"
  [[ "$ok" == true ]]
}

# 검증 컨텍스트용: 마지막 실행의 스크린샷 경로와 로그 끝부분
print_runtime_evidence() {  # print_runtime_evidence <id>
  local dir ok failed
  dir="$(jq -r --arg id "$1" '.features[] | select(.id == $id) | .lastRun.dir // empty' "$(features_file)")"
  [[ -z "$dir" || ! -d "$PROJECT_ROOT/$dir" ]] && return 0
  ok="$(jq -r --arg id "$1" '.features[] | select(.id == $id) | .lastRun.ok' "$(features_file)")"
  failed="$(jq -r --arg id "$1" '.features[] | select(.id == $id) | .lastRun.failedStep // ""' "$(features_file)")"
  echo
  echo "## 실행 확인 (실행 렌즈 — 스크린샷은 Read 로 직접 열어 화면을 본다)"
  [[ "$ok" == true ]] && echo "- 설치·실행·캡처 성공" || echo "- 실패한 단계: $failed"
  find "$PROJECT_ROOT/$dir" -name '*.png' | sort | sed "s#^$PROJECT_ROOT/#- 스크린샷: #"
  if [[ -s "$PROJECT_ROOT/$dir/runtime.log" ]]; then
    echo "- 실행 로그 끝부분:"
    echo '```'
    tail -n 40 "$PROJECT_ROOT/$dir/runtime.log"
    echo '```'
  fi
  echo "- 겹친 글자, 안 보이는 아이콘·배경, 화면 밖으로 밀린 요소, 크래시·경고 로그는 REQ·REG 위반이다."
}
