#!/usr/bin/env bash
#
# harness figma [컴포넌트이름] — Figma 시각 충실도 렌즈 (UI 프로젝트 전용).
#   렌더된 컴포넌트를 Figma 디자인과 측정 비교한다. 엔진: UIMatch (@uimatch/cli).
#   무겁다(브라우저 렌더 + 렌더 서버 필요). 편집마다가 아니라 컴포넌트 완성 뒤·pre-push·CI·수동으로.
#
#   설정 figma.fileKey · figma.profile · figma.components[{name, node, url, selector}]
#   components 가 비면 아무것도 하지 않는다(백엔드 프로젝트면 정상).
#   엔진이나 FIGMA_ACCESS_TOKEN 이 없으면 안내만 하고 통과한다(개발 흐름을 막지 않는다).
#   충실도 미달이면 exit 1, 없는 컴포넌트 이름이면 exit 2.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

ONLY="${1:-}"
load_config
COMPONENTS="$(jq -c '(.figma.components // [])[]' <<<"$RESOLVED_CONFIG")"
FILE_KEY="$(cfg '.figma.fileKey')"
PROFILE="$(cfg '.figma.profile')"
OUT_DIR="$(project_path "$(cfg '.figma.outDir')")"

skip() { echo "ℹ️ figma: $*"; exit 0; }

uimatch_command() {
  if command -v uimatch >/dev/null 2>&1; then echo uimatch; return; fi
  if command -v npx >/dev/null 2>&1 && npx --no-install uimatch version >/dev/null 2>&1; then echo "npx --no-install uimatch"; return; fi
  return 0
}

compare_component() {  # compare_component <엔진> <컴포넌트 JSON> → 통과면 0
  local engine="$1" row="$2" name node url selector args
  name="$(jq -r .name <<<"$row")"
  node="$(jq -r .node <<<"$row")"
  url="$(jq -r .url <<<"$row")"
  selector="$(jq -r '.selector // empty' <<<"$row")"
  args=(compare "figma=$FILE_KEY:$node" "story=$url" "profile=$PROFILE" "outDir=$OUT_DIR/$name")
  [[ -n "$selector" ]] && args+=("selector=$selector")
  echo "🎨 [$name] Figma $FILE_KEY:$node ↔ $url"
  # shellcheck disable=SC2086  # 엔진 명령은 "npx --no-install uimatch" 처럼 여러 단어일 수 있다
  if $engine "${args[@]}"; then
    echo "   ✅ [$name] 디자인 충실도 통과 ($PROFILE)"
    return 0
  fi
  echo "   ⛔ [$name] 디자인과 어긋남 — $OUT_DIR/$name 의 보고서대로 간격·색·요소를 고친다"
  return 1
}

[[ -z "$COMPONENTS" ]] && skip "figma.components 가 비어 있다 — 시각 검증 대상 아님"
[[ -n "$FILE_KEY" ]] || skip "figma.fileKey 가 없다 — project.json 에 Figma 파일 키를 적는다"
ENGINE="$(uimatch_command)"
[[ -n "$ENGINE" ]] || skip "UIMatch 가 없다 — 설치(선택): npm i -D @uimatch/cli playwright && npx playwright install chromium"
[[ -n "${FIGMA_ACCESS_TOKEN:-}" ]] || skip "FIGMA_ACCESS_TOKEN 이 없다 — export FIGMA_ACCESS_TOKEN=figd_... 뒤 다시 실행"

ran=0
failed=0
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  [[ -n "$ONLY" && "$(jq -r .name <<<"$row")" != "$ONLY" ]] && continue
  ran=$((ran + 1))
  compare_component "$ENGINE" "$row" || failed=$((failed + 1))
done <<<"$COMPONENTS"

[[ "$ran" -eq 0 && -n "$ONLY" ]] && die "$EXIT_USAGE" "figma.components 에 '$ONLY' 가 없다"
[[ "$failed" -gt 0 ]] && { echo "❌ figma: ${ran}개 중 ${failed}개가 디자인과 어긋난다"; exit "$EXIT_GATE_FAILED"; }
echo "✅ figma: ${ran}개 컴포넌트 모두 디자인 충실"
