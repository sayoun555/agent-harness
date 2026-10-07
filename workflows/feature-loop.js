export const meta = {
  name: 'feature-loop',
  description: '기능 원장의 pending 기능을 하나씩 구현 → 결정론 게이트 → 독립 검증 → 기록하는 제한 루프. 막히거나 위험하면 사람에게 넘긴다.',
  whenToUse: '.harness/features.json 에 acceptance 가 있는 pending 기능이 있을 때. args: { maxIterations, parallel }',
  phases: [
    { title: 'Preflight', detail: '원장 · acceptance · 작업 트리(또는 기준선) 점검' },
    { title: 'Loop', detail: '선택 → 구현 → 게이트 → 검증 → 기록, 기능마다 반복' },
    { title: 'Audit', detail: '통과한 기능의 acceptance 재실행 + 최종 상태' },
  ],
}

// ── 그래프 ─────────────────────────────────────────────────────────
//
//   선택 ─▶ 구현 ─▶ 게이트(verify) ─▶ 검증(review) ─▶ 기록(record) ─▶ 선택 …
//            ▲        │실패              │반려
//            └────────┴──────────────────┘  실패 사유를 다음 구현에 넣는다 (시도 한도 · 반복 감지는 원장이 판정)
//
//   구현 노드에서 스스로 정할 수 없는 설계 결정을 만나면 질문을 남기고 판단 대기로 빠진다.
//   기록 노드에서 위험 파일이면 기록하지 않고 사람 승인 대기로 빠진다.
//   막힘 · 승인 대기 · 판단 대기 기능은 다시 선택되지 않고, 그 변경은 치워서 보관된다.
//
//   병렬(parallel ≥ 2) — 구현만 동시에, 게이트부터는 하나씩.
//     커밋 운용   각자 워크트리에서 구현해 harness/wip-<id> 에 커밋 → adopt 로 가져온다
//     커밋 없음   같은 작업 트리에서 구현하고 바꾼 파일을 claim → 게이트·검증·기록이 그 범위만 본다
//
// 상태 전이와 지시문은 전부 harness CLI 가 만든다. 이 스크립트는 흐름만 제어한다.

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
    filesChanged: { type: 'array', items: { type: 'string' }, description: '바꾸거나 만든 파일 경로 전부' },
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
    reason: { type: 'string', description: '반려면 무엇·어느 기준(ID)·고칠 방법 1~2문장. 통과면 한 줄.' },
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

let currentPhase = 'Preflight'

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

// ── 지시문 ─────────────────────────────────────────────────────────
// 구현자 지시문은 harness feature brief 한 곳에서 만든다 (루프 없이 진행하는 스킬과 같다).
async function briefFor(feature, mode) {
  const brief = await runHarness(`feature brief ${feature.id} --mode ${mode} --json`, `지시문:${tagOf(feature)}`)
  return brief && brief.prompt
}

// 사전 점검에서 연결된 MCP 만 검증 지시로 붙인다. 없으면 지시도 없다.
let runtimeHints = []

function reviewPrompt(feature) {
  const runtime = runtimeHints.length
    ? ['', '[런타임 확인 — 연결된 MCP]', ...runtimeHints.map((h) => `- ${h}`)].join('\n')
    : ''
  return [
    '너는 이 기능을 구현하지 않은 독립 검증자(적대자)다.',
    `먼저 \`${HARNESS} review --context ${feature.id}\` 를 실행해 프로토콜·기준·footgun·diff 를 읽는다.`,
    '필요하면 바뀐 파일을 Read 로 직접 확인한다. 파일을 수정하거나 커밋하지 마라.',
    '컴파일·테스트·acceptance 는 이미 통과했다. 그것들이 못 잡는 의미 위반과 구조 문제를 본다.',
    '반려할 때는 어긴 기준의 ID 를 적는다. 확신이 없으면 통과(approved=true)다.',
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
  const decision = verdict.approved ? '--approve' : '--reject'
  const reviewed = await runHarness(
    `feature review ${feature.id} ${decision} --reason ${shellQuote(verdict.reason)} --json`, `판정:${tag}`)
  if (!verdict.approved) {
    return { ...step, node: 'review', result: reviewed ? reviewed.status : 'no-response', reason: verdict.reason }
  }

  const recorded = await runHarness(`feature record ${feature.id} --json`, `기록:${tag}`)
  return { ...step, node: 'record', result: recorded ? recorded.result : 'no-response', reason: recorded ? recorded.reason : '' }
}

async function implement(feature, mode, schema, extra = {}) {
  const prompt = await briefFor(feature, mode)
  if (!prompt) return null
  return agent(prompt, { label: `구현:${tagOf(feature)}`, phase: 'Loop', schema, ...extra })
}

// ── 한 바퀴: 순차 ──────────────────────────────────────────────────
async function runSequential(feature, iteration) {
  const work = await implement(feature, 'sequential', IMPLEMENTATION)
  return (await askIfNeeded(feature, work, iteration)) || gateReviewRecord(feature, iteration)
}

// ── 한 바퀴: 병렬 ──────────────────────────────────────────────────
// 커밋 운용: 각자 워크트리에서 구현하고, 결과 브랜치를 하나씩 가져온다. 실패면 그 결과를, 아니면 null.
async function bringInFromWorktree(feature, work, iteration) {
  const branch = (work && work.branch) || `harness/wip-${feature.id}`
  const adopted = await runHarness(`feature adopt ${feature.id} ${shellQuote(branch)} --json`, `가져오기:${tagOf(feature)}`)
  if (adopted && adopted.result === 'adopted') return null
  return { ...stepOf(feature, iteration), node: 'adopt', result: adopted ? adopted.status : 'no-response', reason: adopted ? adopted.reason : '' }
}

// 커밋 없음: 같은 트리에서 구현했으니, 바꾼 파일을 그 기능의 범위로 적는다.
async function claimInSharedTree(feature, work) {
  const files = (work && work.filesChanged) || []
  if (files.length) await runHarness(`feature claim ${feature.id} --files ${shellQuote(files.join(','))} --json`, `범위:${tagOf(feature)}`)
  return null
}

async function runParallel(batch, iteration, autoCommit) {
  const mode = autoCommit ? 'isolated' : 'shared'
  const schema = autoCommit ? ISOLATED_IMPLEMENTATION : IMPLEMENTATION
  const extra = autoCommit ? { isolation: 'worktree' } : {}
  const works = await parallel(batch.map((feature) => () => implement(feature, mode, schema, extra)))

  const outcomes = []
  for (let i = 0; i < batch.length; i++) {
    const feature = batch[i]
    const work = works[i]
    const asked = await askIfNeeded(feature, work, iteration)
    if (asked) { outcomes.push(asked); continue }
    const failed = autoCommit ? await bringInFromWorktree(feature, work, iteration) : await claimInSharedTree(feature, work)
    outcomes.push(failed || await gateReviewRecord(feature, iteration))
  }
  return outcomes
}

// ── 실행 ───────────────────────────────────────────────────────────
phase('Preflight')
const preflight = await runHarness('feature preflight --json', 'preflight')
if (!preflight || !preflight.ok) {
  log('preflight 실패 — 루프를 시작하지 않는다.')
  return { stopReason: 'preflight-failed', problems: preflight ? preflight.problems : ['응답 없음'] }
}
for (const note of preflight.notes || []) log(note)
const AUTO_COMMIT = preflight.autoCommit !== false
const mcp = Array.isArray(preflight.mcp) ? preflight.mcp : []
runtimeHints = mcp.filter((m) => m.state === 'connected' && m.reviewHint).map((m) => m.reviewHint)
const mcpSuggestions = mcp.filter((m) => m.state !== 'connected')
  .map((m) => ({ name: m.name, state: m.state, purpose: m.purpose, install: m.install }))
if (runtimeHints.length) log(`런타임 검증 MCP 연결됨: ${mcp.filter((m) => m.state === 'connected').map((m) => m.name).join(', ')}`)

const PARALLEL = Math.max(1, Number((args && args.parallel) || preflight.parallel || 1))
if (PARALLEL > 1) log(`병렬 모드: 한 바퀴에 최대 ${PARALLEL}개 기능 동시 구현 (${AUTO_COMMIT ? '워크트리' : '같은 트리 + 범위'})`)
if (!AUTO_COMMIT) log('커밋 없이 운용: 기록은 원장과 기준선에만 남는다')

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
    outcomes = await runParallel(batch, iteration, AUTO_COMMIT)
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
const features = Array.isArray(ledger) ? ledger : []
const byStatus = (status) => features
  .filter((f) => f.status === status)
  .map((f) => ({ id: f.id, reason: f.lastFailure || '' }))

return {
  stopReason,
  autoCommit: AUTO_COMMIT,
  iterations: steps.length,
  passing: byStatus('passing').map((f) => f.id),
  needsDecision: features                             // 사람: harness feature decide ID --answer 답
    .filter((f) => f.status === 'needs-decision').map((f) => ({ id: f.id, question: f.question })),
  awaitingApproval: byStatus('awaiting-approval'),    // 사람: harness feature approve ID
  blocked: byStatus('blocked'),                       // 사람: 원인 해결 후 harness feature reset ID
  interrupted: [...byStatus('verified'), ...byStatus('reviewed')].map((f) => f.id),  // 판정 뒤 기록 전에 끊긴 기능
  pending: byStatus('pending').map((f) => f.id),
  auditRegressions: audit ? audit.regressed : [],
  mcpSuggestions,                                     // 사람: 설치할지 결정 (하네스는 설치하지 않는다)
  steps,
}
