#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
[ "$EUID" -eq 0 ] || { echo '관리자 권한으로 실행해 주세요.' >&2; exit 1; }
BASE='/Library/Application Support/Awake'
if [ -x "$BASE/lidawake" ]; then "$BASE/lidawake" off; fi
launchctl bootout system/io.paul.awake.lidawake 2>/dev/null || true
rm -f /Library/LaunchDaemons/io.paul.awake.lidawake.plist
rm -f /etc/sudoers.d/awake-lidawake-*
rm -f "$BASE/lidawake" "$BASE/lidawake-watchdog"
rmdir "$BASE" 2>/dev/null || true
echo 'Awake의 관리자 도구를 제거했습니다. 기존 lidawake 설치는 유지됩니다.'
