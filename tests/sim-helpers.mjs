// tests/sim-helpers.mjs — 워크플로우 시뮬레이션이 같이 쓰는 도구.
// agent() 만 가짜로 두고, 하네스 명령은 임시 git 프로젝트에서 실제로 실행한다.

import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, delimiter } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
// bash 명령 문자열에 넣는 경로는 / 로 쓴다 — Windows 의 D:\a\… 는 bash 가 역슬래시를 이스케이프로 먹는다
export const bashPath = (path) => path.replaceAll('\\', '/')
export const HARNESS = bashPath(join(ROOT, 'bin/harness'))

// 가짜 claude: `claude -p /usage` 에 세션 FAKE_USAGE_PERCENT(기본 10)% 로 답한다.
// 시뮬레이션이 이 기계의 실제 요금제 사용량에 흔들리지 않게 한다(실제 claude 를 부르지 않는다).
export const FAKE_USAGE_ANSWER = 'if [[ "$1 $2" == "-p /usage" ]]; then printf \'{"result":"Current session: %s%% used · resets soon\\\\nCurrent week (all models): 5%% used · resets later"}\\n\' "${FAKE_USAGE_PERCENT:-10}"; fi\n'
const FAKE_CLAUDE_BIN = mkdtempSync(join(tmpdir(), 'fake-claude-'))
writeFileSync(join(FAKE_CLAUDE_BIN, 'claude'), `#!/usr/bin/env bash\n${FAKE_USAGE_ANSWER}`, { mode: 0o755 })
export const SIM_ENV = { ...process.env, PATH: `${FAKE_CLAUDE_BIN}${delimiter}${process.env.PATH}` }

export function sh(cwd, command, env = SIM_ENV) {
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
  const module = await import(pathToFileURL(file).href)  // Windows 의 C:\… 는 URL 이 아니라서 import 가 거부한다
  return () => module.default(globals)
}

// 런타임의 parallel(): 모든 thunk 를 기다리고, 실패는 null 로
export async function fakeParallel(thunks) {
  return Promise.all(thunks.map((t) => t().catch(() => null)))
}

export const noBudget = { total: null, spent: () => 0, remaining: () => Infinity }

// 워크플로우가 내는 하네스 명령을 이 저장소의 하네스로 바꾼다. args.projectRoot 를 주면 앞에 `cd <루트> &&` 가 붙는다.
const HARNESS_COMMAND = /^((?:cd '[^']*' && )?)\.harness\/bin\/harness/

// 결정론 노드(harness 명령)는 프롬프트 마지막 줄을 실제로 실행한다
export function runCommandNode(dir, prompt, env) {
  const command = prompt.trim().split('\n').pop().replace(HARNESS_COMMAND, `$1bash ${HARNESS}`)
  const r = sh(dir, command, env)
  return { exitCode: r.status, stdout: r.stdout }
}

export function schemaKeys(opts) {
  return Object.keys((opts.schema && opts.schema.properties) || {})
}

// ── 실제 에이전트처럼: 짧은 부트스트랩 프롬프트의 명령을 직접 실행해 진짜 프롬프트를 받는다 ──
export function featureIdOf(prompt) {
  return (prompt.match(/prompt (?:implement|review) ([\w-]+)/) || [])[1]
}

export function followBootstrap(dir, prompt) {
  const command = (prompt.match(/`((?:cd '[^']*' && )?\.harness\/bin\/harness prompt [^`]+)`/) || [])[1]
  if (!command) throw new Error(`부트스트랩 명령이 없다:\n${prompt}`)
  return mustRun(dir, command.replace(HARNESS_COMMAND, `$1bash ${HARNESS}`))
}

// 검증 프롬프트의 "대조표 항목" 을 전부 채운 대조표. violations: {ID: "파일:줄 — 설명"}
export function checklistVerdict(reviewText, violations = {}) {
  const section = reviewText.split('## 대조표 항목')[1] || ''
  const ids = [...section.matchAll(/^- ([A-Z]+[0-9]*): /gm)].map((m) => m[1])
  if (!ids.includes('REQ')) throw new Error('대조표 항목을 찾지 못했다')
  return {
    checks: ids.map((id) => violations[id]
      ? { id, result: 'violated', where: violations[id].where, note: violations[id].note }
      : { id, result: 'kept', where: '', note: '시뮬레이션' }),
    summary: Object.keys(violations).length ? '위반 있음' : '전 항목 지킴',
  }
}
