#!/usr/bin/env bash
#
# permissions.sh — 루프가 하네스 · 빌드 명령마다 사람에게 묻고 멈추지 않도록 Claude Code 허용 규칙을 넣는다. source 전용.
#
# 넣는 것은 사람이 정한 명령뿐이다:
#   - 하네스 자신 (.harness/bin/harness …)
#   - project.json 의 build 명령 (compileCommand · testCommand · formatCommand · formatCheckCommand)
# 원장의 acceptance 는 넣지 않는다 — 에이전트가 feature add 로 쓸 수 있어, 넣으면 에이전트가 제 권한을 넓히는 길이 된다.
# 그래서 이 일은 사람이 실행하는 init · harness permissions 에서만 하고, 루프 안(사전 점검 등)에서는 하지 않는다.
# 에이전트가 그때그때 치는 명령(mv · sed -i 등)도 알 수 없어 넣지 않는다 — 자동 모드(auto mode)로 돌린다.
#
# 쓰는 곳은 .claude/settings.local.json — 이 머신 · 이 사람의 결정이라 커밋하지 않는다(.git/info/exclude 에 넣는다).
# 사람이 적어 둔 deny · ask 규칙은 Claude Code 에서 allow 보다 앞서니 그대로 지켜진다.
#

readonly HARNESS_PERMISSION_RULE='Bash(.harness/bin/harness *)'

permission_settings_file() { printf '%s\n' "$PROJECT_ROOT/.claude/settings.local.json"; }

permission_source_commands() {
  cfg '.build.compileCommand'
  cfg '.build.testCommand'
  cfg '.build.formatCommand'
  cfg '.build.formatCheckCommand'
}

# permission_rules_json < 명령들 → {rules: [...], skipped: [...]}
#   Claude Code 는 && · || · ; · | 로 이은 명령을 나눠서 하나씩 규칙과 맞춘다. 그래서 나눠서 각각 넣는다.
#   cd 는 따로 넣지 않는다(작업 디렉터리 안 이동). 치환($( ) · ``)이 든 명령은 규칙으로 정확히 적을 수 없어 넣지 않는다.
permission_rules_json() {
  jq -Rsc --arg harness "$HARNESS_PERMISSION_RULE" '
    [ split("\n")[] | select(test("\\S")) ] as $commands
    | [ $commands[] | select(test("\\$\\(|`")) ] as $skipped
    | [ $commands[] | select(test("\\$\\(|`") | not)
        | splits("\\s*(?:&&|\\|\\||;|\\|)\\s*")
        | sub("^\\s+"; "") | sub("\\s+$"; "")
        | select(length > 0 and (test("^cd(\\s|$)") | not))
        | "Bash(\(.))" ] as $rules
    | {rules: ([$harness] + $rules | unique), skipped: ($skipped | unique)}'
}

settings_is_tracked() { git -C "$PROJECT_ROOT" ls-files --error-unmatch "$1" >/dev/null 2>&1; }

# 커밋 대상이 아니게 한다 — 공유 설치에서도 트리를 더럽히지 않아야 루프 사전 점검이 통과한다
exclude_settings_from_git() {
  local exclude
  git -C "$PROJECT_ROOT" check-ignore -q .claude/settings.local.json 2>/dev/null && return 0
  exclude="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 0
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' ".claude/settings.local.json" >> "$exclude"
}

# permissions_sync → {result: "ok"|"tracked", added: [...], skipped: [...], file}
#   있는 규칙은 지우지 않고 없는 것만 더한다(사람이 넣은 규칙 · 옛 명령 규칙을 건드리지 않는다).
#   커밋된 settings.local.json 은 건드리지 않는다(팀 설정을 이 머신의 결정으로 바꾸지 않는다).
permissions_sync() {
  local file wanted added
  file="$(permission_settings_file)"
  wanted="$(permission_source_commands | permission_rules_json)"
  if settings_is_tracked "$file"; then
    jq -c --arg file "$file" '{result: "tracked", added: [], skipped, file: $file}' <<<"$wanted"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  [[ -s "$file" ]] || echo '{}' > "$file"
  exclude_settings_from_git
  added="$(jq -c --argjson wanted "$wanted" '$wanted.rules - (.permissions.allow // [])' "$file")"
  [[ "$added" != "[]" ]] && json_update "$file" '.permissions.allow = ((.permissions.allow // []) + $added)' --argjson added "$added"
  jq -c --argjson added "$added" --arg file "$file" '{result: "ok", added: $added, skipped, file: $file}' <<<"$wanted"
}
