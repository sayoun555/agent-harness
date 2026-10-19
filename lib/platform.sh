#!/usr/bin/env bash
#
# platform.sh — OS 차이를 한곳에서 흡수한다. common.sh 와 테스트가 source 한다.
#   이 파일은 source 전용이다. 직접 실행하지 않는다.
#

# Windows 의 bash(Git Bash · MSYS2 · Cygwin)인가. $OSTYPE 은 bash 변수라 프로세스를 띄우지 않는다
# (Windows 에서는 프로세스 하나가 비싸다).
WINDOWS_SHELL=0
case "${OSTYPE:-}" in msys*|cygwin*) WINDOWS_SHELL=1 ;; esac

# 네이티브 jq.exe 는 줄 끝을 CRLF 로 낸다. $(jq -r …) 로 받은 값 끝에 \r 이 붙어 경로 · 상태 비교가
# 모두 어긋난다. --binary 는 LF 그대로 낸다.
if [[ "$WINDOWS_SHELL" -eq 1 ]]; then jq() { command jq --binary "$@"; }; fi

# 내용의 SHA-1. macOS · 리눅스에는 shasum(perl)이 있고, Git Bash 에는 sha1sum 만 있다.
#   둘의 출력은 같다 — 원장에 이미 적힌 해시(기준 버전 · 실패 지문)가 OS 를 옮겨도 그대로 맞는다.
SHA1_COMMAND=shasum
command -v shasum >/dev/null 2>&1 || SHA1_COMMAND=sha1sum
