# 논문

agent-harness 의 설계 근거가 된 논문. 신뢰도 티어는 이전 프로젝트에서 게재지와 심사 상태를 arXiv 원문으로 직접 확인해 매긴 것을 따른다.
PDF 는 저장소에 넣지 않는다. arXiv 번호로 찾는다.

| 티어 | 뜻 | 쓰는 법 |
|---|---|---|
| A | 동료심사 통과, 상위 학회·저널 | 설계의 뼈대. 단정해도 된다 |
| B | 2024~25, 유명 연구소 + 인정 벤치마크 | 수치까지 인용 가능. 단독 단정은 A 로 |
| C | 2025~26 arXiv 프리프린트, 미심사 | 방향 참고만. 수치를 단독 근거로 쓰지 않는다 |
| 미확인 | 원문이나 게재지를 직접 확인하지 않음 (이전 조사의 3표 검증을 통과한 주장이라도 티어는 매기지 않았다) | 읽기 전에는 단독 근거로 쓰지 않는다 |

## 1. 자기 수정에는 외부 신호가 필요하다

루프의 종료 조건을 LLM 의 "다 됐다" 가 아니라 acceptance 명령과 결정론 게이트에 거는 근거.

| 티어 | 논문 | 핵심 | agent-harness 에서 |
|---|---|---|---|
| A | Huang et al., *LLMs Cannot Self-Correct Reasoning Yet*, ICLR 2024 (`2310.01798`) | 외부 피드백 없는 자기 수정은 실패하고 때로 악화된다 | 게이트 노드는 전부 명령 실행 |
| A | Kamoi et al., *When Can LLMs Actually Correct Their Own Mistakes?*, TACL 2024 (`2406.01297`) | 내재적 자기 수정은 자주 성능을 떨어뜨리고, 기존 연구는 과대평가했다 | 〃 |
| A | Gou et al., *CRITIC*, ICLR 2024 (`2305.11738`) | 도구 없이 자기 비판하면 악화된다 | 적대자에게 컨텍스트 명령과 파일 읽기를 준다 |
| A | Shinn et al., *Reflexion*, NeurIPS 2023 (`2303.11366`) | 외부 신호(단위 테스트) 기반의 언어적 반성 → HumanEval 80→91% | 실패 사유와 출력 끝부분을 다음 구현 프롬프트에 넣는다 |
| A | Chen et al., *Teaching LLMs to Self-Debug*, ICLR 2024 (`2304.05128`) | 실행 결과로 디버깅, 테스트가 있으면 +12% | acceptance 는 실행 가능한 명령이어야 한다 |
| 미확인 | Renze & Guven, *Self-Reflection in LLM Agents* (`2405.06682`) | 반성이 풍부할수록 이득(재시도 +4.1% < 해답 +13.9% < 복합 +14.6%). 단 외부 정보 누출에 기댄다 | 〃 |

## 2. 검증자와 판정

| 티어 | 논문 | 핵심 | agent-harness 에서 |
|---|---|---|---|
| A | Lightman et al., *Let's Verify Step by Step*, ICLR 2024 (`2305.20050`) | 과정 검증이 결과 검증보다 낫다 | 편집 직후 훅, 기능마다 게이트 |
| A | Zheng et al., *Judging LLM-as-a-Judge*, NeurIPS 2023 (`2306.05685`) | LLM 심판의 위치·장황함·자기 선호 편향 | 적대자는 구현자와 다른 에이전트, 기본값은 통과 |
| A | Wang et al., *Self-Consistency*, ICLR 2023 (`2203.11171`) | 다수 샘플 다수결 | 이전 프로젝트의 다수결 패널. 이번에는 넣지 않음(아래 파일럿 참고) |
| B | Zhuge et al., *Agent-as-a-Judge*, Meta 2024 (`2410.10934`) | 결과만 보는 판정(인간 일치 60~70%) 대신 전체 궤적 평가 → 90% | 적대자에게 diff 전체와 신규 파일을 준다 |
| B | Gandhi et al., *SWE-PRM*, IBM 2025 (`2509.02360`) | 추론 중 과정 보상 모델이 궤적을 교정 → SWE-bench Verified 40.0→50.6% | 반복 실패 감지는 이것의 아주 단순한 형태 |
| B | Kumar et al., *SCoRe*, Google DeepMind, ICLR 2025 보고 (`2409.12917`) | 강화학습으로 자기 수정을 학습 | 학습이 아니라 추론 시 가드라서 직접 쓰지 않음 |
| C | Raghavendra et al., *Agentic Rubrics* (`2601.04171`) | 실행 없는 검증 루브릭, SWE-Bench +3.5pp | 참고만 |

## 3. 제한된 자율과 게이트 속이기

| 티어 | 논문 | 핵심 | agent-harness 에서 |
|---|---|---|---|
| C | Lee, *Practical Limits of Autonomous Test Repair* (`2605.01471`) | 자율 수리 산출물 38% 실패, assertion 약화·테스트 삭제 관찰 | test-guard 를 결정론 검사로 만든 이유 |
| C | Gajjar, *Verify Before You Fix* (`2604.10800`) | 실행 검증 없이 고치면 불필요 수정 +131.7% | 게이트 통과 전에는 커밋하지 않는다 |
| C | Babu & Agrawal, *Self-Healing Agentic Orchestrators* (`2606.01416`) | 신뢰성 = 제한된 런타임 통제, 98.8% vs 단순 재시도 94.5% | 시도 한도·반복 한도·예산 하한 |

## 4. 컨텍스트: 많이 넣는다고 좋아지지 않는다

| 티어 | 논문 | 핵심 | agent-harness 에서 |
|---|---|---|---|
| A | Liu et al., *Lost in the Middle*, TACL 2024 (`2307.03172`) | 위치만 옮겨도 멀티홉 QA 20~30점 하락 | 세션 주입은 원장 요약과 진행 상태만 |
| A | *Context Length Alone Hurts LLM Performance Despite Perfect Retrieval*, EMNLP 2025 Findings (`2510.05381`) | 완벽히 검색해도 길이만 늘면 13.9~85% 저하 | 〃 |
| A | *Found in the Middle*, ACL 2024 Findings (`2406.16008`) | 보정 기법은 attention 가중치가 필요해 닫힌 API 에서 못 쓴다 | 검색·발췌 같은 블랙박스 방법만 쓴다 |

## 5. 멀티에이전트: 코딩에는 조심

| 티어 | 논문 | 핵심 | agent-harness 에서 |
|---|---|---|---|
| 미확인 | Cemri et al., *Why Do Multi-Agent LLM Systems Fail? (MAST)* (`2503.13657`) | 14가지 실패 모드, 인계할 때 컨텍스트 손실이 지배적 | 병렬 분기를 넣지 않은 이유 |
| 미확인 | Du et al., *Multi-Agent Debate* (`2305.14325`) | 토론으로 사실성 향상 | 참고만 |
| 미확인 | `2510.26585` | 같은 토큰 예산이면 단일 에이전트가 우세하다는 시사 | 이전 조사의 한계 절에서 인용. 원문 미정독 |

## 6. 2026 루프·그래프 엔지니어링 (이번 조사)

| 티어 | 논문 | 핵심 | agent-harness 에서 |
|---|---|---|---|
| C | Lulla, Treude, Baltes et al., *Loop Engineering: Building Blocks, Adoption, and Impact* (`2608.21884`, 2026-08) | 좋은 루프 = 트리거, 기계 판정 종료 조건, 상태 파일, 검증 서브에이전트, 토큰 예산, 사람 에스컬레이션 | 루프 설계 체크리스트. 트리거만 아직 없음 |
| C | Feng et al., *Graph Engineering in the Era of LLM Agents* (`2608.21156`, 2026-08) | 프롬프트 → 컨텍스트 → 하네스 → 루프 → 그래프 엔지니어링 순서 제안 | 용어의 출처. 아직 현업 용어는 아님 |
| C | Hu Wei, *From Agent Loops to Structured Graphs* (`2604.11378`, 2026-04) | 자유 루프의 문제(암묵적 의존, 무한 복구, 섞인 이력) → 명시적 그래프·불변 계획·에스컬레이션 복구. 실험 없는 입장 논문 | 상태 기계로 된 원장과 사람 노드 |
| 미확인 | *RRSI: Regularized Recursive Self-Improvement of Agent Harnesses*, Google (`2609.24972`, 2026-09) | 모델 재학습 없이 하네스(프롬프트·도구·흐름·메모리)를 스스로 고쳐 Terminal-Bench 2.1 74.2→80.2% | 국내 기사로만 확인. 원문 미정독 |
