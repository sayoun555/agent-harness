// tests/workflow-sim-recovery.mjs — 루프가 스스로 빠져나와야 하는 경우를 LLM 없이 검증한다 (현장 보고: 같은 자리를 18바퀴).
//
//   node tests/workflow-sim-recovery.mjs
//
// 실행 1  커밋 없이 · 순차 · 세션 작업 디렉터리가 프로젝트 밖 (args.projectRoot)
//         전용 에이전트 이름을 받았지만 이 세션에는 그 정의가 없다 → 기본 에이전트로 바꿔 계속한다
//         a  구현자가 바꾼 파일을 범위로 적는다(claim) → passing
//         r  review 명령은 실행됐는데 응답을 잃었다 → 원장을 다시 읽어 reviewed 면 기록으로 이어 간다 → passing
// 실행 2  held 가 범위 없이 구현을 시작한 채 끊겼다. x 의 구현자는 "이미 되어 있음"(바꾼 파일 없음)
//         x 의 게이트는 소유권 검사에 거부된다(--json 이라 error 한 줄) → 원장이 세지 않는 반복
//         같은 결과가 두 번 연속이면 루프를 멈춘다 (maxIterations 까지 돌지 않는다)
// 실행 3  다음 기능을 고르는 명령의 응답을 잃었다 → 완료로 끝내지 않는다
// 실행 4  요금제 사용량이 기준(90%)을 넘었다 → 다음 기능을 시작하지 않고 멈춘다. 이유가 보고서에 남는다

import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import {
  makeProject, addFeature, loadWorkflow, fakeParallel, noBudget, runCommandNode, schemaKeys, mustRun, HARNESS,
  featureIdOf, followBootstrap, checklistVerdict, SIM_ENV,
} from './sim-helpers.mjs'

const LEDGER = { loop: { maxAttempts: 3, repeatLimit: 2, autoCommit: false } }
const elsewhere = mkdtempSync(join(tmpdir(), 'other-repo-'))   // 세션이 열린 다른 저장소
const ledgerOf = (dir) => JSON.parse(mustRun(dir, `bash ${HARNESS} feature list --json`))

// ── 실행 1 ─────────────────────────────────────────────────────────
async function runRecovery() {
  const project = makeProject(LEDGER)
  addFeature(project, 'a', '에이', 'test -f src/a.js')
  addFeature(project, 'r', '알', 'test -f src/r.js')
  const typedCalls = []
  const labels = []

  async function agent(prompt, opts = {}) {
    labels.push(opts.label)
    if (opts.agentType) {   // 이 세션에는 플러그인 정의가 없다
      typedCalls.push(opts.agentType)
      throw new Error(`Agent type '${opts.agentType}' not found`)
    }
    const keys = schemaKeys(opts)
    if (keys.includes('exitCode')) {
      if (/feature (list|next|show) /.test(prompt)) assert.match(prompt, /--fields /, '원장은 필요한 필드만 읽는다')
      if (/feature list /.test(prompt)) assert.match(prompt, /--fields id,status,lastFailure,question/, '모든 기능을 읽는 것은 끝 요약뿐이다')
      const result = runCommandNode(elsewhere, prompt)
      if (/feature review r /.test(prompt)) return { exitCode: result.exitCode, stdout: '' }   // 실행은 됐는데 응답을 잃었다
      return result
    }
    const id = featureIdOf(prompt)
    if (keys.includes('filesChanged')) {
      assert.ok(prompt.includes(`프로젝트 루트는 ${project} `), "프롬프트가 프로젝트 루트를 알려야 한다")  // 경로를 정규식에 넣으면 Windows 의 \ 가 이스케이프가 된다
      followBootstrap(elsewhere, prompt)
      writeFileSync(join(project, `src/${id}.js`), `export const ${id} = 1;\n`)
      return { needsDecision: false, question: '', summary: id, filesChanged: [`src/${id}.js`] }
    }
    if (keys.includes('checks')) {
      const review = followBootstrap(elsewhere, prompt)
      assert.ok(!review.includes('--verdict-file'), '루프 안의 검증자는 직접 제출하지 않는다')
      return checklistVerdict(review)
    }
    throw new Error(`알 수 없는 agent 호출: ${opts.label}`)
  }

  const agents = { runner: 'agent-harness:harness-runner', implementer: 'agent-harness:harness-implementer', reviewer: 'agent-harness:harness-reviewer' }
  try {
    const run = await loadWorkflow({
      agent, parallel: fakeParallel, phase: () => {}, log: () => {}, budget: noBudget,
      args: { projectRoot: project, agents },
    })
    const result = await run()
    assert.equal(result.stopReason, 'all-done')
    const nodes = result.steps.map((s) => `${s.feature}:${s.node}:${s.result}`)
    assert.deepEqual(nodes, ['a:record:passing', 'r:record:passing'])
    assert.deepEqual(typedCalls, [agents.runner], '전용 정의는 한 번 실패한 뒤 다시 쓰지 않는다')
    assert.ok(labels.includes('범위:a#1') && labels.includes('범위:r#1'), '순차에서도 바꾼 파일을 범위로 적는다')
    assert.ok(labels.includes('원장:r'), '응답을 잃으면 원장을 다시 읽는다')
    assert.deepEqual(ledgerOf(project).map((f) => f.status), ['passing', 'passing'])
    console.log('✓ 실행 1: 전용 에이전트 대체 · projectRoot · 순차 범위 · 잃은 응답 복구')
    console.log('  ' + nodes.join('\n  '))
  } finally {
    rmSync(project, { recursive: true, force: true })
  }
}

// ── 실행 2 ─────────────────────────────────────────────────────────
async function runStuck() {
  const project = makeProject(LEDGER)
  addFeature(project, 'x', '엑스', 'true')
  addFeature(project, 'held', '홀드', 'true')
  mustRun(project, `bash ${HARNESS} feature preflight >/dev/null 2>&1; bash ${HARNESS} feature start held >/dev/null`)
  let implemented = 0

  async function agent(prompt, opts = {}) {
    const keys = schemaKeys(opts)
    if (keys.includes('exitCode')) return runCommandNode(project, prompt)
    if (keys.includes('filesChanged')) {
      followBootstrap(project, prompt)
      implemented++
      return { needsDecision: false, question: '', summary: '이미 되어 있음', filesChanged: [] }
    }
    throw new Error(`알 수 없는 agent 호출: ${opts.label}`)
  }

  try {
    const logs = []
    const run = await loadWorkflow({ agent, parallel: fakeParallel, phase: () => {}, log: (m) => logs.push(m), args: {}, budget: noBudget })
    const result = await run()
    assert.equal(result.stopReason, 'stuck')
    assert.ok(logs.includes('[1/20] x: gate → error · 사용량 세션 10% · 주간(전체) 5%'), `진행 줄에 사용량이 붙는다: ${logs.join(' | ')}`)
    assert.deepEqual(result.steps.map((s) => `${s.iteration}:${s.feature}:${s.node}:${s.result}`), ['1:x:gate:error', '2:x:gate:error'])
    assert.equal(result.stuck.feature, 'x')
    assert.match(result.stuck.reason, /범위 미지정 — 기록 전인 다른 기능\(held\)/)
    assert.equal(implemented, 2, '두 바퀴에서 멈춘다')
    assert.equal(result.report, '.harness/runs/report.md')
    const report = readFileSync(join(project, result.report), 'utf8')
    assert.match(report, /루프가 멈춤\(stuck\): x: gate → error 범위 미지정/, '멈춘 이유가 보고서의 이상 신호에 남는다')
    console.log('✓ 실행 2: 원장이 세지 않는 반복을 두 번째에 멈춘다 · 보고서에 이유가 남는다')
  } finally {
    rmSync(project, { recursive: true, force: true })
  }
}

// ── 실행 3 ─────────────────────────────────────────────────────────
// 다음 기능을 고르는 명령의 응답을 잃었다 → 완료(all-done)가 아니라 원장을 못 읽은 것으로 멈춘다
async function runLostSelection() {
  const project = makeProject(LEDGER)
  addFeature(project, 'a', '에이', 'true')
  async function agent(prompt, opts = {}) {
    if (!schemaKeys(opts).includes('exitCode')) throw new Error(`구현까지 가면 안 된다: ${opts.label}`)
    if (/feature next/.test(prompt)) return null
    return runCommandNode(project, prompt)
  }
  try {
    const run = await loadWorkflow({ agent, parallel: fakeParallel, phase: () => {}, log: () => {}, args: {}, budget: noBudget })
    const result = await run()
    assert.equal(result.stopReason, 'ledger-unreadable')
    assert.deepEqual(result.pending, ['a'])
    console.log('✓ 실행 3: 선택 응답을 잃으면 완료로 끝내지 않는다')
  } finally {
    rmSync(project, { recursive: true, force: true })
  }
}

// ── 실행 4 ─────────────────────────────────────────────────────────
async function runUsageLimit() {
  const project = makeProject(LEDGER)
  addFeature(project, 'a', '에이', 'true')
  const env = { ...SIM_ENV, FAKE_USAGE_PERCENT: '95' }
  async function agent(prompt, opts = {}) {
    if (!schemaKeys(opts).includes('exitCode')) throw new Error(`구현까지 가면 안 된다: ${opts.label}`)
    if (/feature next/.test(prompt)) throw new Error('사용량이 넘었으면 다음 기능을 고르지 않는다')
    return runCommandNode(project, prompt, env)
  }
  try {
    const run = await loadWorkflow({ agent, parallel: fakeParallel, phase: () => {}, log: () => {}, args: {}, budget: noBudget })
    const result = await run()
    assert.equal(result.stopReason, 'usage-limit')
    assert.equal(result.usage, '세션 95% · 주간(전체) 5%')
    assert.deepEqual(result.pending, ['a'])
    const report = readFileSync(join(project, result.report), 'utf8')
    assert.match(report, /루프가 멈춤\(usage-limit\): 세션 95% · 주간\(전체\) 5% \(기준 90%\)/)
    console.log('✓ 실행 4: 요금제 사용량이 기준을 넘으면 다음 기능을 시작하지 않는다 · 보고서에 이유가 남는다')
  } finally {
    rmSync(project, { recursive: true, force: true })
  }
}

// ── 실행 5 ─────────────────────────────────────────────────────────
// 앞 기능이 막혔다 → 그 기능에 의존하는 기능은 고르지 않는다. 끝은 완료(all-done)가 아니라 대기(waiting)
async function runWaiting() {
  const project = makeProject(LEDGER)
  addFeature(project, 'a', '에이', 'false')
  mustRun(project, `bash ${HARNESS} feature add --id b --desc 비 --acceptance true --depends-on a >/dev/null 2>&1`)
  const implementedIds = []
  async function agent(prompt, opts = {}) {
    const keys = schemaKeys(opts)
    if (keys.includes('exitCode')) return runCommandNode(project, prompt)
    if (keys.includes('filesChanged')) {
      followBootstrap(project, prompt)
      implementedIds.push(featureIdOf(prompt))
      writeFileSync(join(project, 'src/a.js'), `export const a = ${implementedIds.length};\n`)
      return { needsDecision: false, question: '', summary: '구현', filesChanged: ['src/a.js'] }
    }
    throw new Error(`알 수 없는 agent 호출: ${opts.label}`)
  }
  try {
    const run = await loadWorkflow({ agent, parallel: fakeParallel, phase: () => {}, log: () => {}, args: {}, budget: noBudget })
    const result = await run()
    assert.ok(implementedIds.every((id) => id === 'a'), `앞 기능이 막힌 동안 b 를 구현하지 않는다: ${implementedIds}`)
    assert.deepEqual(result.blocked.map((f) => f.id), ['a'])
    assert.equal(result.stopReason, 'waiting')
    assert.deepEqual(result.waiting, [{ id: 'b', waitingFor: ['a'] }])
    const report = readFileSync(join(project, result.report), 'utf8')
    assert.match(report, /- 대기: b ← a\(blocked\)/)
    console.log('✓ 실행 5: 앞 기능이 막히면 뒤 기능을 고르지 않고 대기로 끝난다 · 보고서의 사람이 할 일에 남는다')
  } finally {
    rmSync(project, { recursive: true, force: true })
  }
}

try {
  await runRecovery()
  await runStuck()
  await runLostSelection()
  await runUsageLimit()
  await runWaiting()
} finally {
  rmSync(elsewhere, { recursive: true, force: true })
}
