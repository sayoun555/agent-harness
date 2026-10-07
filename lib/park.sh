#!/usr/bin/env bash
#
# park.sh — 커밋으로 운용할 때의 보관소(브랜치). source 전용. 정책은 lib/record.sh 가 고른다.
#
# 왜: 커밋 노드는 작업 트리 전체를 담는다. 승인 대기·막힘·판단 대기 기능의 변경이
#     작업 트리에 남으면, 다음 기능이 통과할 때 그 변경이 승인 없이 함께 커밋된다.
#
# 어떻게: 변경을 harness/<기능ID> 브랜치의 커밋으로 만들고(브랜치 전환 없이),
#         작업 트리를 HEAD 로 되돌린다. 기능 원장의 변경은 보관하지 않고 그대로 둔다.
#         루프는 깨끗한 트리에서 시작하므로(preflight) 되돌리는 변경은 루프가 만든 것뿐이다.
#

parked_branch() { printf 'harness/%s\n' "$1"; }

ledger_pathspec() { printf ':(exclude)%s\n' "$(cfg '.state.featuresFile')"; }

has_changes_outside_ledger() {
  [[ -n "$(git status --porcelain --untracked-files=all -- . "$(ledger_pathspec)")" ]]
}

# 원장을 보존한 채 작업 트리를 HEAD 로 되돌린다 (무시된 파일은 건드리지 않는다)
restore_clean_tree_keeping_ledger() {
  local ledger backup
  ledger="$(features_file)"
  backup="$(mktemp)"
  cp "$ledger" "$backup"
  git reset -q --hard HEAD
  git clean -fdq
  cp "$backup" "$ledger"
  rm -f "$backup"
}

# park_changes <id> <commit-message> → 보관한 브랜치 이름 (변경이 없으면 빈 출력)
park_changes() {
  local id="$1" message="$2" tree commit branch
  has_changes_outside_ledger || return 0
  git add -A -- . "$(ledger_pathspec)"
  tree="$(git write-tree)"
  commit="$(git commit-tree "$tree" -p HEAD -m "$message")"
  branch="$(parked_branch "$id")"
  git branch -f "$branch" "$commit"
  restore_clean_tree_keeping_ledger
  printf '%s\n' "$branch"
}

# unpark_changes <branch> — 보관한 변경을 작업 트리로 되가져온다 (커밋하지 않음)
#   HEAD 가 그사이 앞으로 갔으면 충돌할 수 있다. 충돌하면 되돌리고 1 을 반환한다.
UNPARK_ERROR=""
unpark_changes() {
  local branch="$1" log
  log="$(mktemp)"
  if git cherry-pick --no-commit "$branch" > "$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  UNPARK_ERROR="$(tail -n 20 "$log")"
  rm -f "$log"
  git cherry-pick --abort >/dev/null 2>&1 || true
  restore_clean_tree_keeping_ledger
  return 1
}
