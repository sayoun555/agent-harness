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

# 진행 중 = 이 작업 트리에 기록 전 변경이 있을 수 있는 기능. jq 정의이고, 소유권(lib/record.sh)과 drift(lib/drift.sh)가 같이 쓴다.
#   verified · reviewed, 또는 pending 인데 이 트리에서 구현을 시작한 것(구현 프롬프트를 받았고 isolated 가 아님).
#   기록·보관·reset 되거나 drift 로 다시 열리면 implementedUnder 를 지운다 — 그 뒤로는 진행 중이 아니다.
readonly JQ_IN_FLIGHT='def in_flight:
  .status == "verified" or .status == "reviewed"
  or (.status == "pending" and .implementedUnder != null and .implementedUnder.mode != "isolated");'

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

# 고를 수 있는 기능 = pending 이고 앞 기능(dependsOn)이 모두 passing. jq 정의이고 `.features as $all` 아래에서 쓴다.
#   앞 기능이 승인 대기 · 막힘이면 그 변경은 보관돼 트리에 없다. 그 위에서 구현하면 승인할 때 충돌한다(현장 보고 H7).
#   그래서 앞 기능이 기록될 때까지 고르지 않는다. 기다리는 기능은 요약 · 보고서에 "대기" 로 나온다.
readonly JQ_READY='def ready($all):
  .status == "pending"
  and ((.dependsOn // []) | all(. as $d | $all | any(.id == $d and .status == "passing")));
def waiting_for($all):
  [(.dependsOn // [])[] as $d | $all[] | select(.id == $d and .status != "passing") | "\(.id)(\(.status))"];'

next_pending_id() {
  jq -r "$JQ_READY"' .features as $all | [.features[] | select(ready($all))][0].id // empty' "$(features_file)"
}

# dependency_problem <id> <dependsOn JSON 배열> → 문제가 있으면 한 줄 (없으면 빈 출력)
#   없는 기능 · 자기 자신 · 순환이면 그 기능은 영영 고를 수 없다. 조용히 멈춰 있지 않게 등록할 때 막는다.
dependency_problem() {
  jq -r --arg id "$1" --argjson deps "$2" '
    (.features | map({key: .id, value: (.dependsOn // [])}) | from_entries) as $graph
    | ($graph + {($id): $deps}) as $g
    | def closure: . as $s | ($s + [$s[] | ($g[.] // [])[]] | unique) as $n | if $n == $s then $s else ($n | closure) end;
    ([$deps[] | select(. as $d | $graph | has($d) | not)]) as $missing
    | if ($deps | index($id)) then "자기 자신에 의존할 수 없다: \($id)"
      elif ($missing | length) > 0 then "그런 기능이 없다: \($missing | join(", "))"
      elif ($deps | unique | closure | index($id)) then "순환 의존이 된다: \($id) → \($deps | join(", ")) → … → \($id)"
      else empty end' "$(features_file)"
}

# --depends-on a,b → JSON 배열 (빈 값이면 [])
depends_on_json() { split_commas "$1" | lines_to_json; }

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
  printf '%s' "$1" | sed 's/[0-9][0-9]*/N/g' | "$SHA1_COMMAND" | cut -c1-12
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

current_head() { git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || true; }

# 판단 대기 질문이 나온 뒤 쌓인 커밋 수 {ID: N} (N > 0 만). 원장만 바꾼 커밋은 세지 않는다 — 루프 끝 원장 커밋은 상황 변화가 아니다
stale_questions_json() {
  local ledger id head n out='{}'
  [[ -f "$(features_file)" ]] || { echo '{}'; return 0; }
  ledger="$(cfg '.state.featuresFile')"
  while IFS=$'\t' read -r id head; do
    [[ -n "$id" && -n "$head" ]] || continue
    n="$(git -C "$PROJECT_ROOT" rev-list --count "$head..HEAD" -- . ":(exclude)$ledger" 2>/dev/null || echo 0)"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && out="$(jq -c --arg id "$id" --argjson n "$n" '. + {($id): $n}' <<<"$out")"
  done < <(jq -r '.features[] | select(.status == "needs-decision" and (.askedAt.head // "") != "") | "\(.id)\t\(.askedAt.head)"' "$(features_file)")
  printf '%s\n' "$out"
}

# 낡았을 수 있는 질문에 붙이는 꼬리 (jq 정의, $stale = stale_questions_json)
readonly JQ_QUESTION_AGE='def question_age($stale):
  if ($stale[.id] // 0) > 0
  then " (질문은 \(.askedAt.head) 시점 — 그 뒤 커밋 \($stale[.id])개. 전제가 지금도 맞는지 확인하고 답한다)" else "" end;'

# 세션 시작 주입용 한 단락 요약 (원장이 없으면 빈 출력)
features_summary() {
  local file
  file="$(features_file)"
  [[ -f "$file" ]] || return 0
  jq -r --argjson stale "$(stale_questions_json)" "$JQ_READY$JQ_QUESTION_AGE"'
    .features as $all |
    def ids(s): [.features[] | select(.status == s) | .id] | join(", ");
    "기능 원장: 전체 \(.features | length) · 통과 \([.features[] | select(.status == "passing")] | length)"
    + " · 남음 \([.features[] | select(.status == "pending" or .status == "verified" or .status == "reviewed")] | length)"
    + (if ids("blocked") != "" then "\n  막힘(사람 확인 필요): " + ids("blocked") else "" end)
    + (if ids("awaiting-approval") != "" then "\n  승인 대기: " + ids("awaiting-approval") else "" end)
    + ([.features[] | select(.status == "needs-decision") | "\n  판단 필요: \(.id) — \(.question)\(question_age($stale))"] | join(""))
    + ([.features[] | select(.status == "pending" and (ready($all) | not)) | "\n  대기(앞 기능): \(.id) ← \(waiting_for($all) | join(", "))"] | join(""))
    + (([.features[] | select(ready($all))][0]) as $n
       | if $n then "\n  다음: \($n.id) — \($n.description)" else "" end)
  ' "$file"
}
