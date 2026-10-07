#!/usr/bin/env bash
#
# harness init — 이 프로젝트에 하네스를 끼운다. 여러 번 실행해도 안전하다(있는 파일은 건드리지 않음).
#
#   harness init [--preset 이름] [--local] [--no-commit] [--no-plugin] [--no-git-hooks] [--ci] [--ci-loop] [--codex]
#
#   --local      추적 대상 파일을 하나도 건드리지 않는다. 하네스는 이 머신의 이 클론에만 있다.
#                무시 목록은 .git/info/exclude, 플러그인은 .claude/settings.local.json, 설계 문서는 .harness/design/
#   --no-commit  하네스가 커밋·브랜치를 만들지 않는다 (loop.autoCommit: false)
#
#   만드는 것
#     .harness/project.json    프로젝트 설정 (프리셋 + 덮어쓸 값)          ← 커밋
#     .harness/features.json   기능 원장                                  ← 커밋
#     .harness/bin/harness     이 머신의 하네스를 가리키는 shim           ← gitignore
#     .claude/settings.json    이 프로젝트에서만 플러그인을 켠다 (--no-plugin 으로 끔)  ← 커밋
#     git core.hooksPath       pre-commit·pre-push 게이트 (--no-git-hooks 로 끔)
#     .github/workflows/harness-gate.yml   CI 백스톱 (--ci)
#     .github/workflows/harness-loop.yml   일정·원장 변경 때 루프를 돌려 PR 로 (--ci-loop)
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
LOCAL_ONLY=0
NO_COMMIT=0
WANT_PLUGIN=1
WANT_GIT_HOOKS=1
WANT_CI=0
WANT_CI_LOOP=0
WANT_CODEX=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset)       PRESET="${2:-}"; shift ;;
      --local)        LOCAL_ONLY=1 ;;
      --no-commit)    NO_COMMIT=1 ;;
      --no-plugin)    WANT_PLUGIN=0 ;;
      --no-git-hooks) WANT_GIT_HOOKS=0 ;;
      --ci)           WANT_CI=1 ;;
      --ci-loop)      WANT_CI_LOOP=1 ;;
      --codex)        WANT_CODEX=1 ;;
      *)              die "$EXIT_USAGE" "알 수 없는 옵션: $1" ;;
    esac
    shift
  done
  if [[ "$LOCAL_ONLY" -eq 1 && $((WANT_CI + WANT_CI_LOOP)) -gt 0 ]]; then
    die "$EXIT_USAGE" "--local 은 추적 대상 파일을 만들지 않는다 — --ci · --ci-loop 와 함께 쓸 수 없다"
  fi
  return 0
}

# ── 설치 흔적이 남는 곳 ─────────────────────────────────────────────
# 공유 설치는 팀이 같은 설정을 받도록 커밋 대상 파일에, 로컬 설치는 이 클론에만 남는 파일에 쓴다.
ignore_list_file() {
  if [[ "$LOCAL_ONLY" -eq 1 ]]; then git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-path info/exclude
  else printf '%s\n' "$PROJECT_ROOT/.gitignore"; fi
}

plugin_settings_file() {
  if [[ "$LOCAL_ONLY" -eq 1 ]]; then printf '%s\n' "$PROJECT_ROOT/.claude/settings.local.json"
  else printf '%s\n' "$PROJECT_ROOT/.claude/settings.json"; fi
}

relative_to_root() { printf '%s\n' "${1#"$PROJECT_ROOT"/}"; }

# 무시할 경로: 로컬 설치는 하네스 전체, 공유 설치는 머신·실행마다 다른 것만
ignored_paths() {
  if [[ "$LOCAL_ONLY" -eq 1 ]]; then
    printf '%s\n' ".harness/" ".claude/settings.local.json"
    return
  fi
  printf '%s\n' ".harness/bin/" ".harness/trace.jsonl" ".harness/figma/" ".harness/runs/" ".harness/loop.lock" \
    ".harness/build.lock/" ".harness/baseline.json" ".harness/parked/" "$(jq -r '.state.progressFile' "$DEFAULTS_FILE")"
}

# ── 스택 감지 ───────────────────────────────────────────────────────
# 빌드 파일 이름만 보면 Android 와 Spring 이 둘 다 Gradle 이라 구분되지 않는다. 내용을 본다.
project_has_file() {  # project_has_file <이름> — 깊이 4 안에 그 이름의 파일이 있나
  find "$PROJECT_ROOT" -maxdepth 4 -name "$1" -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/build/*' \
    -print 2>/dev/null | grep -q .
}

build_files_mention() {  # build_files_mention <정규식> — 루트·모듈의 Gradle·Maven 파일
  local file
  for file in "$PROJECT_ROOT"/build.gradle* "$PROJECT_ROOT"/*/build.gradle* "$PROJECT_ROOT"/pom.xml \
              "$PROJECT_ROOT"/gradle/libs.versions.toml; do
    [[ -f "$file" ]] && grep -qE "$1" "$file" && return 0
  done
  return 1
}

package_json_depends_on() {  # package_json_depends_on <패키지>
  [[ -f "$PROJECT_ROOT/package.json" ]] \
    && jq -e --arg p "$1" '((.dependencies // {}) + (.devDependencies // {})) | has($p)' "$PROJECT_ROOT/package.json" >/dev/null 2>&1
}

detect_preset() {
  if project_has_file AndroidManifest.xml || build_files_mention 'com\.android\.(application|library)'; then
    echo android
  elif build_files_mention 'org\.springframework\.boot'; then
    echo spring
  elif package_json_depends_on next; then
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
  config="$(jq -n --arg preset "$PRESET" --argjson local "$LOCAL_ONLY" --argjson noCommit "$NO_COMMIT" '{
    _about: "프리셋 위에 이 프로젝트만의 값을 덮어쓴다. 객체는 깊게 병합, 배열은 교체. 해석 결과: harness config",
    preset: $preset,
    designDocsDir: "",
    build: {},
    approval: {}
  }
  + (if $local == 1 then {design: {docsDir: ".harness/design"}} else {} end)
  + (if $noCommit == 1 then {loop: {autoCommit: false}} else {} end)')"
  write_if_absent "$PROJECT_CONFIG" "$config" ".harness/project.json (preset: $PRESET)"
}

create_feature_ledger() {
  write_if_absent "$PROJECT_HARNESS_DIR/features.json" '{"features": []}' ".harness/features.json"
}

create_shim() {
  ensure_shim || true
  info "✅ .harness/bin/harness → $HARNESS_HOME"
}

ensure_ignored() {
  local file pattern
  file="$(ignore_list_file)"
  mkdir -p "$(dirname "$file")"
  while IFS= read -r pattern; do
    grep -qxF "$pattern" "$file" 2>/dev/null && continue
    printf '%s\n' "$pattern" >> "$file"
    info "✅ $(relative_to_root "$file") += $pattern"
  done < <(ignored_paths)
}

# 플러그인을 전역이 아니라 이 프로젝트에서만 켠다. 다른 프로젝트에는 스킬도 훅도 로드되지 않는다.
#   형식은 `claude plugin install --scope project|local` 이 쓰는 것과 같다. 기존 설정은 보존한다.
enable_plugin_for_project() {
  [[ "$WANT_PLUGIN" -eq 1 ]] || return 0
  local settings
  settings="$(plugin_settings_file)"
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || echo '{}' > "$settings"
  json_update "$settings" '
    .extraKnownMarketplaces[$market] = {source: {source: "github", repo: $repo}}
    | .enabledPlugins[$plugin] = true' \
    --arg market "$MARKETPLACE_NAME" --arg repo "$MARKETPLACE_REPO" --arg plugin "$PLUGIN_ID"
  info "✅ $(relative_to_root "$settings") — 이 프로젝트에서만 $PLUGIN_ID 활성화"
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

install_ci_loop() {
  [[ "$WANT_CI_LOOP" -eq 1 ]] || return 0
  write_if_absent "$PROJECT_ROOT/.github/workflows/harness-loop.yml" \
    "$(cat "$HARNESS_HOME/templates/harness-loop.yml")" ".github/workflows/harness-loop.yml (ANTHROPIC_API_KEY 비밀과 HARNESS_REPO 변수를 설정할 것)"
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

print_commit_step() {
  if [[ "$LOCAL_ONLY" -eq 1 ]]; then
    echo "  3) 커밋할 것이 없다 — 하네스 파일은 모두 git 에서 무시된다 (.git/info/exclude)"
  else
    echo "  3) .harness/project.json · .harness/features.json · .claude/settings.json · .gitignore 를 커밋한다 (팀원도 같은 설정을 받는다)"
  fi
}

print_next_steps() {
  {
    echo
    echo "다음 단계"
    echo "  1) 해석된 설정 확인:      .harness/bin/harness config"
    echo "  2) 기능 추가:            .harness/bin/harness feature add --id ID --desc 설명 --acceptance '테스트 명령'"
    print_commit_step
    echo "  4) Claude Code 를 이 프로젝트에서 열고 말로 시킨다: \"PLAN.md 보고 기능 목록 만들어 줘\", \"루프 돌려 줘\""
    [[ "$NO_COMMIT" -eq 1 ]] && echo "  ※ 커밋 없이 운용한다: 기록은 원장과 기준선에만 남는다"
    echo
    echo "비용 줄이기 (서브에이전트는 시작할 때 세션의 CLAUDE.md·메모리·플러그인·MCP 목록을 모두 싣는다)"
    echo "  - 하네스 작업은 이 저장소에서 연 Claude Code 세션으로 한다"
    echo "  - 이 프로젝트에서 쓰지 않는 플러그인·MCP 는 끈다:  /plugin · claude mcp list"
  } >&2
  return 0
}

main() {
  parse_args "$@"
  [[ -z "$PRESET" ]] && PRESET="$(detect_preset)"
  [[ -f "$(preset_file_for "$PRESET")" ]] || die "$EXIT_USAGE" "프리셋이 없다: $PRESET (있는 것: $(ls "$HARNESS_HOME/presets" | grep -v '^_' | sed 's/\.json$//' | paste -sd ' ' -))"
  info "🧭 하네스 → $PROJECT_ROOT (preset: $PRESET)"
  create_project_config
  create_feature_ledger
  create_shim
  ensure_ignored
  enable_plugin_for_project
  install_git_hooks
  install_ci
  install_ci_loop
  install_codex_adapter
  report_mcp
  print_next_steps
}

main "$@"
