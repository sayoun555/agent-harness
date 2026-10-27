#!/usr/bin/env bash
#
# report.sh — 실행 기록(trace)과 원장에서 사람이 읽는 보고서(Markdown)를 만든다. source 전용.
#   모델을 부르지 않는다. 문제 · 해결 문장은 검증자 · 하네스가 trace 에 이미 남긴 것을 엮는다.
#

report_file() { project_path "$(cfg '.state.reportFile')"; }

# 표 칸에 넣을 수 있게: 줄바꿈은 공백, | 는 \|. 길면 자른다.
readonly JQ_REPORT_DEFS='
def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|") | if length > 400 then .[0:400] + " …" else . end;
def minutes($a; $b): ((($b | fromdateiso8601) - ($a | fromdateiso8601)) / 60 | floor);
def problem: (.result == "fail") or (.result == "reject") or (.result == "reopened") or (.result == "overlap")
  or (.result == "regressed") or (.result == "commit-failed") or (.event == "ask") or (.event == "park") or (.event == "reset");
def describe:
  if .event == "implement" then "구현 시작(시도 \(.attempt // "?"))"
  elif .event == "verify" and .result == "pass" then "게이트 통과"
  elif .event == "verify" then "**문제** 게이트 실패(\(.step // "?")) → \(.status // "?")" + (if (.detail // "") != "" then ": \(.detail)" else "" end)
  elif .event == "review" and .result == "approve" then "검토 승인: \(.reason // "")"
  elif .event == "review" then "**문제** 검토 반려 → \(.status // "?"): \(.reason // "")"
  elif .event == "drift" then "**문제** 검증 뒤 파일이 바뀌어 다시 엶: \(.files // "")"
  elif .result == "reopened" then "**문제** 다시 엶(\(.event)): \(.reason // "")"
  elif .event == "claim" then "**문제** 범위가 다른 기능과 겹침: \(.files // "")"
  elif .event == "ask" then "**판단 요청** \(.question // "")"
  elif .event == "decide" then "**사람 결정** \(.answer // "")"
  elif .event == "park" then "변경 보관(\(.kind // "")): \(.ref // "")"
  elif .event == "reset" then "사람이 대기열로 되돌림"
  elif .event == "audit" then "**문제** 감사에서 회귀"
  elif .result == "passing" then "기록 → passing" + (if (.ref // "") != "" then " (\(.ref))" else "" end)
  elif .result == "awaiting-approval" then "위험 파일 — 사람 승인 대기"
  elif .result == "commit-failed" then "**문제** 커밋 실패(git 훅)"
  else "\(.event) \(.result // "")" end;
'

# build_report <trace.jsonl> <features.json> <생성 시각> → Markdown
build_report() {  # build_report <trace> <원장> <지금> [낡은 질문 JSON]
  local stale="${4:-}"
  [[ -n "$stale" ]] || stale='{}'
  jq -rn --slurpfile ledger "$2" --arg now "$3" --argjson stale "$stale" "$JQ_REPORT_DEFS$JQ_QUESTION_AGE"'
    [inputs] as $t
    | ($ledger[0].features // []) as $f
    | ($f | map({key: .id, value: .}) | from_entries) as $byId
    | [$t[] | select(.feature != null)] as $ft
    | [
        "# 하네스 실행 보고서",
        "",
        "만든 시각 \($now) · 기록 \($t | length)줄" + (if ($t | length) > 0 then " (\($t[0].ts) ~ \($t[-1].ts))" else "" end),
        "trace 와 원장에서 하네스가 만든다(모델 호출 없음). 문장은 검증자 · 하네스가 남긴 사유 그대로다.",
        "",
        "## 요약",
        "",
        "| 상태 | 기능 수 |", "|---|---|",
        ($f | group_by(.status) | map("| \(.[0].status) | \(length) |") | .[]),
        "",
        (if any($t[]; .event == "loop-end") then
          "루프 종료: " + ([$t[] | select(.event == "loop-end")] | .[-3:] | map("\(.ts) \(.result)") | join(" · "))
         else empty end),
        "",
        "## 트러블슈팅 — 기능별 문제와 해결",
        "",
        ( [$ft | group_by(.feature)[] | select(any(.[]; problem))] as $troubled
          | if ($troubled | length) == 0 then "문제가 기록된 기능이 없다."
            else ($troubled[] | (
              "### \(.[0].feature) (지금: \($byId[.[0].feature].status // "원장에 없음"))",
              "",
              "| 시각 | 내용 |", "|---|---|",
              (.[] | "| \(.ts) | \(describe | cell) |"),
              ""))
            end ),
        "",
        "## 기능당 시간 · 시도 (통과한 기능)",
        "",
        "처음 통과할 때까지다(구현 시작이 기록돼 있으면 거기서부터, 없으면 첫 게이트부터). 세션이 쉰 시간도 들어 있다. 반려 · 실패는 처음 통과 전까지 센다.",
        "",
        "| 기능 | 반려 · 실패 | 분 |", "|---|---|---|",
        ( $ft | group_by(.feature)[]
          | (map(.result == "passing") | index(true)) as $i
          | select($i != null)
          | .[0:$i + 1] as $run
          | "| \(.[0].feature) | \([$run[] | select(.result == "fail" or .result == "reject")] | length) | \(minutes($run[0].ts; $run[-1].ts)) |" ),
        "",
        "## 기능을 넘어 반복된 반려 기준",
        "",
        "품질 기준 ID(Q2 · P1 …)만 센다. REQ(요구) · REG(회귀)는 기능마다 다른 내용이라 반복으로 보지 않는다.",
        "",
        ( [$ft[] | select(.event == "review" and .result == "reject")
            | {feature, id: ((.reason // "") | capture("^(?<id>[A-Z]+[0-9]+)").id // empty)}]
          | group_by(.id) | map({id: .[0].id, features: (map(.feature) | unique)}) | map(select(.features | length >= 2))
          | if length == 0 then "없음."
            else ("| 기준 | 기능 수 | 기능 |", "|---|---|---|",
                  (.[] | "| \(.id) | \(.features | length) | \(.features | join(", ")) |"))
            end ),
        "",
        "## 하네스 이상 신호",
        "",
        ( [ ($t[] | select(.event == "loop-end" and (.result == "stuck" or .result == "ledger-unreadable" or .result == "budget" or .result == "usage-limit"))
              | "- \(.ts) 루프가 멈춤(\(.result))" + (if (.reason // "") != "" then ": \(.reason | cell)" else "" end)),
            ($t[] | select(.event == "agents-fallback") | "- \(.ts) 전용 에이전트를 띄우지 못해 기본 에이전트로 돌았다(도구 제한이 빠진다): \(.reason | cell) → 플러그인 업데이트 · 재설치 `claude plugin update agent-harness@agent-harness`"),
            ($t[] | select(.event == "preflight" and .result == "released-stale") | "- \(.ts) 끊긴 실행이 남긴 진행 중 표시를 풀었다: \(.features)"),
            ($t[] | select(.event == "loop-run" and .exitCode != 0) | "- \(.ts) 헤드리스 루프가 종료 코드 \(.exitCode) 로 끝남 (\(.log))") ]
          | if length == 0 then "없음." else .[] end ),
        "",
        "## 사람이 할 일",
        "",
        ( [ ($f[] | select(.status == "needs-decision") | "- 판단: \(.id) — \(.question // "" | cell)\(question_age($stale)) → `harness feature decide \(.id) --answer …`"),
            ($f[] | select(.status == "awaiting-approval") | "- 승인: \(.id) → `harness feature approve \(.id)`"),
            ($f[] | select(.status == "blocked") | "- 막힘: \(.id) — \(.lastFailure // "" | cell) → 원인을 푼 뒤 `harness feature reset \(.id)`"),
            ($f as $all | $f[] | select(.status == "pending")
              | [(.dependsOn // [])[] as $d | $all[] | select(.id == $d and .status != "passing") | "\(.id)(\(.status))"] as $w
              | select($w | length > 0) | "- 대기: \(.id) ← \($w | join(", ")) — 앞 기능이 기록되면 루프가 이어서 고른다") ]
          | if length == 0 then "없음." else .[] end )
      ] | .[]
  ' "$1"
}
