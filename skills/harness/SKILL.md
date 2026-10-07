---
name: harness
description: 하네스가 끼워진 프로젝트(.harness/project.json 이 있음)에서 설계하기(기존 코드를 완성품으로), 기능 목록 만들기, 루프 실행, 상태 확인, 판단 요청에 답하기, 승인, 막힌 기능 재개를 말로 시킬 때 쓴다. 하네스가 없는 프로젝트에서는 쓰지 않는다.
---

# 하네스 조작

## 0. 먼저 확인한다 (다른 것을 읽기 전에)

```bash
test -f .harness/project.json && test -x .harness/bin/harness && echo plugged || echo absent
```

- `absent` 이면 여기서 끝낸다. 사용자에게 한 줄만 말한다: "이 프로젝트에는 하네스가 없습니다. 쓰시려면 `harness init` 으로 끼울 수 있습니다." 이 파일의 나머지는 읽지 않는다.
- `plugged` 이면 아래에서 요청에 맞는 절 하나만 따른다. 모든 명령은 `.harness/bin/harness` 로 부른다.

## 1A. 설계하기 ("이 코드 완성품으로 만들어 줘", "설계부터 해 줘")

기존 코드를 완성품으로 만들거나 규모가 있는 기능이면, 기능 목록 전에 이 절부터 한다.

1. 기준을 읽는다. 설계는 이 기준으로만 한다. 기준마다 "적용 조건" 을 확인하고, 해당하지 않는 기준은 쓰지 않는다.
   ```bash
   .harness/bin/harness design criteria
   ```
2. 사용자가 가리킨 코드를 조사한다. 하드코딩된 곳은 `파일:줄` 로 적고, 이 저장소가 이미 쓰는 관례(폴더 구조·상태 관리·데이터 접근·스타일링)를 찾는다.
3. 양식에서 문서를 만들고 채운다. 절 제목과 표의 열은 바꾸지 않는다.
   ```bash
   .harness/bin/harness design new 이름
   ```
   - 근거 기준 열에는 기준 ID(C1, F2 …)를 적는다.
   - 되돌리기 어려운 결정(스키마·외부 API 계약·인증·공개 URL)은 정하지 말고 상태를 `사람 결정 필요` 로, 선택지를 `선택` 열에 적는다.
   - 구성 요소마다 검증 계획에 한 줄 이상. 테스트 환경이 없으면 "테스트 환경 구성" 을 첫 구성 요소와 첫 기능으로 둔다.
   - 기능 분해의 acceptance 는 검증 계획의 명령에서 가져온다. 칸 안의 파이프는 `\|` 로 쓴다.
4. 검사를 돌린다. 문서 문제가 있으면 고치고 다시 돌린다.
   ```bash
   .harness/bin/harness design check 문서
   ```
5. `사람 결정 필요` 가 남았으면 **한꺼번에** 묻는다. 결정마다 선택지와 각 선택의 대가를 한 줄씩. 답을 받으면 상태를 `사람 결정: <답>` 으로 바꾸고 4로 돌아간다.
6. 독립 검토를 받는다. 이 설계를 쓰지 않은 서브에이전트(Agent 도구)에게 아래 출력을 주고 기준 위반을 찾게 한다. 지적이 타당하면 고치고 4로 돌아간다.
   ```bash
   .harness/bin/harness design review-context 문서
   ```
7. 설계 요약을 보여 주고 확인을 받는다. 확인되면 원장에 넣고, 설계 문서와 원장만 커밋한다.
   ```bash
   .harness/bin/harness design import 문서
   git add 문서 .harness/features.json && git commit -m "docs(design): 이름 설계와 기능 N개"
   ```
   `design import` 는 검사를 통과하지 못한 설계를 원장에 넣지 않는다.

## 1B. 기능 목록 만들기 ("기획서 보고 기능 목록 만들어 줘")

작고 설계가 이미 분명하면 1A 없이 이 절로 바로 온다.

1. 사용자가 가리킨 문서를 읽는다.
2. 기능을 작게 나눈다. 기능마다 세 가지를 정한다.
   - `id`: 짧은 영문 kebab-case
   - `desc`: 한 문장
   - `acceptance`: 이 기능이 되면 통과하고 안 되면 실패하는 **실행 가능한 명령**. 가능하면 이 저장소의 기존 테스트 명령을 쓴다. 테스트가 없으면 그 기능을 확인하는 가장 작은 명령(특정 테스트 파일 실행, grep, 스크립트)을 쓴다.
3. 표로 한 번 보여 주고 확인을 받는다. 확인 전에는 원장에 넣지 않는다.
4. 확인되면 기능마다 추가한다.
   ```bash
   .harness/bin/harness feature add --id ID --desc '설명' --acceptance '명령'
   ```
5. 원장 파일만 커밋한다. 다른 파일은 스테이징하지 않는다. 루프는 깨끗한 작업 트리에서만 시작하기 때문이다.
   ```bash
   git add .harness/features.json && git commit -m "chore(harness): 기능 N개 추가"
   ```
   다른 변경이 이미 작업 트리에 있으면 커밋하지 말고, 루프 전에 그 변경을 커밋하거나 stash 해야 한다고 알린다.
6. `.harness/features.json` 은 Edit·Write 로 직접 고치지 않는다. 훅이 거부한다.

## 2A. 루프 실행 ("루프 돌려 줘")

1. 사전 점검을 먼저 돌린다. 실패하면 문제를 그대로 보여 주고 멈춘다.
   ```bash
   .harness/bin/harness feature preflight
   ```
   출력에 "MCP … 없음" 이나 "인증 필요" 가 있으면 한 줄로 알리고 루프는 그대로 진행한다.
   MCP 는 **절대 스스로 설치하지 않는다.** 사용자가 설치하겠다고 하면 그때 출력에 적힌 설치 명령을 실행한다.
2. 워크플로우 경로를 얻어 Workflow 도구로 실행한다.
   ```bash
   .harness/bin/harness path workflow
   ```
   `Workflow({ scriptPath: "<위 출력>", args: { maxIterations: 20 } })`
   경로는 프로젝트 안의 사본이다. 원본 경로로 바꾸지 않는다(작업 디렉터리 밖이라 거부된다).
   사용자가 "병렬로" 라고 하면 `args.parallel` 에 동시 구현 수(2~4)를 넣는다.
3. 끝나면 결과를 요약한다: 통과, 판단 필요(질문 그대로), 승인 대기, 막힘(이유 포함), 남은 기능, MCP 제안.
   판단 필요가 있으면 질문을 먼저 보여 주고 답을 받는다.

## 2B. 루프 없이 진행 ("루프는 안 써", "하나씩 해 줘")

루프를 쓰지 않아도 **구현과 검증은 기능마다 서로 다른 서브에이전트**가 한다. 메인 에이전트는 직접 구현하지 않고, 자기가 구현한 것을 자기가 검증하지 않는다.
기능마다 아래를 차례로 한다.

1. 지시문을 받아 **구현 서브에이전트**(Agent 도구)에게 그대로 준다.
   ```bash
   .harness/bin/harness feature brief ID
   ```
   구현자가 판단을 요청하면 `feature ask ID --question '질문'` 으로 남기고 다음 기능으로 간다.
2. 결정론 게이트를 돌린다. 실패하면 1로 돌아간다(지시문에 실패 사유가 자동으로 들어간다).
   ```bash
   .harness/bin/harness feature verify ID
   ```
3. **검증 서브에이전트**를 구현자와 다른 Agent 호출로 띄운다. 프롬프트: "너는 이 기능을 구현하지 않은 독립 검증자다. `.harness/bin/harness review --context ID` 를 읽고, 기준 ID 와 함께 승인 또는 반려를 판정하라. 파일을 고치지 마라."
4. 판정을 원장에 남긴다. 반려면 1로 돌아간다.
   ```bash
   .harness/bin/harness feature review ID --approve --reason '근거'
   .harness/bin/harness feature review ID --reject --reason '기준 ID 와 이유'
   ```
5. 기록한다. 커밋할지는 설정(`loop.autoCommit`)이 정한다.
   ```bash
   .harness/bin/harness feature record ID
   ```

여러 기능을 같은 작업 트리에서 동시에 구현하면, 각 구현자가 바꾼 파일을 `feature claim ID --files a,b` 로 적은 뒤 2~5를 하나씩 한다. 빌드는 `.harness/bin/harness lock run -- <명령>` 으로 잠금을 잡는다.

## 3. 상태 ("어디까지 됐어", "막힌 거 뭐 있어")

```bash
.harness/bin/harness feature list
.harness/bin/harness feature status
```
막힌 기능은 `lastFailure` 와 `lastFailureDetail` 을 함께 보여 준다: `.harness/bin/harness feature list --json`

## 4. 판단 요청에 답하기 ("캐싱은 Redis로 해")

`needs-decision` 기능의 질문과 사용자의 답을 짝지어 전달한다. 답은 사용자의 말 그대로 쓴다.
```bash
.harness/bin/harness feature decide ID --answer '사용자의 답'
```
기능이 다시 대기열에 들어간다. 루프를 다시 돌릴지 묻는다.

## 5. 승인 ("결제 기능 승인해 줘")

승인 대기 기능의 변경은 치워서 보관돼 있다. 위치는 원장의 `parked.ref` 다.
- 커밋으로 운용하면 브랜치: `git diff HEAD <ref>`
- 커밋 없이 운용하면 패치 파일: 그 파일을 그대로 보여 준다

`riskyFiles` 와 함께 보여 주고, 사용자가 승인하면:
```bash
.harness/bin/harness feature approve ID
```

## 6. 막힌 기능 재개 ("그거 다시 해 줘")

사용자가 원인을 확인했거나 고쳤을 때만 재개한다. 원인을 모른 채 재개하지 않는다.
```bash
.harness/bin/harness feature reset ID
```
그다음 루프를 다시 돌릴지 묻는다.

## 7. 회귀 확인 ("통과한 거 아직 괜찮아?")

```bash
.harness/bin/harness feature audit
```
