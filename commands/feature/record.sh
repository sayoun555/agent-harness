#!/usr/bin/env bash
#
# feature 기록 — record(commit) · approve · adopt. commands/feature.sh 가 source 한다.
# 커밋할지 원장만 쓸지는 lib/record.sh 가 정한다. 여기서는 묻지 않는다.
#

cmd_record() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature record ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_REVIEWED"
  require_sole_owner "$id"
  local json_mode risky problem
  json_mode="$(json_mode_of "$@")"

  problem="$(unrecordable_reason "$id")"
  if [[ -n "$problem" ]]; then reopen_feature "$id" record "$json_mode" "$problem"; return; fi

  scope_of "$id"

  risky="$(risky_changed_files ${SCOPE[@]+"${SCOPE[@]}"})"
  if [[ -n "$risky" ]]; then
    set_feature_fields "$id" "$(jq -cn --arg files "$risky" '{status: "awaiting-approval", riskyFiles: ($files | split("\n"))}')"
    set_aside_changes "$id" "awaiting-approval"
    trace_add record "$(jq -cn --arg id "$id" '{feature: $id, result: "awaiting-approval"}')"
    emit "$json_mode" "$(result_json "$id" awaiting-approval "위험 파일 변경 — 사람 승인 필요" "$risky")" \
      "🔐 record $id: 위험 파일 변경 → 승인 대기 (harness feature approve $id)"$'\n'"$risky"
    return 0
  fi

  if ! record_passing "$id" "" "$STATUS_BLOCKED"; then
    set_feature_fields "$id" "$(jq -cn --arg d "$RECORD_ERROR" '{lastFailure: "git 커밋 실패 (훅 차단 등)", lastFailureDetail: $d}')"
    set_aside_changes "$id" "commit-failed"
    trace_add record "$(jq -cn --arg id "$id" '{feature: $id, result: "commit-failed"}')"
    emit "$json_mode" "$(result_json "$id" commit-failed "git 커밋 실패 (훅 차단 등)" "$RECORD_ERROR")" \
      "⛔ record $id: git 커밋 실패 → blocked (변경은 $(parked_ref "$id") 에 보관)"$'\n'"$RECORD_ERROR"
    return "$EXIT_GATE_FAILED"
  fi
  trace_add record "$(jq -cn --arg id "$id" --arg ref "$RECORD_REF" '{feature: $id, result: "passing", ref: $ref}')"
  emit "$json_mode" "$(result_json "$id" passing "기록됨 ($RECORD_REF)")" "✅ record $id → passing ($RECORD_REF)"
}

# ── 사람 승인 ───────────────────────────────────────────────────────
cmd_approve() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature approve ID"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_AWAITING"
  require_sole_owner "$id"
  # 커밋 운용에서는 승인 커밋에 남의 변경이 섞이지 않도록 깨끗한 트리가 필요하다.
  if auto_commit_enabled && has_changes_outside_ledger; then
    die "$EXIT_USAGE" "작업 트리가 깨끗하지 않다 — 승인 전에 커밋하거나 stash 한다"
  fi
  bring_back_changes "$id" \
    || die "$EXIT_GATE_FAILED" "보관한 변경($(parked_ref "$id"))을 지금 트리에 적용하다 충돌했다. 직접 병합하거나 reset 후 다시 구현한다."$'\n'"$BRING_BACK_ERROR"
  adopt_patch_scope "$id"
  if ! record_passing "$id" " (사람 승인)" "$STATUS_AWAITING"; then
    restore_clean_tree_keeping_ledger
    die "$EXIT_GATE_FAILED" "git 커밋 실패 — awaiting-approval 유지, 변경은 $(parked_ref "$id") 에 그대로 있다"$'\n'"$RECORD_ERROR"
  fi
  drop_parked "$id"
  trace_add approve "$(jq -cn --arg id "$id" --arg ref "$RECORD_REF" '{feature: $id, result: "passing", ref: $ref}')"
  echo "✅ approve $id → passing ($RECORD_REF)"
}

# ── 커밋 운용 병렬: 워크트리 구현 결과 가져오기 ─────────────────────────
# 구현자는 자기 워크트리에서 브랜치에 커밋한다. 게이트·검증·기록은 이 작업 트리에서 하나씩 한다.
# 커밋 없이 운용할 때의 병렬은 같은 트리에서 claim 으로 범위를 나눈다(adopt 를 쓰지 않는다).
adopt_failure() {  # adopt_failure <id> <json-mode> <result> <reason> <detail>
  local id="$1" status
  status="$(record_failure "$id" "$4" "$5")"
  set_aside_if_blocked "$id" "$status"
  trace_add adopt "$(jq -cn --arg id "$id" --arg r "$3" --arg s "$status" '{feature: $id, result: $r, status: $s}')"
  emit "$2" "$(result_json "$id" "$3" "$4" "$5")" "⛔ adopt $id: $4 → $status"
  return "$EXIT_GATE_FAILED"
}

cmd_adopt() {
  local id="${1:-}" branch="${2:-}"; shift 2 || true
  local json_mode
  [[ -n "$id" && -n "$branch" ]] || die "$EXIT_USAGE" "사용: feature adopt ID 브랜치"
  auto_commit_enabled || die "$EXIT_USAGE" "커밋 없이 운용할 때는 adopt 를 쓰지 않는다 — 같은 트리 병렬은 feature claim 으로 범위를 나눈다"
  require_features_file; require_feature "$id"
  require_status "$id" "$STATUS_PENDING"
  json_mode="$(json_mode_of "$@")"
  has_changes_outside_ledger && die "$EXIT_USAGE" "작업 트리가 깨끗하지 않다 — 가져오기 전에 이전 기능이 기록돼야 한다"

  git rev-parse --verify --quiet "$branch^{commit}" >/dev/null \
    || { adopt_failure "$id" "$json_mode" missing "구현 결과 없음" "브랜치 $branch 가 없다 — 구현자가 커밋하지 않았다"; return; }
  if ! unpark_changes "$branch"; then
    git branch -D -q "$branch" 2>/dev/null || true
    adopt_failure "$id" "$json_mode" conflict "병합 충돌" "$UNPARK_ERROR"
    return
  fi
  git reset -q    # cherry-pick --no-commit 이 스테이징한 것을 작업 트리 변경으로 되돌린다
  git branch -D -q "$branch"
  trace_add adopt "$(jq -cn --arg id "$id" '{feature: $id, result: "adopted"}')"
  emit "$json_mode" "$(result_json "$id" adopted "작업 트리로 가져옴")" "📥 adopt $id: 가져옴"
}
