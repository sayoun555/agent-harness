#!/usr/bin/env bash
#
# changes.sh — "무엇이 바뀌었나" 를 한곳에서 판단한다. source 전용.
#
# 모든 비교는 git 트리 두 개의 비교다.
#   기준 트리  커밋으로 운용하면 HEAD 의 트리, 커밋 없이 운용하면(또는 커밋이 아직 없으면) 기준선 트리
#   현재 트리  작업 트리 전체(추적·스테이징·untracked)를 임시 인덱스로 찍은 트리
# 트리와 blob 은 git 객체일 뿐 커밋·브랜치가 아니다. 히스토리에 흔적을 남기지 않고, 커밋 0개 저장소에서도 된다.
#
# 하네스 자신의 상태(.harness/)는 비교 대상이 아니다.
# 범위(scope): 경로 목록을 주면 그 경로만 본다. 같은 트리에서 여러 기능을 동시에 구현할 때 기능별로 나눠 본다.
#

readonly HARNESS_PATHSPEC=':(exclude).harness'

baseline_file() { printf '%s\n' "$PROJECT_HARNESS_DIR/baseline.json"; }

empty_tree() { git hash-object -t tree /dev/null; }

has_head_commit() { git rev-parse --verify --quiet HEAD >/dev/null; }

# ── 현재 트리 ───────────────────────────────────────────────────────
# 진짜 인덱스를 복사해 시작하면 바뀌지 않은 파일은 다시 해시하지 않는다(stat 캐시).
with_temp_index() {  # with_temp_index <명령...> — GIT_INDEX_FILE 을 임시 인덱스로 두고 실행
  local index real code=0
  index="$(mktemp)"
  real="$(git rev-parse --git-path index)"
  if [[ -f "$real" ]]; then cp "$real" "$index"; else rm -f "$index"; fi
  GIT_INDEX_FILE="$index" "$@" || code=$?
  rm -f "$index"
  return "$code"
}

snapshot_worktree() {
  git rm -r -q --cached --ignore-unmatch -- .harness >/dev/null
  git add -A -- . "$HARNESS_PATHSPEC"
  git write-tree
}

current_tree() { with_temp_index snapshot_worktree; }

# ── 기준선 ──────────────────────────────────────────────────────────
baseline_tree() {
  local tree
  tree="$(jq -r '.tree // empty' "$(baseline_file)" 2>/dev/null || true)"
  [[ -n "$tree" ]] && git cat-file -e "$tree^{tree}" 2>/dev/null && printf '%s\n' "$tree"
  return 0
}

has_baseline() { [[ -n "$(baseline_tree)" ]]; }

write_baseline() {  # write_baseline <tree>
  mkdir -p "$(dirname "$(baseline_file)")"
  jq -n --arg tree "$1" --arg at "$(utc_now)" '{tree: $tree, savedAt: $at}' > "$(baseline_file)"
}

# 범위를 주면 기존 기준선에서 그 경로만 지금 상태로 바꾼다. 다른 기능의 진행 중 변경은 기준선에 섞지 않는다.
snapshot_paths_over() {  # snapshot_paths_over <tree> <paths...>
  local tree="$1"; shift
  git read-tree "$tree"
  git add -A -- "$@"
  git write-tree
}

baseline_save() {  # baseline_save [paths...]
  local tree
  if [[ $# -eq 0 ]] || ! has_baseline; then
    tree="$(current_tree)"
  else
    tree="$(with_temp_index snapshot_paths_over "$(baseline_tree)" "$@")"
  fi
  write_baseline "$tree"
}

# ── 기준 트리 ───────────────────────────────────────────────────────
uses_head_as_base() { auto_commit_enabled && has_head_commit; }

base_tree() {
  if uses_head_as_base; then git rev-parse 'HEAD^{tree}'; return; fi
  if has_baseline; then baseline_tree; return; fi
  empty_tree
}

base_label() {
  if uses_head_as_base; then echo "HEAD"
  elif has_baseline; then echo "기준선($(jq -r .savedAt "$(baseline_file)"))"
  else echo "빈 트리(기준선 없음)"; fi
}

# ── 비교 ────────────────────────────────────────────────────────────
# 경로를 주지 않으면 전체. 주면 그 경로만.
changed_files() {  # changed_files [paths...] → 추가·수정·이름 변경 (삭제 제외)
  git diff --name-only --diff-filter=ACMR "$(base_tree)" "$(current_tree)" -- "$@"
}

deleted_files() {  # deleted_files [paths...]
  git diff --name-only --diff-filter=D "$(base_tree)" "$(current_tree)" -- "$@"
}

print_change_diff() {  # print_change_diff [paths...] — 새 파일·삭제·바이너리 포함
  git diff --no-color "$(base_tree)" "$(current_tree)" -- "$@"
}

base_files() { git ls-tree -r --name-only "$(base_tree)"; }

base_content() {  # base_content <path> → 기준 트리에서의 내용 (없으면 빈 출력)
  git show "$(base_tree):$1" 2>/dev/null || true
}

# ── 되돌리기 (커밋 없이 운용할 때의 보관) ────────────────────────────
patch_against_base() {  # patch_against_base [paths...] → git apply 로 되살릴 수 있는 패치
  git diff --binary "$(base_tree)" "$(current_tree)" -- "$@"
}

restore_from_base() {  # restore_from_base [paths...] — 범위 안의 작업 트리를 기준 트리로 되돌린다
  local base current added
  base="$(base_tree)"
  current="$(current_tree)"
  added="$(git diff --name-only --diff-filter=A "$base" "$current" -- "$@")"
  with_temp_index checkout_tree_paths "$base" "$current" "$@"
  [[ -n "$added" ]] && while IFS= read -r path; do rm -f -- "$path"; done <<<"$added"
  return 0
}

checkout_tree_paths() {  # checkout_tree_paths <base> <current> [paths...] — 수정·삭제된 파일을 기준 내용으로
  local base="$1" current="$2" paths; shift 2
  paths="$(git diff --name-only --diff-filter=MDT "$base" "$current" -- "$@")"
  [[ -z "$paths" ]] && return 0
  git read-tree "$base"
  while IFS= read -r path; do git checkout-index -f -- "$path"; done <<<"$paths"
}
