#!/usr/bin/env bash
#
# features.sh — 기능 원장(.harness/features.json)의 읽기와 상태 전이. source 전용.
#
# 상태 전이는 이 파일의 함수로만 일어난다. 에이전트는 원장을 직접 편집하지 못한다
# (pre-edit 훅이 막는다). 그래서 "통과"는 하네스가 acceptance 를 실행해 본 결과로만 기록된다.
#
#   pending ─verify─▶ verified ─review --approve─▶ reviewed ─record─▶ passing
#      ▲                │  review --reject             │  └─ 위험 파일 ─▶ awaiting-approval ─approve─▶ passing
#      └── 실패(한도 전) ┴──────────────────────────────┘
#   실패가 한도에 닿거나 같은 실패가 반복되면 ──▶ blocked (reset 으로만 복귀)
#   구현자가 스스로 정할 수 없는 설계 결정을 만나면 ──▶ needs-decision (decide 로 답하면 pending)
#   통과하지 못하고 떠나는 기능의 변경은 치워서 보관된다 (lib/record.sh — 커밋 운용이면 브랜치, 아니면 패치)
#

readonly STATUS_PENDING="pending"
readonly STATUS_VERIFIED="verified"
readonly STATUS_REVIEWED="reviewed"
readonly STATUS_PASSING="passing"
readonly STATUS_AWAITING="awaiting-approval"
readonly STATUS_BLOCKED="blocked"
readonly STATUS_NEEDS_DECISION="needs-decision"

features_file() { project_path "$(cfg '.state.featuresFile')"; }

require_features_file() {
  local file
  file="$(features_file)"
  [[ -f "$file" ]] || die "$EXIT_CONFIG" "기능 원장이 없다: $file (harness init 또는 harness feature add)"
}

feature_json() {  # feature_json <id> → 기능 객체(JSON) 또는 빈 출력
  jq -c --arg id "$1" '.features[] | select(.id == $id)' "$(features_file)"
}

require_feature() {
  [[ -n "$(feature_json "$1")" ]] || die "$EXIT_USAGE" "그런 기능이 없다: $1"
}

feature_field() {  # feature_field <id> <field>
  jq -r --arg id "$1" --arg f "$2" '.features[] | select(.id == $id) | .[$f] // empty' "$(features_file)"
}

require_status() {  # require_status <id> <허용 상태...>
  local id="$1" current allowed; shift
  current="$(feature_field "$id" status)"
  for allowed in "$@"; do [[ "$current" == "$allowed" ]] && return 0; done
  die "$EXIT_USAGE" "기능 $id 의 상태가 '$current' 이다. 이 명령은 [$*] 상태에서만 가능하다."
}

next_pending_id() {
  jq -r --arg s "$STATUS_PENDING" '[.features[] | select(.status == $s)][0].id // empty' "$(features_file)"
}

set_feature_fields() {  # set_feature_fields <id> <json-object>
  json_update "$(features_file)" \
    '(.features[] | select(.id == $id)) |= (. + $patch)' \
    --arg id "$1" --argjson patch "$2"
}

# result_json <id> <result> <reason> [detail] — 명령 결과를 루프가 읽는 한 줄 JSON 으로
result_json() {
  jq -cn --arg id "$1" --arg result "$2" --arg reason "$3" --arg detail "${4:-}" \
    --arg status "$(feature_field "$1" status)" --argjson attempts "$(feature_field "$1" attempts)" \
    '{id: $id, result: $result, status: $status, attempts: $attempts, reason: $reason, detail: $detail}'
}

# 실패 메시지에서 숫자(시간·줄 번호 등)를 지워 "같은 실패"를 안정적으로 비교한다.
failure_fingerprint() {
  printf '%s' "$1" | sed 's/[0-9][0-9]*/N/g' | shasum | cut -c1-12
}

# record_failure <id> <reason> <detail> → 새 상태를 stdout 으로
record_failure() {
  local id="$1" reason="$2" detail="$3"
  local attempts repeats previous fingerprint status
  local max_attempts repeat_limit prior_attempts prior_repeats
  max_attempts="$(cfg '.loop.maxAttempts')"
  repeat_limit="$(cfg '.loop.repeatLimit')"

  prior_attempts="$(feature_field "$id" attempts)"
  attempts=$(( ${prior_attempts:-0} + 1 ))
  previous="$(feature_field "$id" lastFailureFingerprint)"
  fingerprint="$(failure_fingerprint "$reason$detail")"
  repeats=1   # 같은 실패가 연속으로 몇 번째인가 (처음 보는 실패 = 1)
  if [[ "$fingerprint" == "$previous" ]]; then
    prior_repeats="$(feature_field "$id" repeats)"
    repeats=$(( ${prior_repeats:-0} + 1 ))
  fi

  status="$STATUS_PENDING"
  (( attempts >= max_attempts || repeats >= repeat_limit )) && status="$STATUS_BLOCKED"

  set_feature_fields "$id" "$(jq -cn \
    --arg status "$status" --arg reason "$reason" --arg detail "$detail" --arg fp "$fingerprint" \
    --argjson attempts "$attempts" --argjson repeats "$repeats" \
    '{status: $status, attempts: $attempts, repeats: $repeats,
      lastFailure: $reason, lastFailureDetail: $detail, lastFailureFingerprint: $fp}')"
  printf '%s\n' "$status"
}

# 세션 시작 주입용 한 단락 요약 (원장이 없으면 빈 출력)
features_summary() {
  local file
  file="$(features_file)"
  [[ -f "$file" ]] || return 0
  jq -r '
    def ids(s): [.features[] | select(.status == s) | .id] | join(", ");
    "기능 원장: 전체 \(.features | length) · 통과 \([.features[] | select(.status == "passing")] | length)"
    + " · 남음 \([.features[] | select(.status == "pending" or .status == "verified" or .status == "reviewed")] | length)"
    + (if ids("blocked") != "" then "\n  막힘(사람 확인 필요): " + ids("blocked") else "" end)
    + (if ids("awaiting-approval") != "" then "\n  승인 대기: " + ids("awaiting-approval") else "" end)
    + ([.features[] | select(.status == "needs-decision") | "\n  판단 필요: \(.id) — \(.question)"] | join(""))
    + (([.features[] | select(.status == "pending")][0]) as $n
       | if $n then "\n  다음: \($n.id) — \($n.description)" else "" end)
  ' "$file"
}
