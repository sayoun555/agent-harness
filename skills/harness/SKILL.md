---
name: harness
description: 하네스가 끼워진 프로젝트(.harness/project.json 이 있음)에서 기능 목록 만들기, 루프 실행, 상태 확인, 판단 요청에 답하기, 승인, 막힌 기능 재개를 말로 시킬 때 쓴다. 하네스가 없는 프로젝트에서는 쓰지 않는다.
---

# 하네스 조작

## 0. 먼저 확인한다 (다른 것을 읽기 전에)

```bash
test -f .harness/project.json && test -x .harness/bin/harness && echo plugged || echo absent
```

- `absent` 이면 여기서 끝낸다. 사용자에게 한 줄만 말한다: "이 프로젝트에는 하네스가 없습니다. 쓰시려면 `harness init` 으로 끼울 수 있습니다." 이 파일의 나머지는 읽지 않는다.
- `plugged` 이면 아래에서 요청에 맞는 절 하나만 따른다. 모든 명령은 `.harness/bin/harness` 로 부른다.

## 1. 기능 목록 만들기 ("기획서 보고 기능 목록 만들어 줘")

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

## 2. 루프 실행 ("루프 돌려 줘")

1. 사전 점검을 먼저 돌린다. 실패하면 문제를 그대로 보여 주고 멈춘다.
   ```bash
   .harness/bin/harness feature preflight
   ```
2. 워크플로우 경로를 얻어 Workflow 도구로 실행한다.
   ```bash
   .harness/bin/harness path workflow
   ```
   `Workflow({ scriptPath: "<위 출력>", args: { maxIterations: 20 } })`
3. 끝나면 결과를 요약한다: 통과, 판단 필요(질문 그대로), 승인 대기, 막힘(이유 포함), 남은 기능.
   판단 필요가 있으면 질문을 먼저 보여 주고 답을 받는다.

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

승인 대기 기능의 변경은 `harness/ID` 브랜치에 보관돼 있다. `riskyFiles` 와 함께 diff 를 먼저 보여 준다.
```bash
git diff HEAD harness/ID
```
사용자가 승인하면:
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
