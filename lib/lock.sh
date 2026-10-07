#!/usr/bin/env bash
#
# lock.sh — 빌드 잠금. source 전용.
#   같은 작업 트리에서 여러 에이전트가 빌드·테스트를 동시에 돌리면 빌드 도구가 충돌한다.
#   디렉터리 생성(mkdir)은 원자적이라 잠금으로 쓴다. 잡은 프로세스가 죽었으면 잠금을 회수한다.
#

build_lock_dir() { printf '%s\n' "$PROJECT_HARNESS_DIR/build.lock"; }

lock_holder_pid() { cat "$(build_lock_dir)/pid" 2>/dev/null || true; }

reclaim_stale_build_lock() {
  local pid
  pid="$(lock_holder_pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  rm -rf "$(build_lock_dir)"
}

acquire_build_lock() {  # acquire_build_lock → 시간 안에 못 잡으면 1
  local waited=0 timeout
  timeout="$(cfg '.loop.buildLockTimeoutSeconds')"
  mkdir -p "$PROJECT_HARNESS_DIR"
  until mkdir "$(build_lock_dir)" 2>/dev/null; do
    reclaim_stale_build_lock
    (( waited >= timeout )) && return 1
    sleep 1
    waited=$((waited + 1))
  done
  echo "$$" > "$(build_lock_dir)/pid"
}

release_build_lock() { rm -rf "$(build_lock_dir)"; }

# with_build_lock <명령 문자열> — 잠금을 잡고 실행한 뒤 놓는다. 명령의 종료 코드를 돌려준다.
with_build_lock() {
  local code=0
  acquire_build_lock || { info "⏳ 빌드 잠금을 $(cfg '.loop.buildLockTimeoutSeconds')초 안에 잡지 못했다 (pid $(lock_holder_pid))"; return 1; }
  bash -c "$1" || code=$?
  release_build_lock
  return "$code"
}
