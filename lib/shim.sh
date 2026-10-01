#!/usr/bin/env bash
#
# shim.sh — 프로젝트의 .harness/bin/ 을 이 머신의 하네스에 연결한다. source 전용.
#   .harness/bin/harness         하네스 진입점 shim
#   .harness/bin/feature-loop.js 워크플로우 사본
#   shim 은 머신마다 달라서 gitignore 한다. 그래서 새로 clone 한 저장소에는 없다.
#   init 과 세션 시작 훅이 같은 함수로 만들고, 가리키는 곳이 다르면 다시 쓴다.
#

shim_path() { printf '%s\n' "$PROJECT_HARNESS_DIR/bin/harness"; }

shim_content() { printf '#!/usr/bin/env bash\nexec "%s/bin/harness" "$@"\n' "$HARNESS_HOME"; }

# ensure_shim → 새로 썼으면 0, 이미 맞으면 1
ensure_shim() {
  local shim
  shim="$(shim_path)"
  [[ -f "$shim" && "$(cat "$shim")" == "$(shim_content)" ]] && return 1
  mkdir -p "$(dirname "$shim")"
  shim_content > "$shim"
  chmod +x "$shim"
  return 0
}

# 워크플로우 사본. Workflow 도구는 작업 디렉터리 밖의 scriptPath 를 거부한다.
# 그래서 프로젝트 안(.harness/bin/, gitignore)에 사본을 두고 하네스 원본이 바뀌면 다시 쓴다.
workflow_copy_path() { printf '%s\n' "$PROJECT_HARNESS_DIR/bin/feature-loop.js"; }

ensure_workflow_copy() {
  local source="$HARNESS_HOME/workflows/feature-loop.js" copy
  copy="$(workflow_copy_path)"
  cmp -s "$source" "$copy" 2>/dev/null && return 0
  mkdir -p "$(dirname "$copy")"
  cp "$source" "$copy"
}
