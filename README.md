# agent-harness

프로젝트에 끼워 쓰는 범용 에이전트 하네스. 코어는 여기 한 곳에만 있고, 프로젝트는 `.harness/project.json` 설정만 가진다.

이전 프로젝트 하네스의 파일럿 측정에서 값이 확인된 쪽(검증·강제)을 옮기고, 루프와 그래프를 더했다.
설계 원칙은 하나다. **규칙을 늘리지 않고, 진짜 목표만 확실히 쥔다.** 과제약은 과설계와 게이트 속이기를 부른다.

## 무엇이 들어 있나

| 부품 | 하는 일 | 차단 여부 |
|---|---|---|
| `check` | 강한 stub 마커·하드코딩 시크릿 | 차단 |
| `check` | 약한 마커(임시·추후·일단)·파일 크기 | 경고 |
| `test-guard` | 테스트 케이스·assertion 합계 감소, skip 증가 | 차단 (파일별 감소는 경고) |
| `feature` | 기능 원장. 통과 판정은 하네스가 acceptance 를 실행해서만 기록 | — |
| `risk` | 위험 파일(결제·인증 등) 변경 시 자동 커밋 대신 사람 승인 | 승인 대기 |
| `review` | 스택 기준·footgun 으로 의미 적대자 컨텍스트 생성 | 루프에서 반려 |
| `trace` | 노드마다 한 줄 JSONL. 반복 감지·비용·부품 빼 보기 실험의 원천 | — |
| `feature-loop` | 위 부품을 잇는 제한 루프 워크플로우 | — |

## 설치

쓰려는 프로젝트 폴더에서 한 줄. 다시 실행하면 업데이트다.

```bash
curl -fsSL https://raw.githubusercontent.com/sayoun555/agent-harness/main/install.sh | bash
```

하는 일은 세 가지다.
1. 하네스를 `~/.agent-harness` 에 받는다.
2. 이 프로젝트에 끼운다. 스택(spring · nextjs · generic)은 자동 감지하고, 직접 고르려면 `| bash -s -- --preset spring`.
3. Claude Code 플러그인을 **이 프로젝트에만** 켠다. 다른 프로젝트에는 스킬도 훅도 로드되지 않는다.

끝나면 `.harness/`, `.claude/settings.json`, `.gitignore` 를 커밋한다. 팀원이 clone 하면 같은 설정을 받는다.

## 쓰기: Claude Code 에서 말로

| 이렇게 말하면 | 하네스가 하는 일 |
|---|---|
| "PLAN.md 보고 기능 목록 만들어 줘" | 기능과 acceptance 명령을 표로 제안 → 확인하면 원장에 추가하고 원장만 커밋 |
| "루프 돌려 줘" | 사전 점검 → feature-loop 실행 → 통과·승인 대기·막힘 요약 |
| "어디까지 됐어", "막힌 거 뭐 있어" | 원장 상태와 막힌 이유 |
| "캐싱은 Redis로 해" | 판단을 기다리던 기능에 결정을 붙여 다시 대기열에 |
| "결제 기능 승인해 줘" | 보관 브랜치의 diff 를 보여 주고 승인 |
| "그거 다시 해 줘" | 원인을 확인한 막힌 기능을 다시 대기열에 |

스킬은 첫 단계에서 `.harness/project.json` 이 있는지 확인하고, 없으면 한 줄만 알리고 끝난다.
훅은 모델 밖의 셸 스크립트라 하네스가 없는 곳에서는 출력 없이 끝난다(토큰 0).

## 설정의 층

`presets/_defaults.json` → `presets/<preset>.json` → `.harness/project.json` 순서로 덮는다. 객체는 깊게 병합, 배열은 교체.
스택 전용 내용(footgun·판단 기준·테스트 패턴·위험 경로)은 전부 프리셋에 있다. 코어 스크립트와 적대자 프로토콜에는 스택 이름이 나오지 않는다.

## 사람이 하는 일

루프는 네 경우에 기능을 멈추고 다른 기능으로 넘어간다. 끝나면 요약에 모여 나온다.
통과하지 못한 기능의 변경은 `harness/<기능ID>` 브랜치에 보관하고 작업 트리를 되돌린다. 다음 기능의 커밋에 섞이지 않게 하기 위해서다.

| 상황 | 말로 | 명령으로 |
|---|---|---|
| 구현자가 설계 결정을 물음 | "캐싱은 Redis로 해" | `harness feature decide ID --answer 답` |
| 위험 파일이라 승인 대기 | "결제 기능 승인해 줘" | `harness feature approve ID` |
| 같은 실패 반복·시도 한도·커밋 실패로 막힘 | 원인을 보고 "그거 다시 해 줘" | `harness feature reset ID` |
| 통과했던 기능이 깨졌는지 | "통과한 거 아직 괜찮아?" | `harness feature audit` |

## 다른 도구

- **git 훅**: `init` 이 `core.hooksPath` 를 하네스의 `git-hooks/` 로 건다. 끄려면 `--no-git-hooks`.
- **`--no-verify` 차단**: `export PATH="$HOME/.agent-harness/guard/bin:$PATH"`
- **Codex**: `harness init --codex` 가 `.codex/hooks.json` 을 만든다.
- **CI**: `harness init --ci` 가 워크플로우를 만든다. 저장소 변수 `HARNESS_REPO`·`HARNESS_REF` 로 이 하네스를 버전 고정 참조한다.
- **명령으로 직접**: `.harness/bin/harness --help`

## 근거

왜 이렇게 만들었는지는 [docs/research/](docs/research/README.md) 에 있다. 논문과 신뢰도 티어, 업계 자료, 이전 하네스의 파일럿 측정, 베이스 평가, 결정마다의 근거 강도.
구조는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 테스트

```bash
bash tests/run.sh              # 결정론 부품 45개
node tests/workflow-sim.mjs    # 루프 그래프: LLM 만 가짜, 하네스 명령은 실제 실행
```

## 알려진 한계

- `feature-loop` 는 LLM 을 가짜로 바꾼 시뮬레이션으로만 검증했다. 실제 모델로 끝까지 돌린 기록은 아직 없다.
- 결정론 노드는 에이전트가 명령을 실행하고 결과를 전달한다. 전달이 틀려도 원장이 기준이지만, 루프의 분기 판단은 그 전달에 기댄다.
- 에이전트가 `jq` 로 원장을 직접 바꾸는 것까지는 막지 않는다. `feature audit` 가 acceptance 를 다시 돌려 거짓 통과를 되돌린다.
- 파일별 설계 문서 라우팅과 Figma 시각 비교 렌즈는 아직 없다.
