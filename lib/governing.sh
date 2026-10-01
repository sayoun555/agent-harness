#!/usr/bin/env bash
#
# governing.sh — 편집할 파일을 지배하는 설계 문서 찾기. source 전용.
#
# 설정 governingDoc.map 은 [{globs: [...], docs: [...]}] 이다. 첫 번째로 맞는 항목의 문서를 쓴다.
# governingDoc.alwaysForExtension 은 {확장자: [문서...]} 이다. 그 확장자면 항상 붙인다.
# 기본값은 비어 있다. 이전 파일럿에서 이 주입의 정확도 효과가 거의 0 이었기 때문에,
# 설계 문서가 많고 에이전트가 찾기 어려운 프로젝트에서만 켠다.
#

# governing_docs_for <상대 경로> → 문서를 한 줄에 하나씩 (중복 제거)
governing_docs_for() {
  local path="$1" entry glob doc
  load_config
  {
    while IFS= read -r entry; do
      while IFS= read -r glob; do
        # shellcheck disable=SC2053  # glob 매칭이 의도다
        if [[ -n "$glob" && "$path" == $glob ]]; then
          jq -r '.docs[]?' <<<"$entry"
          break 2
        fi
      done < <(jq -r '.globs[]?' <<<"$entry")
    done < <(jq -c '(.governingDoc.map // [])[]' <<<"$RESOLVED_CONFIG")
    jq -r --arg ext "${path##*.}" '(.governingDoc.alwaysForExtension // {})[$ext][]?' <<<"$RESOLVED_CONFIG"
  } | awk 'NF && !seen[$0]++'
}
