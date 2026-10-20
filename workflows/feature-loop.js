export const meta = {
  name: 'feature-loop',
  description: '기능 원장의 pending 기능을 하나씩 구현 → 결정론 게이트 → 독립 검증 → 기록하는 제한 루프. 막히거나 위험하면 사람에게 넘긴다.',
  whenToUse: '.harness/features.json 에 acceptance 가 있는 pending 기능이 있을 때. args: { maxIterations, parallel, agents, projectRoot }',
  phases: [
    { title: 'Preflight', detail: '원장 · acceptance · 작업 트리(또는 기준선) 점검' },
    { title: 'Loop', detail: '선택 → 구현 → 게이트 → 검증 → 기록, 기능마다 반복' },
    { title: 'Audit', detail: '통과한 기능의 acceptance 재실행 + 최종 상태' },
  ],
}

// ── 그래프 ─────────────────────────────────────────────────────────
//
//   선택 ─▶ 구현 ─▶ (범위) ─▶ 게이트(verify) ─▶ 검증(대조표 → review) ─▶ 기록(record) ─▶ 선택 …
//            ▲                  │실패              │반려
//            └──────────────────┴──────────────────┘  실패 사유를 다음 구현에 넣는다 (시도 한도 · 반복 감지는 원장이 판정)
//
//   구현 노드에서 스스로 정할 수 없는 설계 결정을 만나면 질문을 남기고 판단 대기로 빠진다.
//   기록 노드에서 위험 파일이면 기록하지 않고 사람 승인 대기로 빠진다.
//   막힘 · 승인 대기 · 판단 대기 기능은 다시 선택되지 않고, 그 변경은 치워서 보관된다.
//
//   커밋 없이 운용하면 구현자가 바꾼 파일을 그 기능의 범위로 적는다(claim). 게이트·검증·기록이 그 범위만 본다.
//   순차든 병렬이든 같다 — 다른 기능의 변경이 트리에 남아 있어도 누구 변경인지 가를 수 있다.
//
//   병렬(parallel ≥ 2) — 구현만 동시에, 게이트부터는 하나씩.
//     커밋 운용   각자 워크트리에서 구현해 harness/wip-<id> 에 커밋 → adopt 로 가져온다
//     커밋 없음   같은 작업 트리에서 구현하고 바꾼 파일을 claim
//
//   원장이 세지 않는 반복(명령 거부 · 응답 없음 · 범위 겹침 · 다시 열림)은 원장의 시도 한도에 걸리지 않는다.
//   같은 기능이 같은 노드에서 같은 결과로, 시도 횟수도 그대로인 채 두 번 연속이면 루프를 멈추고 사람에게 넘긴다.
//
// 상태 전이와 지시문은 전부 harness CLI 가 만든다. 이 스크립트는 흐름만 제어한다.

// 세션의 작업 디렉터리가 프로젝트 루트가 아니어도 되도록, 루트를 받으면 거기서 명령을 실행한다.
const PROJECT_ROOT = (args && args.projectRoot) || ''
const HARNESS = PROJECT_ROOT ? `cd ${shellQuote(PROJECT_ROOT)} && .harness/bin/harness` : '.harness/bin/harness'
const MAX_ITERATIONS = (args && args.maxIterations) || 20
const BUDGET_FLOOR = 50000

// 원장은 필요한 필드만 읽는다. 전체에는 실패 출력 · 대조표가 실려 커지고, 명령 실행 에이전트가 옮기는 동안 걸러질 수 있다.
const SELECT_FIELDS = 'id,attempts,figma'                 // 선택: 태그 · 시도 횟수 · 구현자 종류
const SUMMARY_FIELDS = 'id,status,lastFailure,question'   // 끝 요약

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

// 검증자의 대조표. 승인·반려는 하네스가 이 표로 정한다(lib/verdict.sh). 빠진 항목이 있으면 반려된다.
const VERDICT = {
  type: 'object',
  properties: {
    checks: {
      type: 'array',
      description: '"대조표 항목" 의 모든 ID 를 하나씩',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: '항목 ID (REQ · REG · Q1 · K6 · A2 · P3 …)' },
          result: { type: 'string', enum: ['kept', 'violated', 'na'] },
          where: { type: 'string', description: 'violated 면 파일:줄. 아니면 빈 문자열' },
          note: { type: 'string', description: 'kept 는 근거, violated 는 무엇·고칠 방법(구조로 — 특정 상태만 막는 분기 금지), na 는 왜 해당 없는지' },
        },
        required: ['id', 'result', 'where', 'note'],
      },
    },
    summary: { type: 'string', description: '한 줄 요약' },
  },
  required: ['checks', 'summary'],
}

// ── 에이전트 ───────────────────────────────────────────────────────
function shellQuote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'"
}

let currentPhase = 'Preflight'

// 플러그인이 켜져 있으면 preflight 가 하네스 전용 에이전트 이름을 준다 (도구를 필요한 것만 가진 정의).
// 호출하는 쪽(loop run · 스킬)이 이미 preflight 를 돌렸으면 args.agents 로 받아 preflight 부터 쓴다.
// 없으면 기본 에이전트를 쓴다.
let AGENTS = (args && args.agents) || {}

// 하네스 CLI 는 프로젝트 설정만 보고 이름을 준다. 이 세션에 플러그인이 없으면(다른 저장소에서 연 세션 등)
// 그 정의를 띄우지 못한다. 그때는 기본 에이전트로 다시 띄우고, 이번 실행 동안 전용 정의를 쓰지 않는다.
let agentsUnavailable = false
async function spawn(prompt, opts, role) {
  const agentType = role && !agentsUnavailable ? AGENTS[role] : undefined
  if (!agentType) return agent(prompt, opts)
  try {
    return await agent(prompt, { ...opts, agentType })
  } catch (error) {
    log(`전용 에이전트 ${agentType} 를 띄우지 못했다 — 기본 에이전트로 바꾼다 (${(error && error.message) || error})`)
    agentsUnavailable = true
    return agent(prompt, opts)
  }
}

// Figma 화면이 붙은 기능은 Figma MCP 를 가진 정의로 띄운다. 그 정의가 없으면(조건 미달) 기본 에이전트.
// 실제 화면을 MCP 로 확인하라는 지시(runtimeHints)가 붙은 검증은 그 MCP 를 가진 기본 에이전트로.
function implementerOf(feature) { return feature.figma ? 'figmaImplementer' : 'implementer' }
function reviewerOf(feature) {
  if (runtimeHints.length) return null
  return feature.figma ? 'figmaReviewer' : 'reviewer'
}

// ── 결정론 노드: harness CLI 한 줄 실행 ──────────────────────────────
function lastJsonLine(stdout) {
  const lines = String(stdout || '').trim().split('\n').reverse()
  for (const line of lines) {
    try { return JSON.parse(line) } catch (e) { /* JSON 이 아닌 줄은 건너뛴다 */ }
  }
  return null
}

async function runHarness(command, label) {
  const result = await spawn(
    [
      '다음 셸 명령 하나만 Bash 도구로 그대로 실행하라.',
      '다른 명령을 실행하거나 파일을 수정하지 마라. 결과를 해석하지 말고 exitCode 와 stdout 원문을 반환하라.',
      '',
      `${HARNESS} ${command}`,
    ].join('\n'),
    { label, phase: currentPhase, schema: COMMAND_RESULT, effort: 'low' },
    'runner'
  )
  return result ? lastJsonLine(result.stdout) : null
}

// 응답이 없거나 명령이 거부됐을 때만 원장을 다시 읽는다. 명령은 끝났는데 응답만 잃었을 수 있다.
function lostReply(reply) { return !reply || reply.result === 'error' }

async function ledgerStatus(feature) {
  const found = await runHarness(`feature show ${feature.id} --fields status --json`, `원장:${feature.id}`)
  return found && found.status ? found.status : null
}

// 답을 잃었는데 원장이 이미 wanted 상태면 그 단계는 된 것이다 — 이어 간다.
async function reached(feature, reply, wanted) {
  return lostReply(reply) && (await ledgerStatus(feature)) === wanted
}

// ── 프롬프트 ───────────────────────────────────────────────────────
// 구현자·검증자 프롬프트는 harness prompt 가 만든다(루프·스킬·사람이 같은 것을 쓴다).
// 에이전트가 그 명령을 직접 실행해 받아 간다. 긴 프롬프트를 다른 에이전트가 중계하지 않게.
const WHERE = PROJECT_ROOT ? `프로젝트 루트는 ${PROJECT_ROOT} 다. 파일 경로와 명령은 이 루트 기준이다.` : ''

function implementPrompt(feature, mode) {
  return [
    `너는 기능 ${feature.id} 을 구현하는 코더다.`,
    WHERE,
    `먼저 \`${HARNESS} prompt implement ${feature.id} --mode ${mode}\` 를 실행하고, 출력된 지시를 그대로 따른다.`,
  ].filter(Boolean).join('\n')
}

// 사전 점검에서 연결된 MCP 만 검증 지시로 붙인다. 없으면 지시도 없다.
let runtimeHints = []

function reviewPrompt(feature) {
  const runtime = runtimeHints.length
    ? ['', '[런타임 확인 — 연결된 MCP]', ...runtimeHints.map((h) => `- ${h}`)].join('\n')
    : ''
  return [
    `너는 기능 ${feature.id} 을 구현하지 않은 독립 검증자다.`,
    WHERE,
    `먼저 \`${HARNESS} prompt review ${feature.id} --mode loop\` 를 실행하고, 출력된 프로토콜대로 대조표를 낸다.`,
    runtime,
  ].filter(Boolean).join('\n')
}

// ── 노드 ───────────────────────────────────────────────────────────
function tagOf(feature) { return `${feature.id}#${feature.attempts + 1}` }
function stepOf(feature, iteration) { return { iteration, feature: feature.id, attempt: feature.attempts + 1 } }

// 노드가 다음으로 넘기지 못했을 때의 기록. 명령이 거부했으면 result 는 error, 응답이 없으면 no-response.
function stopped(step, node, reply, field = 'status') {
  return {
    ...step,
    node,
    result: reply ? (reply[field] || reply.result) : 'no-response',
    reason: reply ? reply.reason || '' : '',
  }
}

// 구현자가 판단을 요청했으면 원장에 질문을 남긴다. 요청하지 않았으면 null.
async function askIfNeeded(feature, work, iteration) {
  if (!(work && work.needsDecision && work.question)) return null
  const asked = await runHarness(`feature ask ${feature.id} --question ${shellQuote(work.question)} --json`, `질문:${tagOf(feature)}`)
  return { ...stepOf(feature, iteration), node: 'implement', result: asked ? asked.status || asked.result : 'no-response', reason: work.question }
}

// 커밋 없이 운용할 때: 같은 트리에서 구현했으니, 바꾼 파일을 그 기능의 범위로 적는다. 된 것이면 null.
// 다른 기능의 범위와 겹치면 이번 바퀴에는 게이트로 가지 않는다 (앞 기능이 기록된 뒤 다시 구현).
async function claimChangedFiles(feature, work, iteration) {
  const files = (work && work.filesChanged) || []
  if (!files.length) return null
  const claimed = await runHarness(`feature claim ${feature.id} --files ${shellQuote(files.join(','))} --json`, `범위:${tagOf(feature)}`)
  if (claimed && claimed.result === 'claimed') return null
  return stopped(stepOf(feature, iteration), 'claim', claimed, 'result')
}

// 게이트 → 검증 → 기록. 변경이 이미 메인 작업 트리에 있어야 한다.
async function gateReviewRecord(feature, iteration) {
  const tag = tagOf(feature)
  const step = stepOf(feature, iteration)

  const gate = await runHarness(`feature verify ${feature.id} --json`, `게이트:${tag}`)
  if (!(gate && gate.result === 'pass') && !(await reached(feature, gate, 'verified'))) {
    return stopped(step, 'gate', gate)
  }

  // 검증자가 응답하지 않으면 빈 대조표를 낸다. 하네스가 "빠진 항목" 으로 반려한다.
  const verdict = await spawn(reviewPrompt(feature), { label: `검증:${tag}`, phase: 'Loop', schema: VERDICT }, reviewerOf(feature))
    || { checks: [], summary: '검증자 응답 없음' }
  const reviewed = await runHarness(
    `feature review ${feature.id} --verdict-json ${shellQuote(JSON.stringify(verdict))} --json`, `판정:${tag}`)
  if (!(reviewed && reviewed.result === 'approve') && !(await reached(feature, reviewed, 'reviewed'))) {
    return stopped(step, 'review', reviewed)
  }

  const recorded = await runHarness(`feature record ${feature.id} --json`, `기록:${tag}`)
  if (await reached(feature, recorded, 'passing')) return { ...step, node: 'record', result: 'passing', reason: '응답을 잃었지만 원장에 기록됨' }
  return stopped(step, 'record', recorded, 'result')
}

function implement(feature, mode, schema, extra = {}) {
  return spawn(implementPrompt(feature, mode), { label: `구현:${tagOf(feature)}`, phase: 'Loop', schema, ...extra }, implementerOf(feature))
}

// 범위를 판단 요청보다 먼저 적는다. 판단 대기로 떠나며 보관할 때 그 기능의 파일만 치우게.
//   커밋 운용에는 범위가 없다(트리가 깨끗한 데서 한 기능씩 · 병렬은 워크트리).
async function claimThenAsk(feature, work, iteration, autoCommit) {
  return (autoCommit ? null : await claimChangedFiles(feature, work, iteration))
    || askIfNeeded(feature, work, iteration)
}

// ── 한 바퀴: 순차 ──────────────────────────────────────────────────
async function runSequential(feature, iteration, autoCommit) {
  const work = await implement(feature, 'sequential', IMPLEMENTATION)
  return (await claimThenAsk(feature, work, iteration, autoCommit)) || gateReviewRecord(feature, iteration)
}

// ── 한 바퀴: 병렬 ──────────────────────────────────────────────────
// 커밋 운용: 각자 워크트리에서 구현하고, 결과 브랜치를 하나씩 가져온다. 실패면 그 결과를, 아니면 null.
async function bringInFromWorktree(feature, work, iteration) {
  const branch = (work && work.branch) || `harness/wip-${feature.id}`
  const adopted = await runHarness(`feature adopt ${feature.id} ${shellQuote(branch)} --json`, `가져오기:${tagOf(feature)}`)
  if (adopted && adopted.result === 'adopted') return null
  return stopped(stepOf(feature, iteration), 'adopt', adopted)
}

async function runParallel(batch, iteration, autoCommit) {
  const mode = autoCommit ? 'isolated' : 'shared'
  const schema = autoCommit ? ISOLATED_IMPLEMENTATION : IMPLEMENTATION
  const extra = autoCommit ? { isolation: 'worktree' } : {}
  const works = await parallel(batch.map((feature) => () => implement(feature, mode, schema, extra)))

  // 같은 트리면 게이트 전에 모두의 범위를 먼저 적는다. 앞 기능이 기록되면 범위가 풀려서,
  // 하나씩 적으면 겹친 파일이 앞 기능의 변경으로 기록된다.
  const outcomes = []
  const ready = []
  for (let i = 0; i < batch.length; i++) {
    const feature = batch[i]
    const held = await claimThenAsk(feature, works[i], iteration, autoCommit)
    if (held) { outcomes.push(held); continue }
    ready.push({ feature, work: works[i] })
  }
  for (const { feature, work } of ready) {
    const failed = autoCommit ? await bringInFromWorktree(feature, work, iteration) : null
    outcomes.push(failed || await gateReviewRecord(feature, iteration))
  }
  return outcomes
}

// ── 원장이 세지 않는 반복 ───────────────────────────────────────────
// 시도 횟수(attempt)가 키에 들어 있다. 원장이 실패를 세면 키가 달라지고, 그 반복은 원장의 한도가 맡는다.
const lastOutcomeOf = {}
function repeatsWithoutProgress(outcome) {
  const key = [outcome.node, outcome.result, outcome.reason, outcome.attempt].join('\u0000')
  const repeated = lastOutcomeOf[outcome.feature] === key
  lastOutcomeOf[outcome.feature] = key
  return repeated
}

// ── 실행 ───────────────────────────────────────────────────────────
phase('Preflight')
const preflight = await runHarness('feature preflight --json', 'preflight')
if (!preflight || !preflight.ok) {
  log('preflight 실패 — 루프를 시작하지 않는다.')
  return { stopReason: 'preflight-failed', problems: preflight ? preflight.problems || [preflight.reason] : ['응답 없음'] }
}
for (const note of preflight.notes || []) log(note)
const AUTO_COMMIT = preflight.autoCommit !== false
AGENTS = preflight.agents || {}
if (AGENTS.implementer && !agentsUnavailable) log('하네스 전용 에이전트 사용 (도구를 필요한 것만 가진 정의)')
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
let stuck = null
for (let iteration = 1; iteration <= MAX_ITERATIONS && !stuck; iteration++) {
  if (budget.total && budget.remaining() < BUDGET_FLOOR) { stopReason = 'budget'; break }

  // 선택 응답을 잃었거나 거부됐으면 할 일이 없는 것이 아니다 — 원장을 읽지 못한 것이다. 완료로 끝내지 않고 멈춘다.
  let outcomes
  if (PARALLEL > 1) {
    const batch = await runHarness(`feature next --json --limit ${PARALLEL} --fields ${SELECT_FIELDS}`, `선택#${iteration}`)
    if (!Array.isArray(batch)) { stopReason = 'ledger-unreadable'; break }
    if (batch.length === 0) { stopReason = 'all-done'; break }
    outcomes = await runParallel(batch, iteration, AUTO_COMMIT)
  } else {
    const feature = await runHarness(`feature next --json --fields ${SELECT_FIELDS}`, `선택#${iteration}`)
    if (lostReply(feature)) { stopReason = 'ledger-unreadable'; break }
    if (!feature.id) { stopReason = 'all-done'; break }
    outcomes = [await runSequential(feature, iteration, AUTO_COMMIT)]
  }
  for (const outcome of outcomes) {
    outcome.outputTokensSoFar = budget.spent()
    steps.push(outcome)
    log(`[${iteration}/${MAX_ITERATIONS}] ${outcome.feature}: ${outcome.node} → ${outcome.result}`)
    if (!stuck && repeatsWithoutProgress(outcome)) stuck = outcome
  }
}
if (stuck) {
  stopReason = 'stuck'
  log(`${stuck.feature}: ${stuck.node} → ${stuck.result} 가 진전 없이 두 번 연속 — 루프를 멈춘다. ${stuck.reason}`)
}
if (stopReason === 'ledger-unreadable') log('다음 기능을 고르는 명령이 응답하지 않았다 — 완료가 아니다. 루프를 멈춘다.')
if (stopReason === 'max-iterations') log(`최대 ${MAX_ITERATIONS}바퀴에 도달 — 남은 기능은 다음 실행에서 이어간다.`)

currentPhase = 'Audit'
phase('Audit')
const audit = await runHarness('feature audit --json', 'audit')
const ledger = await runHarness(`feature list --json --fields ${SUMMARY_FIELDS}`, '원장')
const features = Array.isArray(ledger) ? ledger : []
// 사람이 읽는 보고서(기능별 문제와 해결 · 시간 · 이상 신호). 하네스가 trace 로 만든다 — 모델은 명령 하나만 실행한다.
const stopNote = stuck ? ` --reason ${shellQuote(`${stuck.feature}: ${stuck.node} → ${stuck.result} ${stuck.reason || ''}`)}` : ''
const report = await runHarness(`trace report --stop-reason ${stopReason}${stopNote} --json`, '보고서')
const byStatus = (status) => features
  .filter((f) => f.status === status)
  .map((f) => ({ id: f.id, reason: f.lastFailure || '' }))

return {
  stopReason,
  stuck: stuck ? { feature: stuck.feature, node: stuck.node, result: stuck.result, reason: stuck.reason } : null,  // 사람: 이유를 보고 claim · reset 등으로 푼다
  autoCommit: AUTO_COMMIT,
  iterations: steps.length,
  passing: byStatus('passing').map((f) => f.id),
  needsDecision: features                             // 사람: harness feature decide ID --answer 답
    .filter((f) => f.status === 'needs-decision').map((f) => ({ id: f.id, question: f.question })),
  awaitingApproval: byStatus('awaiting-approval'),    // 사람: harness feature approve ID
  blocked: byStatus('blocked'),                       // 사람: 원인 해결 후 harness feature reset ID
  interrupted: [...byStatus('verified'), ...byStatus('reviewed')].map((f) => f.id),  // 판정 뒤 기록 전에 끊긴 기능
  pending: byStatus('pending').map((f) => f.id),
  auditRegressions: audit && Array.isArray(audit.regressed) ? audit.regressed : [],
  mcpSuggestions,                                     // 사람: 설치할지 결정 (하네스는 설치하지 않는다)
  report: report && report.path ? report.path : null, // 사람: 기능별 문제와 해결 · 시간 · 할 일
  steps,
}
