#!/usr/bin/env bash
#
# tests/run.sh — 결정론 부품 테스트. 테스트마다 임시 git 저장소를 새로 만든다.
#   bash tests/run.sh            전체
#   bash tests/run.sh 이름패턴    이름에 패턴이 들어간 테스트만
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT/bin/harness"
FILTER="${1:-}"
PASSED=0
FAILED=0
FAILED_NAMES=()

# ── 픽스처 ──────────────────────────────────────────────────────────
# 작은 JS 프로젝트: src/ 소스, tests/ 테스트. testGuard 패턴은 project.json 에서 준다.
make_project() {
  local dir
  dir="$(mktemp -d)"
  cd "$dir" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name test
  mkdir -p src tests
  echo 'export const add = (a, b) => a + b;' > src/math.js
  printf 'test("adds", () => {\n  expect(add(1, 2)).toBe(3);\n  expect(add(0, 0)).toBe(0);\n});\n' > tests/math.test.js
  bash "$HARNESS" init --preset generic --no-git-hooks >/dev/null 2>&1
  jq '. + {
        testGuard: {testCasePattern: "\\btest\\(", assertionPattern: "\\bexpect\\(", skipPattern: "\\btest\\.skip\\("},
        loop: {maxAttempts: 3, repeatLimit: 2},
        approval: {riskGlobs: ["*payment*"]}
      }' .harness/project.json > .harness/p.tmp && mv .harness/p.tmp .harness/project.json
  git add -A && git commit -qm init
}

cleanup_project() { cd /; rm -rf "$1"; }

# delete_lines <pattern> <file> — sed -i 는 BSD·GNU 문법이 달라서 쓰지 않는다
delete_lines() { grep -v -- "$1" "$2" > "$2.tmp" || true; mv "$2.tmp" "$2"; }

h() { bash "$HARNESS" "$@"; }
status_of() { jq -r --arg id "$1" '.features[] | select(.id == $id) | .status' .harness/features.json; }
field_of() { jq -r --arg id "$1" --arg f "$2" '.features[] | select(.id == $id) | .[$f]' .harness/features.json; }

# ── 단언 ────────────────────────────────────────────────────────────
# 단언 실패는 플래그로 기록한다. set -e 에 기대지 않는다
# (if 조건 안에서 실행되면 bash 가 set -e 를 끄므로 중간 단언이 무시된다).
CURRENT_TEST_FAILED=0
fail() { printf '    ✗ %s\n' "$*"; CURRENT_TEST_FAILED=1; return 0; }
assert_eq() { [[ "$1" == "$2" ]] || fail "기대 '$2', 실제 '$1' ${3:-}"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "'$2' 가 없다: ${1:0:300}"; }
assert_exit() {  # assert_exit <expected> <command...>
  local expected="$1" actual=0; shift
  "$@" >/dev/null 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || fail "종료 코드 기대 $expected, 실제 $actual: $*"
}

run_test() {  # run_test <name>
  local name="$1" dir
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return
  dir="$(pwd)"
  make_project
  local project="$PWD"
  CURRENT_TEST_FAILED=0
  "$name"
  if [[ "$CURRENT_TEST_FAILED" -eq 0 ]]; then
    PASSED=$((PASSED + 1)); printf '  ✓ %s\n' "$name"
  else
    FAILED=$((FAILED + 1)); FAILED_NAMES+=("$name"); printf '  ✗ %s\n' "$name"
  fi
  cleanup_project "$project"
  cd "$dir" || true
}

# ── 설정 ────────────────────────────────────────────────────────────
test_config_merges_defaults_preset_and_project() {
  assert_eq "$(h config .loop.maxAttempts)" "3"
  assert_eq "$(h config .loop.maxIterations)" "20"            # defaults 에서
  assert_eq "$(h config -r .testGuard.assertionPattern)" '\bexpect\('   # project 에서
}

test_spring_preset_carries_java_criteria() {
  jq '.preset = "spring"' .harness/project.json > p && mv p .harness/project.json
  assert_contains "$(h config -r '.review.footguns[0].id')" "tx-self-invocation"
  assert_eq "$(h config -r .rules.maxFileLines)" "200"
}

# ── check ───────────────────────────────────────────────────────────
test_check_blocks_stub_marker() {
  echo '// TODO: 나중에' >> src/math.js
  assert_exit 1 h check src/math.js
}

test_check_only_warns_on_soft_korean_marker() {
  printf '/**\n * 추후 리포트 인프라.\n */\n' >> src/math.js
  assert_contains "$(h check src/math.js)" "[marker]"
  assert_exit 0 h check src/math.js
}

test_check_warns_on_hardcoded_values_from_nextjs_preset() {
  jq '.preset = "nextjs"' .harness/project.json > p && mv p .harness/project.json
  mkdir -p src/app
  cat > src/app/page.tsx <<'TSX'
const products = [{ id: 1, name: "키보드" }];
export default function Page() {
  return <h1 className="text-[#333] p-[18px]" style={{ color: "#1a2b3c" }}>{products.length}</h1>;
}
fetch("http://localhost:8080/api");
TSX
  local out
  out="$(h check src/app/page.tsx)"
  assert_contains "$out" "[hardcode:tailwind-arbitrary]"
  assert_contains "$out" "[hardcode:hex-color]"
  assert_contains "$out" "[hardcode:data-literal]"
  assert_contains "$out" "[hardcode:localhost-url]"
  assert_exit 0 h check src/app/page.tsx
}

test_check_hardcode_patterns_are_quiet_on_clean_code() {
  jq '.preset = "nextjs"' .harness/project.json > p && mv p .harness/project.json
  mkdir -p src/app
  printf 'export default function Page({ items }: { items: string[] }) {\n  return <ul className="p-4 text-gray-800">{items.map((i) => <li key={i}>{i}</li>)}</ul>;\n}\n' > src/app/page.tsx
  assert_eq "$(h check src/app/page.tsx | grep -c hardcode || true)" "0"
}

test_check_blocks_hardcoded_secret() {
  echo 'const apiKey = "k3y-live-abcdef123456";' >> src/math.js
  assert_exit 1 h check src/math.js
}

test_check_ignores_secret_from_env() {
  echo 'const apiKey = process.env.API_KEY || "fallback-value-123";' >> src/math.js
  assert_exit 0 h check src/math.js
}

test_check_ignores_test_files() {
  echo '// TODO: 테스트 보강' >> tests/math.test.js
  assert_exit 0 h check tests/math.test.js
}

test_check_warns_on_size_without_blocking() {
  jq '.rules = {maxFileLines: 2}' .harness/project.json > p && mv p .harness/project.json
  printf 'a\nb\nc\n' >> src/math.js
  local out
  out="$(h check src/math.js)"
  assert_contains "$out" "[size]"
  assert_exit 0 h check src/math.js
}

# ── test-guard ──────────────────────────────────────────────────────
test_guard_passes_when_tests_grow() {
  printf 'test("zero", () => { expect(add(0, 1)).toBe(1); });\n' > tests/extra.test.js
  assert_exit 0 h test-guard
}

test_guard_fails_when_assertion_removed() {
  delete_lines 'add(0, 0)' tests/math.test.js
  assert_exit 1 h test-guard
  assert_contains "$(h test-guard --json)" '"weakened":true'
}

test_guard_fails_when_test_file_deleted() {
  rm tests/math.test.js
  assert_exit 1 h test-guard
}

test_guard_fails_when_skip_added() {
  printf 'test.skip("later", () => { expect(1).toBe(1); });\n' >> tests/math.test.js
  assert_exit 1 h test-guard
}

test_guard_only_warns_when_assertion_moves_between_files() {
  delete_lines 'add(0, 0)' tests/math.test.js
  printf 'test("moved", () => { expect(add(0, 0)).toBe(0); });\n' > tests/zero.test.js
  # 합계는 케이스 1→2, assertion 2→2 라서 실패가 아니다. math.test.js 의 감소는 경고만 한다.
  local out
  out="$(h test-guard --json)"
  assert_contains "$out" '"weakened":false'
  assert_contains "$out" 'assertion 감소: tests/math.test.js'
}

# ── feature: 상태 전이 ───────────────────────────────────────────────
add_feature() { h feature add --id "$1" --desc "$2" --acceptance "$3" >/dev/null 2>&1; git add -A; git commit -qm "add $1"; }

# 결정론 게이트와 독립 검증 승인까지 (기록 직전 상태로)
verify_and_review() { h feature verify "$1" >/dev/null 2>&1; h feature review "$1" --approve >/dev/null 2>&1; }

parked_ref_of() { jq -r --arg id "$1" '.features[] | select(.id == $id) | .parked.ref // ""' .harness/features.json; }

test_feature_verify_review_record_marks_passing() {
  add_feature sub "빼기" 'grep -q "sub" src/math.js'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  assert_exit 0 h feature verify sub
  assert_eq "$(status_of sub)" "verified"
  assert_exit 2 h feature record sub "(독립 검증 전에는 기록할 수 없다)"
  assert_exit 0 h feature review sub --approve --reason "기준 위반 없음"
  assert_eq "$(status_of sub)" "reviewed"
  assert_exit 0 h feature record sub
  assert_eq "$(status_of sub)" "passing"
  assert_contains "$(git log -1 --format=%s)" "feat(sub)"
  assert_eq "$(git status --porcelain)" ""
}

test_feature_failure_increments_attempts_and_keeps_pending() {
  add_feature mul "곱하기" 'grep -q "mul" src/math.js'
  assert_exit 1 h feature verify mul
  assert_eq "$(status_of mul)" "pending"
  assert_eq "$(field_of mul attempts)" "1"
  assert_eq "$(field_of mul lastFailure)" "acceptance 실패"
}

test_feature_same_failure_twice_blocks() {
  add_feature mul "곱하기" 'grep -q "mul" src/math.js'
  h feature verify mul >/dev/null 2>&1 || true
  h feature verify mul >/dev/null 2>&1 || true
  assert_eq "$(status_of mul)" "blocked" "(같은 실패 2회)"
  assert_eq "$(field_of mul repeats)" "2"
}

test_feature_different_failures_block_at_max_attempts() {
  add_feature mul "곱하기" 'echo "attempt $(cat .n 2>/dev/null)"; exit 1'
  local i
  for i in a b c; do echo "$i" > .n; h feature verify mul >/dev/null 2>&1 || true; done
  assert_eq "$(field_of mul attempts)" "3"
  assert_eq "$(status_of mul)" "blocked" "(서로 다른 실패 3회 = 최대 시도)"
}

test_feature_weakened_tests_fail_verify() {
  add_feature noop "아무것도 안 함" 'true'
  delete_lines 'add(0, 0)' tests/math.test.js
  assert_exit 1 h feature verify noop
  assert_eq "$(field_of noop lastFailure)" "테스트 약화 실패"
}

test_feature_reject_records_review_failure() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  assert_exit 0 h feature reject sub --reason "과설계"
  assert_eq "$(status_of sub)" "pending"
  assert_contains "$(field_of sub lastFailure)" "리뷰 반려: 과설계"
}

test_feature_commit_waits_for_approval_on_risky_file() {
  add_feature pay "결제" 'test -f src/payment.js'
  echo 'export const pay = () => true;' > src/payment.js
  verify_and_review pay
  assert_exit 0 h feature record pay
  assert_eq "$(status_of pay)" "awaiting-approval"
  assert_eq "$(git log -1 --format=%s)" "add pay" "(아직 커밋하면 안 됨)"
  assert_exit 0 h feature approve pay
  assert_eq "$(status_of pay)" "passing"
  assert_contains "$(git log -1 --format=%b)" "사람 승인"
}

test_feature_commit_rolls_back_when_git_hook_blocks() {
  add_feature sub "빼기" 'true'
  git config core.hooksPath "$ROOT/git-hooks"
  echo '// TODO: 임시' >> src/math.js     # verify 는 통과하지만 pre-commit 이 막는다
  verify_and_review sub
  assert_exit 1 h feature record sub
  assert_eq "$(status_of sub)" "blocked" "(커밋 실패는 사람이 볼 수 있게 막힘으로)"
  assert_eq "$(field_of sub lastFailure)" "git 커밋 실패 (훅 차단 등)"
  assert_eq "$(git log -1 --format=%s)" "add sub"
  assert_eq "$(git status --porcelain -- src)" "" "(변경은 보관되고 트리는 깨끗해야 함)"
  assert_contains "$(git show harness/sub:src/math.js)" "// TODO: 임시"
}

# ── 보관: 통과 못 한 기능의 변경이 다음 커밋에 섞이지 않는다 ─────────
test_risky_change_is_parked_and_not_leaked_into_next_commit() {
  add_feature pay "결제" 'test -f src/payment.js'
  add_feature sub "빼기" 'grep -q "const sub" src/math.js'
  echo 'export const pay = () => true;' > src/payment.js
  verify_and_review pay; h feature record pay >/dev/null 2>&1
  assert_eq "$(status_of pay)" "awaiting-approval"
  assert_eq "$(test -e src/payment.js && echo leaked || echo clean)" "clean" "(작업 트리에서 빠져야 함)"
  assert_eq "$(parked_ref_of pay)" "harness/pay"

  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  verify_and_review sub; h feature record sub >/dev/null 2>&1
  assert_eq "$(status_of sub)" "passing"
  assert_eq "$(git show --name-only --format= HEAD | grep -c payment || true)" "0" "(결제 코드가 빼기 커밋에 섞이면 안 됨)"

  assert_exit 0 h feature approve pay
  assert_eq "$(status_of pay)" "passing"
  assert_eq "$(test -f src/payment.js && echo ok)" "ok"
  assert_eq "$(git branch --list harness/pay)" "" "(승인 후 보관 브랜치 삭제)"
}

test_blocked_feature_changes_are_parked() {
  add_feature mul "곱하기" 'grep -q "const mul =" src/math.js'
  echo 'export const mull = 1;' >> src/math.js   # 틀린 구현: 실패가 반복돼 막힌다
  h feature verify mul >/dev/null 2>&1 || true
  h feature verify mul >/dev/null 2>&1 || true
  assert_eq "$(status_of mul)" "blocked"
  assert_eq "$(git status --porcelain -- src)" ""
  assert_contains "$(git show harness/mul:src/math.js)" "mull"
  assert_contains "$(h feature reset mul)" "harness/mul"
}

test_approve_refuses_dirty_tree() {
  add_feature pay "결제" 'test -f src/payment.js'
  echo 'export const pay = () => true;' > src/payment.js
  verify_and_review pay; h feature record pay >/dev/null 2>&1
  echo 'stray' > src/other.js
  assert_exit 2 h feature approve pay
  assert_eq "$(status_of pay)" "awaiting-approval"
}

# ── 판단 요청 ───────────────────────────────────────────────────────
test_ask_moves_feature_to_needs_decision() {
  add_feature cache "캐싱" 'true'
  assert_exit 0 h feature ask cache --question "Redis 와 메모리 캐시 중 무엇으로?"
  assert_eq "$(status_of cache)" "needs-decision"
  assert_eq "$(field_of cache question)" "Redis 와 메모리 캐시 중 무엇으로?"
  assert_eq "$(h feature next)" "" "(판단 대기 기능은 다시 선택되지 않음)"
  local out
  out="$(CLAUDE_PROJECT_DIR="$PWD" h hook session < /dev/null)"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "판단 필요: cache"
}

test_decide_records_answer_and_requeues() {
  add_feature cache "캐싱" 'true'
  h feature ask cache --question "어디에?" >/dev/null 2>&1
  assert_exit 0 h feature decide cache --answer "Redis"
  assert_eq "$(status_of cache)" "pending"
  assert_eq "$(jq -c '.features[0].decisions' .harness/features.json)" '[{"question":"어디에?","answer":"Redis"}]'
  h feature ask cache --question "TTL?" >/dev/null 2>&1
  h feature decide cache --answer "10분" >/dev/null 2>&1
  assert_eq "$(jq -r '.features[0].decisions | length' .harness/features.json)" "2" "(결정은 누적)"
}

test_reset_accepts_needs_decision() {
  add_feature cache "캐싱" 'true'
  h feature ask cache --question "어디에?" >/dev/null 2>&1
  assert_exit 0 h feature reset cache
  assert_eq "$(status_of cache)" "pending"
}

test_feature_verify_refuses_blocked_feature() {
  add_feature mul "곱하기" 'false'
  h feature verify mul >/dev/null 2>&1 || true
  h feature verify mul >/dev/null 2>&1 || true
  assert_exit 2 h feature verify mul
  assert_exit 0 h feature reset mul
  assert_eq "$(status_of mul)" "pending"
  assert_eq "$(field_of mul attempts)" "0"
}

test_feature_audit_detects_regression() {
  add_feature sub "빼기" 'grep -q "sub" src/math.js'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  verify_and_review sub && h feature record sub >/dev/null 2>&1
  delete_lines 'sub' src/math.js
  assert_exit 1 h feature audit
  assert_eq "$(status_of sub)" "pending"
}

test_preflight_reports_plugin_agents_only_when_enabled() {
  add_feature sub "빼기" 'true'
  mkdir -p .claude
  echo '{}' > .claude/settings.json; echo '{}' > .claude/settings.local.json
  assert_eq "$(h feature preflight --json | jq -c .agents)" "{}" "(플러그인이 꺼져 있으면 기본 에이전트)"
  echo '{"enabledPlugins": {"agent-harness@agent-harness": true}}' > .claude/settings.local.json
  assert_eq "$(h feature preflight --json | jq -r '.agents | [.runner, .implementer, .reviewer] | join(" ")')" \
    "agent-harness:harness-runner agent-harness:harness-implementer agent-harness:harness-reviewer"
}

test_feature_preflight_rejects_dirty_tree() {
  add_feature sub "빼기" 'true'
  assert_exit 0 h feature preflight
  echo 'x' > stray.txt
  assert_exit 1 h feature preflight
  assert_contains "$(h feature preflight --json)" "작업 트리가 깨끗하지 않다"
}

test_feature_next_returns_first_pending() {
  add_feature a "첫째" 'true'
  add_feature b "둘째" 'true'
  assert_eq "$(h feature next)" "a"
  h feature verify a >/dev/null 2>&1
  assert_eq "$(h feature next)" "b"
  assert_eq "$(h feature next --json | jq -r .description)" "둘째"
}

test_feature_next_limit_returns_batch() {
  add_feature a "첫째" 'true'
  add_feature b "둘째" 'true'
  add_feature c "셋째" 'true'
  assert_eq "$(h feature next --json --limit 2 | jq -c 'map(.id)')" '["a","b"]'
  assert_exit 2 h feature next --json --limit 0
}

test_feature_adopt_without_branch_counts_as_failure() {
  add_feature a "첫째" 'true'
  assert_exit 1 h feature adopt a harness/wip-a
  assert_eq "$(status_of a)" "pending"
  assert_eq "$(field_of a lastFailure)" "구현 결과 없음"
}

test_feature_adopt_brings_branch_into_worktree() {
  add_feature a "첫째" 'test -f src/a.js'
  git checkout -q -b harness/wip-a && echo 'x' > src/a.js && git add -A && git commit -qm wip && git checkout -q -
  assert_exit 0 h feature adopt a harness/wip-a
  assert_eq "$(git status --porcelain -- src)" "?? src/a.js" "(가져온 변경은 커밋 전 작업 트리에)"
  assert_eq "$(git branch --list harness/wip-a)" ""
  assert_exit 0 h feature verify a
}

test_trace_records_each_node() {
  add_feature sub "빼기" 'true'
  verify_and_review sub
  h feature record sub >/dev/null 2>&1
  assert_eq "$(jq -r .event .harness/trace.jsonl | paste -sd, -)" "verify,review,record"
  assert_contains "$(h trace summary)" "record"
}

# ── init: 프로젝트 단위 플러그인 활성화 ─────────────────────────────
test_init_enables_plugin_only_for_this_project() {
  local settings=.claude/settings.json
  assert_eq "$(jq -r '.enabledPlugins["agent-harness@agent-harness"]' $settings)" "true"
  assert_eq "$(jq -r '.extraKnownMarketplaces["agent-harness"].source.repo' $settings)" "sayoun555/agent-harness"
  assert_eq "$(jq -r '.extraKnownMarketplaces["agent-harness"].source.source' $settings)" "github"
}

test_init_preserves_existing_claude_settings() {
  echo '{"permissions": {"deny": ["Read(./.env)"]}, "enabledPlugins": {"other@m": true}}' > .claude/settings.json
  h init --no-git-hooks >/dev/null 2>&1
  assert_eq "$(jq -r '.permissions.deny[0]' .claude/settings.json)" "Read(./.env)"
  assert_eq "$(jq -r '.enabledPlugins["other@m"]' .claude/settings.json)" "true"
  assert_eq "$(jq -r '.enabledPlugins["agent-harness@agent-harness"]' .claude/settings.json)" "true"
}

test_init_no_plugin_leaves_claude_settings_alone() {
  rm -rf .claude
  h init --no-plugin --no-git-hooks >/dev/null 2>&1
  assert_eq "$(test -e .claude/settings.json && echo exists || echo absent)" "absent"
}

test_path_workflow_is_a_copy_inside_the_project() {
  local path
  path="$(h path workflow)"
  assert_eq "$path" "$(pwd -P)/.harness/bin/feature-loop.js" "(Workflow 도구는 작업 디렉터리 밖 경로를 거부한다)"
  assert_eq "$(cmp -s "$path" "$ROOT/workflows/feature-loop.js" && echo same)" "same"
  echo "// 낡은 사본" > "$path"
  h path workflow >/dev/null
  assert_eq "$(cmp -s "$path" "$ROOT/workflows/feature-loop.js" && echo same)" "same" "(원본과 다르면 다시 쓴다)"
  assert_eq "$(git status --porcelain)" "" "(사본은 gitignore 된 .harness/bin/ 에 있다)"
}

test_session_hook_recreates_missing_shim() {
  rm -f .harness/bin/harness
  CLAUDE_PROJECT_DIR="$PWD" h hook session < /dev/null >/dev/null
  assert_eq "$(test -x .harness/bin/harness && echo ok)" "ok"
  assert_eq "$(.harness/bin/harness path home)" "$ROOT"
}

# 스킬의 0단계 확인 명령과 같은 명령 (SKILL.md 와 문구를 맞춘다)
skill_guard() { test -f .harness/project.json && test -x .harness/bin/harness && echo plugged || echo absent; }

test_skill_guard_reports_absent_without_harness() {
  rm -rf .harness
  assert_eq "$(skill_guard)" "absent"
}

test_skill_guard_reports_plugged_with_harness() {
  assert_eq "$(skill_guard)" "plugged"
  assert_contains "$(cat "$ROOT/skills/harness/SKILL.md")" 'test -f .harness/project.json && test -x .harness/bin/harness && echo plugged || echo absent'
}

# ── MCP: 확인만 하고 설치하지 않는다 ────────────────────────────────
# fake_claude_bin <mcp-list-출력> → 가짜 claude 가 든 디렉터리. 호출되면 그 디렉터리에 .called 를 남긴다.
fake_claude_bin() {
  local dir
  dir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\ntouch "%s/.called"\n[[ "$1 $2" == "mcp list" ]] && cat <<'"'"'OUT'"'"'\n%s\nOUT\n' "$dir" "$1" > "$dir/claude"
  chmod +x "$dir/claude"
  printf '%s\n' "$dir"
}

recommend_playwright() {
  jq '. + {app: {startCommand: "npm run dev"}, mcp: {recommended: [{
        name: "playwright", detect: "(^|:)playwright$", purpose: "화면 확인",
        install: "claude mcp add playwright -- npx -y @playwright/mcp@latest",
        reviewHint: "Playwright 로 확인. 먼저 {startCommand}"}]}}' \
    .harness/project.json > p && mv p .harness/project.json
  git add -A && git commit -qm "mcp 권장"
}

mcp_state() { jq -r '.[0].state' <<<"$1"; }

test_mcp_reports_connected() {
  recommend_playwright
  local bin out
  bin="$(fake_claude_bin 'playwright: npx -y @playwright/mcp@latest - ✔ Connected')"
  out="$(PATH="$bin:$PATH" h mcp --json)"
  assert_eq "$(mcp_state "$out")" "connected"
  assert_eq "$(jq -r '.[0].reviewHint' <<<"$out")" "Playwright 로 확인. 먼저 npm run dev" "({startCommand} 치환)"
}

test_mcp_reports_absent_with_install_hint() {
  recommend_playwright
  local bin
  bin="$(fake_claude_bin 'figma: npx -y figma-developer-mcp --stdio - ✔ Connected')"
  assert_eq "$(mcp_state "$(PATH="$bin:$PATH" h mcp --json)")" "absent"
  assert_contains "$(PATH="$bin:$PATH" h mcp)" "설치(선택): claude mcp add playwright"
}

test_mcp_matches_plugin_namespaced_server() {
  recommend_playwright
  local bin
  bin="$(fake_claude_bin 'plugin:tools:playwright: npx @playwright/mcp - ! Needs authentication')"
  assert_eq "$(mcp_state "$(PATH="$bin:$PATH" h mcp --json)")" "needs-auth"
}

test_mcp_unknown_without_claude_cli() {
  recommend_playwright
  assert_eq "$(mcp_state "$(PATH="/usr/bin:/bin" h mcp --json)")" "unknown"
}

test_mcp_not_checked_when_preset_recommends_none() {
  local bin
  bin="$(fake_claude_bin 'playwright: x - ✔ Connected')"
  assert_eq "$(PATH="$bin:$PATH" h mcp --json)" "[]"
  add_feature a "첫째" 'true'
  PATH="$bin:$PATH" h feature preflight >/dev/null 2>&1
  assert_eq "$(test -e "$bin/.called" && echo called || echo skipped)" "skipped" "(느린 claude mcp list 를 부르지 않아야 함)"
}

test_preflight_carries_mcp_and_never_blocks_on_it() {
  recommend_playwright
  add_feature a "첫째" 'true'
  local bin out
  bin="$(fake_claude_bin 'nothing: x - ✗ Failed')"
  out="$(PATH="$bin:$PATH" h feature preflight --json)"
  assert_eq "$(jq -r .ok <<<"$out")" "true" "(MCP 가 없어도 루프는 시작)"
  assert_eq "$(jq -r '.mcp[0].state' <<<"$out")" "absent"
  assert_eq "$(git status --porcelain)" "" "(확인만 하고 아무것도 설치·변경하지 않음)"
}

# ── 설계 단계 ───────────────────────────────────────────────────────
# write_design <path> <결정 상태> [검증 계획에서 뺄 구성 요소] [요구 원천 종류] [추가 요구 추적 줄]
write_design() {
  local path="$1" status="$2" unverified="${3:-}" source_kind="${4:-1차}" extra_trace="${5:-}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<DOC
# 설계: 계산기

## 요구 원천

| 문서 | 판·날짜 | 종류 | 범위 |
|---|---|---|---|
| docs/SRS.md | v1.2 · 2026-09-01 | $source_kind | §3 연산 |
| docs/interface.md | 2026-09-10 | 파생 | 함수 시그니처 |

## 완성 정의

사용자가 두 수의 차와 곱을 얻는다. 데이터는 입력값뿐이다.

## UX·레퍼런스

없음 (화면이 없다)

## 범위 밖

나눗셈.

## 현재 상태

src/math.js 에 add 만 있다. 함수는 named export 로 둔다.

## 설계 결정

| ID | 결정 | 선택 | 근거 기준 | 상태 |
|---|---|---|---|---|
| D1 | 모듈 형식 | ES 모듈 | C5 | 결정됨 |
| D2 | 저장 방식 | 없음 · 로컬 저장소 | C2 | $status |

## 구성 요소

| 구성 요소 | 역할 | 왜 필요한가 | 근거 기준 |
|---|---|---|---|
| sub | 빼기 | 완성 정의의 차 | C1 |
| mul | 곱하기 | 완성 정의의 곱 | C1 |

## 검증 계획

| 구성 요소 | 확인 방법 | 명령 |
|---|---|---|
$( [[ "$unverified" == "sub" ]] || echo '| sub | 함수 존재 | `grep -q "const sub" src/math.js` |' )
| mul | 함수 존재 | \`grep -q "const mul" src/math.js \|\| exit 1\` |

## 기능 분해

| id | 설명 | acceptance |
|---|---|---|
| calc-sub | 빼기 함수 | \`grep -q "const sub" src/math.js\` |
| calc-mul | 곱하기 함수 | \`grep -q "const mul" src/math.js \|\| exit 1\` |

## 요구 추적

| 요구 ID | 출처 | 구성 요소 | 기능 | 검증 |
|---|---|---|---|---|
| SR-301 | SRS §3.1 | sub | calc-sub | 함수 존재 |
| SR-302 | SRS §3.2 | mul | calc-mul | 함수 존재 |
| SR-303 | SRS §3.3 | - | 범위 밖 | - |
$extra_trace
DOC
}

test_design_new_creates_doc_that_fails_until_filled() {
  local doc
  doc="$(h design new calc)"
  assert_eq "$doc" "docs/design/calc.md"
  assert_contains "$(head -1 "$doc")" "# 설계: calc"
  assert_exit 1 h design check "$doc"
  assert_contains "$(h design check "$doc")" "절이 비어 있다: ## 완성 정의"
  assert_contains "$(h design check "$doc")" "절이 비어 있다: ## UX·레퍼런스"
  assert_exit 2 h design new calc
}

test_design_check_passes_complete_doc() {
  write_design docs/design/calc.md "사람 결정: 없음"
  assert_exit 0 h design check docs/design/calc.md
  assert_eq "$(h design check docs/design/calc.md --json | jq -c '{ok, problems, unresolved, warnings}')" '{"ok":true,"problems":[],"unresolved":[],"warnings":[]}'
}

test_design_check_requires_primary_requirement_source() {
  write_design docs/design/calc.md "결정됨" "" "파생"
  assert_exit 1 h design check docs/design/calc.md
  assert_contains "$(h design check docs/design/calc.md)" "1차 요구 문서가 없다"
}

test_design_check_rejects_unmapped_requirement() {
  write_design docs/design/calc.md "결정됨" "" "1차" "| SR-304 | SRS §3.4 | div | calc-div | 함수 존재 |"
  local out
  out="$(h design check docs/design/calc.md)"
  assert_contains "$out" "요구 SR-304 의 기능 'calc-div' 가 기능 분해에 없다"
  assert_contains "$out" "요구 SR-304 의 구성 요소 'div' 가 구성 요소 표에 없다"
}

test_design_check_warns_when_feature_carries_too_many_requirements() {
  local rows="" i
  for i in 1 2 3 4 5 6 7; do rows="$rows| SR-4$i | SRS §4 | sub | calc-sub | 함수 존재 |"$'\n'; done
  write_design docs/design/calc.md "결정됨" "" "1차" "$rows"
  assert_exit 0 h design check docs/design/calc.md "(경고는 막지 않는다)"
  assert_contains "$(h design check docs/design/calc.md)" "기능 calc-sub 가 요구 8개를 맡는다 (> 6)"
}

test_design_trace_summarizes_coverage() {
  write_design docs/design/calc.md "결정됨"
  local out
  out="$(h design trace docs/design/calc.md --json)"
  assert_eq "$(jq -c '{total, mapped, outOfScope}' <<<"$out")" '{"total":3,"mapped":2,"outOfScope":1}'
  assert_contains "$(h design trace docs/design/calc.md)" "요구 3개 — 기능에 이어짐 2 · 범위 밖 1 · 이어지지 않음 0"
}

test_design_check_lists_pending_human_decisions() {
  write_design docs/design/calc.md "사람 결정 필요"
  assert_exit 1 h design check docs/design/calc.md
  assert_eq "$(h design check docs/design/calc.md --json | jq -c '.unresolved')" '[{"id":"D2","decision":"저장 방식","options":"없음 · 로컬 저장소"}]'
}

test_design_check_requires_verification_per_component() {
  write_design docs/design/calc.md "결정됨" sub
  assert_contains "$(h design check docs/design/calc.md)" "구성 요소 'sub' 의 검증 방법이 없다"
}

test_design_check_rejects_unknown_decision_status() {
  write_design docs/design/calc.md "아마도"
  assert_contains "$(h design check docs/design/calc.md)" "결정 D2 의 상태가 올바르지 않다"
}

test_design_import_refuses_until_decisions_are_made() {
  write_design docs/design/calc.md "사람 결정 필요"
  assert_exit 1 h design import docs/design/calc.md
  assert_eq "$(jq '.features | length' .harness/features.json)" "0"
}

test_design_import_adds_features_with_design_reference() {
  write_design docs/design/calc.md "사람 결정: 없음"
  assert_exit 0 h design import docs/design/calc.md
  assert_eq "$(jq -r '[.features[].id] | join(",")' .harness/features.json)" "calc-sub,calc-mul"
  assert_eq "$(field_of calc-mul acceptance)" 'grep -q "const mul" src/math.js || exit 1' "(이스케이프된 파이프 복원)"
  assert_eq "$(field_of calc-sub designDoc)" "docs/design/calc.md"
  assert_contains "$(h design import docs/design/calc.md)" "건너뜀 2개"
}

test_design_import_carries_human_decisions_into_features() {
  write_design docs/design/calc.md "사람 결정: 로컬 저장소"
  h design import docs/design/calc.md >/dev/null
  assert_eq "$(jq -c '.features[0].decisions' .harness/features.json)" '[{"question":"D2 저장 방식","answer":"로컬 저장소"}]'
  assert_contains "$(h feature brief calc-sub)" "- D2 저장 방식 → 로컬 저장소" "(구현 지시문에 자동으로 들어간다)"
}

# 기능 분해의 "화면" 칸 (Figma 노드 링크). 칸이 없는 예전 문서도 그대로 읽힌다.
add_screen_column() {  # add_screen_column <doc> <calc-sub 화면> <calc-mul 화면>
  sed -i.bak -e "/^| calc-sub |/ s#\$# $2 |#" -e "/^| calc-mul |/ s#\$# $3 |#" "$1" && rm -f "$1.bak"
}

test_design_import_carries_figma_screen() {
  write_design docs/design/calc.md "사람 결정: 없음"
  add_screen_column docs/design/calc.md "https://www.figma.com/design/abc?node-id=1-2" "-"
  assert_exit 0 h design check docs/design/calc.md
  h design import docs/design/calc.md >/dev/null
  assert_eq "$(field_of calc-sub figma)" "https://www.figma.com/design/abc?node-id=1-2"
  assert_eq "$(jq -r '.features[1] | has("figma")' .harness/features.json)" "false" "(- 는 화면 없음)"
  assert_contains "$(h feature list)" "[Figma]"
}

test_design_check_rejects_screen_that_is_not_a_link() {
  write_design docs/design/calc.md "사람 결정: 없음"
  add_screen_column docs/design/calc.md "메인 화면" "-"
  assert_exit 1 h design check docs/design/calc.md
  assert_contains "$(h design check docs/design/calc.md)" "기능 calc-sub 의 화면은 Figma 링크"
}

test_figma_feature_carries_node_to_both_prompts() {
  h feature add --id home --desc "홈 화면" --acceptance true --figma "https://www.figma.com/design/abc?node-id=3-4" >/dev/null
  assert_contains "$(h prompt implement home)" "[화면 기준 — Figma] https://www.figma.com/design/abc?node-id=3-4"
  assert_contains "$(h prompt implement home)" "Figma 를 열 수 없으면 추측해서 만들지 않는다"
  assert_contains "$(h prompt review home)" "## 화면 기준 (Figma): https://www.figma.com/design/abc?node-id=3-4"
  add_feature plain "화면 없음" 'true'
  [[ "$(h prompt implement plain)" != *"화면 기준"* ]] || fail "화면 없는 기능에 Figma 지시가 붙었다"
}

test_preflight_offers_figma_agents_only_with_figma_mcp() {
  h feature add --id home --desc "홈 화면" --acceptance true --figma "https://www.figma.com/design/abc?node-id=3-4" >/dev/null
  git add -A && git commit -qm "add home"
  local with without
  with="$(fake_claude_bin 'figma: npx -y figma-developer-mcp --stdio - ✔ Connected')"
  assert_eq "$(PATH="$with:$PATH" h feature preflight --json | jq -r '.agents.figmaImplementer + " " + .agents.figmaReviewer')" \
    "agent-harness:harness-figma-implementer agent-harness:harness-figma-reviewer"
  without="$(fake_claude_bin 'figma-other: npx x - ✔ Connected')"
  local out
  out="$(PATH="$without:$PATH" h feature preflight --json)"
  assert_eq "$(jq -r '.agents | has("figmaImplementer")' <<<"$out")" "false" "(아는 이름의 Figma MCP 가 없으면 기본 에이전트)"
  assert_contains "$(jq -r '.notes | join(" ")' <<<"$out")" "Figma 링크가 있는 기능(home): Figma MCP"
}

test_figma_agent_definitions_match_known_servers() {
  local servers server tool file
  servers="$(sed -n 's/^readonly FIGMA_MCP_SERVERS="\(.*\)"$/\1/p' "$ROOT/lib/agents.sh")"
  [[ -n "$servers" ]] || fail "FIGMA_MCP_SERVERS 를 찾지 못했다"
  for file in "$ROOT"/agents/harness-figma-*.md; do
    for server in ${servers//|/ }; do
      tool="mcp__${server//:/_}"
      grep -q "^tools:.*\b$tool\b" "$file" || fail "$(basename "$file") 의 tools 에 $tool 이 없다 (FIGMA_MCP_SERVERS 와 짝)"
    done
  done
}

test_review_context_points_to_agreed_design() {
  write_design docs/design/calc.md "사람 결정: 없음"
  h design import docs/design/calc.md >/dev/null
  assert_contains "$(h review --context calc-sub)" "합의된 설계: docs/design/calc.md"
}

test_spring_design_criteria_are_common_and_backend() {
  jq '.preset = "spring"' .harness/project.json > p && mv p .harness/project.json
  local criteria
  criteria="$(h design criteria)"
  assert_contains "$criteria" "C1. 완성의 정의부터"
  assert_contains "$criteria" "B5. 메시지 브로커는 근거가 있을 때만"
  assert_eq "$(grep -c 'F1\.' <<<"$criteria" || true)" "0" "(Spring 에는 프론트엔드 기준이 없다)"
}

test_every_criterion_has_rule_reason_condition_and_check() {
  local file id missing
  for file in "$ROOT"/design/criteria/*.md; do
    while IFS= read -r id; do
      missing="$(awk -v h="$id" 'index($0, h) == 1 { on = 1; next } /^## / { on = 0 } on' "$file" \
        | grep -c -E '^- \*\*(규칙|이유|적용 조건|확인 방법):\*\*' || true)"
      [[ "$missing" -ge 4 ]] || fail "$(basename "$file") 의 '$id' 에 규칙·이유·적용 조건·확인 방법 중 빠진 것이 있다 ($missing/4)"
    done < <(grep -E '^## [A-Z][0-9]+\.' "$file")
  done
}

test_design_criteria_follow_preset_and_project() {
  assert_contains "$(h design criteria)" "C1. 완성의 정의부터"
  assert_eq "$(h design criteria | grep -c 'F1\.' || true)" "0" "(generic 에는 프론트엔드 기준이 없다)"
  jq '.preset = "nextjs"' .harness/project.json > p && mv p .harness/project.json
  assert_contains "$(h design criteria)" "F1. 데이터와 표현을 분리한다"
  mkdir -p docs && echo "# 우리 팀 기준" > docs/team-criteria.md
  jq '.design = {criteria: ["common.md", "frontend.md", "docs/team-criteria.md"]}' .harness/project.json > p && mv p .harness/project.json
  assert_contains "$(h design criteria)" "# 우리 팀 기준"
}

# ── Figma 렌즈 ──────────────────────────────────────────────────────
# fake_uimatch_bin <종료코드> → 가짜 uimatch. 받은 인자를 그 디렉터리의 args 에 남긴다.
fake_uimatch_bin() {
  local dir
  dir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/args"\nexit %s\n' "$dir" "$1" > "$dir/uimatch"
  chmod +x "$dir/uimatch"
  printf '%s\n' "$dir"
}

configure_figma() {
  jq '.figma = {fileKey: "KEY123", components: [
        {name: "button", node: "1-2", url: "http://localhost:6006/iframe.html?id=button", selector: "#root button"},
        {name: "card", node: "3-4", url: "http://localhost:6006/iframe.html?id=card"}]}' \
    .harness/project.json > p && mv p .harness/project.json
}

test_figma_is_off_without_components() {
  assert_contains "$(h figma)" "figma.components 가 비어 있다"
  assert_exit 0 h figma
}

test_figma_skips_without_engine_or_token() {
  configure_figma
  assert_contains "$(PATH="/usr/bin:/bin" h figma)" "UIMatch 가 없다"
  local bin
  bin="$(fake_uimatch_bin 0)"
  assert_contains "$(PATH="$bin:$PATH" FIGMA_ACCESS_TOKEN= h figma)" "FIGMA_ACCESS_TOKEN 이 없다"
  assert_exit 0 env PATH="$bin:$PATH" FIGMA_ACCESS_TOKEN= bash "$HARNESS" figma
}

test_figma_passes_documented_arguments() {
  configure_figma
  local bin
  bin="$(fake_uimatch_bin 0)"
  assert_exit 0 env PATH="$bin:$PATH" FIGMA_ACCESS_TOKEN=figd_x bash "$HARNESS" figma button
  assert_eq "$(paste -sd ' ' "$bin/args")" "compare figma=KEY123:1-2 story=http://localhost:6006/iframe.html?id=button profile=component/strict outDir=$(pwd -P)/.harness/figma/button selector=#root button"
}

test_figma_fails_when_design_diverges() {
  configure_figma
  local bin
  bin="$(fake_uimatch_bin 1)"
  assert_exit 1 env PATH="$bin:$PATH" FIGMA_ACCESS_TOKEN=figd_x bash "$HARNESS" figma
  assert_exit 2 env PATH="$bin:$PATH" FIGMA_ACCESS_TOKEN=figd_x bash "$HARNESS" figma nothing
}

# ── loop 트리거 ─────────────────────────────────────────────────────
# fake_loop_claude <출력> → 가짜 claude. 호출되면 그 디렉터리에 .called 와 stdin(prompt) 을 남긴다.
fake_loop_claude() {
  local dir
  dir="$(mktemp -d)"
  printf '#!/usr/bin/env bash\ntouch "%s/.called"\nprintf "%%s\\n" "$@" > "%s/args"\ncat > "%s/prompt"\necho "%s"\n' "$dir" "$dir" "$dir" "$1" > "$dir/claude"
  chmod +x "$dir/claude"
  printf '%s\n' "$dir"
}

test_loop_run_skips_model_when_nothing_pending() {
  local bin
  bin="$(fake_loop_claude done)"
  assert_exit 0 env PATH="$bin:$PATH" bash "$HARNESS" loop run
  assert_eq "$(test -e "$bin/.called" && echo called || echo skipped)" "skipped" "(할 일이 없으면 토큰 0)"
}

test_loop_run_skips_model_when_preflight_fails() {
  add_feature a "첫째" 'true'
  echo stray > stray.txt
  local bin
  bin="$(fake_loop_claude done)"
  assert_exit 1 env PATH="$bin:$PATH" bash "$HARNESS" loop run
  assert_eq "$(test -e "$bin/.called" && echo called || echo skipped)" "skipped"
}

test_loop_run_invokes_headless_claude_with_workflow() {
  add_feature a "첫째" 'true'
  local bin
  bin="$(fake_loop_claude '{"stopReason":"all-done"}')"
  assert_exit 0 env PATH="$bin:$PATH" bash "$HARNESS" loop run --max 5 --parallel 2 --plugin-dir /opt/harness
  assert_contains "$(cat "$bin/prompt")" '"scriptPath": "'"$(pwd -P)"'/.harness/bin/feature-loop.js"'
  assert_contains "$(cat "$bin/prompt")" '{"maxIterations":5,"parallel":2,"agents":{"runner":"agent-harness:harness-runner"'
  assert_contains "$(paste -sd ' ' "$bin/args")" "-p --output-format text --permission-mode acceptEdits"
  assert_contains "$(paste -sd ' ' "$bin/args")" "--plugin-dir /opt/harness"
  assert_eq "$(ls .harness/runs/*.log | wc -l | tr -d ' ')" "1"
  assert_eq "$(jq -r 'select(.event == "loop-run") | .exitCode' .harness/trace.jsonl)" "0"
  assert_eq "$(test -e .harness/loop.lock && echo left || echo released)" "released"
}

test_loop_run_refuses_second_run_while_locked() {
  add_feature a "첫째" 'true'
  sleep 30 & local holder=$!
  echo "$holder" > .harness/loop.lock
  local bin
  bin="$(fake_loop_claude done)"
  assert_exit 4 env PATH="$bin:$PATH" bash "$HARNESS" loop run
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_exit 0 env PATH="$bin:$PATH" bash "$HARNESS" loop run
}

test_loop_schedule_prints_cron_line_only() {
  local out
  out="$(h loop schedule '*/30 * * * *')"
  assert_contains "$out" "*/30 * * * * cd "
  assert_contains "$out" "loop run >>"
  assert_eq "$(git status --porcelain)" ""
}

# ── 백엔드 코드 기준 ────────────────────────────────────────────────
use_spring() { jq '.preset = "spring"' .harness/project.json > p && mv p .harness/project.json; }

# java_class <경로> <public 메서드 수> [import 줄]
java_class() {
  local path="$1" count="$2" import_line="${3:-}" i
  mkdir -p "$(dirname "$path")"
  {
    echo "package com.shop.order.domain;"
    [[ -n "$import_line" ]] && echo "$import_line"
    echo "public class Order {"
    echo "    public Order() {}"
    echo "    public record Line(long qty) {}"
    for ((i = 1; i <= count; i++)); do echo "    public long amount$i(final long base) { return base; }"; done
    echo "    private void hidden() {}"
    echo "}"
  } > "$path"
}

test_check_warns_on_too_many_public_methods() {
  use_spring
  java_class src/main/java/com/shop/order/domain/Order.java 8
  assert_contains "$(h check src/main/java/com/shop/order/domain/Order.java)" "[methods]"
  assert_contains "$(h check src/main/java/com/shop/order/domain/Order.java)" "public 메서드 8개 > 7"
  java_class src/main/java/com/shop/order/domain/Order.java 7
  assert_eq "$(h check src/main/java/com/shop/order/domain/Order.java | grep -c '\[methods\]' || true)" "0" "(생성자·record 선언은 세지 않는다)"
}

test_check_warns_on_domain_importing_outer_layer() {
  use_spring
  java_class src/main/java/com/shop/order/domain/Order.java 1 "import com.shop.order.infrastructure.JpaOrderRepository;"
  local out
  out="$(h check src/main/java/com/shop/order/domain/Order.java)"
  assert_contains "$out" "[import:domain-outer-layer]"
  assert_exit 0 h check src/main/java/com/shop/order/domain/Order.java
  java_class src/main/java/com/shop/order/domain/Order.java 1 "import com.shop.order.domain.OrderRepository;"
  assert_eq "$(h check src/main/java/com/shop/order/domain/Order.java | grep -c 'import:' || true)" "0"
}

test_check_forbidden_import_can_block() {
  use_spring
  jq '.rules = {forbiddenImports: [{id: "no-infra", files: "*/domain/*.java",
        pattern: "^import[[:space:]]+([A-Za-z0-9_]+\\.)+infrastructure\\.", message: "의존성 방향", severity: "block"}]}' \
    .harness/project.json > p && mv p .harness/project.json
  java_class src/main/java/com/shop/order/domain/Order.java 1 "import com.shop.order.infrastructure.JpaOrderRepository;"
  assert_exit 1 h check src/main/java/com/shop/order/domain/Order.java
}

test_review_criteria_for_spring_include_code_and_design() {
  use_spring
  local out
  out="$(h review --criteria)"
  assert_contains "$out" "K6. 컬렉션에 규칙이 붙으면 일급 컬렉션으로"
  assert_contains "$out" "K8. 디자인 패턴은 조건이 맞을 때만"
  assert_contains "$out" "K9. 설정은 타입 있는 객체로 한곳에서"
  assert_contains "$out" "B2. 의존성 방향을 지킨다"
}

test_review_criteria_always_include_common_code_criteria() {
  local out
  out="$(h review --criteria)"
  assert_contains "$out" "Q1. 정석으로 해결한다 — 땜빵 금지"
  assert_contains "$out" "Q2. 상태 기계는 상태 기계로 만든다"
  assert_contains "$out" "Q3. 동시성 전략은 하나"
  assert_eq "$(grep -c 'K6\.' <<<"$out" || true)" "0" "(generic 에는 Spring 기준이 없다)"
}

test_review_context_carries_code_criteria() {
  use_spring
  add_feature a "첫째" 'true'
  assert_contains "$(h review --context a)" "K4. 객체에 일을 시킨다"
}

# ── 커밋 없이 운용 (loop.autoCommit: false) ─────────────────────────
use_ledger_mode() {
  jq '.loop = ((.loop // {}) + {autoCommit: false})' .harness/project.json > p && mv p .harness/project.json
}

# 커밋을 모두 없앤다(파일은 스테이징된 채로). 보고된 상황: 커밋 0개 저장소
drop_all_commits() { git update-ref -d "$(git symbolic-ref HEAD)"; }

commit_count() { git rev-list --all 2>/dev/null | wc -l | tr -d ' '; }

test_ledger_mode_records_without_any_commit() {
  use_ledger_mode
  add_feature sub "빼기" 'grep -q "const sub" src/math.js'
  drop_all_commits
  assert_exit 0 h feature preflight "(커밋 0개·더러운 트리라도 기준선으로 시작)"
  assert_eq "$(test -s .harness/baseline.json && echo saved)" "saved"
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  verify_and_review sub
  assert_exit 0 h feature record sub
  assert_eq "$(status_of sub)" "passing"
  assert_eq "$(commit_count)" "0" "(커밋을 만들지 않는다)"
  assert_eq "$(git for-each-ref refs/heads refs/harness | wc -l | tr -d ' ')" "0" "(브랜치도 만들지 않는다)"
  assert_eq "$(h baseline show | grep -c 'src/math.js' || true)" "0" "(기록 뒤 기준선이 갱신된다)"
}

test_ledger_mode_review_context_sees_staged_files_without_head() {
  use_ledger_mode
  add_feature a "첫째" 'true'
  drop_all_commits
  h feature preflight >/dev/null 2>&1
  echo 'export const div = (a, b) => a / b;' > src/div.js
  git add src/div.js
  local out
  out="$(h review --context a)"
  assert_contains "$out" "- src/div.js"
  assert_contains "$out" "+export const div"
}

test_ledger_mode_test_guard_compares_with_baseline() {
  use_ledger_mode
  drop_all_commits
  assert_contains "$(h test-guard)" "감시하지 못했다" "(기준선이 없으면 조용히 통과하지 않는다)"
  h baseline save >/dev/null
  delete_lines 'add(0, 0)' tests/math.test.js
  assert_exit 1 h test-guard
  assert_contains "$(h test-guard --json)" '"weakened":true'
}

test_ledger_mode_blocked_feature_is_set_aside_as_patch() {
  use_ledger_mode
  add_feature mul "곱하기" 'grep -q "const mul =" src/math.js'
  h feature preflight >/dev/null 2>&1
  echo 'export const mull = 1;' >> src/math.js
  h feature verify mul >/dev/null 2>&1 || true
  h feature verify mul >/dev/null 2>&1 || true
  assert_eq "$(status_of mul)" "blocked"
  assert_eq "$(parked_ref_of mul)" ".harness/parked/mul.patch"
  assert_contains "$(cat .harness/parked/mul.patch)" "+export const mull = 1;"
  assert_eq "$(grep -c mull src/math.js || true)" "0" "(작업 트리는 기준선으로 되돌아간다)"
  assert_eq "$(commit_count)" "2"
}

test_ledger_mode_risky_feature_waits_and_approve_brings_it_back() {
  use_ledger_mode
  add_feature pay "결제" 'test -f src/payment.js'
  h feature preflight >/dev/null 2>&1
  echo 'export const pay = () => true;' > src/payment.js
  verify_and_review pay
  assert_exit 0 h feature record pay
  assert_eq "$(status_of pay)" "awaiting-approval"
  assert_eq "$(test -e src/payment.js && echo left || echo set-aside)" "set-aside"
  assert_exit 0 h feature approve pay
  assert_eq "$(status_of pay)" "passing"
  assert_eq "$(test -f src/payment.js && echo back)" "back"
  assert_eq "$(test -e .harness/parked/pay.patch && echo left || echo dropped)" "dropped"
  assert_eq "$(commit_count)" "2" "(승인도 커밋하지 않는다)"
}

test_ledger_mode_claimed_scopes_keep_features_apart() {
  use_ledger_mode
  add_feature a "에이" 'test -f src/a.js'
  add_feature b "비" 'test -f src/b.js'
  h feature preflight >/dev/null 2>&1
  echo 'export const a = 1;' > src/a.js
  echo 'export const b = 1;' > src/b.js
  h feature claim a --files src/a.js >/dev/null
  h feature claim b --files src/b.js >/dev/null
  assert_eq "$(h review --context a | grep -c 'src/b.js' || true)" "0" "(a 의 검증에는 b 가 보이지 않는다)"
  verify_and_review a
  h feature record a >/dev/null 2>&1
  assert_eq "$(status_of a)" "passing"
  assert_contains "$(h review --context b)" "- src/b.js" "(a 를 기록해도 b 의 변경은 기준선에 섞이지 않는다)"
  assert_eq "$(jq -c '.features[] | select(.id == "a") | .scope' .harness/features.json)" "null" "(기록하면 범위를 지운다)"
}

test_adopt_is_refused_in_ledger_mode() {
  use_ledger_mode
  add_feature a "에이" 'true'
  assert_exit 2 h feature adopt a harness/wip-a
}

test_feature_commit_is_an_alias_of_record() {
  add_feature sub "빼기" 'true'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  verify_and_review sub
  assert_exit 0 h feature commit sub
  assert_eq "$(status_of sub)" "passing"
}

test_review_reject_requires_reason_and_records_failure() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  assert_exit 2 h feature review sub --reject
  assert_exit 0 h feature review sub --reject --reason "플래그로 흉내 낸 상태 기계"
  assert_eq "$(status_of sub)" "pending"
  assert_eq "$(field_of sub lastFailure)" "리뷰 반려: 플래그로 흉내 낸 상태 기계"
}

# ── 검증 대조표 ─────────────────────────────────────────────────────
# full_checklist [위반ID] → 대조표 항목 전부를 채운 JSON (위반ID 하나는 violated)
full_checklist() {
  h review --context "$1" | sed -n '/^## 대조표 항목/,/^$/p' | sed -n 's/^- \([A-Z][A-Z0-9]*\): .*/\1/p' \
    | jq -Rsc --arg bad "${2:-}" 'split("\n") | map(select(length > 0))
        | {checks: map(if . == $bad then {id: ., result: "violated", where: "src/math.js:2", note: "플래그로 흉내 낸 상태"}
                       else {id: ., result: "kept", where: "", note: "확인함"} end),
           summary: "요약"}'
}

test_review_checklist_all_kept_approves() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  assert_exit 0 h feature review sub --verdict-json "$(full_checklist sub)"
  assert_eq "$(status_of sub)" "reviewed"
  assert_eq "$(jq -r '.features[0].lastReview.checks | length' .harness/features.json)" "9" "(REQ·REG·Q1~Q7 대조표가 원장에 남는다)"
}

test_review_checklist_violation_rejects_with_location() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  h feature review sub --verdict-json "$(full_checklist sub Q2)" >/dev/null
  assert_eq "$(status_of sub)" "pending"
  assert_eq "$(field_of sub lastFailure)" "리뷰 반려: Q2 src/math.js:2 — 플래그로 흉내 낸 상태"
}

test_review_checklist_with_missing_items_rejects() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  h feature review sub --verdict-json '{"checks":[{"id":"REQ","result":"kept"},{"id":"REG","result":"kept"}],"summary":"승인"}' >/dev/null
  assert_eq "$(status_of sub)" "pending" "(대조표를 건너뛰면 승인하지 않는다)"
  assert_contains "$(field_of sub lastFailure)" "검증 대조표에 빠진 항목: Q1, Q2"
}

test_review_checklist_bad_shape_rejects() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  h feature review sub --verdict-json '{"approved": true}' >/dev/null
  assert_contains "$(field_of sub lastFailure)" "검증 대조표 형식이 틀렸다"
}

test_review_checklist_from_file() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  mkdir -p .harness/verdicts
  full_checklist sub > .harness/verdicts/sub.json   # 검증 프롬프트가 알려 주는 자리 (비교 대상 밖)
  assert_exit 0 h feature review sub --verdict-file .harness/verdicts/sub.json
  assert_eq "$(status_of sub)" "reviewed"
}

# ── 프로젝트 기준 ───────────────────────────────────────────────────
test_project_criteria_join_checklist_and_prompts() {
  add_feature sub "빼기" 'true'
  h criteria add --title "같은 정보를 두 번 담지 않는다" --rule "한 값은 한 필드에만" >/dev/null
  h criteria add --title "버튼 차단은 공용 처리 하나로" --rule "화면마다 다르게 막지 않는다" >/dev/null
  assert_contains "$(h criteria list)" "P2    버튼 차단은 공용 처리 하나로"
  assert_contains "$(h review --context sub)" "- P1: 같은 정보를 두 번 담지 않는다"
  assert_contains "$(h prompt implement sub)" "## P2. 버튼 차단은 공용 처리 하나로"
  assert_contains "$(h review --criteria)" "## P1. 같은 정보를 두 번 담지 않는다"
}

test_criteria_add_requires_title_and_rule() {
  assert_exit 2 h criteria add --title "제목만"
}

# ── 표준 프롬프트 ───────────────────────────────────────────────────
test_prompt_implement_carries_everything_useful() {
  h feature add --id cache --desc "캐싱" --acceptance false --design docs/design/c.md \
    --decisions-json '[{"question":"D1 저장소","answer":"Redis"}]' >/dev/null
  git add -A && git commit -qm "add cache"
  h feature verify cache >/dev/null 2>&1 || true
  local out
  out="$(h prompt implement cache)"
  assert_contains "$out" "설계 문서: docs/design/c.md"
  assert_contains "$out" "- D1 저장소 → Redis"
  assert_contains "$out" "[직전 시도 실패"
  assert_contains "$out" "## Q3. 동시성 전략은 하나"
  assert_eq "$(h feature brief cache)" "$out" "(brief 는 prompt implement 와 같다)"
}

test_prompt_review_is_self_contained() {
  add_feature sub "빼기" 'true'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  local out
  out="$(h prompt review sub)"
  assert_contains "$out" "독립 검증자"
  assert_contains "$out" "feature review sub --verdict-file"
  assert_contains "$out" "## 대조표 항목"
  assert_contains "$out" "+export const sub"
}

# ── 검증 후 변경 (drift) ────────────────────────────────────────────
pass_feature() {  # pass_feature <id> — 게이트·검증·기록까지
  verify_and_review "$1"
  h feature record "$1" >/dev/null 2>&1
}

test_drift_catches_edit_after_verification() {
  use_ledger_mode
  add_feature sub "빼기" 'grep -q "const sub" src/math.js'
  h feature preflight >/dev/null 2>&1
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  pass_feature sub
  assert_eq "$(jq -r '.features[0].verifiedFiles | keys | join(",")' .harness/features.json)" "src/math.js"
  assert_contains "$(h feature drift)" "검증 후 바뀐 기능 없음"
  echo '// 상태바 손질' >> src/math.js
  assert_contains "$(h feature drift)" "- sub: src/math.js"
  h feature preflight >/dev/null 2>&1
  assert_eq "$(status_of sub)" "pending" "(다음 루프가 다시 검증하도록 대기열로)"
  assert_eq "$(field_of sub lastFailure)" "검증 후 변경됨: src/math.js"
}

test_drift_ignores_changes_verified_by_a_later_feature() {
  use_ledger_mode
  add_feature sub "빼기" 'grep -q "const sub" src/math.js'
  add_feature mul "곱하기" 'grep -q "const mul" src/math.js'
  h feature preflight >/dev/null 2>&1
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  pass_feature sub
  echo 'export const mul = (a, b) => a * b;' >> src/math.js
  pass_feature mul
  assert_contains "$(h feature drift)" "검증 후 바뀐 기능 없음" "(mul 이 같은 파일을 고쳤지만 그 변경은 검증됐다)"
}

test_drift_reopens_in_commit_mode_audit() {
  add_feature sub "빼기" 'grep -q "const sub" src/math.js'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  pass_feature sub
  assert_eq "$(git status --porcelain)" "" "(통과 표시와 검증 해시가 커밋에 같이 담긴다)"
  echo '// 손질' >> src/math.js
  assert_exit 1 h feature audit   # acceptance 는 통과해도 검증 후 변경이면 실패
  assert_eq "$(status_of sub)" "pending"
  assert_eq "$(field_of sub lastFailure)" "검증 후 변경됨: src/math.js"
}

test_hook_warns_when_editing_verified_file() {
  use_ledger_mode
  add_feature sub "빼기" 'grep -q "const sub" src/math.js'
  h feature preflight >/dev/null 2>&1
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  pass_feature sub
  echo '// 손질' >> src/math.js
  local out
  out="$(hook_input "$PWD/src/math.js" | CLAUDE_PROJECT_DIR="$PWD" h hook post-edit)"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "이미 검증을 통과한 기능(sub)의 파일이다"
}

# ── 같은 트리의 기록·보관 (현장 보고 D) ─────────────────────────────
test_unscoped_feature_stops_when_another_is_in_this_tree() {
  use_ledger_mode
  jq '.approval.riskGlobs = ["*payment*"]' .harness/project.json > p && mv p .harness/project.json
  add_feature a "에이" 'true'
  add_feature b "비" 'true'
  h feature preflight >/dev/null 2>&1
  h prompt implement a >/dev/null; echo 'a' > src/a.js
  h prompt implement b >/dev/null; echo 'pay' > src/payment.js
  assert_exit 2 h feature verify a   # b 가 같은 트리에서 구현 중이다
  assert_contains "$(h feature verify a 2>&1)" "범위 미지정 — 기록 전인 다른 기능(b)"
  assert_eq "$(status_of a)" "pending"
  assert_eq "$(ls src | tr '\n' ' ')" "a.js math.js payment.js " "(아무 파일도 치우지 않았다)"
  assert_eq "$(ls .harness/parked 2>/dev/null)" ""
}

test_review_reopens_when_tree_changed_after_gate() {
  use_ledger_mode
  jq '.approval.riskGlobs = ["*payment*"]' .harness/project.json > p && mv p .harness/project.json
  add_feature a "에이" 'true'
  h feature preflight >/dev/null 2>&1
  echo 'a' > src/a.js
  h feature verify a >/dev/null 2>&1
  echo 'pay' > src/payment.js   # 프롬프트 없이 손으로 다른 작업이 섞였다
  assert_exit 1 h feature review a --approve
  assert_eq "$(field_of a lastFailure)" "게이트 후 변경됨 — 게이트 때 본 변경과 지금 트리가 다르다"
  assert_eq "$(ls .harness/parked 2>/dev/null)" ""
}

test_claimed_features_record_in_the_same_tree() {
  use_ledger_mode
  add_feature a "에이" 'true'
  add_feature b "비" 'true'
  h feature preflight >/dev/null 2>&1
  echo 'a' > src/a.js; echo 'b' > src/b.js
  h feature claim a --files src/a.js >/dev/null
  h feature claim b --files src/b.js >/dev/null
  verify_and_review a; verify_and_review b
  assert_exit 0 h feature record a
  assert_exit 0 h feature record b
  assert_eq "$(status_of b)" "passing"
}

test_claim_refuses_file_in_another_scope() {
  use_ledger_mode
  add_feature a "에이" 'true'
  add_feature b "비" 'true'
  h feature claim a --files src/shared.js,src/a.js >/dev/null
  assert_exit 1 h feature claim b --files src/b.js,src/shared.js
  assert_eq "$(h feature claim b --files src/shared.js --json | jq -r .result)" "overlap"
  assert_eq "$(jq -c '.features[1].scope' .harness/features.json)" "null" "(겹치면 범위를 적지 않는다)"
  assert_exit 0 h feature claim b --files src/b.js
}

test_record_refuses_when_reviewed_change_is_gone() {
  use_ledger_mode
  add_feature sub "빼기" 'true'
  h feature preflight >/dev/null 2>&1
  echo 'export const sub = (a, b) => a - b;' > src/sub.js
  verify_and_review sub
  rm src/sub.js
  assert_exit 1 h feature record sub
  assert_eq "$(status_of sub)" "pending"
  assert_eq "$(field_of sub lastFailure)" "기록할 변경이 없다 — 변경이 다른 기능에 보관됐거나 되돌려졌다"
}

test_record_refuses_when_changed_after_review() {
  add_feature sub "빼기" 'true'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  verify_and_review sub
  echo '// 검토 뒤 손질' >> src/math.js
  assert_exit 1 h feature record sub
  assert_eq "$(field_of sub lastFailure)" "검토 후 변경됨 — 검토 때 본 변경과 지금 트리가 다르다"
}

test_review_prompt_survives_diff_larger_than_limit() {
  jq '.review.maxDiffLines = 5' .harness/project.json > p && mv p .harness/project.json
  add_feature a "에이" 'true'
  big_file src/Big.kt 20000
  h feature verify a >/dev/null 2>&1
  local out
  out="$(h prompt review a)"
  assert_contains "$out" "## 대조표 항목"
  assert_contains "$out" "줄 중 5줄만 보였다"
}

test_gitignored_harness_dir_does_not_warn() {
  use_ledger_mode
  echo ".harness" > .gitignore
  add_feature sub "빼기" 'true'
  h feature preflight >/dev/null 2>&1
  echo 'x' > src/sub.js
  local out
  out="$(h feature verify sub 2>&1)"
  [[ "$out" != *"ignored"* ]] || fail "ignore 경고가 나왔다: $out"
}

test_check_sees_untracked_files_without_commits() {
  use_ledger_mode
  drop_all_commits
  git rm -q -r --cached . >/dev/null
  h feature preflight >/dev/null 2>&1
  echo '// TODO: 나중에' > src/stub.js
  assert_exit 1 h check
  assert_exit 1 h check --all
  assert_exit 0 h check --staged
}

# ── 실행 렌즈 ───────────────────────────────────────────────────────
# 가짜 명령으로 실행 렌즈를 켠다. setup_cmd 가 실패하면 그 단계에서 멈춘다.
enable_runtime() {
  local setup_cmd="${1:-echo 설치됨}"
  jq --arg setup "$setup_cmd" '.runtime = {enabled: true, appId: "com.example.app",
      setup: [{name: "설치", command: $setup}, {name: "실행", command: "echo {appId} 실행 >> {dir}/launched"}],
      screens: [{name: "첫 화면", command: "printf PNG > {out}"}, {name: "설정", command: "printf PNG > {out}"}],
      log: "echo W/App: 경고 하나",
      teardown: [{name: "종료", command: "echo 종료"}]}' .harness/project.json > p && mv p .harness/project.json
}

test_runtime_lens_runs_as_last_gate_and_feeds_review() {
  enable_runtime
  add_feature a "에이" 'true'
  assert_exit 0 h feature verify a
  local dir
  dir="$(jq -r '.features[0].lastRun.dir' .harness/features.json)"
  assert_eq "$(ls "$dir"/*.png | wc -l | tr -d ' ')" "2"
  assert_contains "$(cat "$dir/launched")" "com.example.app 실행" "({appId}·{dir} 치환)"
  local out
  out="$(h review --context a)"
  assert_contains "$out" "## 실행 확인"
  assert_contains "$out" "스크린샷: $dir/01-첫_화면.png"
  assert_contains "$out" "W/App: 경고 하나"
}

test_runtime_lens_failure_fails_gate() {
  enable_runtime "exit 3"
  add_feature a "에이" 'true'
  assert_exit 1 h feature verify a
  assert_eq "$(field_of a lastFailure)" "실행 확인 실패"
  assert_eq "$(jq -r '.features[0].lastRun.failedStep' .harness/features.json)" "설치"
}

test_runtime_lens_is_off_by_default() {
  add_feature a "에이" 'true'
  assert_exit 0 h feature verify a
  assert_eq "$(jq -r '.features[0].lastRun // "없음"' .harness/features.json)" "없음"
}

# ── 기준 버전 ───────────────────────────────────────────────────────
test_review_warns_when_criteria_changed_after_implementation() {
  add_feature sub "빼기" 'true'
  h prompt implement sub >/dev/null
  assert_eq "$(jq -r '.features[0].implementedUnder.criteriaIds | length' .harness/features.json)" "7" "(Q1~Q7)"
  assert_eq "$(h prompt review sub | grep -c '기준이 다르다' || true)" "0" "(기준이 그대로면 알리지 않는다)"
  h criteria add --title "같은 정보를 두 번 담지 않는다" --rule "한 값은 한 필드에만" >/dev/null
  assert_contains "$(h prompt review sub)" "구현 뒤에 추가된 항목: P1"
}

test_prompt_records_attempt_and_one_shot_rule() {
  add_feature sub "빼기" 'false'
  assert_contains "$(h prompt implement sub)" "[기능 sub · 시도 1 · 구현 전용] 이 지시 하나만 처리하고 끝낸다"
  h feature verify sub >/dev/null 2>&1 || true
  assert_contains "$(h prompt implement sub)" "시도 2"
  assert_contains "$(h prompt review sub)" "검증 전용"
}

# ── 빌드 잠금 ───────────────────────────────────────────────────────
test_lock_runs_command_and_releases() {
  assert_exit 0 h lock run -- true
  assert_exit 1 h lock run -- false "(명령의 종료 코드를 그대로 돌려준다)"
  assert_eq "$(test -e .harness/build.lock && echo held || echo released)" "released"
}

test_lock_reclaims_stale_lock() {
  mkdir -p .harness/build.lock && echo 999999 > .harness/build.lock/pid
  assert_exit 0 h lock run -- true "(죽은 프로세스의 잠금은 회수한다)"
}

test_lock_waits_for_holder() {
  mkdir -p .harness/build.lock
  sleep 3 & local holder=$!
  echo "$holder" > .harness/build.lock/pid
  ( sleep 2; rm -rf .harness/build.lock ) &
  local start end
  start="$(date +%s)"
  assert_exit 0 h lock run -- true
  end="$(date +%s)"
  (( end - start >= 1 )) || fail "잠금을 기다리지 않았다"
  kill "$holder" 2>/dev/null; wait 2>/dev/null
}

# ── 구현자 지시문 ────────────────────────────────────────────────────
test_brief_is_the_single_implementer_prompt() {
  add_feature sub "빼기" 'true'
  local seq iso shared
  seq="$(h feature brief sub)"
  assert_contains "$seq" "기능 id: sub"
  assert_contains "$seq" "# 품질 기준 (검증 대조표 항목 · 기준 버전"
  assert_contains "$seq" "Q1. 정석으로 해결한다"
  assert_contains "$seq" "git commit 하지 않는다"
  iso="$(h feature brief sub --mode isolated --json | jq -r .prompt)"
  assert_contains "$iso" "git checkout -q -b harness/wip-sub"
  shared="$(h feature brief sub --mode shared)"
  assert_contains "$shared" ".harness/bin/harness lock run --"
  assert_contains "$shared" "filesChanged"
  assert_exit 2 h feature brief sub --mode nope
}

test_brief_carries_decisions_and_last_failure() {
  h feature add --id cache --desc "캐싱" --acceptance false --decisions-json '[{"question":"D1 저장소","answer":"Redis"}]' >/dev/null
  git add -A && git commit -qm "add cache"
  h feature verify cache >/dev/null 2>&1 || true
  local out
  out="$(h feature brief cache)"
  assert_contains "$out" "- D1 저장소 → Redis"
  assert_contains "$out" "[직전 시도 실패"
  assert_contains "$out" "구조로 해결"
}

# ── 로컬 전용 설치 ──────────────────────────────────────────────────
# 하네스 흔적을 지우고 깨끗한 커밋 상태에서 다시 끼운다
reinstall() { rm -rf .harness .claude .gitignore; git add -A; git commit -qm "하네스 제거" 2>/dev/null || true; h init --no-git-hooks "$@" >/dev/null 2>&1; }

test_init_local_touches_no_tracked_file() {
  reinstall --local
  assert_eq "$(git status --porcelain)" "" "(추적 대상 파일이 하나도 바뀌지 않는다)"
  assert_contains "$(cat .git/info/exclude)" ".harness/"
  assert_contains "$(cat .git/info/exclude)" ".claude/settings.local.json"
  assert_eq "$(jq -r '.enabledPlugins["agent-harness@agent-harness"]' .claude/settings.local.json)" "true"
  assert_eq "$(test -e .claude/settings.json && echo exists || echo absent)" "absent"
  assert_eq "$(h config -r .design.docsDir)" ".harness/design"
  assert_eq "$(h design new calc)" ".harness/design/calc.md"
  assert_eq "$(git status --porcelain)" "" "(설계 문서도 git 에 잡히지 않는다)"
}

test_init_no_commit_sets_ledger_mode() {
  reinstall --local --no-commit
  assert_eq "$(h config '.loop.autoCommit')" "false"
}

test_init_local_refuses_ci_templates() {
  rm -rf .harness
  assert_exit 2 h init --local --ci --no-git-hooks
}

# ── 스택 감지 ───────────────────────────────────────────────────────
detected_preset() { rm -f .harness/project.json; h init --no-git-hooks --no-plugin 2>&1 | sed -n 's/.*(preset: \([a-z]*\)).*/\1/p' | head -1; }

test_detect_android_by_manifest() {
  mkdir -p app/src/main && echo '<manifest/>' > app/src/main/AndroidManifest.xml
  touch build.gradle.kts
  assert_eq "$(detected_preset)" "android" "(루트 build.gradle.kts 가 있어도 Spring 이 아니다)"
}

test_detect_android_by_gradle_plugin() {
  echo 'plugins { id("com.android.application") }' > build.gradle.kts
  assert_eq "$(detected_preset)" "android"
}

test_detect_spring_only_with_spring_boot_plugin() {
  echo 'plugins { id("org.springframework.boot") version "3.3.0" }' > build.gradle.kts
  assert_eq "$(detected_preset)" "spring"
  echo 'plugins { kotlin("jvm") }' > build.gradle.kts
  assert_eq "$(detected_preset)" "generic" "(Spring 이 아닌 Gradle 은 generic)"
}

# ── 언어별 stub ─────────────────────────────────────────────────────
test_check_blocks_language_stubs() {
  printf 'fun load(): Int = TODO()\n' > src/A.kt
  assert_exit 1 h check src/A.kt
  printf 'fun save() { throw NotImplementedError() }\n' > src/B.kt
  assert_exit 1 h check src/B.kt
  printf 'def run():\n    raise NotImplementedError\n' > src/c.py
  assert_exit 1 h check src/c.py
  printf 'fun ok() = myTODO(1)\nval s = "TODOS"\n' > src/D.kt
  assert_exit 0 h check src/D.kt "(식별자 안의 TODO 는 아니다)"
}

# ── Android 기준과 크기 ─────────────────────────────────────────────
test_android_review_criteria_include_common_and_android() {
  jq '.preset = "android"' .harness/project.json > p && mv p .harness/project.json
  local out
  out="$(h review --criteria)"
  assert_contains "$out" "Q2. 상태 기계는 상태 기계로 만든다"
  assert_contains "$out" "A5. 하드웨어와 외부 콜백은 한 경계 안에 가둔다"
}

big_file() { local i; for ((i = 1; i <= $2; i++)); do echo "val v$i = $i"; done > "$1"; }

test_review_context_reports_grown_oversized_files() {
  jq '.rules = {maxFileLines: 10}' .harness/project.json > p && mv p .harness/project.json
  add_feature a "에이" 'true'
  big_file src/Big.kt 30
  local out
  out="$(h review --context a)"
  assert_contains "$out" "## 게이트 경고"
  assert_contains "$out" "src/Big.kt: 30줄 > 10 (새 파일)"
}

test_size_policy_block_growth_blocks_only_grown_files() {
  big_file src/Old.kt 30
  git add -A && git commit -qm "기존 큰 파일"
  jq '.rules = {maxFileLines: 10, sizePolicy: "block-growth"}' .harness/project.json > p && mv p .harness/project.json
  add_feature a "에이" 'true'
  echo "// 작은 수정" > src/small.kt
  assert_exit 0 h feature verify a "(손대지 않은 기존 큰 파일은 막지 않는다)"
  h feature review a --approve >/dev/null && h feature record a >/dev/null
  add_feature b "비" 'true'
  big_file src/Old.kt 31
  assert_exit 1 h feature verify b
  assert_eq "$(field_of b lastFailure)" "크기 초과 실패"
}

test_size_policy_warn_does_not_block() {
  jq '.rules = {maxFileLines: 10}' .harness/project.json > p && mv p .harness/project.json
  add_feature a "에이" 'true'
  big_file src/Big.kt 30
  assert_exit 0 h feature verify a
}

# ── 훅 ──────────────────────────────────────────────────────────────
hook_input() { jq -cn --arg p "$1" '{tool_input: {file_path: $p}}'; }

test_hook_pre_edit_denies_ledger() {
  local out
  out="$(hook_input "$PWD/.harness/features.json" | CLAUDE_PROJECT_DIR="$PWD" h hook pre-edit)"
  assert_eq "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "deny"
}

test_hook_pre_edit_allows_source() {
  local out
  out="$(hook_input "$PWD/src/math.js" | CLAUDE_PROJECT_DIR="$PWD" h hook pre-edit)"
  assert_eq "$out" ""
}

test_hook_pre_edit_is_silent_without_governing_map() {
  assert_eq "$(hook_input "$PWD/src/math.js" | CLAUDE_PROJECT_DIR="$PWD" h hook pre-edit)" ""
}

test_hook_pre_edit_points_to_governing_docs() {
  jq '.governingDoc = {map: [{globs: ["src/pay*"], docs: ["docs/PAY.md"]}, {globs: ["src/*"], docs: ["docs/CORE.md"]}],
                       alwaysForExtension: {js: ["AGENTS.md"]}}' .harness/project.json > p && mv p .harness/project.json
  local out
  out="$(hook_input "$PWD/src/payment.js" | CLAUDE_PROJECT_DIR="$PWD" h hook pre-edit)"
  assert_eq "$(jq -r .hookSpecificOutput.additionalContext <<<"$out" | grep -o 'docs/PAY.md · AGENTS.md')" "docs/PAY.md · AGENTS.md" "(첫 매치 + 확장자 문서)"
  assert_eq "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out")" "none" "(막지 않는다)"
  out="$(hook_input "$PWD/src/math.js" | CLAUDE_PROJECT_DIR="$PWD" h hook pre-edit)"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "docs/CORE.md"
}

test_hook_post_edit_feeds_back_stub() {
  echo '// TODO: 나중에' >> src/math.js
  local out
  out="$(hook_input "$PWD/src/math.js" | CLAUDE_PROJECT_DIR="$PWD" h hook post-edit)"
  assert_eq "$(jq -r .decision <<<"$out")" "block"
  assert_contains "$(jq -r .reason <<<"$out")" "[stub]"
}

test_hook_session_injects_ledger_summary() {
  add_feature sub "빼기" 'true'
  local out
  out="$(CLAUDE_PROJECT_DIR="$PWD" h hook session < /dev/null)"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "다음: sub — 빼기"
}

test_hooks_are_silent_without_harness() {
  rm -rf .harness
  local out
  out="$(hook_input "$PWD/src/math.js" | CLAUDE_PROJECT_DIR="$PWD" h hook post-edit)"
  assert_eq "$out" ""
  assert_exit 0 h check --all
}

# ── review 컨텍스트 ─────────────────────────────────────────────────
test_review_context_includes_diff_and_new_files() {
  add_feature sub "빼기" 'true'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  echo 'export const div = (a, b) => a / b;' > src/div.js
  local out
  out="$(h review --context sub)"
  assert_contains "$out" "# 검증 프로토콜"
  assert_contains "$out" "+export const sub"
  assert_contains "$out" "+export const div"
}

# ── git 래퍼 ────────────────────────────────────────────────────────
test_git_wrapper_blocks_no_verify() {
  echo 'x' > new.txt && git add new.txt
  assert_exit 1 "$ROOT/guard/bin/git" commit --no-verify -m x
  assert_exit 1 "$ROOT/guard/bin/git" commit -n -m x
  assert_exit 0 "$ROOT/guard/bin/git" commit -qm x
}

# ── 실행 ────────────────────────────────────────────────────────────
echo "harness tests"
for name in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_test "$name"
done
echo
echo "통과 $PASSED · 실패 $FAILED"
[[ "$FAILED" -eq 0 ]] || { printf '실패: %s\n' "${FAILED_NAMES[@]}"; exit 1; }
