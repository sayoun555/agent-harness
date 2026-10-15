// tests/fuzz-ledger.mjs — 원장 명령을 무작위 순서로 돌려, 보고를 기다리지 않고 규칙끼리 부딪히는 곳을 찾는다.
//
//   node tests/fuzz-ledger.mjs [--seeds N] [--steps M] [--from S] [--jobs J] [--mode ledger|commit|both]
//
// 모델(LLM)은 부르지 않는다. 구현자 · 사람의 손 수정은 파일 쓰기로 흉내 내고, 하네스 명령은 실제로 실행한다.
// 같은 시드는 같은 순서를 만든다 — 실패하면 시드와 단계 기록으로 그대로 재현한다.
//
// 매 단계 검사
//   P1 비정상 종료 없음      종료 코드는 0 · 1 · 2 뿐이고, stderr 에 셸 · jq 오류가 없다
//   P2 보관 밖 파일 변경 없음 하네스는 보관(park)과 승인(approve) 때만 작업 파일을 바꾼다
//   P3 기록 직후 drift 없음   막 기록한 기능이 바로 "검증 후 변경됨" 으로 잡히지 않는다
//   P5 보관은 자기 변경만     기능을 보관하며 진행 중인 다른 기능이 마지막으로 쓴 파일을 치우지 않는다
// 끝 검사
//   P4 끝까지 갈 수 있다     루프가 하는 일(구현 · 범위 · verify · review · record)과 문서의 복구(claim)만으로
//                            모든 기능이 끝 상태(passing · blocked · awaiting-approval · needs-decision)에 닿는다.
//                            reset 과 원장 손 수정은 쓰지 않는다

import { spawn, spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { makeProject, addFeature, mustRun, HARNESS } from './sim-helpers.mjs'

const argv = process.argv.slice(2)
const opt = (name, fallback) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : fallback }
const SEEDS = Number(opt('seeds', 40))
const STEPS = Number(opt('steps', 20))
const FROM = Number(opt('from', 1))
const JOBS = Number(opt('jobs', 4))
const MODE = opt('mode', 'both')

// ── 결정론 난수 ─────────────────────────────────────────────────────
function rng(seed) {
  let a = seed >>> 0
  const next = () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296 }
  return { next, int: (n) => Math.floor(next() * n), pick: (xs) => xs[Math.floor(next() * xs.length)], chance: (p) => next() < p }
}

// ── 시나리오 ────────────────────────────────────────────────────────
// 기능마다 자기 파일이 있고, 같이 고치는 파일(shared)과 위험 파일(pay)이 있다. d 는 d.ok 를 만들어야 통과한다.
const FEATURES = ['a', 'b', 'c', 'd']
const OWN = { a: 'src/a.txt', b: 'src/b.txt', c: 'src/c.txt', d: 'src/d.ok' }
const SHARED = ['src/shared1.txt', 'src/shared2.txt']
const RISKY = 'src/pay.txt'
const POOL = [...Object.values(OWN), ...SHARED, RISKY]
const TERMINAL = new Set(['passing', 'blocked', 'awaiting-approval', 'needs-decision'])
const SHELL_ERRORS = /unbound variable|jq: error|syntax error|command not found|No such file or directory|integer expression expected/

class Violation extends Error {}

function setUp(mode) {
  const dir = makeProject({
    loop: { maxAttempts: 3, repeatLimit: 2, autoCommit: mode === 'commit' },
    approval: { riskGlobs: ['*pay*'] },
  })
  for (const f of FEATURES) addFeature(dir, f, f, f === 'd' ? 'test -f src/d.ok' : 'true')
  if (mode === 'commit') mustRun(dir, 'git add -A && git commit -qm base')
  return dir
}

function runSequence(seed, mode) {
  const r = rng(seed * 7919 + (mode === 'commit' ? 1 : 0))
  const dir = setUp(mode)
  const log = []
  const wrote = Object.fromEntries(FEATURES.map((f) => [f, new Set()]))   // 기능이 쓴 파일 (구현자가 보고할 filesChanged)
  let model = snapshot(dir)
  let writes = 0
  const lastWriter = {}   // 파일 → 마지막으로 쓴 쪽 (기능 ID 또는 '사람')

  const h = (...args) => {
    const res = spawnSync('bash', [HARNESS, ...args], { cwd: dir, encoding: 'utf8' })
    const line = `${args.join(' ')} → ${res.status}`
    log.push(line + (res.status === 0 ? '' : `  ${reasonOf(res)}`))
    if (![0, 1, 2].includes(res.status)) throw new Violation(`P1 종료 코드 ${res.status}: ${line}\n${res.stderr}`)
    if (SHELL_ERRORS.test(res.stderr)) throw new Violation(`P1 셸 오류: ${line}\n${res.stderr}`)
    return res
  }
  const ledger = () => JSON.parse(readFileSync(join(dir, '.harness/features.json'), 'utf8')).features
  const statusOf = (id) => ledger().find((f) => f.id === id).status
  const traceLines = () => { const p = join(dir, '.harness/trace.jsonl'); return existsSync(p) ? readFileSync(p, 'utf8').trim().split('\n').filter(Boolean) : [] }

  const write = (file, by) => {
    const text = `${by} ${++writes}\n`
    writeFileSync(join(dir, file), text)
    model[file] = text
    lastWriter[file] = by
    log.push(`(${by} 이 ${file} 을 씀)`)
  }

  // 하네스 명령 하나를 실행하고 P2 · P3 를 본다
  const step = (...args) => {
    const before = traceLines().length
    const beforeLedger = ledger()
    const inFlight = new Set(beforeLedger.filter(isInFlight).map((f) => f.id))
    const scopeOf = Object.fromEntries(beforeLedger.map((f) => [f.id, f.scope || null]))
    const res = h(...args)
    const added = traceLines().slice(before).map((l) => JSON.parse(l))
    const parked = added.some((e) => e.event === 'park')
    const brought = args[1] === 'approve' && res.status === 0
    const now = snapshot(dir)
    // P5 보관은 그 기능의 변경만 치운다 — 진행 중인 다른 기능이 마지막으로 쓴 파일을 건드리지 않는다.
    //    범위로 맡은 파일은 그 기능의 것이다(한 파일에 섞인 두 기능의 변경은 가를 수 없고, 맡은 쪽이 주인 — README 알려진 한계).
    for (const e of added.filter((x) => x.event === 'park')) {
      const claimed = scopeOf[e.feature] || []
      for (const file of POOL) {
        const owner = lastWriter[file]
        if (claimed.includes(file)) continue
        if (now[file] !== model[file] && owner && owner !== e.feature && inFlight.has(owner)) {
          throw new Violation(`P5 ${e.feature} 를 보관하며 진행 중인 ${owner} 의 ${file} 까지 치웠다: ${args.join(' ')}`)
        }
      }
    }
    if (!parked && !brought) {
      for (const file of POOL) {
        if (now[file] !== model[file]) throw new Violation(`P2 보관 없이 ${file} 이 바뀌었다 (${JSON.stringify(model[file])} → ${JSON.stringify(now[file])}): ${args.join(' ')}`)
      }
    }
    model = now
    if (args[1] === 'record' && added.some((e) => e.event === 'record' && e.result === 'passing')) {
      const drift = JSON.parse(h('feature', 'drift', '--json').stdout)
      if (drift.some((d) => d.id === args[2])) throw new Violation(`P3 기록 직후 drift: ${args[2]} ${JSON.stringify(drift)}`)
    }
    return res
  }

  // ── 무작위 동작 ───────────────────────────────────────────────────
  const implement = (f) => {
    step('prompt', 'implement', f)
    const files = [OWN[f]]
    if (r.chance(0.35)) files.push(r.pick(SHARED))
    if (r.chance(0.1)) files.push(RISKY)
    for (const file of files) { write(file, f); wrote[f].add(file) }
  }
  const claimWritten = (f) => { if (wrote[f].size) step('feature', 'claim', f, '--files', [...wrote[f]].join(','), '--json') }

  const actions = [
    [6, () => { const f = r.pick(FEATURES); if (statusOf(f) === 'pending') implement(f) }],
    [3, () => claimWritten(r.pick(FEATURES))],
    [5, () => step('feature', 'verify', r.pick(FEATURES), '--json')],
    [4, () => step('feature', 'review', r.pick(FEATURES), '--approve', '--json')],
    [1, () => step('feature', 'review', r.pick(FEATURES), '--reject', '--reason', '퍼즈 반려', '--json')],
    [4, () => step('feature', 'record', r.pick(FEATURES), '--json')],
    [1, () => step('feature', 'approve', r.pick(FEATURES))],
    [1, () => step('feature', 'ask', r.pick(FEATURES), '--question', '어느 쪽?', '--json')],
    [1, () => step('feature', 'decide', r.pick(FEATURES), '--answer', '이쪽')],
    [1, () => step('feature', 'reset', r.pick(FEATURES))],
    [2, () => step('feature', 'preflight', '--json')],
    [1, () => step('feature', 'audit', '--json')],
    [2, () => write(r.pick(POOL), '사람')],   // 사람의 손 수정 (어떤 기능도 맡지 않은 변경)
  ]
  const total = actions.reduce((s, [w]) => s + w, 0)
  const act = () => { let x = r.int(total); for (const [w, fn] of actions) { if ((x -= w) < 0) return fn() } }

  try {
    step('feature', 'preflight', '--json')
    for (let i = 0; i < STEPS; i++) act()
    finish()
    return null
  } catch (error) {
    if (!(error instanceof Violation)) throw error
    return { seed, mode, message: error.message, log, ledger: summary() }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }

  // ── P4: 루프와 문서의 복구만으로 끝까지 ─────────────────────────────
  function finish() {
    log.push('── 끝까지 진행 (루프 + claim 복구) ──')
    // 커밋 운용은 트리가 깨끗해야 시작한다. 사전 점검이 시키는 대로 사람이 stash 로 정리한다(원장 · 하네스 상태는 두고).
    if (mode === 'commit' && step('feature', 'preflight', '--json').status !== 0) {
      mustRun(dir, "git stash push -u -q -- . ':(exclude).harness'")
      log.push('(사람이 stash 로 트리를 정리)')
      model = snapshot(dir)
      for (const f of FEATURES) wrote[f].clear()
      for (const file of Object.keys(lastWriter)) delete lastWriter[file]
    }
    if (step('feature', 'preflight', '--json').status !== 0) { skippedFinish++; return }
    for (let round = 0; round < 12; round++) {
      const before = JSON.stringify(ledger().map((f) => [f.status, f.attempts, f.scope]))
      for (const f of FEATURES) {
        const status = statusOf(f)
        if (TERMINAL.has(status)) continue
        if (status === 'pending') {                          // 루프의 한 바퀴: 새 구현자가 자기 파일을 (다시) 쓰고 범위를 적는다
          step('prompt', 'implement', f)
          write(OWN[f], f); wrote[f].add(OWN[f])
          if (mode === 'ledger') claimWritten(f)             // 루프의 자동 범위는 커밋 없이 운용할 때만
        }
        if (statusOf(f) === 'pending') blockedOwner(f, step('feature', 'verify', f, '--json'))
        if (statusOf(f) === 'verified') blockedOwner(f, step('feature', 'review', f, '--approve', '--json'))
        if (statusOf(f) === 'reviewed') blockedOwner(f, step('feature', 'record', f, '--json'))
      }
      if (ledger().every((f) => TERMINAL.has(f.status))) return
      if (JSON.stringify(ledger().map((f) => [f.status, f.attempts, f.scope])) === before) {
        throw new Violation(`P4 진전 없음: ${summary()}`)
      }
    }
    throw new Violation(`P4 12바퀴 안에 끝나지 않음: ${summary()}`)
  }

  // 소유권에 막히면 문서의 첫 복구: 그 기능이 쓴 파일로 claim
  function blockedOwner(f, res) {
    if (res.status === 2 && /범위 미지정/.test(res.stderr)) claimWritten(f)
  }

  function summary() {
    try { return ledger().map((f) => `${f.id}:${f.status}${f.scope ? `[${f.scope.join(',')}]` : ''}${f.implementedUnder ? '*' : ''}`).join(' ') } catch { return '(원장 없음)' }
  }
}

// lib/features.sh 의 JQ_IN_FLIGHT 와 같은 정의
function isInFlight(f) {
  return f.status === 'verified' || f.status === 'reviewed'
    || (f.status === 'pending' && f.implementedUnder != null && f.implementedUnder.mode !== 'isolated')
}

function reasonOf(res) {
  const last = String(res.stdout || '').trim().split('\n').pop()
  try { const j = JSON.parse(last); if (j && j.reason) return `[${j.result}] ${j.reason}`.slice(0, 140) } catch { /* JSON 이 아니다 */ }
  return String(res.stderr || '').trim().split('\n')[0].slice(0, 140)
}

function snapshot(dir) {
  return Object.fromEntries(POOL.map((file) => {
    const p = join(dir, file)
    return [file, existsSync(p) ? readFileSync(p, 'utf8') : null]
  }))
}

// ── 실행: 시드 범위를 프로세스 여러 개로 나눈다 ─────────────────────
const modes = MODE === 'both' ? ['ledger', 'commit'] : [MODE]
let skippedFinish = 0   // 루프가 시작하지 않는 상태라 P4 를 보지 않은 순서

if (argv.includes('--worker')) {
  const failures = []
  for (let s = FROM; s < FROM + SEEDS; s++) {
    for (const mode of modes) { const f = runSequence(s, mode); if (f) failures.push(f) }
  }
  process.stdout.write(JSON.stringify({ failures, skipped: skippedFinish }))
} else {
  const per = Math.ceil(SEEDS / JOBS)
  const self = fileURLToPath(import.meta.url)
  const jobs = []
  for (let j = 0; j < JOBS; j++) {
    const from = FROM + j * per
    const count = Math.min(per, FROM + SEEDS - from)
    if (count <= 0) continue
    jobs.push(new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [self, '--worker', '--from', String(from), '--seeds', String(count), '--steps', String(STEPS), '--mode', MODE])
      let out = '', err = ''
      child.stdout.on('data', (d) => { out += d })
      child.stderr.on('data', (d) => { err += d })
      child.on('close', (code) => code === 0 ? resolve(JSON.parse(out)) : reject(new Error(`작업 프로세스 실패 (${code})\n${err}`)))
    }))
  }
  const results = await Promise.all(jobs)
  const failures = results.flatMap((r) => r.failures)
  const skipped = results.reduce((s, r) => s + r.skipped, 0)
  const runs = SEEDS * modes.length
  const skipNote = skipped ? ` · ${skipped}개는 루프가 시작하지 않는 상태라 P4 건너뜀` : ''
  if (!failures.length) {
    console.log(`✓ 원장 퍼즈: ${runs}개 순서 × ${STEPS}단계 (${modes.join(' · ')}) — 위반 없음${skipNote}`)
  } else {
    const kinds = {}
    for (const f of failures) { const k = f.message.slice(0, 2); kinds[k] = (kinds[k] || 0) + 1 }
    console.log(`✗ 원장 퍼즈: ${runs}개 중 ${failures.length}개 위반 ${JSON.stringify(kinds)}${skipNote}`)
    for (const f of failures) console.log(`  시드 ${f.seed} ${f.mode}: ${f.message.split('\n')[0].slice(0, 150)}`)
    for (const f of failures.slice(0, 5)) {
      console.log(`\n── 시드 ${f.seed} (${f.mode}) — 재현: node tests/fuzz-ledger.mjs --from ${f.seed} --seeds 1 --jobs 1 --mode ${f.mode} --steps ${STEPS}`)
      console.log(f.message)
      console.log('원장: ' + f.ledger)
      console.log(f.log.slice(-25).map((l) => '  ' + l).join('\n'))
    }
    process.exit(1)
  }
}
