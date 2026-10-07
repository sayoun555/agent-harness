#!/usr/bin/env bash
#
# record.sh — 기록 정책. source 전용. lib/changes.sh · lib/park.sh · lib/features.sh 가 필요하다.
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

# record_passing <id> <suffix> <status-on-failure> → 실패하면 원장을 되돌리고 1 (RECORD_ERROR)
record_passing() {
  local id="$1" suffix="$2" rollback_status="$3"
  scope_of "$id"   # 범위는 원장을 바꾸기 전에 읽는다 (기준선을 이 기능의 경로만 갱신하려고)
  set_feature_fields "$id" "$(jq -cn --arg at "$(utc_now)" '{status: "passing", passedAt: $at, scope: null}')"
  if auto_commit_enabled; then
    commit_passing "$id" "$suffix" && return 0
    set_feature_fields "$id" "$(jq -cn --arg s "$rollback_status" '{status: $s, passedAt: null}')"
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
set_aside_changes() {
  local id="$1" kind="$2" ref parked
  if auto_commit_enabled; then
    ref="$(park_changes "$id" "wip($id): $kind — $(feature_field "$id" description)")"
    parked='{"kind":"branch"}'
  else
    scope_of "$id"
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
