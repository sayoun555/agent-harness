# 리서치

agent-harness 가 왜 이렇게 생겼는지의 근거.

| 문서 | 내용 |
|---|---|
| [papers.md](papers.md) | 논문과 신뢰도 티어 |
| [industry.md](industry.md) | 하네스·루프·그래프 엔지니어링 업계 자료, 구글, GitHub 생태계 |
| [pilot-evidence.md](pilot-evidence.md) | 이전 프로젝트 하네스의 16개 파일럿 실험과 한계 |
| [base-assessment.md](base-assessment.md) | 이전 하네스가 좋은 베이스였는지, 무엇을 물려받았는지, 어떻게 확정할지 |

## 설계 결정과 근거

| 결정 | 근거 | 근거의 강도 |
|---|---|---|
| 루프 종료 조건은 LLM 판단이 아니라 acceptance 명령 | Huang ICLR'24, Kamoi TACL'24, CRITIC ICLR'24 | 강함 (A) |
| 실패 사유와 출력을 다음 시도에 넣는다 | Reflexion NeurIPS'23, Self-Debug ICLR'24 | 강함 (A) |
| 적대자는 구현자와 다른 에이전트, 기본값은 통과 | Zheng NeurIPS'23, 파일럿 ADVERSARY | 중간 (A + 작은 파일럿) |
| 적대자에게 diff 전체와 신규 파일을 준다 | Agent-as-a-Judge (Meta'24) | 중간 (B) |
| 테스트 약화를 결정론으로 검사 | Lee `2605.01471` | 약함 (C) — 방향만 |
| 시도 한도·같은 실패 반복 한도·예산 하한 | SWE-PRM (IBM'25), `2606.01416`, 루프 엔지니어링 `2608.21884` | 중간 (B + C) |
| 규칙 주입을 늘리지 않는다 | 파일럿 COMPLIANCE·BOUNDARY·DRIFT, Lost in the Middle TACL'24, `2510.05381` | 중간 (A + 작은 파일럿) |
| 생성 규칙은 강제하지 않고 과설계도 위반으로 본다 | 파일럿 GENQUALITY, Vercel 도구 축소 사례 | 약함 (파일럿 n=1~2) |
| 병렬 분기를 넣지 않는다 | Cognition·Anthropic 합의, MAST | 중간 |
| 사람 노드: 위험 파일 승인, 막힘, 판단 요청 | Böckeler 2026-04, Osmani 2026-06, `2604.11378` | 약함~중간 (업계 합의, 실험 없음) |
| 통과 못 한 변경은 브랜치에 보관 | 이번 구현에서 찾은 결함(승인 대기 코드가 다음 커밋에 섞임) | 테스트로 확인 |
| 약한 한국어 마커는 경고만 | 이전 프로젝트 트러블슈팅, 이번 파일럿에서 재현 | 사례 2건 |

근거가 "약함" 인 줄은 측정으로 바뀔 수 있다. [base-assessment.md](base-assessment.md) 의 비교 실험이 그 측정이다.
