# 구조

## 설계에서 루프까지

```
기존 코드·기획 ─▶ 설계 문서(기준 적용) ─▶ design check ─▶ 사람 결정 ─▶ 독립 검토 ─▶ 사람 확인 ─▶ design import ─▶ 루프
                                            │ 실패                ▲
                                            └─────────────────────┘
```

design check 를 통과하지 못한 설계는 원장에 들어가지 않는다. 원장의 기능은 설계 문서를 가리키고, 구현자는 그 문서를, 검증자는 "설계 결정과 어긋났는가" 를 본다.

## 루프 그래프

```
선택 ─▶ 구현 ─▶ 게이트 ─▶ 검증 ─▶ 기록 ─▶ 선택 …
         ▲       │실패     │반려
         └───────┴─────────┘   실패 사유를 다음 구현 프롬프트에 넣는다
                                기록: 위험 파일이면 커밋 대신 사람 승인 대기
```

| 노드 | 누가 | 명령 |
|---|---|---|
| 선택 | 결정론 | `feature next --json` |
| 구현 | LLM (매 바퀴 새 컨텍스트) | — |
| 게이트 | 결정론 | `feature verify ID` = compile → test-guard → acceptance |
| 검증 | LLM (구현하지 않은 독립 적대자) | `review --context ID` 를 읽고 판정 |
| 기록 | 결정론 | `feature commit ID` 또는 `feature reject ID` |

워크플로우(`workflows/feature-loop.js`)는 흐름만 제어한다. 상태 전이는 모두 `lib/features.sh` 에 있다.

## 병렬 모드 (loop.parallel ≥ 2)

```
선택(최대 N개) ─▶ 구현 ×N (각자 워크트리, harness/wip-<id> 에 커밋)
                    │
                    ▼  하나씩
               가져오기 ─▶ 게이트 ─▶ 검증 ─▶ 기록
                 │충돌
                 └─▶ 실패로 기록 → 다음 바퀴에 최신 HEAD 위에서 다시 구현
```

원장은 메인 작업 트리 한 곳에서만 쓴다. 병렬인 것은 구현(가장 느린 LLM 단계)뿐이다.

## 트리거

`harness loop run` 은 모델을 부르기 전에 사전 점검과 pending 개수를 본다. 실패하거나 0 이면 끝난다(토큰 0). 잠금 파일로 겹쳐 실행되지 않는다.
Workflow 도구는 작업 디렉터리 밖의 스크립트를 거부하므로, 워크플로우는 프로젝트 안 `.harness/bin/feature-loop.js` 사본으로 실행한다.

## 기능 상태

```
pending ─verify 통과─▶ verified ─commit─▶ passing
   │ ▲                   │   └─위험 파일─▶ awaiting-approval ─approve─▶ passing
   │ └── 실패(한도 전) ───┘
   └─구현자가 질문─▶ needs-decision ─decide─▶ pending (결정이 다음 구현에 전달됨)
실패가 maxAttempts 에 닿거나, 같은 실패가 repeatLimit 번 연속이거나, git 훅이 커밋을 막으면 ─▶ blocked ─reset─▶ pending
```

## 보관

blocked · awaiting-approval · needs-decision 으로 떠나는 기능의 변경은 `harness/<id>` 브랜치의 커밋으로 보관하고, 작업 트리를 HEAD 로 되돌린다. 기능 원장의 변경은 보관하지 않고 유지한다.
이게 없으면 커밋 노드가 작업 트리 전체를 담기 때문에, 승인을 기다리던 결제 코드가 다음 기능의 커밋에 승인 없이 섞인다.
approve 는 보관 브랜치를 가져와 커밋하고 브랜치를 지운다. reset 은 HEAD 에서 다시 구현하고 보관 브랜치는 참고용으로 남긴다.

같은 실패 판정은 실패 이유와 출력 끝부분에서 숫자를 지운 지문으로 한다. 시간·줄 번호가 달라도 같은 실패로 본다.

## 종료 조건

| 조건 | 결과 |
|---|---|
| pending 기능이 없음 | `all-done` |
| `maxIterations` 바퀴 | `max-iterations`, 다음 실행에서 이어감 |
| 토큰 예산 하한 | `budget` |
| 사전 점검 실패 | `preflight-failed`, 루프 시작 안 함 |

## 막는 것과 막지 않는 것

막는 것은 셋이다. 강한 stub 마커와 시크릿, 테스트 약화, 원장 직접 편집이다.
나머지는 경고다. 파일 크기, 약한 한국어 마커, 파일별 assertion 감소가 여기에 속한다.
이전 파일럿 측정에서 규칙 주입의 효과는 거의 0이었고, 단순 과제에 규칙을 강하게 걸면 과설계가 나왔다. 그래서 루프의 종료 조건은 대리 지표가 아니라 기능의 acceptance 에 건다.

## 부품 빼 보기

`trace.jsonl` 에 노드별 결과가 남는다. 게이트나 검증 노드를 하나 끄고 같은 원장으로 돌려서 통과율이 같으면, 그 부품은 뺀다.
