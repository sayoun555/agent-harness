// tests/workflow-sim-parallel.mjs — 병렬 분기(loop.parallel = 2)를 LLM 없이 검증한다.
//
//   node tests/workflow-sim-parallel.mjs
//
// 워크트리 구현자는 실제 git worktree 를 만들어 브랜치에 커밋한다. 가져오기·게이트·기록은 실제 하네스 명령.
//
//   1바퀴 [a, b]  서로 다른 파일 → 둘 다 passing
//   2바퀴 [c, d]  같은 줄을 고침 → c 는 passing, d 는 병합 충돌로 pending
//   3바퀴 [d, e]  d 는 최신 HEAD 위에서 다시 구현 → passing, e 도 passing

import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import assert from 'node:assert/strict'
import {
  makeProject, addFeature, mustRun, loadWorkflow, fakeParallel, noBudget, runCommandNode, schemaKeys,
} from './sim-helpers.mjs'

const project = makeProject({ loop: { maxAttempts: 3, repeatLimit: 2, parallel: 2 } })
writeFileSync(join(project, 'src/shared.js'), 'export const tag = "x";\n')
addFeature(project, 'a', '에이', 'test -f src/a.js')
addFeature(project, 'b', '비', 'test -f src/b.js')
addFeature(project, 'c', '씨', 'grep -q "c" src/shared.js')
addFeature(project, 'd', '디', 'grep -q "+d" src/shared.js')
addFeature(project, 'e', '이', 'test -f src/e.js')
mustRun(project, 'git add -A && git commit -qm init')

// 기능별 구현: 워크트리 경로를 받아 파일을 바꾼다
const implement = {
  a: (wt) => writeFileSync(join(wt, 'src/a.js'), 'export const a = 1;\n'),
  b: (wt) => writeFileSync(join(wt, 'src/b.js'), 'export const b = 1;\n'),
  c: (wt) => rewriteTag(wt, (t) => t.replace('x', 'c')),
  d: (wt) => rewriteTag(wt, (t) => `${t}+d`),
  e: (wt) => writeFileSync(join(wt, 'src/e.js'), 'export const e = 1;\n'),
}
function rewriteTag(wt, change) {
  const file = join(wt, 'src/shared.js')
  const tag = readFileSync(file, 'utf8').match(/"(.*)"/)[1]
  writeFileSync(file, `export const tag = "${change(tag)}";\n`)
}

// 런타임의 isolation: 'worktree' 흉내: HEAD 에서 워크트리를 만들고, 구현자가 지시받은 대로 브랜치에 커밋한다
function implementInWorktree(id) {
  const wt = join(mkdtempSync(join(tmpdir(), 'wt-')), id)
  const branch = `harness/wip-${id}`
  mustRun(project, `git worktree add -q --detach ${wt} HEAD`)
  implement[id](wt)
  mustRun(wt, `git checkout -q -b ${branch} && git add -A -- . ':(exclude).harness/features.json' && git commit -q -m "wip(${id})"`)
  mustRun(project, `git worktree remove --force ${wt}`)
  return branch
}

const isolatedCalls = []
async function agent(prompt, opts = {}) {
  const keys = schemaKeys(opts)
  if (keys.includes('exitCode')) return runCommandNode(project, prompt)
  const id = (prompt.match(/기능 id: ([\w-]+)/) || prompt.match(/--context ([\w-]+)/) || [])[1]
  if (keys.includes('branch')) {
    assert.equal(opts.isolation, 'worktree', '병렬 구현은 워크트리 격리여야 한다')
    assert.match(prompt, new RegExp(`git checkout -q -b harness/wip-${id}`))
    isolatedCalls.push(id)
    return { needsDecision: false, question: '', summary: id, filesChanged: [], branch: implementInWorktree(id) }
  }
  if (keys.includes('approved')) return { approved: true, reason: 'ok' }
  throw new Error(`알 수 없는 agent 호출: ${opts.label}`)
}

try {
  const run = await loadWorkflow({ agent, parallel: fakeParallel, phase: () => {}, log: () => {}, args: {}, budget: noBudget })
  const result = await run()

  assert.equal(result.stopReason, 'all-done')
  assert.deepEqual(result.passing.sort(), ['a', 'b', 'c', 'd', 'e'])
  assert.deepEqual(result.auditRegressions, [])

  const nodes = result.steps.map((s) => `${s.iteration}:${s.feature}:${s.node}:${s.result}`)
  assert.deepEqual(nodes, [
    '1:a:record:passing',
    '1:b:record:passing',
    '2:c:record:passing',
    '2:d:adopt:pending',       // c 와 같은 줄 → 병합 충돌
    '3:d:record:passing',      // 최신 HEAD 위에서 다시 구현
    '3:e:record:passing',
  ])
  assert.deepEqual(isolatedCalls, ['a', 'b', 'c', 'd', 'd', 'e'])

  const log = execFileSync('git', ['log', '--format=%s'], { cwd: project, encoding: 'utf8' }).trim().split('\n')
  assert.deepEqual(log, ['feat(e): 이', 'feat(d): 디', 'feat(c): 씨', 'feat(b): 비', 'feat(a): 에이', 'init'])
  assert.match(readFileSync(join(project, 'src/shared.js'), 'utf8'), /"c\+d"/)

  const leftovers = execFileSync('git', ['branch', '--list', 'harness/*'], { cwd: project, encoding: 'utf8' }).trim()
  assert.equal(leftovers, '', `남은 작업 브랜치: ${leftovers}`)
  assert.equal(execFileSync('git', ['status', '--porcelain'], { cwd: project, encoding: 'utf8' }).trim(), '')

  const trace = readFileSync(join(project, '.harness/trace.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
  assert.deepEqual(trace.filter((t) => t.event === 'adopt').map((t) => `${t.feature}:${t.result}`),
    ['a:adopted', 'b:adopted', 'c:adopted', 'd:conflict', 'd:adopted', 'e:adopted'])

  console.log('✓ feature-loop 병렬 분기 시뮬레이션 통과')
  console.log('  ' + nodes.join('\n  '))
} finally {
  rmSync(project, { recursive: true, force: true })
}
