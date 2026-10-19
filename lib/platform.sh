#!/usr/bin/env bash
#
# platform.sh — OS 차이를 한곳에서 흡수한다. common.sh 와 테스트가 source 한다.
#   이 파일은 source 전용이다. 직접 실행하지 않는다.
#

# Windows(Git Bash · MSYS2 · Cygwin)의 네이티브 jq.exe 는 줄 끝을 CRLF 로 낸다.
#   $(jq -r …) 로 받은 값 끝에 \r 이 붙어 경로 · 상태 비교가 모두 어긋난다. --binary 는 LF 그대로 낸다.
#   $OSTYPE 은 bash 변수라 프로세스를 띄우지 않는다(Windows 에서는 프로세스 하나가 비싸다).
case "${OSTYPE:-}" in
  msys*|cygwin*) jq() { command jq --binary "$@"; } ;;
esac
