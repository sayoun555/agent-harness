// tests/workflow-sim.mjs — feature-loop 워크플로우의 그래프를 LLM 없이 검증한다.
//
//   node tests/workflow-sim.mjs
//
// agent() 만 가짜로 바꾼다. 하네스 명령(게이트·원장·커밋)은 임시 git 프로젝트에서 실제로 실행된다.
// 구현자·검증자는 기능별 시나리오대로 움직인다. 그래서 그래프의 모든 분기를 결정적으로 밟는다.
//
//   sub  1차 구현 누락 → 게이트 실패 → 2차에 구현 → 통과 → passing
//   div  구현 → 검증자 1차 반려 → 재구현 → 승인 → passing
//   pay  위험 파일(payment) → 커밋 대신 awaiting-approval
//   mul  acceptance 가 늘 실패 → 같은 실패 2회 → blocked

import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, appendFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import assert from 'node:assert/strict'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const HARNESS = join(ROOT, 'bin/harness')

// ── 임시 프로젝트 ──────────────────────────────────────────────────
function sh(cwd, command) {
  return spawnSync('bash', ['-c', command], { cwd, encoding: 'utf8' })
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
  })
  writeFileSync(configPath, JSON.stringify(config, null, 2))
  const add = (id, desc, acceptance) => run(`bash ${HARNESS} feature add --id ${id} --desc '${desc}' --acceptance '${acceptance}' 2>/dev/null`)
  add('sub', '빼기', 'grep -q "const sub" src/math.js')
  add('div', '나누기', 'test -f src/div.js')
  add('pay', '결제', 'test -f src/payment.js')
  add('mul', '곱하기', 'false')
  run('git add -A && git commit -qm init')
  return dir
}

// ── 가짜 agent(): 시나리오 ─────────────────────────────────────────
function makeFakeAgent(project) {
  const calls = { implement: {}, review: {} }
  const bump = (kind, id) => (calls[kind][id] = (calls[kind][id] || 0) + 1)
  const featureIdIn = (prompt) => (prompt.match(/기능 id: ([\w-]+)/) || prompt.match(/--context ([\w-]+)/) || [])[1]

  const implement = {
    sub: (n) => { if (n >= 2) appendFileSync(join(project, 'src/math.js'), 'export const sub = (a, b) => a - b;\n') },
    div: () => writeFileSync(join(project, 'src/div.js'), 'export const div = (a, b) => a / b;\n'),
    pay: () => writeFileSync(join(project, 'src/payment.js'), 'export const pay = () => true;\n'),
    mul: () => {},
  }
  const review = { div: (n) => n >= 2 }

  return async function agent(prompt, opts = {}) {
    const props = Object.keys((opts.schema && opts.schema.properties) || {})
    if (props.includes('exitCode')) {                       // 결정론 노드: 명령 실제 실행
      const command = prompt.trim().split('\n').pop().replace(/^\.harness\/bin\/harness/, `bash ${HARNESS}`)
      const r = sh(project, command)
      return { exitCode: r.status, stdout: r.stdout }
    }
    const id = featureIdIn(prompt)
    if (props.includes('filesChanged')) {                   // 구현 노드
      implement[id](bump('implement', id))
      return { summary: `sim ${id}`, filesChanged: [] }
    }
    if (props.includes('approved')) {                       // 검증 노드
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
  const run = await loadWorkflow({
    agent: makeFakeAgent(project),
    phase: () => {},
    log: (m) => logs.push(m),
    args: { maxIterations: 20 },
    budget: { total: null, spent: () => 0, remaining: () => Infinity },
  })
  const result = await run()

  assert.equal(result.stopReason, 'all-done')
  assert.deepEqual(result.passing.sort(), ['div', 'sub'])
  assert.deepEqual(result.awaitingApproval.map((f) => f.id), ['pay'])
  assert.deepEqual(result.blocked.map((f) => f.id), ['mul'])
  assert.deepEqual(result.auditRegressions, [])

  const nodes = result.steps.map((s) => `${s.feature}:${s.node}:${s.result}`)
  assert.deepEqual(nodes, [
    'sub:gate:pending',              // 1차 구현 누락
    'sub:record:passing',            // 실패 사유를 받고 2차에 통과
    'div:review:pending',            // 검증자 반려
    'div:record:passing',            // 반려 사유를 받고 통과
    'pay:record:awaiting-approval',  // 위험 파일 → 사람 승인
    'mul:gate:pending',
    'mul:gate:blocked',              // 같은 실패 2회 → 막힘
  ])

  const commits = execFileSync('git', ['log', '--format=%s'], { cwd: project, encoding: 'utf8' }).trim().split('\n')
  assert.deepEqual(commits, ['feat(div): 나누기', 'feat(sub): 빼기', 'init'])
  const trace = readFileSync(join(project, '.harness/trace.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
  assert.equal(trace.filter((t) => t.event === 'verify').length, 7)
  // 작은따옴표가 든 LLM 반려 사유가 셸을 거쳐 그대로 기록돼야 한다 (명령 주입 방지 확인)
  assert.equal(trace.find((t) => t.event === 'review').reason, "과설계 — 'it's' 따옴표도 안전해야 한다")

  console.log('✓ feature-loop 그래프 시뮬레이션 통과')
  console.log('  ' + nodes.join('\n  '))
} finally {
  rmSync(project, { recursive: true, force: true })
}
