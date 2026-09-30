// tests/workflow-sim.mjs — feature-loop 워크플로우의 그래프를 LLM 없이 검증한다.
//
//   node tests/workflow-sim.mjs
//
// agent() 만 가짜로 바꾼다. 하네스 명령(게이트·원장·커밋)은 임시 git 프로젝트에서 실제로 실행된다.
// 구현자·검증자는 기능별 시나리오대로 움직인다. 그래서 그래프의 모든 분기를 결정적으로 밟는다.
//
//   sub  1차 구현 누락 → 게이트 실패 → 2차에 구현 → 통과 → passing
//   div  구현 → 검증자 1차 반려 → 재구현 → 승인 → passing
//   pay   위험 파일(payment) → 커밋 대신 awaiting-approval, 변경은 harness/pay 에 보관
//   tail  pay 다음에 통과 → 그 커밋에 결제 코드가 섞이면 안 된다
//   cache 구현자가 설계 결정을 물음 → needs-decision
//   mul   acceptance 가 늘 실패 → 같은 실패 2회 → blocked

import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, appendFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import assert from 'node:assert/strict'

const questions_cache = "Redis 와 메모리 캐시 중 무엇으로? ('it's' 따옴표 포함)"

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const HARNESS = join(ROOT, 'bin/harness')

// ── 임시 프로젝트 ──────────────────────────────────────────────────
// 가짜 claude: `claude mcp list` 에 Playwright 가 연결된 것처럼 답한다 (실제 MCP 설정은 건드리지 않음)
const FAKE_BIN = mkdtempSync(join(tmpdir(), 'fake-claude-'))
writeFileSync(join(FAKE_BIN, 'claude'),
  '#!/usr/bin/env bash\n[[ "$1 $2" == "mcp list" ]] && echo "playwright: npx -y @playwright/mcp@latest - ✔ Connected"\n',
  { mode: 0o755 })
const ENV = { ...process.env, PATH: `${FAKE_BIN}:${process.env.PATH}` }

function sh(cwd, command) {
  return spawnSync('bash', ['-c', command], { cwd, encoding: 'utf8', env: ENV })
}

function makeProject() {
  const dir = mkdtempSync(join(tmpdir(), 'harness-sim-'))
  const run = (c) => { const r = sh(dir, c); if (r.status !== 0) throw new Error(`${c}\n${r.stderr}`) }
  run('git init -q && git config user.email t@e && git config user.name t')
  run('mkdir -p src tests && echo "export const add = (a, b) => a + b;" > src/math.js')
  writeFileSync(join(dir, 'tests/math.test.js'), 'test("adds", () => { expect(add(1, 2)).toBe(3) })\n')
  run(`bash ${HARNESS} init --preset generic --no-git-hooks 2>/dev/null`)
  const configPath = join(dir, '.harness/project.json')
  const config = JSON.parse(readFileSync(configPath, 'utf8'))
  Object.assign(config, {
    testGuard: { testCasePattern: '\\btest\\(', assertionPattern: '\\bexpect\\(', skipPattern: '\\btest\\.skip\\(' },
    loop: { maxAttempts: 3, repeatLimit: 2 },
    approval: { riskGlobs: ['*payment*'] },
    app: { startCommand: 'npm run dev' },
    mcp: { recommended: [{ name: 'playwright', detect: '(^|:)playwright$', purpose: '화면 확인',
      install: 'claude mcp add playwright -- npx -y @playwright/mcp@latest',
      reviewHint: 'Playwright MCP 로 화면을 확인한다. 먼저 {startCommand}' }] },
  })
  writeFileSync(configPath, JSON.stringify(config, null, 2))
  const add = (id, desc, acceptance) => run(`bash ${HARNESS} feature add --id ${id} --desc '${desc}' --acceptance '${acceptance}' 2>/dev/null`)
  add('sub', '빼기', 'grep -q "const sub" src/math.js')
  add('div', '나누기', 'test -f src/div.js')
  add('pay', '결제', 'test -f src/payment.js')
  add('tail', '꼬리', 'test -f src/tail.js')
  add('cache', '캐싱', 'true')
  add('mul', '곱하기', 'false')
  run('git add -A && git commit -qm init')
  return dir
}

// ── 가짜 agent(): 시나리오 ─────────────────────────────────────────
function makeFakeAgent(project) {
  const calls = { implement: {}, review: {}, reviewPrompts: [] }
  const bump = (kind, id) => (calls[kind][id] = (calls[kind][id] || 0) + 1)
  const featureIdIn = (prompt) => (prompt.match(/기능 id: ([\w-]+)/) || prompt.match(/--context ([\w-]+)/) || [])[1]

  const implement = {
    sub: (n) => { if (n >= 2) appendFileSync(join(project, 'src/math.js'), 'export const sub = (a, b) => a - b;\n') },
    div: () => writeFileSync(join(project, 'src/div.js'), 'export const div = (a, b) => a / b;\n'),
    pay: () => writeFileSync(join(project, 'src/payment.js'), 'export const pay = () => true;\n'),
    tail: () => writeFileSync(join(project, 'src/tail.js'), 'export const tail = 1;\n'),
    mul: () => {},
  }
  const questions = { cache: "Redis 와 메모리 캐시 중 무엇으로? ('it's' 따옴표 포함)" }
  const review = { div: (n) => n >= 2 }

  fakeAgent.calls = calls
  return fakeAgent
  async function fakeAgent(prompt, opts = {}) {
    const props = Object.keys((opts.schema && opts.schema.properties) || {})
    if (props.includes('exitCode')) {                       // 결정론 노드: 명령 실제 실행
      const command = prompt.trim().split('\n').pop().replace(/^\.harness\/bin\/harness/, `bash ${HARNESS}`)
      const r = sh(project, command)
      return { exitCode: r.status, stdout: r.stdout }
    }
    const id = featureIdIn(prompt)
    if (props.includes('filesChanged')) {                   // 구현 노드
      bump('implement', id)
      if (questions[id]) return { needsDecision: true, question: questions[id], summary: '', filesChanged: [] }
      implement[id](calls.implement[id])
      return { needsDecision: false, question: '', summary: `sim ${id}`, filesChanged: [] }
    }
    if (props.includes('approved')) {                       // 검증 노드
      calls.reviewPrompts.push(prompt)
      const n = bump('review', id)
      const approved = review[id] ? review[id](n) : true
      return { approved, reason: approved ? 'ok' : "과설계 — 'it's' 따옴표도 안전해야 한다" }
    }
    throw new Error(`알 수 없는 agent 호출: ${opts.label}`)
  }
}

// ── 워크플로우 로드 ────────────────────────────────────────────────
async function loadWorkflow(globals) {
  const source = readFileSync(join(ROOT, 'workflows/feature-loop.js'), 'utf8').replace(/^export const meta/m, 'const meta')
  const wrapped = `export default async function run({ agent, phase, log, args, budget }) {\n${source}\n}`
  const file = join(mkdtempSync(join(tmpdir(), 'wf-')), 'wf.mjs')
  writeFileSync(file, wrapped)
  const module = await import(file)
  return () => module.default(globals)
}

// ── 실행 · 단언 ────────────────────────────────────────────────────
const project = makeProject()
try {
  const logs = []
  const fakeAgent = makeFakeAgent(project)
  const run = await loadWorkflow({
    agent: fakeAgent,
    phase: () => {},
    log: (m) => logs.push(m),
    args: { maxIterations: 20 },
    budget: { total: null, spent: () => 0, remaining: () => Infinity },
  })
  const result = await run()

  assert.equal(result.stopReason, 'all-done')
  assert.deepEqual(result.passing.sort(), ['div', 'sub', 'tail'])
  assert.deepEqual(result.awaitingApproval.map((f) => f.id), ['pay'])
  assert.deepEqual(result.blocked.map((f) => f.id), ['mul'])
  assert.deepEqual(result.needsDecision, [{ id: 'cache', question: questions_cache }])
  assert.deepEqual(result.interrupted, [])
  assert.deepEqual(result.auditRegressions, [])

  const nodes = result.steps.map((s) => `${s.feature}:${s.node}:${s.result}`)
  assert.deepEqual(nodes, [
    'sub:gate:pending',              // 1차 구현 누락
    'sub:record:passing',            // 실패 사유를 받고 2차에 통과
    'div:review:pending',            // 검증자 반려
    'div:record:passing',            // 반려 사유를 받고 통과
    'pay:record:awaiting-approval',  // 위험 파일 → 사람 승인
    'tail:record:passing',           // 보관 덕분에 결제 코드 없이 커밋
    'cache:implement:needs-decision',// 추측 대신 질문
    'mul:gate:pending',
    'mul:gate:blocked',              // 같은 실패 2회 → 막힘
  ])

  const commits = execFileSync('git', ['log', '--format=%s'], { cwd: project, encoding: 'utf8' }).trim().split('\n')
  assert.deepEqual(commits, ['feat(tail): 꼬리', 'feat(div): 나누기', 'feat(sub): 빼기', 'init'])
  const tailFiles = execFileSync('git', ['show', '--name-only', '--format=', 'HEAD'], { cwd: project, encoding: 'utf8' })
  assert.ok(!tailFiles.includes('payment'), `꼬리 커밋에 결제 코드가 섞였다:\n${tailFiles}`)
  const parked = execFileSync('git', ['show', 'harness/pay:src/payment.js'], { cwd: project, encoding: 'utf8' })
  assert.match(parked, /export const pay/)
  const trace = readFileSync(join(project, '.harness/trace.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
  assert.equal(trace.filter((t) => t.event === 'verify').length, 8)
  assert.equal(trace.find((t) => t.event === 'ask').question, questions_cache)
  // 작은따옴표가 든 LLM 반려 사유가 셸을 거쳐 그대로 기록돼야 한다 (명령 주입 방지 확인)
  assert.equal(trace.find((t) => t.event === 'review').reason, "과설계 — 'it's' 따옴표도 안전해야 한다")

  // 연결된 MCP 는 검증자 지시로 붙고, 설치 제안은 비어야 한다
  assert.ok(fakeAgent.calls.reviewPrompts.length > 0)
  for (const p of fakeAgent.calls.reviewPrompts) {
    assert.match(p, /\[런타임 확인 — 연결된 MCP\]/)
    assert.match(p, /Playwright MCP 로 화면을 확인한다\. 먼저 npm run dev/)
  }
  assert.deepEqual(result.mcpSuggestions, [])

  console.log('✓ feature-loop 그래프 시뮬레이션 통과')
  console.log('  ' + nodes.join('\n  '))
} finally {
  rmSync(project, { recursive: true, force: true })
  rmSync(FAKE_BIN, { recursive: true, force: true })
}
