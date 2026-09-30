#!/usr/bin/env bash
#
# harness init — 이 프로젝트에 하네스를 끼운다. 여러 번 실행해도 안전하다(있는 파일은 건드리지 않음).
#
#   harness init [--preset 이름] [--no-plugin] [--no-git-hooks] [--ci] [--codex]
#
#   만드는 것
#     .harness/project.json    프로젝트 설정 (프리셋 + 덮어쓸 값)          ← 커밋
#     .harness/features.json   기능 원장                                  ← 커밋
#     .harness/bin/harness     이 머신의 하네스를 가리키는 shim           ← gitignore
#     .claude/settings.json    이 프로젝트에서만 플러그인을 켠다 (--no-plugin 으로 끔)  ← 커밋
#     git core.hooksPath       pre-commit·pre-push 게이트 (--no-git-hooks 로 끔)
#     .github/workflows/harness-gate.yml   CI 백스톱 (--ci)
#     .codex/hooks.json        Codex 어댑터 (--codex)
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/shim.sh"
source "$HARNESS_HOME/lib/mcp.sh"
require_commands git jq

readonly PLUGIN_ID="agent-harness@agent-harness"
readonly MARKETPLACE_NAME="agent-harness"
readonly MARKETPLACE_REPO="sayoun555/agent-harness"

PRESET=""
WANT_PLUGIN=1
WANT_GIT_HOOKS=1
WANT_CI=0
WANT_CODEX=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset)       PRESET="${2:-}"; shift ;;
      --no-plugin)    WANT_PLUGIN=0 ;;
      --no-git-hooks) WANT_GIT_HOOKS=0 ;;
      --ci)           WANT_CI=1 ;;
      --codex)        WANT_CODEX=1 ;;
      *)              die "$EXIT_USAGE" "알 수 없는 옵션: $1" ;;
    esac
    shift
  done
}

detect_preset() {
  if [[ -f "$PROJECT_ROOT/build.gradle.kts" || -f "$PROJECT_ROOT/build.gradle" \
        || -f "$PROJECT_ROOT/backend/build.gradle.kts" || -f "$PROJECT_ROOT/pom.xml" ]]; then
    echo spring
  elif [[ -f "$PROJECT_ROOT/package.json" ]] && jq -e '(.dependencies // {}) | has("next")' "$PROJECT_ROOT/package.json" >/dev/null 2>&1; then
    echo nextjs
  else
    echo generic
  fi
}

write_if_absent() {  # write_if_absent <path> <content> <label>
  if [[ -e "$1" ]]; then
    info "ℹ️  $3 이미 있음 — 그대로 둔다"
  else
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
    info "✅ $3 생성"
  fi
}

create_project_config() {
  local config
  config="$(jq -n --arg preset "$PRESET" '{
    _about: "프리셋 위에 이 프로젝트만의 값을 덮어쓴다. 객체는 깊게 병합, 배열은 교체. 해석 결과: harness config",
    preset: $preset,
    designDocsDir: "",
    build: {},
    approval: {}
  }')"
  write_if_absent "$PROJECT_CONFIG" "$config" ".harness/project.json (preset: $PRESET)"
}

create_feature_ledger() {
  write_if_absent "$PROJECT_HARNESS_DIR/features.json" '{"features": []}' ".harness/features.json"
}

create_shim() {
  ensure_shim || true
  info "✅ .harness/bin/harness → $HARNESS_HOME"
}

ensure_gitignored() {  # ensure_gitignored <pattern...>
  local gitignore="$PROJECT_ROOT/.gitignore" pattern
  for pattern in "$@"; do
    grep -qxF "$pattern" "$gitignore" 2>/dev/null && continue
    printf '%s\n' "$pattern" >> "$gitignore"
    info "✅ .gitignore += $pattern"
  done
}

# 플러그인을 전역이 아니라 이 프로젝트에서만 켠다. 다른 프로젝트에는 스킬도 훅도 로드되지 않는다.
#   형식은 `claude plugin install --scope project` 가 쓰는 것과 같다. 기존 설정은 보존한다.
enable_plugin_for_project() {
  [[ "$WANT_PLUGIN" -eq 1 ]] || return 0
  local settings="$PROJECT_ROOT/.claude/settings.json"
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || echo '{}' > "$settings"
  json_update "$settings" '
    .extraKnownMarketplaces[$market] = {source: {source: "github", repo: $repo}}
    | .enabledPlugins[$plugin] = true' \
    --arg market "$MARKETPLACE_NAME" --arg repo "$MARKETPLACE_REPO" --arg plugin "$PLUGIN_ID"
  info "✅ .claude/settings.json — 이 프로젝트에서만 $PLUGIN_ID 활성화"
}

install_git_hooks() {
  [[ "$WANT_GIT_HOOKS" -eq 1 ]] || return 0
  local current
  current="$(git -C "$PROJECT_ROOT" config --local core.hooksPath || true)"
  if [[ -n "$current" && "$current" != "$HARNESS_HOME/git-hooks" ]]; then
    info "⚠️  core.hooksPath 가 이미 '$current' 이다. 덮지 않는다. $HARNESS_HOME/git-hooks 의 훅을 그쪽에서 호출하라."
    return 0
  fi
  git -C "$PROJECT_ROOT" config --local core.hooksPath "$HARNESS_HOME/git-hooks"
  info "✅ git core.hooksPath → $HARNESS_HOME/git-hooks"
}

install_ci() {
  [[ "$WANT_CI" -eq 1 ]] || return 0
  write_if_absent "$PROJECT_ROOT/.github/workflows/harness-gate.yml" \
    "$(cat "$HARNESS_HOME/templates/harness-gate.yml")" ".github/workflows/harness-gate.yml (HARNESS_REPO 변수를 설정할 것)"
}

install_codex_adapter() {
  [[ "$WANT_CODEX" -eq 1 ]] || return 0
  write_if_absent "$PROJECT_ROOT/.codex/hooks.json" \
    "$(sed "s#__HARNESS_HOME__#$HARNESS_HOME#g" "$HARNESS_HOME/adapters/codex/hooks.json")" ".codex/hooks.json"
}

report_mcp() {  # 권하는 MCP 가 있으면 연결 상태를 알린다. 설치는 하지 않는다.
  has_mcp_recommendations || return 0
  info ""
  info "권하는 MCP (확인만 한다, 설치는 선택):"
  mcp_status_text "$(mcp_status_json)" | sed 's/^/  /' >&2
}

print_next_steps() {
  cat >&2 <<EOF

다음 단계
  1) 해석된 설정 확인:      .harness/bin/harness config
  2) 기능 추가:            .harness/bin/harness feature add --id ID --desc 설명 --acceptance '테스트 명령'
  3) .harness/ · .claude/settings.json · .gitignore 를 커밋한다 (팀원도 같은 설정을 받는다)
  4) Claude Code 를 이 프로젝트에서 열고 말로 시킨다: "PLAN.md 보고 기능 목록 만들어 줘", "루프 돌려 줘"
EOF
}

main() {
  parse_args "$@"
  [[ -z "$PRESET" ]] && PRESET="$(detect_preset)"
  [[ -f "$(preset_file_for "$PRESET")" ]] || die "$EXIT_USAGE" "프리셋이 없다: $PRESET (있는 것: $(ls "$HARNESS_HOME/presets" | grep -v '^_' | sed 's/\.json$//' | paste -sd ' ' -))"
  info "🧭 하네스 → $PROJECT_ROOT (preset: $PRESET)"
  create_project_config
  create_feature_ledger
  create_shim
  ensure_gitignored ".harness/bin/" ".harness/trace.jsonl" "$(jq -r '.state.progressFile' "$DEFAULTS_FILE")"
  enable_plugin_for_project
  install_git_hooks
  install_ci
  install_codex_adapter
  report_mcp
  print_next_steps
}

main "$@"
