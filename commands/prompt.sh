#!/usr/bin/env bash
#
# harness prompt — 구현자·검증자 표준 프롬프트.
#   implement ID [--mode sequential|isolated|shared] [--json]
#   review ID [--json]
#
#   루프·스킬·사람이 모두 이 명령에서 같은 프롬프트를 받는다. 에이전트가 직접 실행해 받아 간다.
#   기능 · 설계 문서 · 사람 결정 · 직전 실패 사유 · 품질 기준(공통 + 스택 + .harness/criteria/)이 자동으로 들어간다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/criteria.sh"
source "$HARNESS_HOME/lib/prompts.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

role="${1:-}"; id="${2:-}"
[[ "$role" =~ ^(implement|review)$ && -n "$id" ]] || die "$EXIT_USAGE" "사용: harness prompt <implement|review> ID [--mode M] [--json]"
shift 2
require_features_file; require_feature "$id"
case "$role" in
  implement) emit_implement_prompt "$id" "$@" ;;
  review)    emit_review_prompt "$id" "$@" ;;
esac
