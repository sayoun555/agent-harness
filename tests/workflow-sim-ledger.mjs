// tests/workflow-sim-ledger.mjs — 커밋 없이 운용(loop.autoCommit: false)하는 루프를 LLM 없이 검증한다.
//
//   node tests/workflow-sim-ledger.mjs
//
// 커밋이 하나도 없는 저장소에서, 같은 작업 트리 병렬(parallel = 2)로 돈다.
//
//   1바퀴 [a, b]     같은 트리에서 동시에 구현 → 각자 범위(claim)로 검증·기록 → passing
//   2바퀴 [pay, bad] pay 는 위험 파일 → 승인 대기 (패치로 보관, 트리에서 치움)
//                    bad 는 acceptance 실패 → pending
//   3바퀴 [bad]      같은 실패 2회 → blocked (패치로 보관)
//   끝까지 커밋·브랜치·ref 를 하나도 만들지 않는다.

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import {
  makeProject, addFeature, loadWorkflow, fakeParallel, noBudget, runCommandNode, schemaKeys, mustRun, HARNESS,
} from './sim-helpers.mjs'

const project = makeProject({
  loop: { maxAttempts: 3, repeatLimit: 2, parallel: 2, autoCommit: false },
  approval: { riskGlobs: ['*payment*'] },
})
addFeature(project, 'a', '에이', 'test -f src/a.js')
addFeature(project, 'b', '비', 'test -f src/b.js')
addFeature(project, 'pay', '결제', 'test -f src/payment.js')
addFeature(project, 'bad', '나쁨', 'false')
mustRun(project, 'git add -A')   // 스테이징만 하고 커밋은 하지 않는다 (보고된 상황)

const files = { a: 'src/a.js', b: 'src/b.js', pay: 'src/payment.js', bad: 'src/bad.js' }
const sharedPrompts = []

async function agent(prompt, opts = {}) {
  const keys = schemaKeys(opts)
  if (keys.includes('exitCode')) return runCommandNode(project, prompt)
  const id = (prompt.match(/기능 id: ([\w-]+)/) || prompt.match(/--context ([\w-]+)/) || [])[1]
  if (keys.includes('filesChanged')) {
    assert.equal(opts.isolation, undefined, '커밋 없는 병렬은 워크트리를 쓰지 않는다')
    sharedPrompts.push(prompt)
    writeFileSync(join(project, files[id]), `export const ${id} = 1;\n`)
    return { needsDecision: false, question: '', summary: id, filesChanged: [files[id]] }
  }
  if (keys.includes('approved')) {
    const context = mustRun(project, `bash ${HARNESS} review --context ${id}`)
    for (const [other, path] of Object.entries(files)) {
      if (other !== id) assert.ok(!context.includes(`- ${path}`), `${id} 의 검증에 ${other} 의 파일이 보이면 안 된다`)
    }
    return { approved: true, reason: 'ok' }
  }
  throw new Error(`알 수 없는 agent 호출: ${opts.label}`)
}

const git = (...args) => execFileSync('git', args, { cwd: project, encoding: 'utf8' }).trim()

try {
  const run = await loadWorkflow({ agent, parallel: fakeParallel, phase: () => {}, log: () => {}, args: {}, budget: noBudget })
  const result = await run()

  assert.equal(result.stopReason, 'all-done')
  assert.equal(result.autoCommit, false)
  const nodes = result.steps.map((s) => `${s.iteration}:${s.feature}:${s.node}:${s.result}`)
  assert.deepEqual(nodes, [
    '1:a:record:passing',
    '1:b:record:passing',
    '2:pay:record:awaiting-approval',
    '2:bad:gate:pending',
    '3:bad:gate:blocked',
  ])
  assert.deepEqual(result.passing.sort(), ['a', 'b'])

  // 커밋·브랜치·ref 를 하나도 만들지 않았다
  assert.equal(git('rev-list', '--all'), '')
  assert.equal(git('for-each-ref'), '')

  // 위험 파일과 막힌 기능은 패치로 보관되고 트리에서 치워졌다
  assert.ok(!existsSync(join(project, 'src/payment.js')))
  assert.ok(!existsSync(join(project, 'src/bad.js')))
  assert.match(readFileSync(join(project, '.harness/parked/pay.patch'), 'utf8'), /\+export const pay = 1;/)
  assert.match(readFileSync(join(project, '.harness/parked/bad.patch'), 'utf8'), /\+export const bad = 1;/)
  assert.ok(existsSync(join(project, 'src/a.js')) && existsSync(join(project, 'src/b.js')))

  // 기록한 기능은 기준선에 들어갔다 — 남은 변경이 없다
  assert.doesNotMatch(mustRun(project, `bash ${HARNESS} baseline show`), /src\//)

  // 같은 트리 병렬 지시문: 빌드 잠금, 바꾼 파일 보고
  assert.ok(sharedPrompts.every((p) => p.includes('lock run --') && p.includes('filesChanged')))

  // 승인하면 패치를 되가져와 passing (여전히 커밋 없음)
  mustRun(project, `bash ${HARNESS} feature approve pay`)
  assert.ok(existsSync(join(project, 'src/payment.js')))
  assert.equal(git('rev-list', '--all'), '')

  console.log('✓ feature-loop 커밋 없는 운용 시뮬레이션 통과')
  console.log('  ' + nodes.join('\n  '))
} finally {
  rmSync(project, { recursive: true, force: true })
}
