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

## 끼우기

```bash
cd <프로젝트>
bash ~/agent-harness/bin/harness init            # 스택 자동 감지 (spring · nextjs · generic)
.harness/bin/harness config                      # 해석된 설정 확인
.harness/bin/harness feature add --id sub --desc "빼기" --acceptance "npm test -- sub"
git add .harness .gitignore && git commit -m "chore: agent-harness"
```

Claude Code 에서는 플러그인으로 불러온다. 하네스가 끼워지지 않은 저장소에서는 모든 훅이 아무것도 하지 않는다.

```bash
claude --plugin-dir ~/agent-harness                         # 이번 세션만
/plugin marketplace add ~/agent-harness                     # 계속 쓰기 (로컬 마켓플레이스)
/plugin install agent-harness@agent-harness-local
```

루프 실행은 Claude Code 안에서 `/agent-harness:feature-loop`.

## 설정의 층

`presets/_defaults.json` → `presets/<preset>.json` → `.harness/project.json` 순서로 덮는다. 객체는 깊게 병합, 배열은 교체.
스택 전용 내용(footgun·판단 기준·테스트 패턴·위험 경로)은 전부 프리셋에 있다. 코어 스크립트와 적대자 프로토콜에는 스택 이름이 나오지 않는다.

## 사람이 하는 일

| 상황 | 명령 |
|---|---|
| 위험 파일이라 승인 대기 | `harness feature approve ID` |
| 같은 실패 반복·시도 한도로 막힘 | 원인 해결 후 `harness feature reset ID` |
| 통과했던 기능이 깨졌는지 | `harness feature audit` |

## 다른 도구

- **git 훅**: `init` 이 `core.hooksPath` 를 이 저장소의 `git-hooks/` 로 건다. `--no-git-hooks` 로 끈다.
- **`--no-verify` 차단**: `export PATH="$HOME/agent-harness/guard/bin:$PATH"`
- **Codex**: `harness init --codex` 가 `.codex/hooks.json` 을 만든다.
- **CI**: `harness init --ci` 가 워크플로우를 만든다. 저장소 변수 `HARNESS_REPO`·`HARNESS_REF` 로 이 하네스를 버전 고정 참조한다.

## 테스트

```bash
bash tests/run.sh              # 결정론 부품 33개
node tests/workflow-sim.mjs    # 루프 그래프: LLM 만 가짜, 하네스 명령은 실제 실행
```

## 알려진 한계

- `feature-loop` 는 LLM 을 가짜로 바꾼 시뮬레이션으로만 검증했다. 실제 모델로 끝까지 돌린 기록은 아직 없다.
- 결정론 노드는 에이전트가 명령을 실행하고 결과를 전달한다. 전달이 틀려도 원장이 기준이지만, 루프의 분기 판단은 그 전달에 기댄다.
- 에이전트가 `jq` 로 원장을 직접 바꾸는 것까지는 막지 않는다. `feature audit` 가 acceptance 를 다시 돌려 거짓 통과를 되돌린다.
- 파일별 설계 문서 라우팅과 Figma 시각 비교 렌즈는 아직 없다.
