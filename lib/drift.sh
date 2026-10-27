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
# 진행 중인 기능(JQ_IN_FLIGHT)이 맡은 파일의 변경은 아직 검증 중인 변경이다. drift 로 보지 않는다.
# 그 기능이 기록되면 absorb 로 해시가 맞춰지고, 보관되면 파일이 기준으로 되돌아간다. 어느 쪽이든 판정은 그때 끝난다.
# 범위가 없는 진행 중 기능은 트리 전체를 맡는다(lib/record.sh 의 소유권) — 그동안은 drift 판정 전체를 미룬다.
#

readonly DELETED_MARK="(삭제)"

# 감시하지 않는 파일(rules.driftIgnore 글롭): 모든 기능이 고치는 공용 기록 · 색인 문서(목차 · 작업 기록 등).
#   이런 파일을 검증 파일로 남기면 사람이 한 줄만 고쳐도 그 파일을 가진 통과 기능이 전부 다시 열린다(현장 보고 H12).
#   기능 커밋에는 그대로 담긴다. 글롭의 * 는 / 도 넘는다(docs/* = docs 아래 전부).
drift_ignored() {  # drift_ignored <상대 경로> → 감시하지 않으면 0
  local pattern
  while IFS= read -r pattern; do
    # shellcheck disable=SC2053  # 글롭으로 맞춘다
    [[ -n "$pattern" && "$1" == $pattern ]] && return 0
  done < <(cfg_lines '.rules.driftIgnore')
  return 1
}

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
  local id="$1" hashes path watched=(); shift
  for path in "$@"; do drift_ignored "$path" || watched+=("$path"); done
  [[ ${#watched[@]} -eq 0 ]] && return 0
  hashes="$(hashes_json "${watched[@]}")"
  json_update "$(features_file)" '
    .features |= map(
      if .id == $id then .verifiedFiles = $h
      elif .status == "passing" and (.verifiedFiles // null) != null
        then .verifiedFiles |= with_entries(if $h[.key] then .value = $h[.key] else . end)
      else . end)' --arg id "$id" --argjson h "$hashes"
}

# 진행 중인 기능이 맡은 파일: 한 줄에 하나. 범위 없는 진행 중 기능이 있으면 "*" 한 줄(트리 전체)
in_flight_paths() {
  jq -r "$JQ_IN_FLIGHT"'
    [.features[] | select(in_flight)] as $f
    | if any($f[]; (.scope // []) | length == 0) then "*" else ($f | map(.scope[]) | unique[]) end' "$(features_file)"
}

# 통과한 기능 중 파일이 검증 뒤에 바뀐 것 (진행 중인 기능이 맡은 파일은 뺀다): "ID<TAB>경로,경로"
drifted_features() {
  local id stored path changed held
  held="$(in_flight_paths)"
  [[ "$held" == "*" ]] && return 0
  while IFS=$'\t' read -r id stored; do
    [[ -z "$id" ]] && continue
    changed=""
    while IFS=$'\t' read -r path hash; do
      [[ -n "$path" && "$(file_hash "$path")" != "$hash" ]] || continue
      drift_ignored "$path" && continue   # 설정을 나중에 더해도 이미 남은 해시로 다시 열지 않는다
      grep -qxF -- "$path" <<<"$held" && continue
      changed="${changed:+$changed,}$path"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$stored")
    [[ -n "$changed" ]] && printf '%s\t%s\n' "$id" "$changed"
  done < <(jq -r '.features[] | select(.status == "passing" and (.verifiedFiles // null) != null)
                  | "\(.id)\t\(.verifiedFiles | tojson)"' "$(features_file)")
  return 0
}

# 검증 후 바뀐 기능을 다시 대기열로. 다음 루프가 게이트·검증을 다시 한다.
#   다시 연 기능은 아직 구현을 시작하지 않은 것이다 — 진행 중 표시(implementedUnder)를 지운다.
reopen_drifted_features() {  # → 다시 연 기능 "ID<TAB>경로들" 한 줄씩
  local id files
  while IFS=$'\t' read -r id files; do
    [[ -z "$id" ]] && continue
    set_feature_fields "$id" "$(jq -cn --arg f "$files" \
      '{status: "pending", implementedUnder: null,
        lastFailure: ("검증 후 변경됨: " + $f), lastFailureDetail: "", lastFailureFingerprint: ""}')"
    trace_add drift "$(jq -cn --arg id "$id" --arg f "$files" '{feature: $id, result: "reopened", files: $f}')"
    printf '%s\t%s\n' "$id" "$files"
  done < <(drifted_features)
  return 0
}

# 이 파일을 검증한 통과 기능 (편집 직후 경고용): ID 한 줄씩
passing_features_owning() {  # passing_features_owning <상대 경로>
  jq -r --arg p "$1" '.features[] | select(.status == "passing" and ((.verifiedFiles // {}) | has($p))) | .id' "$(features_file)"
}
