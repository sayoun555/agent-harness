#!/usr/bin/env bash
#
# install.sh — agent-harness 한 줄 설치. 프로젝트 폴더에서 실행한다.
#
#   curl -fsSL https://raw.githubusercontent.com/sayoun555/agent-harness/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --preset spring      # init 옵션 전달
#
#   1) 하네스를 ~/.agent-harness 에 받는다 (있으면 업데이트)
#   2) 지금 폴더가 git 프로젝트면 하네스를 끼운다 (harness init)
#   3) claude CLI 가 있으면 이 프로젝트에만 플러그인을 설치한다 (--scope project)
#   다시 실행하면 업데이트다. 이미 있는 프로젝트 설정은 건드리지 않는다.
#
set -euo pipefail

readonly REPO_URL="https://github.com/sayoun555/agent-harness.git"
readonly MARKETPLACE_REPO="sayoun555/agent-harness"
readonly PLUGIN_ID="agent-harness@agent-harness"
readonly INSTALL_DIR="${AGENT_HARNESS_HOME:-$HOME/.agent-harness}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'agent-harness 설치: %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=() tool
  for tool in git jq bash; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  fail "필요한 도구가 없다: ${missing[*]} (macOS: brew install ${missing[*]})"
}

fetch_harness() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" pull -q --ff-only || fail "업데이트 실패 — $INSTALL_DIR 에 로컬 변경이 있는지 확인한다"
    say "✅ 하네스 업데이트: $INSTALL_DIR ($(git -C "$INSTALL_DIR" rev-parse --short HEAD))"
  else
    git clone -q "$REPO_URL" "$INSTALL_DIR"
    say "✅ 하네스 설치: $INSTALL_DIR"
  fi
}

project_root() { git rev-parse --show-toplevel 2>/dev/null || true; }

plug_into_project() {  # plug_into_project <root> <init 옵션...>
  local root="$1"; shift
  (cd "$root" && bash "$INSTALL_DIR/bin/harness" init "$@")
}

install_plugin_for_project() {  # install_plugin_for_project <root>
  local root="$1"
  if ! command -v claude >/dev/null 2>&1; then
    say "ℹ️  claude CLI 가 없다 — Claude Code 에서 이 프로젝트를 열면 플러그인 설치 안내가 뜬다"
    return 0
  fi
  (
    cd "$root"
    claude plugin marketplace add "$MARKETPLACE_REPO" --scope project >/dev/null 2>&1 || true
    claude plugin install "$PLUGIN_ID" --scope project >/dev/null 2>&1
  ) && say "✅ Claude Code 플러그인: 이 프로젝트에만 설치됨" \
    || say "⚠️  플러그인 자동 설치 실패 — Claude Code 에서 /plugin 으로 $PLUGIN_ID 를 설치한다"
}

main() {
  require_tools
  fetch_harness
  local root
  root="$(project_root)"
  if [[ -z "$root" ]]; then
    say ""
    say "지금 폴더는 git 프로젝트가 아니다. 하네스만 받아 두었다."
    say "쓰려는 프로젝트 폴더에서 같은 명령을 다시 실행한다."
    return 0
  fi
  plug_into_project "$root" "$@"
  install_plugin_for_project "$root"
  say ""
  say "끝. .harness/ · .claude/settings.json · .gitignore 를 커밋한 뒤, Claude Code 에서 말로 시킨다."
  say "  예) \"PLAN.md 보고 기능 목록 만들어 줘\"  →  \"루프 돌려 줘\""
}

main "$@"
