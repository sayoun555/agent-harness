#!/usr/bin/env bash
#
# feature 원장 관리 — start · edit · remove · move. commands/feature.sh 가 source 한다.
#   원장은 훅이 직접 편집을 막는다. 등록한 기능을 고치는 길은 이 명령들뿐이다(현장 보고 H2).
#

# 구현을 시작한다: 표준 구현 프롬프트를 내고, 이 기능을 "구현 시작"(진행 중)으로 남긴다.
#   prompt implement 는 읽기만 한다. 사람이 지시문을 보려고 실행해도 기능이 잡히지 않게 나눴다(현장 보고 H6).
cmd_start() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature start ID [--mode sequential|isolated|shared] [--json]"
  require_features_file; require_feature "$id"
  emit_implement_prompt "$id" --start "$@"
}

# 판정을 받았거나 받는 중인 기능은 완료 기준이 바뀌면 그 판정이 무효다 — 게이트부터 다시
reopen_for_new_definition() {  # reopen_for_new_definition <id> <무엇이 바뀌었나>
  case "$(feature_field "$1" status)" in
    "$STATUS_VERIFIED"|"$STATUS_REVIEWED")
      set_feature_fields "$1" "$(jq -cn --arg why "$2 바뀌어 게이트부터 다시" '{status: "pending", lastFailure: $why, lastFailureDetail: ""}')" ;;
  esac
  return 0
}

cmd_edit() {
  local id="${1:-}" patch='{}' changed=() value deps problem; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature edit ID [--desc 설명] [--acceptance 명령] [--design 문서] [--figma 링크] [--depends-on a,b]  (빈 값이면 지운다: --depends-on '')"
  require_features_file; require_feature "$id"
  if has_flag --desc "$@" || has_flag --acceptance "$@"; then
    [[ "$(feature_field "$id" status)" != "$STATUS_PASSING" ]] \
      || die "$EXIT_USAGE" "통과한 기능($id)의 설명 · 완료 기준은 바꾸지 않는다 — 기록과 어긋난다. 바뀐 요구는 새 기능으로 추가한다"
  fi
  if has_flag --desc "$@"; then
    value="$(flag_value --desc "$@")"; [[ -n "$value" ]] || die "$EXIT_USAGE" "--desc 는 비울 수 없다"
    patch="$(jq -c --arg v "$value" '. + {description: $v}' <<<"$patch")"; changed+=(설명)
  fi
  if has_flag --acceptance "$@"; then
    value="$(flag_value --acceptance "$@")"; [[ -n "$value" ]] || die "$EXIT_USAGE" "--acceptance 는 비울 수 없다"
    patch="$(jq -c --arg v "$value" '. + {acceptance: $v}' <<<"$patch")"; changed+=("완료 기준")
  fi
  if has_flag --design "$@"; then
    patch="$(jq -c --arg v "$(flag_value --design "$@")" '. + {designDoc: (if $v == "" then null else $v end)}' <<<"$patch")"; changed+=("설계 문서")
  fi
  if has_flag --figma "$@"; then
    patch="$(jq -c --arg v "$(flag_value --figma "$@")" '. + {figma: (if $v == "" then null else $v end)}' <<<"$patch")"; changed+=(Figma)
  fi
  if has_flag --depends-on "$@"; then
    deps="$(depends_on_json "$(flag_value --depends-on "$@")")"
    problem="$(dependency_problem "$id" "$deps")"
    [[ -z "$problem" ]] || die "$EXIT_USAGE" "$problem"
    patch="$(jq -c --argjson v "$deps" '. + {dependsOn: (if ($v | length) == 0 then null else $v end)}' <<<"$patch")"; changed+=("앞 기능")
  fi
  [[ ${#changed[@]} -gt 0 ]] || die "$EXIT_USAGE" "바꿀 것이 없다 (--desc · --acceptance · --design · --figma · --depends-on)"
  # null 은 그 칸을 지운다(설계 문서 · Figma · 앞 기능 해제)
  json_update "$(features_file)" \
    '(.features[] | select(.id == $id)) |= ((. + $patch) | delpaths([$patch | to_entries[] | select(.value == null) | [.key]]))' \
    --arg id "$id" --argjson patch "$patch"
  if has_flag --desc "$@" || has_flag --acceptance "$@" || has_flag --design "$@"; then
    reopen_for_new_definition "$id" "$(IFS=,; echo "${changed[*]}") 이(가)"
  fi
  trace_add edit "$(jq -cn --arg id "$id" --arg what "$(IFS=,; echo "${changed[*]}")" '{feature: $id, changed: $what}')"
  echo "✏️ edit $id: $(IFS=,; echo "${changed[*]}") → $(feature_field "$id" status)"
}

cmd_remove() {
  local id="${1:-}" dependents ref
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature remove ID"
  require_features_file; require_feature "$id"
  dependents="$(jq -r --arg id "$id" '[.features[] | select((.dependsOn // []) | index($id)) | .id] | join(", ")' "$(features_file)")"
  [[ -z "$dependents" ]] || die "$EXIT_USAGE" "$dependents 이(가) $id 에 의존한다 — 먼저 feature edit 로 --depends-on 을 고친다"
  jq -e "$JQ_IN_FLIGHT"' .features[] | select(.id == $id) | in_flight | not' --arg id "$id" "$(features_file)" >/dev/null \
    || die "$EXIT_USAGE" "$id 의 변경이 이 작업 트리에 있을 수 있다(진행 중) — 변경을 정리하고 feature reset 한 뒤 지운다"
  ref="$(parked_ref "$id")"
  json_update "$(features_file)" '.features |= map(select(.id != $id))' --arg id "$id"
  trace_add remove "$(jq -cn --arg id "$id" '{feature: $id}')"
  echo "🗑️ remove $id"
  [[ -n "$ref" ]] && echo "   보관한 변경은 $ref 에 그대로 있다(필요 없으면 지운다)."
  return 0
}

# 대기열 순서를 바꾼다. 루프는 앞에서부터 고른다(앞 기능을 기다리는 기능은 건너뛴다).
cmd_move() {
  local id="${1:-}" anchor position; shift || true
  [[ -n "$id" ]] || die "$EXIT_USAGE" "사용: feature move ID (--before ID | --after ID | --first | --last)"
  require_features_file; require_feature "$id"
  if has_flag --first "$@"; then position=first
  elif has_flag --last "$@"; then position=last
  elif [[ -n "$(flag_value --before "$@")" ]]; then position=before; anchor="$(flag_value --before "$@")"
  elif [[ -n "$(flag_value --after "$@")" ]]; then position=after; anchor="$(flag_value --after "$@")"
  else die "$EXIT_USAGE" "사용: feature move ID (--before ID | --after ID | --first | --last)"; fi
  if [[ -n "${anchor:-}" ]]; then
    require_feature "$anchor"
    [[ "$anchor" != "$id" ]] || die "$EXIT_USAGE" "자기 자신 앞뒤로 옮길 수 없다"
  fi
  json_update "$(features_file)" '
    ([.features[] | select(.id == $id)][0]) as $moved
    | [.features[] | select(.id != $id)] as $rest
    | ($rest | map(.id) | index($anchor)) as $at
    | .features = (if $position == "first" then [$moved] + $rest
                   elif $position == "last" then $rest + [$moved]
                   elif $position == "before" then $rest[:$at] + [$moved] + $rest[$at:]
                   else $rest[:$at + 1] + [$moved] + $rest[$at + 1:] end)' \
    --arg id "$id" --arg position "$position" --arg anchor "${anchor:-}"
  trace_add move "$(jq -cn --arg id "$id" --arg p "$position" --arg a "${anchor:-}" '{feature: $id, position: $p, anchor: $a}')"
  echo "↕️ move $id: $(jq -r '[.features[].id] | join(" → ")' "$(features_file)")"
}
