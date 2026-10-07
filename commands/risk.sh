#!/usr/bin/env bash
#
# harness risk — 기준 트리 대비 바뀐 파일 중 사람 승인이 필요한 것 (approval.riskGlobs).
#   harness risk [--json]
#
set -euo pipefail
source "$HARNESS_HOME/lib/common.sh"
source "$HARNESS_HOME/lib/changes.sh"
source "$HARNESS_HOME/lib/risk.sh"
require_commands git jq
project_is_plugged_in || { info "risk: 이 프로젝트에 하네스가 없다 — 건너뜀"; exit 0; }

RISKY="$(risky_changed_files)"
if [[ "${1:-}" == "--json" ]]; then
  jq -Rsc 'split("\n") | map(select(length > 0)) | {riskyFiles: .}' <<<"$RISKY"
elif [[ -z "$RISKY" ]]; then
  echo "✅ risk: 승인이 필요한 변경 없음"
else
  echo "🔐 risk: 사람 승인이 필요한 변경"
  sed 's/^/   /' <<<"$RISKY"
fi
