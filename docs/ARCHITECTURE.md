# 구조

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

## 기능 상태

```
pending ─verify 통과─▶ verified ─commit─▶ passing
   ▲                     │   └─위험 파일─▶ awaiting-approval ─approve─▶ passing
   └── 실패(한도 전) ─────┘
실패가 maxAttempts 에 닿거나 같은 실패가 repeatLimit 번 연속이면 ─▶ blocked ─reset─▶ pending
```

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
