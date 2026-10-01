// tests/sim-helpers.mjs — 워크플로우 시뮬레이션이 같이 쓰는 도구.
// agent() 만 가짜로 두고, 하네스 명령은 임시 git 프로젝트에서 실제로 실행한다.

import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
export const HARNESS = join(ROOT, 'bin/harness')

export function sh(cwd, command, env = process.env) {
  return spawnSync('bash', ['-c', command], { cwd, encoding: 'utf8', env })
}

export function mustRun(cwd, command, env) {
  const r = sh(cwd, command, env)
  if (r.status !== 0) throw new Error(`${command}\n${r.stderr}${r.stdout}`)
  return r.stdout
}

// 하네스를 끼운 빈 프로젝트. configPatch 는 project.json 에 덮어쓴다.
export function makeProject(configPatch = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'harness-sim-'))
  mustRun(dir, 'git init -q && git config user.email t@e && git config user.name t')
  mustRun(dir, 'mkdir -p src tests && echo "export const add = (a, b) => a + b;" > src/math.js')
  writeFileSync(join(dir, 'tests/math.test.js'), 'test("adds", () => { expect(add(1, 2)).toBe(3) })\n')
  mustRun(dir, `bash ${HARNESS} init --preset generic --no-git-hooks --no-plugin 2>/dev/null`)
  const configPath = join(dir, '.harness/project.json')
  const config = JSON.parse(readFileSync(configPath, 'utf8'))
  writeFileSync(configPath, JSON.stringify({
    ...config,
    testGuard: { testCasePattern: '\\btest\\(', assertionPattern: '\\bexpect\\(', skipPattern: '\\btest\\.skip\\(' },
    loop: { maxAttempts: 3, repeatLimit: 2 },
    ...configPatch,
  }, null, 2))
  return dir
}

export function addFeature(dir, id, desc, acceptance, extra = '') {
  mustRun(dir, `bash ${HARNESS} feature add --id ${id} --desc '${desc}' --acceptance '${acceptance}' ${extra} 2>/dev/null`)
}

// 워크플로우 스크립트를 함수로 불러온다 (런타임이 주는 전역을 인자로 넘긴다)
export async function loadWorkflow(globals) {
  const source = readFileSync(join(ROOT, 'workflows/feature-loop.js'), 'utf8').replace(/^export const meta/m, 'const meta')
  const wrapped = `export default async function run({ agent, parallel, phase, log, args, budget }) {\n${source}\n}`
  const file = join(mkdtempSync(join(tmpdir(), 'wf-')), 'wf.mjs')
  writeFileSync(file, wrapped)
  const module = await import(file)
  return () => module.default(globals)
}

// 런타임의 parallel(): 모든 thunk 를 기다리고, 실패는 null 로
export async function fakeParallel(thunks) {
  return Promise.all(thunks.map((t) => t().catch(() => null)))
}

export const noBudget = { total: null, spent: () => 0, remaining: () => Infinity }

// 결정론 노드(harness 명령)는 프롬프트 마지막 줄을 실제로 실행한다
export function runCommandNode(dir, prompt, env) {
  const command = prompt.trim().split('\n').pop().replace(/^\.harness\/bin\/harness/, `bash ${HARNESS}`)
  const r = sh(dir, command, env)
  return { exitCode: r.status, stdout: r.stdout }
}

export function schemaKeys(opts) {
  return Object.keys((opts.schema && opts.schema.properties) || {})
}
