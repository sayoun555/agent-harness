#!/usr/bin/env bash
#
# drift.sh — 검증을 통과한 뒤 바뀐 파일 찾기. source 전용. lib/features.sh 가 필요하다.
#
# 기록(record·approve)할 때 그 기능이 바꾼 파일의 내용 해시를 원장의 verifiedFiles 에 남긴다.
# 나중에 그 파일이 바뀌었는데 어떤 검증도 거치지 않았으면, 그 기능은 "검증 후 변경됨" 이다.
#
# 다른 기능이 같은 파일을 고쳐서 검증을 통과하면, 그 변경은 검증된 것이다.
# 그래서 기록할 때 앞서 통과한 기능들의 해시도 새 내용으로 맞춘다(absorb). 정당한 후속 변경으로 앞 기능이 다시 열리지 않는다.
#

readonly DELETED_MARK="(삭제)"

file_hash() {  # file_hash <상대 경로> → 내용 해시 (없으면 삭제 표시)
  if [[ -f "$1" ]]; then git hash-object -- "$1"; else echo "$DELETED_MARK"; fi
}

hashes_json() {  # hashes_json <경로...> → {"경로": "해시"}
  local path result='{}'
  for path in "$@"; do
    result="$(jq -c --arg p "$path" --arg h "$(file_hash "$path")" '. + {($p): $h}' <<<"$result")"
  done
  printf '%s\n' "$result"
}

# 기록할 때: 이 기능이 바꾼 파일을 남기고, 앞서 통과한 기능들의 같은 파일 해시를 새 내용으로 맞춘다
remember_verified_files() {  # remember_verified_files <id> <경로...>
  local id="$1" hashes; shift
  [[ $# -eq 0 ]] && return 0
  hashes="$(hashes_json "$@")"
  json_update "$(features_file)" '
    .features |= map(
      if .id == $id then .verifiedFiles = $h
      elif .status == "passing" and (.verifiedFiles // null) != null
        then .verifiedFiles |= with_entries(if $h[.key] then .value = $h[.key] else . end)
      else . end)' --arg id "$id" --argjson h "$hashes"
}

# 통과한 기능 중 파일이 검증 뒤에 바뀐 것: "ID<TAB>경로,경로"
drifted_features() {
  local id stored path changed
  while IFS=$'\t' read -r id stored; do
    [[ -z "$id" ]] && continue
    changed=""
    while IFS=$'\t' read -r path hash; do
      [[ -n "$path" && "$(file_hash "$path")" != "$hash" ]] && changed="${changed:+$changed,}$path"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$stored")
    [[ -n "$changed" ]] && printf '%s\t%s\n' "$id" "$changed"
  done < <(jq -r '.features[] | select(.status == "passing" and (.verifiedFiles // null) != null)
                  | "\(.id)\t\(.verifiedFiles | tojson)"' "$(features_file)")
  return 0
}

# 검증 후 바뀐 기능을 다시 대기열로. 다음 루프가 게이트·검증을 다시 한다.
reopen_drifted_features() {  # → 다시 연 기능 "ID<TAB>경로들" 한 줄씩
  local id files
  while IFS=$'\t' read -r id files; do
    [[ -z "$id" ]] && continue
    set_feature_fields "$id" "$(jq -cn --arg f "$files" \
      '{status: "pending", lastFailure: ("검증 후 변경됨: " + $f), lastFailureDetail: "", lastFailureFingerprint: ""}')"
    trace_add drift "$(jq -cn --arg id "$id" --arg f "$files" '{feature: $id, result: "reopened", files: $f}')"
    printf '%s\t%s\n' "$id" "$files"
  done < <(drifted_features)
  return 0
}

# 이 파일을 검증한 통과 기능 (편집 직후 경고용): ID 한 줄씩
passing_features_owning() {  # passing_features_owning <상대 경로>
  jq -r --arg p "$1" '.features[] | select(.status == "passing" and ((.verifiedFiles // {}) | has($p))) | .id' "$(features_file)"
}
