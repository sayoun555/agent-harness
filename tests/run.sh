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
fail() { printf '    ✗ %s\n' "$*"; return 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "기대 '$2', 실제 '$1' ${3:-}"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "'$2' 가 없다: ${1:0:300}"; }
assert_exit() {  # assert_exit <expected> <command...>
  local expected="$1"; shift
  "$@" >/dev/null 2>&1
  local actual=$?
  [[ "$actual" == "$expected" ]] || fail "종료 코드 기대 $expected, 실제 $actual: $*"
}

run_test() {  # run_test <name>
  local name="$1" dir
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return
  dir="$(pwd)"
  make_project
  local project="$PWD"
  if ( set -e; "$name" ); then
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

test_feature_verify_pass_then_commit_marks_passing() {
  add_feature sub "빼기" 'grep -q "sub" src/math.js'
  echo 'export const sub = (a, b) => a - b;' >> src/math.js
  assert_exit 0 h feature verify sub
  assert_eq "$(status_of sub)" "verified"
  assert_exit 0 h feature commit sub
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
  h feature verify pay >/dev/null 2>&1
  assert_exit 0 h feature commit pay
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
  h feature verify sub >/dev/null 2>&1
  assert_exit 1 h feature commit sub
  assert_eq "$(status_of sub)" "verified" "(원장이 되돌아가야 함)"
  assert_eq "$(git log -1 --format=%s)" "add sub"
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
  h feature verify sub >/dev/null 2>&1 && h feature commit sub >/dev/null 2>&1
  delete_lines 'sub' src/math.js
  assert_exit 1 h feature audit
  assert_eq "$(status_of sub)" "pending"
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

test_trace_records_each_node() {
  add_feature sub "빼기" 'true'
  h feature verify sub >/dev/null 2>&1
  h feature commit sub >/dev/null 2>&1
  assert_eq "$(jq -r .event .harness/trace.jsonl | paste -sd, -)" "verify,commit"
  assert_contains "$(h trace summary)" "commit"
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
  assert_contains "$out" "의미 적대자 프로토콜"
  assert_contains "$out" "+export const sub"
  assert_contains "$out" "신규 파일: src/div.js"
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
