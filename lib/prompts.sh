#!/usr/bin/env bash
#
# prompts.sh — 구현자·검증자 표준 프롬프트. source 전용.
#   lib/features.sh · lib/criteria.sh · lib/cli.sh 가 필요하다.
#
# 루프(workflows/feature-loop.js), 루프 없이 진행하는 스킬, 사람이 모두 같은 프롬프트를 쓴다.
# 에이전트는 이 프롬프트를 `harness prompt implement|review ID` 로 직접 받아 온다
# (다른 에이전트가 중계하지 않는다 — 긴 글이 중계 중에 잘리거나 바뀌지 않게).
#
# 들어가는 것: 기능 · 설계 문서 · 사람 결정 · 직전 실패 사유 · 품질 기준(공통 + 스택 + 프로젝트) · 규칙.
# 들어가지 않는 것: 작업 경위, 사람의 발언 인용, 스펙에 이미 있는 내용 (필요하면 읽을 절만 가리킨다).
#

readonly IMPLEMENT_MODES="sequential|isolated|shared"

# ── 구현자 ──────────────────────────────────────────────────────────
#   sequential  기본. 작업 트리에서 혼자 구현한다
#   isolated    커밋 운용 병렬. 자기 워크트리에서 구현하고 harness/wip-<id> 에 커밋한다
#   shared      커밋 없는 병렬. 같은 작업 트리에서 다른 기능과 동시에 구현한다

feature_brief_block() {  # feature_brief_block <id>
  jq -r --arg id "$1" '.features[] | select(.id == $id) |
    "기능 id: \(.id)\n설명: \(.description)\n완료 기준(acceptance): `\(.acceptance)`"
    + (if .designDoc then "\n설계 문서: \(.designDoc) — 이 기능에 해당하는 구성 요소·설계 결정·요구 원천 절만 찾아 읽고 그대로 따른다." else "" end)
    + (if (.decisions // []) | length > 0
       then "\n\n[사람이 내린 결정 — 그대로 따른다]\n" + ([.decisions[] | "- \(.question) → \(.answer)"] | join("\n"))
       else "" end)
    + (if (.attempts // 0) > 0 and (.lastFailure // "") != ""
       then "\n\n[직전 시도 실패 — 이번에 반드시 해결한다. 그 자리를 막는 수정이 아니라 원인을 구조로 해결한다] \(.lastFailure)"
            + (if (.lastFailureDetail // "") != "" then "\n```\n\(.lastFailureDetail)\n```" else "" end)
       else "" end)' "$(features_file)"
}

implement_rules() {
  cat <<'RULES'
규칙
- 이 기능에 필요한 만큼만 바꾼다. 요구되지 않은 추상화는 만들지 않는다 (Q7).
- 아래 품질 기준을 지킨다. 독립 검증자가 같은 기준의 대조표로 판정하고, 하나라도 어기면 반려된다.
- 끝내기 전에 acceptance 명령을 직접 실행해 통과를 확인한다.
- 테스트를 지우거나, assertion 을 줄이거나, skip 하지 않는다. 하네스가 감시한다.
- .harness/ 아래 파일을 편집하지 않는다. 판정과 기록은 하네스가 한다.

판단 요청
- 기능 설명·저장소 코드·설계 문서·위의 결정으로 정할 수 없는 설계 결정이 있으면, 추측으로 고르지 않는다.
  아무 파일도 바꾸지 말고 needsDecision=true 와 질문 하나(선택지 포함)를 돌려준다.
- 이름·파일 배치 같은 사소한 구현 세부는 기존 코드 관례를 따라 스스로 정한다. 묻지 않는다.
RULES
}

implement_mode_rules() {  # implement_mode_rules <id> <mode>
  case "$2" in
    sequential)
      echo "- git commit 하지 않는다." ;;
    isolated)
      cat <<RULES
- 너는 따로 떨어진 git 워크트리에 있다. 다른 기능이 동시에 다른 워크트리에서 구현되고 있다.
- 의존성(node_modules 등)이 없어 acceptance 를 못 돌리면 건너뛰어도 된다. 하네스가 메인 작업 트리에서 다시 검증한다.
- 구현을 마치면 아래 명령으로 네 브랜치에 커밋하고, branch 에 그 이름을 돌려준다.
\`\`\`bash
git checkout -q -b harness/wip-$1
git add -A -- . ':(exclude).harness'
git commit -q -m "wip($1)"
\`\`\`
RULES
      ;;
    shared)
      cat <<'RULES'
- git commit 하지 않는다.
- 같은 작업 트리에서 다른 기능이 동시에 구현되고 있다. 이 기능에 필요한 파일만 바꾸고, 다른 파일은 건드리지 않는다.
- 빌드·테스트는 잠금을 잡고 실행한다: `.harness/bin/harness lock run -- <명령>`
- 끝나면 filesChanged 에 바꾸거나 만든 파일을 빠짐없이 적는다. 하네스가 그 파일만으로 이 기능을 검증한다.
RULES
      ;;
  esac
}

implement_prompt() {  # implement_prompt <id> <mode>
  printf '너는 기능 하나를 구현하는 코더다. 이 저장소의 CLAUDE.md·AGENTS.md 규칙을 따른다.\n\n'
  feature_brief_block "$1"
  printf '\n'
  implement_rules
  implement_mode_rules "$1" "$2"
  printf '\n# 품질 기준 (검증 대조표 항목)\n\n'
  print_review_criteria
}

# emit_implement_prompt <id> [--mode M] [--json]
emit_implement_prompt() {
  local id="$1" mode prompt; shift
  mode="$(flag_value --mode "$@")"
  mode="${mode:-sequential}"
  [[ "$mode" =~ ^($IMPLEMENT_MODES)$ ]] || die "$EXIT_USAGE" "--mode 는 sequential · isolated · shared"
  prompt="$(implement_prompt "$id" "$mode")"
  emit "$(json_mode_of "$@")" "$(jq -cn --arg id "$id" --arg mode "$mode" --arg p "$prompt" '{id: $id, mode: $mode, prompt: $p}')" "$prompt"
}

# ── 검증자 ──────────────────────────────────────────────────────────
review_prompt_header() {  # review_prompt_header <id>
  cat <<HEADER
너는 기능 $1 을 구현하지 않은 독립 검증자다. 파일을 고치거나 커밋하지 않는다.
아래 프로토콜·기준·대조표 항목·변경을 읽고, 바뀐 파일은 직접 열어 확인한 뒤 대조표를 낸다.
루프 밖에서 혼자 실행할 때는 대조표 JSON 을 파일로 저장해 제출한다:
  .harness/bin/harness feature review $1 --verdict-file <그 파일>

HEADER
}

review_prompt() {  # review_prompt <id>
  review_prompt_header "$1"
  bash "$HARNESS_HOME/commands/review.sh" --context "$1"
}

emit_review_prompt() {  # emit_review_prompt <id> [--json]
  local id="$1" prompt; shift
  prompt="$(review_prompt "$id")"
  emit "$(json_mode_of "$@")" "$(jq -cn --arg id "$id" --arg p "$prompt" '{id: $id, prompt: $p}')" "$prompt"
}
