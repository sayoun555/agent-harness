export const meta = {
  name: 'feature-loop',
  description: '기능 원장의 pending 기능을 하나씩 구현 → 결정론 게이트 → 독립 적대자 → 커밋하는 제한 루프. 막히거나 위험하면 사람에게 넘긴다.',
  whenToUse: '.harness/features.json 에 acceptance 가 있는 pending 기능이 있고, 작업 트리가 깨끗할 때. args: { maxIterations, parallel }',
  phases: [
    { title: 'Preflight', detail: '깨끗한 트리 · 원장 · acceptance 점검' },
    { title: 'Loop', detail: '선택 → 구현 → 게이트 → 검증 → 기록, 기능마다 반복' },
    { title: 'Audit', detail: '통과한 기능의 acceptance 재실행 + 최종 상태' },
  ],
}

// ── 그래프 ─────────────────────────────────────────────────────────
//
//   선택 ─▶ 구현 ─▶ 게이트 ─▶ 검증 ─▶ 기록 ─▶ 선택 …
//            ▲       │실패      │반려
//            └───────┴──────────┘  실패 사유를 다음 구현에 넣는다 (시도 한도 · 반복 감지는 원장이 판정)
//   구현 노드에서 스스로 정할 수 없는 설계 결정을 만나면 질문을 남기고 판단 대기로 빠진다.
//   기록 노드에서 위험 파일이면 커밋하지 않고 사람 승인 대기로 빠진다.
//   blocked · awaiting-approval · needs-decision 기능은 다시 선택되지 않는다.
//   그 변경은 harness/<id> 브랜치에 보관된다. 사람이 approve · decide · reset 한다.
//
//   병렬(loop.parallel ≥ 2): 한 바퀴에 기능 여러 개를 각자 워크트리에서 동시에 구현하고
//   harness/wip-<id> 브랜치에 커밋한다. 가져오기·게이트·검증·기록은 하나씩 한다(원장은 한 곳에서만 쓴다).
//   두 기능이 같은 곳을 고쳐 충돌하면 실패로 기록되고, 다음 시도에서 최신 HEAD 위에 다시 구현한다.
//
// 상태 전이는 전부 harness CLI(결정론 스크립트)가 한다. 이 스크립트는 흐름만 제어한다.

const HARNESS = '.harness/bin/harness'
const MAX_ITERATIONS = (args && args.maxIterations) || 20
const BUDGET_FLOOR = 50000

// ── 스키마 ─────────────────────────────────────────────────────────
const COMMAND_RESULT = {
  type: 'object',
  properties: {
    exitCode: { type: 'integer' },
    stdout: { type: 'string', description: 'stdout 원문 그대로. 요약·해석 금지.' },
  },
  required: ['exitCode', 'stdout'],
}

const IMPLEMENTATION = {
  type: 'object',
  properties: {
    needsDecision: { type: 'boolean', description: '사람이 정해야 할 설계 결정 때문에 구현하지 않았으면 true' },
    question: { type: 'string', description: 'needsDecision 일 때: 사람에게 묻는 질문 하나와 선택지. 아니면 빈 문자열' },
    summary: { type: 'string', description: '무엇을 어떻게 바꿨는지 2~3문장' },
    filesChanged: { type: 'array', items: { type: 'string' } },
  },
  required: ['needsDecision', 'question', 'summary', 'filesChanged'],
}

// 워크트리에서 구현할 때는 결과 브랜치를 함께 돌려준다
const ISOLATED_IMPLEMENTATION = {
  type: 'object',
  properties: {
    ...IMPLEMENTATION.properties,
    branch: { type: 'string', description: '구현을 커밋한 브랜치 이름. needsDecision 이면 빈 문자열' },
  },
  required: [...IMPLEMENTATION.required, 'branch'],
}

const VERDICT = {
  type: 'object',
  properties: {
    approved: { type: 'boolean' },
    reason: { type: 'string', description: '반려면 무엇·어느 기준·고칠 방법 1~2문장. 통과면 한 줄.' },
  },
  required: ['approved', 'reason'],
}

// ── 결정론 노드: harness CLI 한 줄 실행 ──────────────────────────────
function shellQuote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'"
}

function lastJsonLine(stdout) {
  const lines = String(stdout || '').trim().split('\n').reverse()
  for (const line of lines) {
    try { return JSON.parse(line) } catch (e) { /* JSON 이 아닌 줄은 건너뛴다 */ }
  }
  return null
}

async function runHarness(command, label) {
  const result = await agent(
    [
      '다음 셸 명령 하나만 Bash 도구로 그대로 실행하라.',
      '다른 명령을 실행하거나 파일을 수정하지 마라. 결과를 해석하지 말고 exitCode 와 stdout 원문을 반환하라.',
      '',
      `${HARNESS} ${command}`,
    ].join('\n'),
    { label, phase: currentPhase, schema: COMMAND_RESULT, effort: 'low' }
  )
  return result ? lastJsonLine(result.stdout) : null
}

// ── LLM 노드 ───────────────────────────────────────────────────────
function implementPrompt(feature) {
  const retry = feature.attempts > 0
    ? [
        '',
        `[직전 시도 실패 — 이번에 반드시 해결한다] ${feature.lastFailure}`,
        feature.lastFailureDetail ? '```\n' + feature.lastFailureDetail + '\n```' : '',
      ].join('\n')
    : ''
  const decisions = (feature.decisions || []).length
    ? ['', '[사람이 내린 결정 — 그대로 따른다]', ...feature.decisions.map((d) => `- ${d.question} → ${d.answer}`)].join('\n')
    : ''
  return [
    '너는 기능 하나를 구현하는 코더다. 이 저장소의 CLAUDE.md·AGENTS.md 규칙을 따른다.',
    `기능 id: ${feature.id}`,
    `설명: ${feature.description}`,
    `완료 기준(acceptance): \`${feature.acceptance}\``,
    feature.designDoc ? `설계 문서: ${feature.designDoc} — 먼저 읽고, 이 기능에 해당하는 구성 요소와 설계 결정을 그대로 따른다.` : '',
    decisions,
    retry,
    '',
    '규칙',
    '- 이 기능에 필요한 만큼만 바꾼다. 요구되지 않은 추상화는 만들지 않는다.',
    `- 검증자는 이 저장소의 코드 기준으로 판정한다. 필요하면 \`${HARNESS} review --criteria\` 로 본다.`,
    '- 끝내기 전에 acceptance 명령을 직접 실행해 통과를 확인한다.',
    '- 테스트를 지우거나, assertion 을 줄이거나, skip 하지 않는다. 하네스가 감시한다.',
    '- .harness/features.json 을 편집하지 않고, git commit 하지 않는다. 판정과 커밋은 하네스가 한다.',
    '',
    '판단 요청',
    '- 기능 설명·저장소 코드·설계 문서·위의 결정으로 정할 수 없는 설계 결정이 있으면, 추측으로 고르지 않는다.',
    '  아무 파일도 바꾸지 말고 needsDecision=true 와 질문 하나(선택지 포함)를 돌려준다.',
    '- 이름·파일 배치 같은 사소한 구현 세부는 기존 코드 관례를 따라 스스로 정한다. 묻지 않는다.',
  ].join('\n')
}

function wipBranch(feature) { return `harness/wip-${feature.id}` }

// 워크트리 구현자: 같은 규칙에, 커밋 대상을 자기 브랜치로 바꾼다
function isolatedImplementPrompt(feature) {
  return implementPrompt(feature).replace(
    '- .harness/features.json 을 편집하지 않고, git commit 하지 않는다. 판정과 커밋은 하네스가 한다.',
    [
      '- 너는 따로 떨어진 git 워크트리에 있다. 다른 기능이 동시에 다른 워크트리에서 구현되고 있다.',
      '- .harness/features.json 을 편집하지 않는다. 판정과 최종 커밋은 하네스가 메인 작업 트리에서 한다.',
      '- 의존성(node_modules 등)이 없어 acceptance 를 못 돌리면 건너뛰어도 된다. 하네스가 메인에서 다시 검증한다.',
      '- 구현을 마치면 아래 명령으로 네 브랜치에 커밋하고, branch 에 그 이름을 돌려준다.',
      '```bash',
      `git checkout -q -b ${wipBranch(feature)}`,
      "git add -A -- . ':(exclude).harness/features.json'",
      `git commit -q -m "wip(${feature.id})"`,
      '```',
    ].join('\n'))
}

// 사전 점검에서 연결된 MCP 만 검증 지시로 붙인다. 없으면 지시도 없다.
let runtimeHints = []

function reviewPrompt(feature) {
  const runtime = runtimeHints.length
    ? ['', '[런타임 확인 — 연결된 MCP]', ...runtimeHints.map((h) => `- ${h}`)].join('\n')
    : ''
  return [
    '너는 이 기능을 구현하지 않은 독립 검증자(적대자)다.',
    `먼저 \`${HARNESS} review --context ${feature.id}\` 를 실행해 프로토콜·스택 기준·footgun·diff 를 읽는다.`,
    '필요하면 바뀐 파일을 Read 로 직접 확인한다. 파일을 수정하거나 커밋하지 마라.',
    '컴파일·테스트·acceptance 는 이미 통과했다. 그것들이 못 잡는 의미 위반만 본다.',
    '확신이 없으면 통과(approved=true)다.',
    runtime,
  ].join('\n')
}

// ── 노드 ───────────────────────────────────────────────────────────
function tagOf(feature) { return `${feature.id}#${feature.attempts + 1}` }
function stepOf(feature, iteration) { return { iteration, feature: feature.id, attempt: feature.attempts + 1 } }

// 구현자가 판단을 요청했으면 원장에 질문을 남긴다. 요청하지 않았으면 null.
async function askIfNeeded(feature, work, iteration) {
  if (!(work && work.needsDecision && work.question)) return null
  const asked = await runHarness(`feature ask ${feature.id} --question ${shellQuote(work.question)} --json`, `질문:${tagOf(feature)}`)
  return { ...stepOf(feature, iteration), node: 'implement', result: asked ? asked.status : 'no-response', reason: work.question }
}

// 게이트 → 검증 → 기록. 변경이 이미 메인 작업 트리에 있어야 한다.
async function gateReviewRecord(feature, iteration) {
  const tag = tagOf(feature)
  const step = stepOf(feature, iteration)
  const gate = await runHarness(`feature verify ${feature.id} --json`, `게이트:${tag}`)
  if (!gate || gate.result !== 'pass') {
    return { ...step, node: 'gate', result: gate ? gate.status : 'no-response', reason: gate ? gate.reason : '' }
  }

  // 검증자가 응답하지 않으면 통과로 치지 않는다. 반려로 기록하고 다음 시도에 맡긴다.
  const verdict = await agent(reviewPrompt(feature), { label: `검증:${tag}`, phase: 'Loop', schema: VERDICT })
    || { approved: false, reason: '검증자 응답 없음' }
  if (!verdict.approved) {
    const rejected = await runHarness(
      `feature reject ${feature.id} --reason ${shellQuote(verdict.reason)} --json`, `반려:${tag}`)
    return { ...step, node: 'review', result: rejected ? rejected.status : 'no-response', reason: verdict.reason }
  }

  const recorded = await runHarness(`feature commit ${feature.id} --json`, `기록:${tag}`)
  return { ...step, node: 'record', result: recorded ? recorded.result : 'no-response', reason: recorded ? recorded.reason : '' }
}

// ── 한 바퀴: 순차 ──────────────────────────────────────────────────
async function runSequential(feature, iteration) {
  const work = await agent(implementPrompt(feature), { label: `구현:${tagOf(feature)}`, phase: 'Loop', schema: IMPLEMENTATION })
  return (await askIfNeeded(feature, work, iteration)) || gateReviewRecord(feature, iteration)
}

// ── 한 바퀴: 병렬 ──────────────────────────────────────────────────
// 구현만 동시에(워크트리), 가져오기부터는 하나씩.
async function runParallel(batch, iteration) {
  const works = await parallel(batch.map((feature) => () =>
    agent(isolatedImplementPrompt(feature), {
      label: `구현:${tagOf(feature)}`, phase: 'Loop', schema: ISOLATED_IMPLEMENTATION, isolation: 'worktree',
    })))
  const outcomes = []
  for (let i = 0; i < batch.length; i++) {
    const feature = batch[i]
    const work = works[i]
    const asked = await askIfNeeded(feature, work, iteration)
    if (asked) { outcomes.push(asked); continue }
    const branch = (work && work.branch) || wipBranch(feature)
    const adopted = await runHarness(`feature adopt ${feature.id} ${shellQuote(branch)} --json`, `가져오기:${tagOf(feature)}`)
    if (!adopted || adopted.result !== 'adopted') {
      outcomes.push({ ...stepOf(feature, iteration), node: 'adopt', result: adopted ? adopted.status : 'no-response', reason: adopted ? adopted.reason : '' })
      continue
    }
    outcomes.push(await gateReviewRecord(feature, iteration))
  }
  return outcomes
}

// ── 실행 ───────────────────────────────────────────────────────────
let currentPhase = 'Preflight'
phase('Preflight')
const preflight = await runHarness('feature preflight --json', 'preflight')
if (!preflight || !preflight.ok) {
  log('preflight 실패 — 루프를 시작하지 않는다.')
  return { stopReason: 'preflight-failed', problems: preflight ? preflight.problems : ['응답 없음'] }
}
const mcp = Array.isArray(preflight.mcp) ? preflight.mcp : []
runtimeHints = mcp.filter((m) => m.state === 'connected' && m.reviewHint).map((m) => m.reviewHint)
const mcpSuggestions = mcp.filter((m) => m.state !== 'connected')
  .map((m) => ({ name: m.name, state: m.state, purpose: m.purpose, install: m.install }))
if (runtimeHints.length) log(`런타임 검증 MCP 연결됨: ${mcp.filter((m) => m.state === 'connected').map((m) => m.name).join(', ')}`)

const PARALLEL = Math.max(1, Number((args && args.parallel) || preflight.parallel || 1))
if (PARALLEL > 1) log(`병렬 모드: 한 바퀴에 최대 ${PARALLEL}개 기능을 워크트리에서 동시에 구현`)

currentPhase = 'Loop'
phase('Loop')
const steps = []
let stopReason = 'max-iterations'
for (let iteration = 1; iteration <= MAX_ITERATIONS; iteration++) {
  if (budget.total && budget.remaining() < BUDGET_FLOOR) { stopReason = 'budget'; break }

  let outcomes
  if (PARALLEL > 1) {
    const batch = await runHarness(`feature next --json --limit ${PARALLEL}`, `선택#${iteration}`)
    if (!Array.isArray(batch) || batch.length === 0) { stopReason = 'all-done'; break }
    outcomes = await runParallel(batch, iteration)
  } else {
    const feature = await runHarness('feature next --json', `선택#${iteration}`)
    if (!feature || !feature.id) { stopReason = 'all-done'; break }
    outcomes = [await runSequential(feature, iteration)]
  }
  for (const outcome of outcomes) {
    outcome.outputTokensSoFar = budget.spent()
    steps.push(outcome)
    log(`[${iteration}/${MAX_ITERATIONS}] ${outcome.feature}: ${outcome.node} → ${outcome.result}`)
  }
}
if (stopReason === 'max-iterations') log(`최대 ${MAX_ITERATIONS}바퀴에 도달 — 남은 기능은 다음 실행에서 이어간다.`)

currentPhase = 'Audit'
phase('Audit')
const audit = await runHarness('feature audit --json', 'audit')
const ledger = await runHarness('feature list --json', '원장')
const byStatus = (status) => (Array.isArray(ledger) ? ledger : [])
  .filter((f) => f.status === status)
  .map((f) => ({ id: f.id, reason: f.lastFailure || '' }))

return {
  stopReason,
  iterations: steps.length,
  passing: byStatus('passing').map((f) => f.id),
  needsDecision: (Array.isArray(ledger) ? ledger : [])   // 사람: harness feature decide ID --answer 답
    .filter((f) => f.status === 'needs-decision').map((f) => ({ id: f.id, question: f.question })),
  awaitingApproval: byStatus('awaiting-approval'),   // 사람: harness feature approve ID
  blocked: byStatus('blocked'),                      // 사람: 원인 해결 후 harness feature reset ID
  interrupted: byStatus('verified').map((f) => f.id),  // 검증 뒤 기록 전에 끊긴 기능 (정상 실행에선 비어 있다)
  pending: byStatus('pending').map((f) => f.id),
  auditRegressions: audit ? audit.regressed : [],
  mcpSuggestions,                                    // 사람: 설치할지 결정 (하네스는 설치하지 않는다)
  steps,
}
