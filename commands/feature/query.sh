#!/usr/bin/env bash
#
# feature 조회 — list · next · status · brief. commands/feature.sh 가 source 한다.
#

cmd_list() {
  if has_flag --json "$@"; then jq -c '.features' "$(features_file)"; return; fi
  jq -r '.features[] | "\(.status)\t\(.id)\t\(.description)"' "$(features_file)" | column -t -s $'\t'
}

cmd_next() {
  local id limit
  limit="$(flag_value --limit "$@")"
  if [[ -n "$limit" ]]; then
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_USAGE" "--limit 은 1 이상의 정수"
    jq -c --argjson n "$limit" --arg s "$STATUS_PENDING" '[.features[] | select(.status == $s)][:$n]' "$(features_file)"
    return
  fi
  id="$(next_pending_id)"
  if has_flag --json "$@"; then
    [[ -n "$id" ]] && feature_json "$id" || echo '{}'
    return
  fi
  [[ -n "$id" ]] && echo "$id" || true
}

cmd_status() {
  local counts
  counts="$(jq -c '.features | group_by(.status) | map({(.[0].status): length}) | add // {}' "$(features_file)")"
  if has_flag --json "$@"; then echo "$counts"; else jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$counts"; fi
}

# ── 구현자 지시문 ────────────────────────────────────────────────────
# 루프(workflows/feature-loop.js)와 루프 없이 진행하는 스킬이 같은 지시문을 쓴다. 지시문은 여기 한 곳에만 있다.
#   --mode sequential  기본. 작업 트리에서 혼자 구현한다
#   --mode isolated    커밋 운용 병렬. 자기 워크트리에서 구현하고 harness/wip-<id> 에 커밋한다
#   --mode shared      커밋 없는 병렬. 같은 작업 트리에서 다른 기능과 동시에 구현한다

brief_feature_block() {  # brief_feature_block <id>
  jq -r --arg id "$1" '.features[] | select(.id == $id) |
    "기능 id: \(.id)\n설명: \(.description)\n완료 기준(acceptance): `\(.acceptance)`"
    + (if .designDoc then "\n설계 문서: \(.designDoc) — 먼저 읽고, 이 기능에 해당하는 구성 요소와 설계 결정을 그대로 따른다." else "" end)
    + (if (.decisions // []) | length > 0
       then "\n\n[사람이 내린 결정 — 그대로 따른다]\n" + ([.decisions[] | "- \(.question) → \(.answer)"] | join("\n"))
       else "" end)
    + (if (.attempts // 0) > 0 and (.lastFailure // "") != ""
       then "\n\n[직전 시도 실패 — 이번에 반드시 해결한다. 그 자리를 막는 수정이 아니라 원인을 구조로 해결한다] \(.lastFailure)"
            + (if (.lastFailureDetail // "") != "" then "\n```\n\(.lastFailureDetail)\n```" else "" end)
       else "" end)' "$(features_file)"
}

brief_rules() {
  cat <<EOF

규칙
- 이 기능에 필요한 만큼만 바꾼다. 요구되지 않은 추상화는 만들지 않는다.
- 검증자는 이 저장소의 코드 기준으로 판정한다. 먼저 \`.harness/bin/harness review --criteria\` 로 기준을 본다.
- 끝내기 전에 acceptance 명령을 직접 실행해 통과를 확인한다.
- 테스트를 지우거나, assertion 을 줄이거나, skip 하지 않는다. 하네스가 감시한다.
- .harness/ 아래 파일을 편집하지 않는다. 판정과 기록은 하네스가 한다.

판단 요청
- 기능 설명·저장소 코드·설계 문서·위의 결정으로 정할 수 없는 설계 결정이 있으면, 추측으로 고르지 않는다.
  아무 파일도 바꾸지 말고 needsDecision=true 와 질문 하나(선택지 포함)를 돌려준다.
- 이름·파일 배치 같은 사소한 구현 세부는 기존 코드 관례를 따라 스스로 정한다. 묻지 않는다.
EOF
}

brief_mode_rules() {  # brief_mode_rules <id> <mode>
  case "$2" in
    sequential)
      echo "- git commit 하지 않는다." ;;
    isolated)
      cat <<EOF
- 너는 따로 떨어진 git 워크트리에 있다. 다른 기능이 동시에 다른 워크트리에서 구현되고 있다.
- 의존성(node_modules 등)이 없어 acceptance 를 못 돌리면 건너뛰어도 된다. 하네스가 메인 작업 트리에서 다시 검증한다.
- 구현을 마치면 아래 명령으로 네 브랜치에 커밋하고, branch 에 그 이름을 돌려준다.
\`\`\`bash
git checkout -q -b harness/wip-$1
git add -A -- . ':(exclude).harness'
git commit -q -m "wip($1)"
\`\`\`
EOF
      ;;
    shared)
      cat <<EOF
- git commit 하지 않는다.
- 같은 작업 트리에서 다른 기능이 동시에 구현되고 있다. 이 기능에 필요한 파일만 바꾸고, 다른 파일은 건드리지 않는다.
- 빌드·테스트는 잠금을 잡고 실행한다: \`.harness/bin/harness lock run -- <명령>\`
- 끝나면 filesChanged 에 바꾸거나 만든 파일을 빠짐없이 적는다. 하네스가 그 파일만으로 이 기능을 검증한다.
EOF
      ;;
  esac
}

cmd_brief() {
  local id="${1:-}"; shift || true
  local mode prompt
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature brief ID [--mode sequential|isolated|shared] [--json]"
  require_features_file; require_feature "$id"
  mode="$(flag_value --mode "$@")"
  mode="${mode:-sequential}"
  [[ "$mode" =~ ^(sequential|isolated|shared)$ ]] || die "$EXIT_USAGE" "--mode 는 sequential · isolated · shared"
  prompt="$(printf '너는 기능 하나를 구현하는 코더다. 이 저장소의 CLAUDE.md·AGENTS.md 규칙을 따른다.\n%s\n%s\n%s\n' \
    "$(brief_feature_block "$id")" "$(brief_rules)" "$(brief_mode_rules "$id" "$mode")")"
  emit "$(json_mode_of "$@")" "$(jq -cn --arg id "$id" --arg mode "$mode" --arg p "$prompt" '{id: $id, mode: $mode, prompt: $p}')" "$prompt"
}
