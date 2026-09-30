#!/usr/bin/env bash
#
# harness review — 의미 적대자.
#   harness review --context 기능ID   적대자에게 줄 컨텍스트만 출력 (루프 워크플로우가 쓴다, LLM 호출 없음)
#   harness review [파일...]          LLM CLI(codex·claude 자동 감지)로 검토 (git 훅·Codex 용)
#                                     파일을 안 주면 staged 파일
#   HARNESS_REVIEW_BLOCK=1           위반 보고 시 exit 1 (기본은 보고만)
#   HARNESS_LLM=codex|claude         CLI 강제 지정
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/features.sh"
require_commands git jq
project_is_plugged_in || { info "review: 이 프로젝트에 하네스가 없다 — 건너뜀"; exit 0; }
cd "$PROJECT_ROOT"

# 재귀 가드: 적대자 LLM 안의 훅이 또 review 를 부르지 않게 한다.
[[ "${HARNESS_REVIEWING:-0}" == "1" ]] && { info "review: 재귀 가드 — 건너뜀"; exit 0; }

print_stack_criteria() {
  echo "## 스택 판단 기준"
  cfg_lines '.review.guidance' | sed 's/^/- /'
  echo
  echo "## 스택 footgun (각각 점검)"
  load_config
  jq -r '(.review.footguns // [])[] | "- [\(.sev)] \(.id): \(.check)"' <<<"$RESOLVED_CONFIG"
  echo
  local docs
  docs="$(cfg '.designDocsDir')"
  [[ -n "$docs" ]] && { echo "## 설계 문서"; echo "- $docs/ 아래. 관련 절만 grep 으로 찾아 대조한다."; echo; }
  return 0
}

print_feature_context() {  # print_feature_context <id>
  local id="$1"
  require_features_file; require_feature "$id"
  echo "## 검토 대상 기능"
  jq -r '"- id: \(.id)\n- 설명: \(.description)\n- acceptance: \(.acceptance)"' <<<"$(feature_json "$id")"
  echo
  echo "## 바뀐 파일 (HEAD 대비)"
  changed_files | sed 's/^/- /'
  echo
  echo "## diff (HEAD 대비, 추적 중인 파일)"
  echo '```diff'
  git diff HEAD -- . ':(exclude).harness/features.json' | head -n 600
  echo '```'
  print_new_files
}

print_new_files() {  # git diff 에 안 나오는 신규(untracked) 파일 내용
  local file
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    printf '\n## 신규 파일: %s\n```\n' "$file"
    head -n 200 "$file"
    echo '```'
  done < <(git ls-files --others --exclude-standard)
}

print_context() {
  cat "$HARNESS_HOME/review/protocol.md"
  echo
  print_stack_criteria
  print_feature_context "$1"
}

detect_llm_cli() {
  [[ -n "${HARNESS_LLM:-}" ]] && { echo "$HARNESS_LLM"; return; }
  command -v codex >/dev/null 2>&1 && { echo codex; return; }
  command -v claude >/dev/null 2>&1 && { echo claude; return; }
  return 0
}

target_files() {
  if [[ $# -gt 0 ]]; then printf '%s\n' "$@"; else git diff --cached --name-only --diff-filter=ACM; fi
}

build_file_prompt() {  # build_file_prompt <files...>
  cat "$HARNESS_HOME/review/protocol.md"
  echo
  print_stack_criteria
  echo "## 검토 대상 파일"
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    printf '\n----- %s -----\n' "$file"
    cat "$file"
  done
  echo
  echo "위반이 있으면 줄마다 '[high|med|low] 파일 — 무엇·기준·고칠 방법'. 없으면 정확히 '위반 없음' 한 줄."
}

run_llm_review() {
  local llm files=()
  llm="$(detect_llm_cli)"
  [[ -z "$llm" ]] && { info "review: LLM CLI(codex·claude)가 없다 — 의미 검토 건너뜀"; exit 0; }
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(target_files "$@")
  [[ ${#files[@]} -eq 0 ]] && { echo "✅ review: 검토할 파일 없음"; exit 0; }

  local prompt output
  prompt="$(mktemp)"
  build_file_prompt "${files[@]}" > "$prompt"
  info "🔎 review: $llm 로 ${#files[@]}개 파일 검토"
  case "$llm" in
    codex)  output="$(HARNESS_REVIEWING=1 codex exec - < "$prompt" 2>&1 || true)" ;;
    claude) output="$(HARNESS_REVIEWING=1 claude -p < "$prompt" 2>&1 || true)" ;;
    *)      rm -f "$prompt"; die "$EXIT_USAGE" "지원하지 않는 LLM CLI: $llm" ;;
  esac
  rm -f "$prompt"
  echo "$output"

  grep -q '위반 없음' <<<"$output" && exit 0
  if grep -qiE '^\[(high|med)\]' <<<"$output"; then
    info "⚠️ review: 의미 위반 보고됨"
    [[ "${HARNESS_REVIEW_BLOCK:-0}" == "1" ]] && exit "$EXIT_GATE_FAILED"
  fi
  exit 0
}

if [[ "${1:-}" == "--context" ]]; then
  [[ -n "${2:-}" ]] || die "$EXIT_USAGE" "사용: harness review --context 기능ID"
  print_context "$2"
else
  run_llm_review "$@"
fi
