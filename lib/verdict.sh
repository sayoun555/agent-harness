#!/usr/bin/env bash
#
# verdict.sh — 독립 검증자의 대조표를 결정론으로 판정한다. source 전용. lib/criteria.sh 가 필요하다.
#
# 반려 기준은 셋이다.
#   REQ  요구 위반     기능 설명·acceptance·설계 결정·요구 원천이 정한 것을 지키지 않았다
#   REG  동작 회귀     이미 되던 동작을 깨뜨렸다
#   그 외 기준 ID      프로젝트 품질 기준(공통 Q · 스택 K/A … · 프로젝트 P …)을 어겼다
#
# 대조표 형식 (검증자가 낸다):
#   {"checks": [{"id": "Q2", "result": "kept|violated|na", "where": "파일:줄", "note": "…"}], "summary": "…"}
#
# 판정:  대조표에 빠진 항목이 있으면 반려(건너뛰지 못하게) · violated 가 하나라도 있으면 반려 · 아니면 승인.
# LLM 이 "승인"이라고 말하는 것만으로는 통과하지 않는다.
#

readonly FIXED_REVIEW_ITEMS=$'REQ\t요구 위반 없음 (기능 설명·acceptance·설계 결정·요구 원천)\nREG\t기존 동작 회귀 없음'

# 검증자가 채워야 할 항목: "ID<TAB>제목"
review_checklist() {
  printf '%s\n' "$FIXED_REVIEW_ITEMS"
  review_criterion_index
}

VERDICT_DECISION=""   # approve | reject
VERDICT_REASON=""

valid_verdict_shape() {  # valid_verdict_shape <json>
  jq -e '(.checks | type == "array")
         and all(.checks[]; (.id | type == "string") and (.result | IN("kept", "violated", "na")))' <<<"$1" >/dev/null 2>&1
}

missing_checklist_ids() {  # missing_checklist_ids <json> → 대조표에 없는 항목 ID (쉼표)
  jq -r --argjson want "$(review_checklist | cut -f1 | lines_to_json)" \
    '[.checks[].id] as $have | [$want[] | select(. as $id | $have | index($id) | not)] | join(", ")' <<<"$1"
}

violations_text() {  # violations_text <json> → "ID 위치 — 설명" 을 "; " 로
  jq -r '[.checks[] | select(.result == "violated")
          | "\(.id) \(.where // "위치 없음") — \(.note // "")"] | join("; ")' <<<"$1"
}

# evaluate_verdict <json> → VERDICT_DECISION, VERDICT_REASON
evaluate_verdict() {
  local verdict="$1" missing violations
  if ! valid_verdict_shape "$verdict"; then
    VERDICT_DECISION=reject
    VERDICT_REASON="검증 대조표 형식이 틀렸다 (checks[].id · result=kept|violated|na)"
    return
  fi
  missing="$(missing_checklist_ids "$verdict")"
  if [[ -n "$missing" ]]; then
    VERDICT_DECISION=reject
    VERDICT_REASON="검증 대조표에 빠진 항목: $missing"
    return
  fi
  violations="$(violations_text "$verdict")"
  if [[ -n "$violations" ]]; then
    VERDICT_DECISION=reject
    VERDICT_REASON="$violations"
    return
  fi
  VERDICT_DECISION=approve
  VERDICT_REASON="$(jq -r '.summary // "대조표 전 항목 지킴 또는 해당 없음"' <<<"$verdict")"
}
