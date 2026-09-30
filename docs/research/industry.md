# 업계 자료

하네스 엔지니어링이라는 말이 생긴 과정과, 2026-10-01 기준의 흐름. 날짜는 글의 게시일이다.
"미확인" 은 요약·2차 출처로만 확인한 것이다.

## 1. 하네스 엔지니어링의 등장

| 날짜 | 출처 | 핵심 |
|---|---|---|
| 2024-12-19 | Anthropic, [*Building effective agents*](https://www.anthropic.com/engineering/building-effective-agents) | 에이전트 = 환경 피드백을 받으며 도구를 루프로 쓰는 LLM. 워크플로우와 에이전트 구분, evaluator-optimizer 패턴. 단순함이 기본 |
| 2025-07-14 | Geoffrey Huntley, [*Ralph*](https://ghuntley.com/ralph/) | `while :; do cat PROMPT.md \| claude-code; done`. 루프마다 할 일 하나, 테스트·타입 검사가 역압 |
| 2025-10-25 | LangChain, [*Agent Frameworks, Runtimes, and Harnesses*](https://www.langchain.com/blog/agent-frameworks-runtimes-and-harnesses-oh-my) | 프레임워크·런타임·하네스 구분. 하네스 = 기본값이 갖춰진 완성형 |
| 2025-11-26 | Anthropic, [*Effective harnesses for long-running agents*](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) | 초기화 에이전트(기능 목록 JSON·init.sh·진행 파일) + 세션마다 기능 하나씩 커밋하는 코딩 에이전트. 브라우저 테스트 도구가 성능을 크게 올림 |
| 2026-01-05 | Philipp Schmid, [*The Importance of Agent Harness in 2026*](https://www.philschmid.de/agent-harness-2026) | 모델 = CPU, 컨텍스트 = RAM, 하네스 = 운영체제. 하네스는 가볍게(Bitter Lesson) |
| 2026-02-05 | Mitchell Hashimoto, [*My AI Adoption Journey*](https://mitchellh.com/writing/my-ai-adoption-journey) | "에이전트가 한 번 나쁜 짓을 하면 다시는 못 하게 만든다." AGENTS.md 갱신 또는 도구 제작 |
| 2026-02-11 | OpenAI, [*Harness engineering*](https://openai.com/index/harness-engineering/) | 5개월·약 100만 줄·사람 코드 0줄. AGENTS.md 는 백과사전이 아니라 약 100줄짜리 지도. 린터·테스트로 구조 강제, 백그라운드 정리 에이전트. (원문 403, GeekNews·위키 요약으로 확인) |
| 2026-02-17 | Birgitta Böckeler, [*Harness Engineering – first thoughts*](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering-memo.html) | OpenAI 글을 컨텍스트 엔지니어링·구조 제약·정리로 읽음. 기능 동작 검증이 약하다고 비판 |
| 2026-02-17 | LangChain, [*Improving Deep Agents with harness engineering*](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering) | 모델 고정, 하네스만 바꿔 Terminal-Bench 2.0 52.8→66.5%. 자기 검증 루프, 완료 전 체크리스트, 반복 감지 미들웨어 |
| 2026-03-10 | LangChain, [*The Anatomy of an Agent Harness*](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness) | 에이전트 = 모델 + 하네스. 파일시스템·코드 실행·샌드박스·메모리·컨텍스트 관리·계획과 검증 |
| 2026-03-24 | Anthropic, [*Harness design for long-running application development*](https://www.anthropic.com/engineering/harness-design-long-running-apps) | 계획자·생성자·평가자. 부품마다 "모델이 못 한다" 는 가정이 들어 있으니 빼 보며 시험하라 |
| 2026-04-02 | Böckeler, [*Harness engineering for coding agent users*](https://martinfowler.com/articles/harness-engineering.html) | 가이드(행동 전)와 센서(행동 후), 각각 계산형과 추론형. 행동 하네스가 가장 미성숙 |

## 2. 2026 하반기

| 날짜 | 출처 | 핵심 |
|---|---|---|
| 2026-06-07 | Peter Steinberger (The Register [보도](https://www.theregister.com/ai-and-ml/2026/06/24/loop-engineering-latest-ai-buzzword-still-needs-humans-in-the-loop/5261735)) | "에이전트에게 프롬프트를 주는 루프를 설계하라." 루프 엔지니어링이라는 말이 퍼짐 |
| 2026-06-08 | Addy Osmani, [*Loop Engineering*](https://addyo.substack.com/p/loop-engineering) | 자동화·워크트리·스킬·플러그인·서브에이전트. "루프는 일을 바꿀 뿐 당신을 지우지 않는다" |
| 2026-06-11 | Daniel Vaughan, [Terminal-Bench 2.1 정리](https://codex.danielvaughan.com/2026/06/11/terminal-bench-2-1-june-2026-benchmark-landscape-codex-cli-harness-engineering-model-scores/) | 같은 모델(GPT-5.5)이 Codex CLI 83.4%, Terminus 2 약 78% |
| 2026-07-17 | IBM, [*What is loop engineering?*](https://www.ibm.com/think/topics/loop-engineering) | 목표 → 행동 → 관찰 → 조정, 종료 기준 |
| 2026-09-24 | Marmelab, [*The State of AI Harness Engineering 2026*](https://marmelab.com/blog/2026/09/24/the-state-of-ai-harness-engineering-2026.html) | 같은 모델도 하네스 8종에서 68~88%. 391개 저장소 중 deny 규칙 커밋 12개. 보안 규칙의 4.4%만 실제 통제. 60%는 테스트도 eval 도 없음. Vercel 은 도구 80% 제거 후 80→100% |

## 3. 구글

| 날짜 | 무엇 | 핵심 |
|---|---|---|
| 2026-05-19 | [Antigravity Agent Harness](https://antigravity.google/blog/introducing-google-antigravity-sdk) | 데스크톱 앱·CLI·SDK·Gemini API Managed Agents 가 같은 런타임. 스킬(SKILL.md)·훅 9종·서브에이전트·MCP·컨텍스트 압축. SDK 핵심 런타임은 비공개 바이너리 |
| 2026-05-21 | [Agent Executor / google/ax](https://cloud.google.com/blog/products/ai-machine-learning/agent-executor-googles-distributed-agent-runtime) | 하네스 한 층 아래의 실행 런타임. 영속 실행·샌드박스·재개·궤적 분기. 하네스와 무관하게 동작 |
| 2026-08-31 | EnvHarness (Google Research) | 에이전트 약점에 맞춰 바뀌는 평가 환경. 에이전트 하네스가 아니라 평가용 (미확인) |
| 2026-09-18 | Antigravity `preview-09-2026` | Files API·Credentials API. 구글 수치: 파일 편집 출력 토큰 40%↓, 다단계 과제 완료율 최대 6%↑ (뉴스 보도로 확인, 공식 페이지 미렌더) |
| 2026-09-29 | RRSI 연구 | 하네스 자기 개선. [papers.md](papers.md) 6절 (미확인) |

## 4. GitHub 생태계 스냅숏 (2026-10-01, `gh api` 로 조회)

스타는 인기 지표이지 품질 지표가 아니다. 몇몇은 두 달 사이 20만 개 넘게 늘었다.

| 저장소 | 스타 | 종류 |
|---|---|---|
| openclaw/openclaw | 390,884 | 상시 실행 개인 에이전트 |
| obra/superpowers | 293,326 | 방법론 스킬 키트 |
| affaan-m/ECC | 270,042 | 훅·스킬·메모리 설정 키트 |
| NousResearch/hermes-agent | 250,277 | 자기 개선 에이전트 |
| deepseek-ai/deepseek-harness | 240,961 | 플러그인 구조 하네스 (2026-08 공개) |
| anomalyco/opencode | 211,106 | 오픈소스 코딩 하네스 |
| github/spec-kit | 139,534 | 스펙 주도 개발 |
| openai/codex | 127,386 | OS 수준 샌드박스 CLI |
| google-gemini/gemini-cli | 107,193 | Antigravity CLI 로 이전 중 |
| snarktank/ralph | 21,888 | 기능 목록이 빌 때까지 도는 루프 |
| langchain-ai/langgraph | 42,522 | 그래프 오케스트레이션 |

상위 하네스의 공통 요소: 에이전트 루프, 핵심 도구, MCP, 스킬, 서브에이전트, 훅, 샌드박스와 권한, 프로젝트 지침 파일과 진행 파일, 컨텍스트 압축, 스펙 주도 계획, 자기 검증, 다중 모델, eval 과 실행 기록.

## 5. 한국어 자료

- GeekNews, [하네스 엔지니어링: 에이전트 우선 세계에서 Codex 활용하기](https://news.hada.io/topic?id=27457) (OpenAI 글 요약)
- GeekNews, [하네스 엔지니어링이란?](https://news.hada.io/topic?id=27667)
- GeekNews, [코딩 에이전트 하네스 설계에 관한 실증 연구](https://news.hada.io/topic?id=33905)
- PyTorchKR, [루프 엔지니어링 자료](https://discuss.pytorch.kr/t/loop-engineering/10796)
