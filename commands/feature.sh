#!/usr/bin/env bash
#
# harness feature — 기능 원장. 루프의 상태와 종료 조건이 여기 있다.
#
#   조회     list [--json] · next [--json] [--limit N] · status [--json]
#            brief ID [--mode M] [--json]                           harness prompt implement 와 같다
#   준비     add --id ID --desc 설명 --acceptance 명령 [--design 문서] [--decisions-json JSON]
#            claim ID --files 경로,경로                            같은 트리 병렬에서 기능이 맡은 파일
#            preflight [--json]                                    시작 전 점검 (커밋 없이 운용하면 기준선 저장)
#   판정     verify ID [--json]                                    컴파일 → 테스트 약화 → acceptance (→ 실행 렌즈). 통과면 verified
#            review ID --verdict-json JSON | --verdict-file 파일     독립 검증자의 대조표. 승인·반려는 하네스가 정한다
#            review ID --approve [--reason 근거] | --reject --reason 이유   사람이 직접 판정할 때
#            reject ID --reason 이유                               review --reject 와 같다
#            audit [--json]                                        passing 기능의 acceptance 재실행 + 검증 후 변경 다시 열기
#            drift [--json] [--reopen]                             검증을 통과한 뒤 바뀐 파일이 있는 기능
#   기록     record ID [--json]                                    reviewed → passing (commit 은 같은 명령)
#            approve ID                                            위험 파일 승인 → passing
#            adopt ID 브랜치 [--json]                              커밋 운용 병렬: 워크트리 결과 가져오기
#   사람     ask ID --question 질문 · decide ID --answer 답 · reset ID
#
#   상태: pending → verified → reviewed → passing
#         막힘(blocked) · 승인 대기(awaiting-approval) · 판단 대기(needs-decision) 로 떠나는 기능의 변경은
#         치워서 보관한다. 커밋 운용이면 harness/<ID> 브랜치, 아니면 .harness/parked/<ID>.patch.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/trace.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/changes.sh"
source "$HARNESS_HOME/lib/source.sh"
source "$HARNESS_HOME/lib/size.sh"
source "$HARNESS_HOME/lib/risk.sh"
source "$HARNESS_HOME/lib/park.sh"
source "$HARNESS_HOME/lib/record.sh"
source "$HARNESS_HOME/lib/mcp.sh"
source "$HARNESS_HOME/lib/criteria.sh"
source "$HARNESS_HOME/lib/verdict.sh"
source "$HARNESS_HOME/lib/prompts.sh"
source "$HARNESS_HOME/lib/drift.sh"
source "$HARNESS_HOME/lib/runtime.sh"
for part in query prepare gate record human; do
  source "$HARNESS_HOME/commands/feature/$part.sh"
done
require_commands git jq shasum
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list|next|status) require_features_file; "cmd_$sub" "$@" ;;
    brief|add|claim|preflight|verify|review|reject|audit|drift|record|approve|adopt|ask|decide|reset) "cmd_$sub" "$@" ;;
    commit)           cmd_record "$@" ;;
    *) die "$EXIT_USAGE" "사용: harness feature <list|next|status|brief|add|claim|preflight|verify|review|reject|audit|drift|record|approve|adopt|ask|decide|reset>" ;;
  esac
}

main "$@"
