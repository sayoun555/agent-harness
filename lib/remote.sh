#!/usr/bin/env bash
#
# remote.sh — 원격(클라우드 · 운영 DB · 배포)을 바꾸는 셸 명령을 알아본다. source 전용.
#
# 에이전트는 코드를 바꾸고 로컬에서 검증한다. 클라우드 자원을 만들거나 지우고, 운영 DB 스키마를 바꾸고,
# 배포하는 것은 되돌리기 어렵고 돈이 든다(C2). 그래서 이런 명령은 훅이 사람에게 묻는다.
# 사람이 없는 실행(헤드리스 루프)에서는 물을 수 없으니 실행되지 않는다.
#
# 명령 목록은 설정 guard.remoteCommands 에 있다: [{pattern, why}].
# pattern 은 명령 이름부터 쓰는 ERE 다. 앞에 "명령의 시작" 경계를 붙여 맞춘다(체인 · 서브셸 안도 잡는다).
#

# 명령 자리: 줄 처음 · ; & | ( ` 뒤. 그 앞에 변수 대입이나 감싸는 명령(sudo · env · npx …)과 그 옵션이 와도 된다.
# 인자 속 단어(grep terraform apply 파일)는 명령 자리가 아니라서 걸리지 않는다.
readonly COMMAND_WRAPPER='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|sudo|env|time|nohup|exec|command|xargs|npx|bunx|pnpx|(pnpm|yarn|npm)[[:space:]]+(dlx|exec))'
readonly COMMAND_START="(^|[;&|(\`])[[:space:]]*(${COMMAND_WRAPPER}([[:space:]]+-[^[:space:]]+)*[[:space:]]+)*"

remote_command_reason() {  # remote_command_reason <셸 명령> → 걸리면 이유 한 줄 (아니면 빈 출력)
  local command="$1" pattern why
  while IFS=$'\t' read -r pattern why; do
    [[ -z "$pattern" ]] && continue
    [[ "$command" =~ ${COMMAND_START}${pattern} ]] && { printf '%s\n' "$why"; return 0; }
  done < <(load_config; jq -r '(.guard.remoteCommands // [])[] | "\(.pattern)\t\(.why)"' <<<"$RESOLVED_CONFIG")
  return 0
}
