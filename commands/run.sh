#!/usr/bin/env bash
#
# harness run ID [--json] — 실행 렌즈를 한 번 돌린다 (설치 → 실행 → 화면 캡처 → 로그 → 정리).
#   runtime.enabled 가 true 면 feature verify 의 마지막 게이트로도 돈다.
#   결과는 .harness/runs/<ID>/<시각>/ 에 남고, 검증 컨텍스트에 스크린샷 경로와 로그가 들어간다.
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/cli.sh"
source "$HARNESS_HOME/lib/features.sh"
source "$HARNESS_HOME/lib/runtime.sh"
require_commands jq
project_is_plugged_in || die "$EXIT_CONFIG" "이 프로젝트에 하네스가 없다 (harness init)"
cd "$PROJECT_ROOT"

id="${1:-}"; shift || true
[[ -n "$id" ]] || die "$EXIT_USAGE" "사용: harness run ID [--json]"
require_features_file; require_feature "$id"
runtime_enabled || info "ℹ️ runtime.enabled 가 false 다 — 수동으로 한 번 돌린다"

code=0
run_runtime_lens "$id" "$(date -u +%Y%m%dT%H%M%SZ)" || code=$?
emit "$(json_mode_of "$@")" \
  "$(jq -cn --arg dir "${RUNTIME_DIR#"$PROJECT_ROOT"/}" --argjson ok "$([[ $code -eq 0 ]] && echo true || echo false)" --arg f "$RUNTIME_FAILED_STEP" '{ok: $ok, dir: $dir, failedStep: $f}')" \
  "$([[ $code -eq 0 ]] && echo "✅ run $id: 실행 확인 → ${RUNTIME_DIR#"$PROJECT_ROOT"/}" || echo "⛔ run $id: $RUNTIME_FAILED_STEP 실패 → ${RUNTIME_DIR#"$PROJECT_ROOT"/}")"
exit "$([[ $code -eq 0 ]] && echo 0 || echo "$EXIT_GATE_FAILED")"
