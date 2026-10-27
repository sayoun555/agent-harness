#!/usr/bin/env bash
#
# record.sh — 기록 정책. source 전용. lib/changes.sh · lib/park.sh · lib/features.sh · lib/drift.sh 가 필요하다.
#
# 명령 코드는 운용 방식을 모른다. 여기 세 가지만 부른다.
#   record_passing     통과를 남긴다
#   set_aside_changes  통과하지 못하고 떠나는 기능의 변경을 치우고 보관한다
#   bring_back_changes 보관한 변경을 되가져온다 (승인)
#
#                 커밋으로 운용 (autoCommit: true)        원장만 (autoCommit: false)
#   통과           git 커밋                              원장 passing + 기준선 갱신
#   보관           harness/<id> 브랜치 + 트리 되돌림       .harness/parked/<id>.patch + 기준선으로 되돌림
#   되가져오기     브랜치 cherry-pick                     git apply
#
# 원장의 parked 필드: {kind: "branch"|"patch", ref: "<브랜치 이름|패치 경로>"}
#

readonly PARKED_DIR_NAME="parked"

parked_patch_path() { printf '%s\n' "$PROJECT_HARNESS_DIR/$PARKED_DIR_NAME/$1.patch"; }

# feature_scope <id> → 기능이 맡은 경로 (같은 트리 병렬일 때만 있다). 없으면 빈 출력 = 전체
feature_scope() { jq -r --arg id "$1" '.features[] | select(.id == $id) | (.scope // [])[]' "$(features_file)"; }

scope_of() {  # scope_of <id> → SCOPE 배열을 채운다
  SCOPE=()
  local path
  while IFS= read -r path; do [[ -n "$path" ]] && SCOPE+=("$path"); done < <(feature_scope "$1")
  return 0
}

# ── 소유권 ──────────────────────────────────────────────────────────
# 범위(claim)가 없는 기능은 작업 트리 전체를 자기 변경으로 본다. 그래서 이 트리에 변경이 남아 있을 수 있는
# 다른 기능이 있으면 누구 변경인지 가를 수 없다. 이때 게이트·검증·기록·보관을 하면 남의 변경까지 판정하거나
# 보관하고 되돌린다. 아무것도 건드리지 않고 멈춘다.
#   이 트리에 변경이 있을 수 있는 기능 = 진행 중인 기능 (lib/features.sh 의 JQ_IN_FLIGHT).
unrecorded_others() {  # unrecorded_others <id> → 그런 다른 기능 (쉼표로)
  jq -r --arg id "$1" "$JQ_IN_FLIGHT"'
    [.features[] | select(.id != $id and in_flight) | .id] | join(", ")' "$(features_file)"
}

require_sole_owner() {  # require_sole_owner <id>
  local others
  scope_of "$1"
  [[ ${#SCOPE[@]} -gt 0 ]] && return 0
  others="$(unrecorded_others "$1")"
  [[ -z "$others" ]] && return 0
  die "$EXIT_USAGE" "범위 미지정 — 기록 전인 다른 기능($others)의 변경이 같은 트리에 섞여 있을 수 있어 $1 의 변경을 가를 수 없다. $(sole_owner_remedy "$1")"
}

sole_owner_remedy() {  # sole_owner_remedy <id> → 운용 방식에 맞는 푸는 길
  if auto_commit_enabled; then
    echo "한 기능씩 구현·기록한다. 막고 있는 기능이 끊긴 것이면 feature reset 그ID (커밋 운용에서는 범위를 나누지 않는다)."
  else
    echo "feature claim $1 --files 경로,경로 로 범위를 나누거나(verified·reviewed 에서도 된다), 막고 있는 기능이 끊긴 것이면 feature reset 그ID."
  fi
}

# ── 게이트가 본 변경 = 검토한 변경 = 기록할 변경 ─────────────────────
# 단계를 통과할 때 범위 안 변경의 해시를 남기고(verifiedChange · reviewedChange), 다음 단계에서 다시 잰다.
# 달라졌으면 앞 단계가 본 것이 아니다. 기록할 때 변경이 비었으면 남의 보관에 휩쓸렸거나 되돌려진 것이다.
readonly NO_CHANGE_FINGERPRINT="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"   # 빈 내용의 git blob 해시

change_fingerprint() {  # change_fingerprint <id> → 범위 안 변경의 해시 (변경이 없으면 NO_CHANGE_FINGERPRINT)
  scope_of "$1"
  patch_against_base ${SCOPE[@]+"${SCOPE[@]}"} | git hash-object --stdin
}

# changed_since <id> <앞 단계가 남긴 필드> <앞 단계 이름> → 달라졌으면 이유 (같거나 기록이 없으면 빈 출력)
changed_since() {
  local before
  before="$(feature_field "$1" "$2")"
  [[ -n "$before" && "$(change_fingerprint "$1")" != "$before" ]] && echo "$3 후 변경됨 — $3 때 본 변경과 지금 트리가 다르다"
  return 0
}

# 한 번 기록된 기능(verifiedFiles 가 있다)이 drift · audit 로 다시 열렸으면, 그 코드는 이미 기준에 들어 있다.
# 그래서 다시 검증할 때 변경이 없는 것이 정상이다 — 지금 코드를 다시 게이트·검토한 것을 기록한다.
# 다시 구현한 변경이 남에게 휩쓸려 사라진 경우는 검토 때 해시(reviewedChange)와 달라져서 따로 걸린다.
was_recorded() {  # was_recorded <id>
  jq -e --arg id "$1" '.features[] | select(.id == $id) | (.verifiedFiles // null) | type == "object"' \
    "$(features_file)" >/dev/null
}

previously_verified_paths() {  # previously_verified_paths <id> → 앞서 기록할 때 검증한 파일
  jq -r --arg id "$1" '.features[] | select(.id == $id) | (.verifiedFiles // {}) | keys[]' "$(features_file)"
}

unrecordable_reason() {  # unrecordable_reason <id> → 기록하면 안 되는 이유 (없으면 빈 출력)
  if [[ "$(change_fingerprint "$1")" == "$NO_CHANGE_FINGERPRINT" ]] && ! was_recorded "$1"; then
    echo "기록할 변경이 없다 — 변경이 다른 기능에 보관됐거나 되돌려졌다"
    return 0
  fi
  changed_since "$1" reviewedChange "검토"
}

# 다음 단계로 넘기지 않고 대기열로 되돌린다 (다시 게이트부터)
reopen_feature() {  # reopen_feature <id> <node> <json-mode> <이유>
  set_feature_fields "$1" "$(jq -cn --arg p "$4" '{status: "pending", lastFailure: $p, lastFailureDetail: ""}')"
  trace_add "$2" "$(jq -cn --arg id "$1" --arg p "$4" '{feature: $id, result: "reopened", reason: $p}')"
  emit "$3" "$(result_json "$1" reopened "$4")" "↩️ $2 $1: $4 → pending"
  return "$EXIT_GATE_FAILED"
}

# ── 통과 ────────────────────────────────────────────────────────────
RECORD_ERROR=""
RECORD_REF=""

commit_passing() {  # commit_passing <id> <suffix>
  local id="$1" suffix="$2" log
  git add -A
  log="$(mktemp)"
  if git commit -q -m "feat($id): $(feature_field "$id" description)" \
       -m "harness: acceptance 통과 — $(feature_field "$id" acceptance)$suffix" > "$log" 2>&1; then
    rm -f "$log"
    RECORD_REF="$(git rev-parse --short HEAD)"
    return 0
  fi
  RECORD_ERROR="$(tail -n 20 "$log")"
  rm -f "$log"
  git reset -q
  return 1
}

# touched_paths → 이 기능이 바꾼 파일 (SCOPE 가 있으면 그 안에서). scope_of 다음에 부른다.
touched_paths() {
  changed_files ${SCOPE[@]+"${SCOPE[@]}"}
  deleted_files ${SCOPE[@]+"${SCOPE[@]}"}
}

# record_passing <id> <suffix> <status-on-failure> → 실패하면 원장을 되돌리고 1 (RECORD_ERROR)
#   통과 표시와 검증한 파일의 해시(drift)를 커밋 전에 원장에 함께 쓴다. 커밋에 원장이 같이 담긴다.
#   다시 열렸던 기능이면 앞서 검증한 파일도 지금 내용으로 다시 남긴다 — 이번 게이트·검토가 지금 내용을 봤다.
record_passing() {
  local id="$1" suffix="$2" rollback_status="$3" ledger_before path touched=()
  scope_of "$id"   # 범위는 원장을 바꾸기 전에 읽는다 (기준선을 이 기능의 경로만 갱신하려고)
  while IFS= read -r path; do
    [[ -n "$path" ]] && touched+=("$path")
  done < <({ touched_paths; previously_verified_paths "$id"; } | awk '!seen[$0]++')
  ledger_before="$(cat "$(features_file)")"
  set_feature_fields "$id" "$(jq -cn --arg at "$(utc_now)" '{status: "passing", passedAt: $at, scope: null, implementedUnder: null}')"
  remember_verified_files "$id" ${touched[@]+"${touched[@]}"}
  if auto_commit_enabled; then
    commit_passing "$id" "$suffix" && return 0
    printf '%s\n' "$ledger_before" > "$(features_file)"   # 다른 기능의 해시 갱신까지 되돌린다
    set_feature_fields "$id" "$(jq -cn --arg s "$rollback_status" '{status: $s}')"
    return 1
  fi
  baseline_save ${SCOPE[@]+"${SCOPE[@]}"}
  RECORD_REF="기준선 갱신"
}

# ── 보관 ────────────────────────────────────────────────────────────
park_as_patch() {  # park_as_patch <id> [paths...] → 패치 경로 (변경이 없으면 빈 출력)
  local id="$1" patch; shift
  patch="$(parked_patch_path "$id")"
  mkdir -p "$(dirname "$patch")"
  patch_against_base "$@" > "$patch"
  [[ -s "$patch" ]] || { rm -f "$patch"; return 0; }
  restore_from_base "$@"
  printf '%s\n' "${patch#"$PROJECT_ROOT"/}"
}

# set_aside_changes <id> <kind> — 변경을 치우고 원장에 위치를 적는다
#   변경이 트리를 떠나므로 진행 중 표시와 범위를 함께 푼다. 범위를 쥔 채로 두면 그 파일을 고쳐야 하는
#   다른 기능의 claim 이 계속 거부된다. 승인으로 되가져오면 보관본의 경로로 범위를 다시 잡는다(adopt_patch_scope).
set_aside_changes() {
  local id="$1" kind="$2" ref parked
  scope_of "$id"   # 풀기 전에 읽는다 — 보관할 경로다
  set_feature_fields "$id" '{"implementedUnder": null, "scope": null}'
  if auto_commit_enabled; then
    ref="$(park_changes "$id" "wip($id): $kind — $(feature_field "$id" description)")"
    parked='{"kind":"branch"}'
  else
    ref="$(park_as_patch "$id" ${SCOPE[@]+"${SCOPE[@]}"})"
    parked='{"kind":"patch"}'
  fi
  [[ -z "$ref" ]] && return 0
  set_feature_fields "$id" "$(jq -cn --argjson p "$parked" --arg ref "$ref" '{parked: ($p + {ref: $ref})}')"
  trace_add park "$(jq -cn --arg id "$id" --arg kind "$kind" --arg ref "$ref" '{feature: $id, kind: $kind, ref: $ref}')"
}

set_aside_if_blocked() {  # set_aside_if_blocked <id> <status>
  [[ "$2" == "$STATUS_BLOCKED" ]] && set_aside_changes "$1" "blocked"
  return 0
}

parked_kind() { jq -r --arg id "$1" '.features[] | select(.id == $id) | .parked.kind // empty' "$(features_file)"; }
parked_ref()  { jq -r --arg id "$1" '.features[] | select(.id == $id) | .parked.ref // empty' "$(features_file)"; }

# ── 되가져오기 ──────────────────────────────────────────────────────
BRING_BACK_ERROR=""

# bring_back_changes <id> → 실패하면 1 (BRING_BACK_ERROR). 보관한 것이 없으면 그대로 0
bring_back_changes() {
  local id="$1" kind ref log
  kind="$(parked_kind "$id")"
  ref="$(parked_ref "$id")"
  case "$kind" in
    branch)
      unpark_changes "$ref" && return 0
      BRING_BACK_ERROR="$UNPARK_ERROR"; return 1 ;;
    patch)
      log="$(mktemp)"
      if git apply --binary "$PROJECT_ROOT/$ref" > "$log" 2>&1; then
        rm -f "$log"
        SCOPE_FROM_PATCH="$(git apply --numstat "$PROJECT_ROOT/$ref" | cut -f3)"
        return 0
      fi
      BRING_BACK_ERROR="$(tail -n 20 "$log")"; rm -f "$log"; return 1 ;;
  esac
  return 0
}

# 되가져온 패치가 건드린 경로를 기능의 범위로 둔다 (원장 운용에서 기준선을 그 경로만 갱신하려고)
SCOPE_FROM_PATCH=""
adopt_patch_scope() {  # adopt_patch_scope <id>
  [[ -z "$SCOPE_FROM_PATCH" ]] && return 0
  set_feature_fields "$1" "$(lines_to_json <<<"$SCOPE_FROM_PATCH" | jq -c '{scope: .}')"
}

# undo_bring_back <id> — 되가져온 변경을 트리에서 다시 뺀다(보관본은 그대로). 승인 전 게이트가 실패했을 때
undo_bring_back() {
  case "$(parked_kind "$1")" in
    branch) restore_clean_tree_keeping_ledger ;;
    patch)  git apply -R --binary "$PROJECT_ROOT/$(parked_ref "$1")" ;;
  esac
  set_feature_fields "$1" '{"scope":null}'
}

drop_parked() {  # drop_parked <id> — 되가져온 뒤 보관본을 지운다
  local kind ref
  kind="$(parked_kind "$1")"
  ref="$(parked_ref "$1")"
  case "$kind" in
    branch) git branch -D -q "$ref" 2>/dev/null || true ;;
    patch)  rm -f "$PROJECT_ROOT/$ref" ;;
  esac
  set_feature_fields "$1" '{"parked":null}'
}
