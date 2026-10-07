#!/usr/bin/env bash
#
# harness baseline — 커밋 없이 운용할 때의 비교 기준.
#   save [경로...]   지금 작업 트리를 기준선으로 (경로를 주면 그 경로만 갱신)
#   show            기준선 정보와 지금 바뀐 파일
#
#   기준선은 git 트리 객체 하나다. 커밋·브랜치를 만들지 않는다. .harness/baseline.json 에 적힌다.
#   diff · test-guard · 위험 파일 판정이 커밋 대신 이 기준선과 비교한다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/changes.sh"
require_commands git jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

cmd_save() {
  baseline_save "$@"
  echo "📸 기준선 저장: $(base_label) — 트리 $(baseline_tree | cut -c1-12)"
}

cmd_show() {
  echo "기준: $(base_label)"
  has_baseline && echo "기준선 트리: $(baseline_tree)"
  echo "바뀐 파일:"
  changed_files | sed 's/^/  /'
  deleted_files | sed 's/^/  (삭제) /'
}

case "${1:-}" in
  save) shift; cmd_save "$@" ;;
  show) cmd_show ;;
  *)    die "$EXIT_USAGE" "사용: harness baseline <save [경로...] | show>" ;;
esac
