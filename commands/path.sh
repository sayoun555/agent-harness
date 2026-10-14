#!/usr/bin/env bash
#
# harness path <home|project|workflow> — 하네스 경로.
#   project 는 프로젝트 루트다. 루프 인자 projectRoot 로 넘기면 세션의 작업 디렉터리와 상관없이 그 루트에서 명령을 실행한다.
#   workflow 는 프로젝트 안의 사본 경로다(없거나 낡았으면 지금 다시 쓴다).
#   Workflow 도구가 작업 디렉터리 밖의 스크립트를 거부하기 때문이다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/shim.sh"

case "${1:-}" in
  home) printf '%s\n' "$HARNESS_HOME" ;;
  project)
    project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
    printf '%s\n' "$PROJECT_ROOT"
    ;;
  workflow)
    project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
    ensure_workflow_copy
    workflow_copy_path
    ;;
  *) die "$EXIT_USAGE" "사용: harness path <home|project|workflow>" ;;
esac
